/* Threaded stress of the Step 6b-1 ring: ONE producer thread (the real SARingIOProc), TWO reader threads (the real SARingRender, one per channel,
 * running concurrently, each on its own schedule) and the main thread taking control-thread snapshots while they run.
 *
 *   systemaudioring_stress paced   [frames]   Readers are NEVER lapped (the producer waits until it is at most `window` ahead of the slowest reader),
 *                                              so every block must be served with exactly the right data and there is no concurrent read of a slot the
 *                                              producer is writing. This is the mode ThreadSanitizer runs with -DSA_RING_PLAIN_SAMPLES: then a missing
 *                                              release/acquire on `w` is a data race on the samples.
 *   systemaudioring_stress lapping [frames]    Tiny ring, the producer is allowed past the window, so readers are overrun and sometimes overtaken WHILE
 *                                              they copy (tornBlocks). Invariant: a block reported served has exactly the right data; a silent block is
 *                                              all zeros. Runs with the production (atomic) sample type.
 *
 * Pacing between the harness threads, in both directions on purpose:
 *   producer -> reader (`gProduced`, "how far the producer has got"): RELAXED counter plus standalone fences. ThreadSanitizer does not model
 *      standalone fences, so this gives it NO happens-before edge: the library's own release/acquire on `w` is the only way the data can reach a
 *      reader, which is exactly what the plain-sample TSan run is there to check.
 *   reader -> producer (`gConsumed`, "how far each reader has read"): real release store / acquire load. The library has no such edge by design (the
 *      producer never looks at a cursor; safety there is the serve window plus the check after the copy), so without one TSan reports the producer's
 *      overwrite of a slot against the reader's earlier read of the previous lap. In the paced mode the readers are never overtaken, and this edge is
 *      what says so to TSan. (First version of this harness used relaxed + fences here too: TSan reported that write-after-read as a race on the REAL
 *      code. Valid in C11, invisible to TSan: a harness false positive, fixed here, see docs/STATUS.md.)
 * No sleeps, no clocks: a thread that has to wait spins with sched_yield() on a counter that another thread publishes; the harness's progress never
 * depends on the code under test. Exit 0 = no failure. */
#include "systemaudioring_common.h"

#include <pthread.h>
#include <sched.h>

static SARing *gRing;
static int64_t gTotal, gLagLimit;
static bool gPaced;
static _Atomic int64_t gProduced, gConsumed[2];
static atomic_bool gProducerDone;
static atomic_int gReadersDone;
static uint64_t gCommitCount;

static uint32_t commitSize(uint64_t i) { return gPaced ? 64u + (uint32_t)((i * 37u) % 449u) : 32u + (uint32_t)((i * 13u) % 97u); }
static uint32_t blockSize(uint64_t c) { return gPaced ? 64u + (uint32_t)((c * 29u) % 129u) : 16u + (uint32_t)((c * 7u) % 49u); }

static inline void publish(_Atomic int64_t *a, int64_t v) { atomic_thread_fence(memory_order_release); atomic_store_explicit(a, v, memory_order_relaxed); }
static inline int64_t observe(_Atomic int64_t *a) { const int64_t v = atomic_load_explicit(a, memory_order_relaxed); atomic_thread_fence(memory_order_acquire); return v; }
/* reader -> producer: a real edge (see the header comment) */
static inline void publishConsumed(int ch, int64_t v) { atomic_store_explicit(&gConsumed[ch], v, memory_order_release); }
static inline int64_t observeConsumed(int ch) { return atomic_load_explicit(&gConsumed[ch], memory_order_acquire); }

static void *producer(void *arg) {
    (void)arg;
    int64_t produced = 0;
    for (uint64_t i = 0; produced < gTotal; i++) {
        uint32_t K = commitSize(i);
        if (produced + K > gTotal) K = (uint32_t)(gTotal - produced);
        for (;;) {
            const int64_t a = observeConsumed(0), b = observeConsumed(1);
            if (produced + K - (a < b ? a : b) <= gLagLimit) break;
            sched_yield();
        }
        saCommit(gRing, produced, K);
        produced += K;
        gCommitCount++;
        publish(&gProduced, produced);
    }
    atomic_store_explicit(&gProducerDone, true, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    return NULL;
}

typedef struct { uint32_t ch; int64_t sumF; uint64_t blocks, servedSeen, silentSeen, wrongData, nonZeroSilence, unexpectedSilence, badFlag; } ReaderResult;

static void *reader(void *arg) {
    ReaderResult *res = (ReaderResult *)arg;
    SARingReader *rd = SARingGetReader(gRing, res->ch);
    float dst[256 + 8];
    int64_t r = 0;
    double t = 100000;
    for (uint64_t c = 0;; c++) {
        const uint32_t F = blockSize(c);
        for (;;) {
            const bool done = atomic_load_explicit(&gProducerDone, memory_order_relaxed);
            atomic_thread_fence(memory_order_acquire);
            if (observe(&gProduced) >= r + F) break;
            if (done) goto finished;
            sched_yield();
        }
        for (uint32_t i = 0; i < F + 8; i++) dst[i] = SA_SENTINEL;
        AudioBufferList l = { 0 };
        l.mNumberBuffers = 1; l.mBuffers[0].mNumberChannels = 1; l.mBuffers[0].mDataByteSize = F * 4u; l.mBuffers[0].mData = dst;
        AudioTimeStamp ts = { 0 };
        ts.mSampleTime = t; ts.mFlags = kAudioTimeStampSampleTimeValid;
        bool silent = false;
        const OSStatus s = SARingRender(rd, &silent, &ts, F, &l);
        if (s != 0) res->badFlag++;
        for (uint32_t i = F; i < F + 8; i++) if (dst[i] != SA_SENTINEL) res->wrongData++;
        if (!silent) {
            res->servedSeen++;
            for (uint32_t i = 0; i < F; i++) if (dst[i] != saSample(res->ch, r + i)) { res->wrongData++; break; }
        } else {
            res->silentSeen++;
            if (gPaced) res->unexpectedSilence++;
            for (uint32_t i = 0; i < F; i++) if (dst[i] != 0.0f) { res->nonZeroSilence++; break; }
        }
        r += F; t += F;
        res->blocks++;
        res->sumF = r;
        publishConsumed((int)res->ch, r);
    }
finished:
    atomic_fetch_add_explicit(&gReadersDone, 1, memory_order_release);
    return NULL;
}

int main(int argc, char **argv) {
    gPaced = argc > 1 && strcmp(argv[1], "paced") == 0;
    if (argc < 2 || (!gPaced && strcmp(argv[1], "lapping") != 0)) { fprintf(stderr, "usage: %s paced|lapping [frames]\n", argv[0]); return 2; }
    gTotal = argc > 2 ? atoll(argv[2]) : (gPaced ? 3000000 : 2000000);
    const uint32_t N = gPaced ? 2048u : 256u;
    const int64_t window = (int64_t)N - (int64_t)(N / 2);
    gLagLimit = gPaced ? window : window + 64;
    gRing = SARingCreate(N);
    if (!gRing) { fprintf(stderr, "create failed\n"); return 3; }
    pthread_t pt, rt[2];
    ReaderResult res[2] = { { .ch = 0 }, { .ch = 1 } };
    pthread_create(&rt[0], NULL, reader, &res[0]);
    pthread_create(&rt[1], NULL, reader, &res[1]);
    pthread_create(&pt, NULL, producer, NULL);

    /* the control thread: snapshots while everything runs */
    long snaps = 0;
    SARingSnapshot prev; memset(&prev, 0, sizeof prev);
    while (atomic_load_explicit(&gReadersDone, memory_order_acquire) < 2) {
        SARingSnapshot s;
        SARingTakeSnapshot(gRing, &s);
        snaps++;
        CHECK(s.w >= prev.w && s.commits >= prev.commits, "snapshot: producer counters went backwards");
        for (int c = 0; c < 2; c++) {
            CHECK(s.reader[c].fill == s.w - s.reader[c].cursor, "snapshot %ld ch%d: fill %lld != w %lld - cursor %lld (fill must come from the w loaded in the snapshot)", snaps, c, (long long)s.reader[c].fill, (long long)s.w, (long long)s.reader[c].cursor);
            CHECK(s.reader[c].cursor >= prev.reader[c].cursor && s.reader[c].calls >= prev.reader[c].calls && s.reader[c].servedBlocks >= prev.reader[c].servedBlocks, "snapshot ch%d: a cursor or counter went backwards", c);
        }
        prev = s;
        sched_yield();
    }
    pthread_join(pt, NULL); pthread_join(rt[0], NULL); pthread_join(rt[1], NULL);

    SARingSnapshot s;
    SARingTakeSnapshot(gRing, &s);
    CHECK(s.w == gTotal && s.commits == gCommitCount && s.rejectedCommits == 0 && s.rejectFlags == 0, "producer: w %lld commits %llu rejected %llu", (long long)s.w, (unsigned long long)s.commits, (unsigned long long)s.rejectedCommits);
    for (int c = 0; c < 2; c++) {
        const SARingReaderStats *x = &s.reader[c];
        const ReaderResult *q = &res[c];
        CHECK(x->calls == q->blocks && x->framesRequested == (uint64_t)q->sumF && x->cursor == q->sumF, "ch%d: calls %llu vs %llu blocks, cursor %lld vs %lld", c, (unsigned long long)x->calls, (unsigned long long)q->blocks, (long long)x->cursor, (long long)q->sumF);
        CHECK(x->calls == x->servedBlocks + x->underrunBlocks + x->overrunBlocks + x->tornBlocks + x->oversizeBlocks + x->badBufferBlocks, "ch%d: outcome counters do not add up", c);
        CHECK(x->servedBlocks == q->servedSeen && x->underrunBlocks + x->overrunBlocks + x->tornBlocks == q->silentSeen, "ch%d: the library's counts differ from what the reader thread saw", c);
        CHECK(q->wrongData == 0, "ch%d: %llu blocks with wrong data or a written canary (a block reported served must have exactly the right frames)", c, (unsigned long long)q->wrongData);
        CHECK(q->nonZeroSilence == 0, "ch%d: %llu silent blocks were not all zeros", c, (unsigned long long)q->nonZeroSilence);
        CHECK(q->badFlag == 0 && x->badBufferBlocks == 0 && x->oversizeBlocks == 0, "ch%d: unexpected error status or bad buffer", c);
        CHECK(x->phaseSelfChanges == 0 && x->phaseMismatches == 0 && x->phaseValidCalls == x->calls && x->phaseInvalidCalls == 0, "ch%d: phase counters (self %llu mismatch %llu): both readers follow the same schedule, so the phase must be constant and equal", c, (unsigned long long)x->phaseSelfChanges, (unsigned long long)x->phaseMismatches);
        CHECK(x->fill == s.w - x->cursor, "ch%d: final fill", c);
        if (gPaced) {
            CHECK(x->servedBlocks == x->calls && q->unexpectedSilence == 0 && x->underrunBlocks == 0 && x->overrunBlocks == 0 && x->tornBlocks == 0, "ch%d paced: every block must be served (silent %llu, under %llu over %llu torn %llu)", c, (unsigned long long)q->silentSeen, (unsigned long long)x->underrunBlocks, (unsigned long long)x->overrunBlocks, (unsigned long long)x->tornBlocks);
        } else {
            CHECK(x->servedBlocks > 0, "ch%d lapping: nothing was served, the run proves nothing", c);
        }
    }
    if (!gPaced) CHECK(s.reader[0].overrunBlocks + s.reader[1].overrunBlocks > 0, "lapping: no overrun happened: the lapping path was not exercised");
    printf("systemaudioring_stress %s: %lld frames, %llu commits, %ld control snapshots; L served %llu overrun %llu torn %llu underrun %llu; R served %llu overrun %llu torn %llu underrun %llu; %ld checks, %d failures\n",
           gPaced ? "paced" : "lapping", (long long)gTotal, (unsigned long long)gCommitCount, snaps,
           (unsigned long long)s.reader[0].servedBlocks, (unsigned long long)s.reader[0].overrunBlocks, (unsigned long long)s.reader[0].tornBlocks, (unsigned long long)s.reader[0].underrunBlocks,
           (unsigned long long)s.reader[1].servedBlocks, (unsigned long long)s.reader[1].overrunBlocks, (unsigned long long)s.reader[1].tornBlocks, (unsigned long long)s.reader[1].underrunBlocks, gChecks, gFailures);
    SARingFree(gRing);
    return gFailures == 0 ? 0 : 1;
}
