#include "CSystemAudioRing.h"

#include <stdalign.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/*
 * Sample storage. Production: `_Atomic float` read and written with RELAXED atomics, so a reader that is overtaken by the producer while it
 * copies is not a data race in the C11 sense (docs/ARCHITECTURE.md, "Reading the ring from two blocks"). ThreadSanitizer cannot check the
 * ordering of relaxed atomics, so scripts/tsan-systemaudioring.sh compiles THIS SAME FILE with -DSA_RING_PLAIN_SAMPLES (plain floats): then a
 * missing release/acquire on `w` is a data race on the samples and TSan reports it. Nothing else differs between the two builds.
 */
#if defined(SA_RING_PLAIN_SAMPLES)
typedef float SASample;
#define SA_SAMPLE_STORE(p, v) (*(p) = (v))
#define SA_SAMPLE_LOAD(p)     (*(p))
#else
typedef _Atomic float SASample;
#define SA_SAMPLE_STORE(p, v) atomic_store_explicit((p), (v), memory_order_relaxed)
#define SA_SAMPLE_LOAD(p)     atomic_load_explicit((p), memory_order_relaxed)
#endif

#define SA_PHASE_NONE_BITS 0x7ff8000000000000ull   /* a quiet NaN: "no valid phase published yet" in ONE atomic word */

struct SARingReader {
    _Alignas(64) const SARing *ring;        /* immutable after SARingCreate */
    const SARingReader *peer;               /* the other channel's reader; immutable after SARingCreate */
    uint32_t channel;                       /* 0 = left, 1 = right; immutable */
    /* Written ONLY by this reader's render block (relaxed stores, no read-modify-write), or by SARingPrime while no block runs. */
    _Atomic int64_t cursor;                 /* r: frame index of the next frame this block will be asked for, after the last call */
    _Atomic uint64_t calls, framesRequested, servedBlocks, servedFrames, underrunBlocks, overrunBlocks, tornBlocks,
                     oversizeBlocks, badBufferBlocks, silentFrames;
    _Atomic uint64_t phaseValidCalls, phaseInvalidCalls, phaseSelfChanges, phaseMismatches, weakRuleViolations;
    _Atomic uint64_t phaseBits;             /* bit pattern of the last valid phase (cursor - sample time), SA_PHASE_NONE_BITS if none */
};

struct SARing {
    uint32_t capacity;                      /* N, a power of two */
    uint32_t mask;                          /* N - 1 */
    uint32_t maxCommit;                     /* N / 2: the most frames one producer commit may carry; also the in-flight margin */
    SASample *plane[SA_RING_CHANNELS];      /* frame j of channel c lives in plane[c][j & mask] */
    /* Written ONLY by the producer. */
    _Alignas(64) _Atomic int64_t w;         /* frames committed; released AFTER the frame data */
    _Atomic uint64_t commits;
    _Atomic uint64_t rejectedCommits;
    _Atomic uint32_t rejectFlags;
    _Atomic uint32_t lastCommitFrames;
    SARingReader readers[SA_RING_CHANNELS]; /* each 64-byte aligned, so two render threads never share a cache line */
};

/* ---- helpers: real time, inlined (so the entry points have no calls) ---- */

/* Single-writer counter: a relaxed load and a relaxed store, no read-modify-write. */
static inline __attribute__((always_inline)) CA_REALTIME_API void sa_bump(_Atomic uint64_t *c, uint64_t n) {
    atomic_store_explicit(c, atomic_load_explicit(c, memory_order_relaxed) + n, memory_order_relaxed);
}

static inline __attribute__((always_inline)) CA_REALTIME_API void sa_reject(SARing *ring, uint32_t flag) {
    sa_bump(&ring->rejectedCommits, 1);
    atomic_store_explicit(&ring->rejectFlags, atomic_load_explicit(&ring->rejectFlags, memory_order_relaxed) | flag, memory_order_relaxed);
}

static inline __attribute__((always_inline)) CA_REALTIME_API double sa_bits_to_double(uint64_t b) { return __builtin_bit_cast(double, b); }
static inline __attribute__((always_inline)) CA_REALTIME_API uint64_t sa_double_to_bits(double d) { return __builtin_bit_cast(uint64_t, d); }

/* The producer's whole job. Protocol (docs/ARCHITECTURE.md, "Step 6b-1"): release fence, data stores, then ONE release store of w.
 * The fence is what lets a reader that sees ANY of this commit's samples also see the previous value of w afterwards (the usual
 * overwrite-detection pattern); the release store is what publishes the commit. */
static inline __attribute__((always_inline)) CA_REALTIME_API void sa_write(SARing *ring, const float *in, uint32_t frames) {
    if (frames == 0) { sa_reject(ring, SA_RING_REJECT_EMPTY); return; }
    if (frames > ring->maxCommit) { sa_reject(ring, SA_RING_REJECT_OVERSIZE); return; }
    const int64_t w0 = atomic_load_explicit(&ring->w, memory_order_relaxed);   /* single writer: our own index */
    atomic_thread_fence(memory_order_release);
    const uint64_t mask = ring->mask;
    SASample *left = ring->plane[0];
    SASample *right = ring->plane[1];
    for (uint32_t i = 0; i < frames; i++) {
        const uint64_t slot = (uint64_t)(w0 + (int64_t)i) & mask;
        SA_SAMPLE_STORE(&left[slot], in[2u * (size_t)i]);
        SA_SAMPLE_STORE(&right[slot], in[2u * (size_t)i + 1u]);
    }
    sa_bump(&ring->commits, 1);
    atomic_store_explicit(&ring->lastCommitFrames, frames, memory_order_relaxed);
    atomic_store_explicit(&ring->w, w0 + (int64_t)frames, memory_order_release);   /* publish only after every sample is written */
}

/* ---- control thread ---- */

SARing *SARingCreate(uint32_t capacityFrames) {
    if (capacityFrames < 2 || capacityFrames > SA_RING_MAX_CAPACITY_FRAMES || (capacityFrames & (capacityFrames - 1u)) != 0) return NULL;
    SARing *ring = (SARing *)aligned_alloc(64, sizeof(SARing));   /* sizeof(SARing) is a multiple of 64 (its alignment) */
    if (!ring) return NULL;
    memset(ring, 0, sizeof *ring);
    for (uint32_t c = 0; c < SA_RING_CHANNELS; c++) {
        ring->plane[c] = (SASample *)calloc(capacityFrames, sizeof(SASample));
        if (!ring->plane[c]) {
            for (uint32_t k = 0; k < c; k++) free(ring->plane[k]);
            free(ring);
            return NULL;
        }
    }
    ring->capacity = capacityFrames;
    ring->mask = capacityFrames - 1u;
    ring->maxCommit = capacityFrames / 2u;
    atomic_init(&ring->w, 0);
    atomic_init(&ring->commits, 0);
    atomic_init(&ring->rejectedCommits, 0);
    atomic_init(&ring->rejectFlags, 0);
    atomic_init(&ring->lastCommitFrames, 0);
    for (uint32_t c = 0; c < SA_RING_CHANNELS; c++) {
        SARingReader *rd = &ring->readers[c];
        rd->ring = ring;
        rd->peer = &ring->readers[SA_RING_CHANNELS - 1u - c];
        rd->channel = c;
        atomic_init(&rd->cursor, 0);
        atomic_init(&rd->calls, 0); atomic_init(&rd->framesRequested, 0); atomic_init(&rd->servedBlocks, 0); atomic_init(&rd->servedFrames, 0);
        atomic_init(&rd->underrunBlocks, 0); atomic_init(&rd->overrunBlocks, 0); atomic_init(&rd->tornBlocks, 0);
        atomic_init(&rd->oversizeBlocks, 0); atomic_init(&rd->badBufferBlocks, 0); atomic_init(&rd->silentFrames, 0);
        atomic_init(&rd->phaseValidCalls, 0); atomic_init(&rd->phaseInvalidCalls, 0); atomic_init(&rd->phaseSelfChanges, 0);
        atomic_init(&rd->phaseMismatches, 0); atomic_init(&rd->weakRuleViolations, 0);
        atomic_init(&rd->phaseBits, SA_PHASE_NONE_BITS);
    }
    return ring;
}

void SARingFree(SARing *ring) {
    if (!ring) return;
    for (uint32_t c = 0; c < SA_RING_CHANNELS; c++) free(ring->plane[c]);
    free(ring);
}

SARingReader *SARingGetReader(SARing *ring, uint32_t channel) {
    return channel < SA_RING_CHANNELS ? &ring->readers[channel] : NULL;
}

bool SARingPrime(SARing *ring, uint32_t primeCallbacks) {
    if (primeCallbacks == 0) return false;
    const int64_t w = atomic_load_explicit(&ring->w, memory_order_acquire);
    const uint64_t commits = atomic_load_explicit(&ring->commits, memory_order_relaxed);
    const uint32_t last = atomic_load_explicit(&ring->lastCommitFrames, memory_order_relaxed);
    if (commits < primeCallbacks) return false;
    const int64_t depth = (int64_t)primeCallbacks * (int64_t)last;
    const int64_t window = (int64_t)ring->capacity - (int64_t)ring->maxCommit;
    if (depth <= 0 || depth > w || depth > window) return false;
    const int64_t start = w - depth;
    for (uint32_t c = 0; c < SA_RING_CHANNELS; c++) {
        SARingReader *rd = &ring->readers[c];
        atomic_store_explicit(&rd->cursor, start, memory_order_relaxed);
        atomic_store_explicit(&rd->calls, 0, memory_order_relaxed); atomic_store_explicit(&rd->framesRequested, 0, memory_order_relaxed);
        atomic_store_explicit(&rd->servedBlocks, 0, memory_order_relaxed); atomic_store_explicit(&rd->servedFrames, 0, memory_order_relaxed);
        atomic_store_explicit(&rd->underrunBlocks, 0, memory_order_relaxed); atomic_store_explicit(&rd->overrunBlocks, 0, memory_order_relaxed);
        atomic_store_explicit(&rd->tornBlocks, 0, memory_order_relaxed); atomic_store_explicit(&rd->oversizeBlocks, 0, memory_order_relaxed);
        atomic_store_explicit(&rd->badBufferBlocks, 0, memory_order_relaxed); atomic_store_explicit(&rd->silentFrames, 0, memory_order_relaxed);
        atomic_store_explicit(&rd->phaseValidCalls, 0, memory_order_relaxed); atomic_store_explicit(&rd->phaseInvalidCalls, 0, memory_order_relaxed);
        atomic_store_explicit(&rd->phaseSelfChanges, 0, memory_order_relaxed); atomic_store_explicit(&rd->phaseMismatches, 0, memory_order_relaxed);
        atomic_store_explicit(&rd->weakRuleViolations, 0, memory_order_relaxed);
        atomic_store_explicit(&rd->phaseBits, SA_PHASE_NONE_BITS, memory_order_relaxed);
    }
    atomic_store_explicit(&ring->rejectedCommits, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->rejectFlags, 0, memory_order_relaxed);
    return true;
}

bool SARingTakeSnapshot(const SARing *ring, SARingSnapshot *out) {
    const int64_t w = atomic_load_explicit(&ring->w, memory_order_acquire);   /* loaded once; fill below uses this value */
    out->w = w;
    out->commits = atomic_load_explicit(&ring->commits, memory_order_relaxed);
    out->rejectedCommits = atomic_load_explicit(&ring->rejectedCommits, memory_order_relaxed);
    out->rejectFlags = atomic_load_explicit(&ring->rejectFlags, memory_order_relaxed);
    out->lastCommitFrames = atomic_load_explicit(&ring->lastCommitFrames, memory_order_relaxed);
    out->capacity = ring->capacity;
    out->maxCommit = ring->maxCommit;
    for (uint32_t c = 0; c < SA_RING_CHANNELS; c++) {
        const SARingReader *rd = &ring->readers[c];
        SARingReaderStats *s = &out->reader[c];
        const int64_t r = atomic_load_explicit(&rd->cursor, memory_order_relaxed);   /* loaded once; fill uses this value */
        s->cursor = r;
        s->fill = w - r;
        s->calls = atomic_load_explicit(&rd->calls, memory_order_relaxed);
        s->framesRequested = atomic_load_explicit(&rd->framesRequested, memory_order_relaxed);
        s->servedBlocks = atomic_load_explicit(&rd->servedBlocks, memory_order_relaxed);
        s->servedFrames = atomic_load_explicit(&rd->servedFrames, memory_order_relaxed);
        s->underrunBlocks = atomic_load_explicit(&rd->underrunBlocks, memory_order_relaxed);
        s->overrunBlocks = atomic_load_explicit(&rd->overrunBlocks, memory_order_relaxed);
        s->tornBlocks = atomic_load_explicit(&rd->tornBlocks, memory_order_relaxed);
        s->oversizeBlocks = atomic_load_explicit(&rd->oversizeBlocks, memory_order_relaxed);
        s->badBufferBlocks = atomic_load_explicit(&rd->badBufferBlocks, memory_order_relaxed);
        s->silentFrames = atomic_load_explicit(&rd->silentFrames, memory_order_relaxed);
        s->phaseValidCalls = atomic_load_explicit(&rd->phaseValidCalls, memory_order_relaxed);
        s->phaseInvalidCalls = atomic_load_explicit(&rd->phaseInvalidCalls, memory_order_relaxed);
        s->phaseSelfChanges = atomic_load_explicit(&rd->phaseSelfChanges, memory_order_relaxed);
        s->phaseMismatches = atomic_load_explicit(&rd->phaseMismatches, memory_order_relaxed);
        s->weakRuleViolations = atomic_load_explicit(&rd->weakRuleViolations, memory_order_relaxed);
    }
    return true;
}

/* ---- producer, real time ---- */

void SARingWrite(SARing *ring, const float *interleavedStereo, uint32_t frames) CA_REALTIME_API {
    sa_write(ring, interleavedStereo, frames);
}

OSStatus SARingIOProc(AudioObjectID inDevice,
                      const AudioTimeStamp *inNow,
                      const AudioBufferList *inInputData,
                      const AudioTimeStamp *inInputTime,
                      AudioBufferList *outOutputData,
                      const AudioTimeStamp *inOutputTime,
                      void *__nullable inClientData) CA_REALTIME_API {
    (void)inDevice; (void)inNow; (void)inInputTime; (void)outOutputData; (void)inOutputTime;
    SARing *ring = (SARing *)inClientData;
    if (!ring) return 0;
    if (!inInputData || inInputData->mNumberBuffers == 0) { sa_reject(ring, SA_RING_REJECT_NO_BUFFERS); return 0; }
    if (inInputData->mNumberBuffers != 1 || inInputData->mBuffers[0].mNumberChannels != SA_RING_CHANNELS) {
        sa_reject(ring, SA_RING_REJECT_BAD_LAYOUT);
        return 0;
    }
    const AudioBuffer *buf = &inInputData->mBuffers[0];
    if (!buf->mData) { sa_reject(ring, SA_RING_REJECT_NULL_DATA); return 0; }
    if (((uintptr_t)buf->mData & 3u) != 0) { sa_reject(ring, SA_RING_REJECT_MISALIGNED); return 0; }
    if ((buf->mDataByteSize % 8u) != 0) { sa_reject(ring, SA_RING_REJECT_PARTIAL); return 0; }
    sa_write(ring, (const float *)buf->mData, buf->mDataByteSize / 8u);
    return 0;
}

/* ---- render side, real time ----
 * no_builtin: the zero-fill loop below must stay a loop. Without it Apple clang turns the loop into a call to `bzero` (seen in the first
 * release object of this step, found by the scan); no_builtin("memset") alone did NOT stop that, the bare attribute does. The scan, not this
 * attribute, is the safety net. (The copy loop reads relaxed atomics, which clang does not turn into memcpy.) */
OSStatus SARingRender(SARingReader *rd,
                      bool *isSilence,
                      const AudioTimeStamp *__nullable ts,
                      uint32_t frameCount,
                      AudioBufferList *__nullable out) CA_REALTIME_API __attribute__((no_builtin)) {
    const SARing *ring = rd->ring;
    const int64_t F = (int64_t)frameCount;
    /* Our own cursor: only this block (or SARingPrime, while no block runs) ever writes it, so a relaxed load reads our own last store. */
    const int64_t r = atomic_load_explicit(&rd->cursor, memory_order_relaxed);

    /* Count-only: the timestamp phase, or the weaker rule when the sample time is not usable (docs: "Divergence"). */
    if (ts && (ts->mFlags & kAudioTimeStampSampleTimeValid) && __builtin_isfinite(ts->mSampleTime)) {
        const double phase = (double)r - ts->mSampleTime;
        const double mine = sa_bits_to_double(atomic_load_explicit(&rd->phaseBits, memory_order_relaxed));
        const double theirs = sa_bits_to_double(atomic_load_explicit(&rd->peer->phaseBits, memory_order_relaxed));
        if (mine == mine && mine != phase) sa_bump(&rd->phaseSelfChanges, 1);
        if (theirs == theirs && theirs != phase) sa_bump(&rd->phaseMismatches, 1);
        atomic_store_explicit(&rd->phaseBits, sa_double_to_bits(phase), memory_order_relaxed);
        sa_bump(&rd->phaseValidCalls, 1);
    } else {
        const int64_t d = atomic_load_explicit(&rd->peer->cursor, memory_order_relaxed) - r;
        if (d != 0 && d != F) sa_bump(&rd->weakRuleViolations, 1);
        sa_bump(&rd->phaseInvalidCalls, 1);
    }

    OSStatus status = 0;
    bool silent = false;
    if (!(out && out->mNumberBuffers == 1 && out->mBuffers[0].mNumberChannels == 1 && out->mBuffers[0].mData &&
          (((uintptr_t)out->mBuffers[0].mData & 3u) == 0) && (uint64_t)out->mBuffers[0].mDataByteSize >= (uint64_t)frameCount * 4u)) {
        sa_bump(&rd->badBufferBlocks, 1);
        status = kAudio_ParamError;   /* nothing is written: the list cannot be trusted */
    } else {
        float *dst = (float *)out->mBuffers[0].mData;
        const int64_t window = (int64_t)ring->capacity - (int64_t)ring->maxCommit;   /* frames behind w that are certain not to be overwritten */
        const int64_t w1 = atomic_load_explicit(&ring->w, memory_order_acquire);
        bool served = false;
        if (F > window) {
            sa_bump(&rd->oversizeBlocks, 1);
        } else if (r + F > w1) {
            sa_bump(&rd->underrunBlocks, 1);
        } else if (w1 - r > window) {
            sa_bump(&rd->overrunBlocks, 1);
        } else {
            const SASample *src = ring->plane[rd->channel];
            const uint64_t mask = ring->mask;
            for (int64_t i = 0; i < F; i++) dst[i] = SA_SAMPLE_LOAD(&src[(uint64_t)(r + i) & mask]);
            atomic_thread_fence(memory_order_acquire);   /* the samples above are read before w is read again */
            const int64_t w2 = atomic_load_explicit(&ring->w, memory_order_relaxed);
            if (w2 - r > window) {
                sa_bump(&rd->tornBlocks, 1);
            } else {
                served = true;
                sa_bump(&rd->servedBlocks, 1);
                sa_bump(&rd->servedFrames, frameCount);
            }
        }
        if (!served) {
            for (int64_t i = 0; i < F; i++) dst[i] = 0.0f;
            sa_bump(&rd->silentFrames, frameCount);
            silent = true;
        }
    }
    *isSilence = silent;
    sa_bump(&rd->calls, 1);
    sa_bump(&rd->framesRequested, frameCount);
    atomic_store_explicit(&rd->cursor, r + F, memory_order_relaxed);   /* advance by exactly the frames asked for, on EVERY call */
    return status;
}
