/*
 * Two-thread stress harness for CTapProbe (Step 6a). Built by scripts/tsan-tapprobe.sh with clang -fsanitize=thread.
 *
 *  - The WRITER thread plays the role of Core Audio's IO thread: it calls SATapProbeIOProc (the real C callback) `kCalls`
 *    times on synthetic buffers whose content is a pure function of the call index, with capacity for fewer records than calls.
 *  - The READER thread plays the control thread: it polls SATapProbeCommitted and reads every newly published record with
 *    SATapProbeReadRecord WHILE the writer is still writing, and checks each record against what call number `i` must have stored.
 *  - Step 6a3: every call also carries an input timestamp whose validity cycles with the call index (both valid, host only, sample only,
 *    none), so the check covers inputHostTime, inputSampleTime and the validity bits of the flags as well: a torn record, a field from another
 *    call, or a field published early is a wrong record.
 *
 * Exit 0 = every record was whole, in order, nothing was published early, overflow was counted. TSan exits 66 on a data race.
 * No sleeps: the reader spins until the writer says it is done (a completion flag), then drains.
 */
#include "CTapProbe.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

#define kCapacity 200000u
#define kCalls    (kCapacity + 1000u)
#define kFrames   8u

static SATapProbe *gProbe;
static atomic_bool gWriterDone;

static float levelFor(uint32_t i) { return (float)((i % 7u) + 1u) / 8.0f; }

/* The input timestamp call i carries: values are pure functions of i; validity cycles through all four combinations. */
static uint64_t inputHostFor(uint32_t i)   { return 1000000u + 3u * (uint64_t)i; }
static double   inputSampleFor(uint32_t i) { return 8.0 * (double)i; }
static bool     hostValidFor(uint32_t i)   { return (i % 4u) == 0u || (i % 4u) == 1u; }
static bool     sampleValidFor(uint32_t i) { return (i % 4u) == 0u || (i % 4u) == 2u; }
static uint32_t expectedFlags(uint32_t i) {
    return (hostValidFor(i) ? 0u : SA_TAP_FLAG_INPUT_HOST_TIME_INVALID) | (sampleValidFor(i) ? 0u : SA_TAP_FLAG_INPUT_SAMPLE_TIME_INVALID);
}

static void *writer(void *arg) {
    (void)arg;
    float samples[kFrames];
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 1;
    list.mBuffers[0].mDataByteSize = sizeof samples;
    list.mBuffers[0].mData = samples;
    AudioBufferList out = { 0 };
    for (uint32_t i = 0; i < kCalls; i++) {
        const float v = levelFor(i);
        for (uint32_t s = 0; s < kFrames; s++) samples[s] = v;
        AudioTimeStamp now = { 0 };
        now.mHostTime = (uint64_t)i + 1u;
        AudioTimeStamp input = { 0 };
        input.mFlags = (hostValidFor(i) ? kAudioTimeStampHostTimeValid : 0) | (sampleValidFor(i) ? kAudioTimeStampSampleTimeValid : 0);
        input.mHostTime = inputHostFor(i);          /* present even when not marked valid: the callback must not keep it */
        input.mSampleTime = inputSampleFor(i);
        AudioTimeStamp other = now;
        SATapProbeIOProc(0, &now, &list, &input, &out, &other, gProbe);
    }
    atomic_store_explicit(&gWriterDone, true, memory_order_release);
    return NULL;
}

static int gFailures;

static void check(uint32_t i, const SATapProbeRecord *r) {
    const float v = levelFor(i);
    const double expectSq = (double)kFrames * (double)v * (double)v;
    const uint64_t wantInputHost = hostValidFor(i) ? inputHostFor(i) : 0u;
    const double wantInputSample = sampleValidFor(i) ? inputSampleFor(i) : 0.0;
    if (r->hostTime != (uint64_t)i + 1u || r->frames != kFrames || r->samples != kFrames || r->peak != v || r->flags != expectedFlags(i) ||
        r->sumSquares < expectSq - 1e-9 || r->sumSquares > expectSq + 1e-9 ||
        r->inputHostTime != wantInputHost || r->inputSampleTime != wantInputSample) {
        if (gFailures++ < 5)
            fprintf(stderr, "record %u is not what call %u stored: hostTime %llu frames %u samples %u peak %f sumSq %f flags %u (want %u) inputHost %llu (want %llu) inputSample %f (want %f)\n",
                    i, i, (unsigned long long)r->hostTime, r->frames, r->samples, r->peak, r->sumSquares, r->flags, expectedFlags(i),
                    (unsigned long long)r->inputHostTime, (unsigned long long)wantInputHost, r->inputSampleTime, wantInputSample);
    }
}

static void *reader(void *arg) {
    (void)arg;
    uint32_t next = 0;
    for (;;) {
        const bool done = atomic_load_explicit(&gWriterDone, memory_order_acquire);
        const uint32_t committed = SATapProbeCommitted(gProbe);
        for (; next < committed; next++) {
            SATapProbeRecord r;
            if (!SATapProbeReadRecord(gProbe, next, &r)) { if (gFailures++ < 5) fprintf(stderr, "published record %u unreadable\n", next); continue; }
            check(next, &r);
        }
        if (done && next >= SATapProbeCommitted(gProbe)) break;
    }
    return NULL;
}

int main(void) {
    gProbe = SATapProbeCreate(kCapacity, 4, true);
    if (!gProbe) { fprintf(stderr, "create failed\n"); return 3; }
    pthread_t w, r;
    pthread_create(&r, NULL, reader, NULL);
    pthread_create(&w, NULL, writer, NULL);
    pthread_join(w, NULL);
    pthread_join(r, NULL);
    const uint32_t committed = SATapProbeCommitted(gProbe);
    const uint64_t dropped = SATapProbeDropped(gProbe);
    printf("committed=%u dropped=%llu failures=%d\n", committed, (unsigned long long)dropped, gFailures);
    int status = 0;
    if (committed != kCapacity) { fprintf(stderr, "expected %u published records\n", kCapacity); status = 1; }
    if (dropped != kCalls - kCapacity) { fprintf(stderr, "expected %u dropped\n", kCalls - kCapacity); status = 1; }
    if (gFailures != 0) status = 1;
    SATapProbeFree(gProbe);
    return status;
}
