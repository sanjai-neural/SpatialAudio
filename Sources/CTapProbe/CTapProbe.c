#include "CTapProbe.h"

#include <float.h>
#include <stdatomic.h>
#include <stdlib.h>

struct SATapProbe {
    SATapProbeRecord *records;
    uint32_t capacity;
    uint32_t bytesPerSample;
    bool isFloat32;
    _Atomic uint32_t committed;   /* written by the IO thread only (release), read by the control thread (acquire) */
    _Atomic uint64_t dropped;
};

SATapProbe *SATapProbeCreate(uint32_t capacity, uint32_t bytesPerSample, bool isFloat32) {
    if (capacity == 0 || bytesPerSample == 0) return NULL;   /* invariant for the callback: bytesPerSample >= 1, so it can never divide by zero */
    SATapProbe *p = (SATapProbe *)calloc(1, sizeof(SATapProbe));
    if (!p) return NULL;
    p->records = (SATapProbeRecord *)calloc(capacity, sizeof(SATapProbeRecord));
    if (!p->records) { free(p); return NULL; }
    p->capacity = capacity;
    p->bytesPerSample = bytesPerSample;
    p->isFloat32 = isFloat32 && bytesPerSample == 4;
    atomic_init(&p->committed, 0);
    atomic_init(&p->dropped, 0);
    return p;
}

void SATapProbeFree(SATapProbe *p) {
    if (!p) return;
    free(p->records);
    free(p);
}

/* Real-time. Everything below is arithmetic on memory the control thread already owns. */
OSStatus SATapProbeIOProc(AudioObjectID inDevice,
                          const AudioTimeStamp *inNow,
                          const AudioBufferList *inInputData,
                          const AudioTimeStamp *inInputTime,
                          AudioBufferList *outOutputData,
                          const AudioTimeStamp *inOutputTime,
                          void *__nullable inClientData) CA_REALTIME_API {
    (void)inDevice; (void)outOutputData; (void)inOutputTime;
    SATapProbe *p = (SATapProbe *)inClientData;
    if (!p) return 0;

    const uint32_t n = atomic_load_explicit(&p->committed, memory_order_relaxed);   /* single writer: our own counter */
    if (n >= p->capacity) {
        atomic_fetch_add_explicit(&p->dropped, 1, memory_order_relaxed);
        return 0;
    }

    uint32_t flags = 0, frames = 0, samples = 0;
    float peak = 0.0f;
    double sumSquares = 0.0;

    if (!inNow) flags |= SA_TAP_FLAG_NO_TIMESTAMP;

    /* Step 6a3: the input timestamp, next to inNow. Validity comes from mFlags only; an invalid field is stored as 0 so garbage never
     * reaches a reader, and the flag bit says it was not valid. */
    uint64_t inputHostTime = 0;
    double inputSampleTime = 0.0;
    if (!inInputTime) {
        flags |= SA_TAP_FLAG_NO_INPUT_TIME | SA_TAP_FLAG_INPUT_HOST_TIME_INVALID | SA_TAP_FLAG_INPUT_SAMPLE_TIME_INVALID;
    } else {
        const uint32_t tf = (uint32_t)inInputTime->mFlags;
        if (tf & kAudioTimeStampHostTimeValid) inputHostTime = inInputTime->mHostTime; else flags |= SA_TAP_FLAG_INPUT_HOST_TIME_INVALID;
        if (tf & kAudioTimeStampSampleTimeValid) inputSampleTime = inInputTime->mSampleTime; else flags |= SA_TAP_FLAG_INPUT_SAMPLE_TIME_INVALID;
    }
    if (!inInputData || inInputData->mNumberBuffers == 0) {
        flags |= SA_TAP_FLAG_NO_BUFFERS;
    } else {
        for (uint32_t b = 0; b < inInputData->mNumberBuffers; b++) {
            const AudioBuffer *buf = &inInputData->mBuffers[b];
            if (b == 0) {
                /* mNumberChannels comes from the HAL. The product is formed in 64 bits: bytesPerSample >= 1 (SATapProbeCreate refuses 0)
                 * and channels >= 1, so the divisor is at least 1 and cannot wrap to 0 the way a 32-bit product can
                 * (4 * 0x40000000 == 0 mod 2^32, a division by zero: undefined behaviour, which arm64 happens to turn into 0). */
                const uint64_t channels = buf->mNumberChannels ? buf->mNumberChannels : 1;
                const uint64_t bytesPerFrame = (uint64_t)p->bytesPerSample * channels;
                frames = (uint32_t)(buf->mDataByteSize / bytesPerFrame);
            }
            if (!buf->mData) { flags |= SA_TAP_FLAG_NULL_BUFFER; continue; }
            if (!p->isFloat32) { flags |= SA_TAP_FLAG_UNSUPPORTED_FORMAT; continue; }
            const float *x = (const float *)buf->mData;
            const uint32_t count = buf->mDataByteSize / 4;
            for (uint32_t i = 0; i < count; i++) {
                const float v = x[i];
                const float a = __builtin_fabsf(v);
                if (!(a <= FLT_MAX)) { flags |= SA_TAP_FLAG_NON_FINITE_SAMPLE; continue; }   /* NaN or infinity: left out of everything */
                if (a > peak) peak = a;
                sumSquares += (double)v * (double)v;
                samples++;
            }
        }
    }

    SATapProbeRecord *r = &p->records[n];
    r->hostTime = inNow ? inNow->mHostTime : 0;
    r->sumSquares = sumSquares;
    r->frames = frames;
    r->samples = samples;
    r->peak = peak;
    r->flags = flags;
    r->inputHostTime = inputHostTime;
    r->inputSampleTime = inputSampleTime;
    atomic_store_explicit(&p->committed, n + 1, memory_order_release);   /* publish only after every field is written */
    return 0;
}

uint32_t SATapProbeCommitted(const SATapProbe *p) {
    return p ? atomic_load_explicit(&p->committed, memory_order_acquire) : 0;
}

uint64_t SATapProbeDropped(const SATapProbe *p) {
    return p ? atomic_load_explicit(&p->dropped, memory_order_relaxed) : 0;
}

uint32_t SATapProbeCapacity(const SATapProbe *p) { return p ? p->capacity : 0; }

bool SATapProbeReadRecord(const SATapProbe *p, uint32_t index, SATapProbeRecord *out) {
    if (!p || !out || index >= SATapProbeCommitted(p)) return false;
    const SATapProbeRecord *r = &p->records[index];
    out->hostTime = r->hostTime;          /* field by field on purpose (TSan does not race-check a bulk copy) */
    out->sumSquares = r->sumSquares;
    out->frames = r->frames;
    out->samples = r->samples;
    out->peak = r->peak;
    out->flags = r->flags;
    out->inputHostTime = r->inputHostTime;
    out->inputSampleTime = r->inputSampleTime;
    return true;
}
