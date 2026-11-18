/* Threaded stress of the Step 6b-1 ring: ONE producer thread (the real SARingIOProc), TWO reader threads (the real SARingRender, one per channel,
 * running concurrently, each on its own schedule) and the main thread taking control-thread snapshots while they run.
 *
 *   systemaudioring_stress paced   [frames]   Readers are NEVER lapped (the producer waits until it is at most `window` ahead of the slowest reader),
 *                                              so every block must be served with exactly the right data and there is no concurrent read of a slot the
 *                                              producer is writing. This is the mode ThreadSanitizer runs with -DSA_RING_PLAIN_SAMPLES: then a missing
 *                                              release/acquire on `w` is a data race on the samples.
 *   systemaudioring_stress lapping [frames]    Tiny ring, the producer is allowed past the window, so readers are overrun and sometimes overtaken WHILE
 *                                              they copy (tornBlocks), and (Step 6b-3a-1) jump forward to w - T and by the phase rule. Invariants: a block
 *                                              reported served has exactly the right data (at the frame index its cursor says it started at); a silent
 *                                              block is all zeros; every call moves the cursor FORWARD by exactly frameCount plus the frames it counted as jumps.
 *                                              Runs with the production (atomic) sample type.
 *   systemaudioring_stress cycles  [cycles]    Step 6b-3a-1: the two readers run CONCURRENTLY in engine-like cycles (same frameCount and sample time for both,
 *                                              a spin barrier at the start of every cycle), with injected faults: the right block skipped in some cycles, the
 *                                              left block asked for half a frameCount in others. Checks: whenever both blocks ran in a cycle they served the SAME
 *                                              frame indices with the right data, the counters equal the injected faults, no flag, no underrun / overrun / torn.
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

static uint64_t tableCalls(const SARingReaderStats *x) { uint64_t t = 0; for (uint32_t k = 0; k < x->distinctFrameCounts && k < SA_RING_FRAME_TABLE_SLOTS; k++) t += x->frameCountCalls[k]; return t; }
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

typedef struct { uint32_t ch; int64_t sumF; uint64_t blocks, servedSeen, silentSeen, wrongData, nonZeroSilence, unexpectedSilence, badFlag, badInvariant; } ReaderResult;

static void *reader(void *arg) {
    ReaderResult *res = (ReaderResult *)arg;
    SARingReader *rd = SARingGetReader(gRing, res->ch);
    float dst[256 + 8];
    int64_t r = 0;   /* the cursor, as the library reports it (it moves by frameCount plus counted jumps) */
    double t = 100000;
    /* DETECTION POWER (found in Step 6b-3a-1: mutant M03 stopped being killed by the TSan plain-sample run): SARingTakeSnapshot loads `w` with ACQUIRE. A snapshot taken
     * just BEFORE every render gave ThreadSanitizer the producer -> reader edge that a render with a RELAXED load of `w` lacks, so it could no longer see that bug. The
     * reader's own cursor and counters are written only by this thread, so the "before" values of a call are exactly the "after" values of the previous call: take ONE
     * snapshot per call, AFTER the render (its acquire then cannot cover the call that precedes it), plus one before the loop. */
    SARingSnapshot prev;
    SARingTakeSnapshot(gRing, &prev);
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
        SARingSnapshot after;
        const OSStatus s = SARingRender(rd, &silent, &ts, F, &l);
        SARingTakeSnapshot(gRing, &after);
        const SARingReaderStats *x = &prev.reader[res->ch], *y = &after.reader[res->ch];
        const int64_t jumped = (int64_t)(y->overrunJumpFrames - x->overrunJumpFrames) + (int64_t)(y->divergenceJumpFrames - x->divergenceJumpFrames);
        if (y->cursor - x->cursor != (int64_t)F + jumped || y->cursor - x->cursor < (int64_t)F || y->calls != x->calls + 1) res->badInvariant++;
        const int64_t start = y->cursor - (int64_t)F;   /* a served block ends at the cursor */
        if (s != 0) res->badFlag++;
        for (uint32_t i = F; i < F + 8; i++) if (dst[i] != SA_SENTINEL) res->wrongData++;
        if (!silent) {
            res->servedSeen++;
            for (uint32_t i = 0; i < F; i++) if (dst[i] != saSample(res->ch, start + i)) { res->wrongData++; break; }
        } else {
            res->silentSeen++;
            if (gPaced) res->unexpectedSilence++;
            for (uint32_t i = 0; i < F; i++) if (dst[i] != 0.0f) { res->nonZeroSilence++; break; }
        }
        r = y->cursor; t += F;
        prev = after;
        res->blocks++;
        res->sumF += F;
        publishConsumed((int)res->ch, r);
    }
finished:
    atomic_fetch_add_explicit(&gReadersDone, 1, memory_order_release);
    return NULL;
}

/* ---- cycles mode (Step 6b-3a-1): two readers CONCURRENTLY in engine-like cycles, with injected faults ----
 * Cycle k: the producer commits F_k frames (only after both readers finished cycle k - 1, through a real release / acquire edge, so ThreadSanitizer sees the reader -> producer
 * order; the producer -> reader order is again left to the library's own release / acquire on `w`). Both reader threads then wait for each other at a spin barrier and
 * call SARingRender at the same moment with the same sample time. Faults: the right block is not asked in every 11th cycle (k % 11 == 5), the left block is asked for half the
 * frameCount in every 13th (k % 13 == 7). Standing fill T = 256, ring 2048 (window 1024): nothing is ever lapped, so the only recovery in play is the divergence jump. */
static int64_t gCycleCount;
static int64_t *gCycleStart[2];    /* the frame index a block served in each cycle (cursor after the call - frameCount asked), or -1 if it did not run */
static uint8_t *gCycleServed[2];
static uint32_t *gCycleAsk[2];
static double *gCycleTs;
static _Atomic int64_t gReady, gCycleDone[2];
static atomic_int gBarrier;
static int gCycleBad[2];

static uint32_t cycleF(int64_t k) { return 64u + 32u * (uint32_t)((k * 7) % 5); }
static bool cycleSkipR(int64_t k) { return k >= 2 && k < gCycleCount - 2 && k % 11 == 5; }
static bool cycleHalfL(int64_t k) { return k >= 2 && k < gCycleCount - 2 && k % 13 == 7 && !cycleSkipR(k); }

static void *cycleProducer(void *arg) {
    (void)arg;
    int64_t produced = 4 * 128;
    for (int64_t k = 0; k < gCycleCount; k++) {
        for (;;) {
            if (atomic_load_explicit(&gCycleDone[0], memory_order_acquire) >= k && atomic_load_explicit(&gCycleDone[1], memory_order_acquire) >= k) break;
            sched_yield();
        }
        const uint32_t F = cycleF(k);
        saCommit(gRing, produced, F);
        produced += F;
        publish(&gReady, k + 1);
    }
    return NULL;
}

static void *cycleReader(void *arg) {
    const int ch = (int)(intptr_t)arg;
    SARingReader *rd = SARingGetReader(gRing, (uint32_t)ch);
    float dst[192 + 8];
    SARingSnapshot prev;                                  /* the previous call's "after" is this call's "before" (single writer); see the note in reader() */
    SARingTakeSnapshot(gRing, &prev);
    for (int64_t k = 0; k < gCycleCount; k++) {
        while (observe(&gReady) < k + 1) sched_yield();
        atomic_fetch_add_explicit(&gBarrier, 1, memory_order_acq_rel);
        while (atomic_load_explicit(&gBarrier, memory_order_acquire) < 2 * (int)(k + 1)) sched_yield();   /* both blocks start the cycle together */
        const uint32_t F = cycleF(k);
        const bool skip = ch == 1 && cycleSkipR(k);
        const uint32_t ask = skip ? 0u : (ch == 0 && cycleHalfL(k) ? F / 2u : F);
        gCycleAsk[ch][k] = ask;
        gCycleStart[ch][k] = -1;
        if (!skip) {
            for (uint32_t i = 0; i < ask + 8; i++) dst[i] = SA_SENTINEL;
            AudioBufferList l = { 0 };
            l.mNumberBuffers = 1; l.mBuffers[0].mNumberChannels = 1; l.mBuffers[0].mDataByteSize = ask * 4u; l.mBuffers[0].mData = dst;
            AudioTimeStamp ts = { 0 };
            ts.mSampleTime = gCycleTs[k]; ts.mFlags = kAudioTimeStampSampleTimeValid;
            bool silent = false;
            SARingSnapshot after;
            const OSStatus st = SARingRender(rd, &silent, &ts, ask, &l);
            SARingTakeSnapshot(gRing, &after);
            const SARingReaderStats *x = &prev.reader[ch], *y = &after.reader[ch];
            const int64_t jumped = (int64_t)(y->overrunJumpFrames - x->overrunJumpFrames) + (int64_t)(y->divergenceJumpFrames - x->divergenceJumpFrames);
            if (st != 0 || y->cursor - x->cursor != (int64_t)ask + jumped || y->cursor - x->cursor < (int64_t)ask) gCycleBad[ch]++;
            for (uint32_t i = ask; i < ask + 8; i++) if (dst[i] != SA_SENTINEL) gCycleBad[ch]++;
            const int64_t start = y->cursor - (int64_t)ask;
            prev = after;
            gCycleStart[ch][k] = start;
            gCycleServed[ch][k] = silent ? 0 : 1;
            if (!silent) { for (uint32_t i = 0; i < ask; i++) if (dst[i] != saSample((uint32_t)ch, start + i)) { gCycleBad[ch]++; break; } }
            else { for (uint32_t i = 0; i < ask; i++) if (dst[i] != 0.0f) { gCycleBad[ch]++; break; } }
        }
        atomic_store_explicit(&gCycleDone[ch], k + 1, memory_order_release);
    }
    atomic_fetch_add_explicit(&gReadersDone, 1, memory_order_release);
    return NULL;
}

static int runCycles(int argc, char **argv) {
    gCycleCount = argc > 2 ? atoll(argv[2]) : 20000;
    if (gCycleCount < 100) { fprintf(stderr, "cycles: at least 100\n"); return 2; }
    gRing = SARingCreate(2048);
    if (!gRing) return 3;
    for (int i = 0; i < 4; i++) saCommit(gRing, 128 * i, 128);
    CHECK(SARingPrime(gRing, 2), "cycles prime");                         /* both readers at 256, T = 256 */
    for (int c = 0; c < 2; c++) {
        gCycleStart[c] = (int64_t *)calloc((size_t)gCycleCount, sizeof(int64_t));
        gCycleServed[c] = (uint8_t *)calloc((size_t)gCycleCount, 1);
        gCycleAsk[c] = (uint32_t *)calloc((size_t)gCycleCount, sizeof(uint32_t));
    }
    gCycleTs = (double *)calloc((size_t)gCycleCount, sizeof(double));
    double t = 100000;
    for (int64_t k = 0; k < gCycleCount; k++) { gCycleTs[k] = t; t += cycleF(k); }
    pthread_t pt, rt[2];
    pthread_create(&rt[0], NULL, cycleReader, (void *)(intptr_t)0);
    pthread_create(&rt[1], NULL, cycleReader, (void *)(intptr_t)1);
    pthread_create(&pt, NULL, cycleProducer, NULL);
    long snaps = 0;
    while (atomic_load_explicit(&gReadersDone, memory_order_acquire) < 2) {
        SARingSnapshot sn;
        SARingTakeSnapshot(gRing, &sn);
        snaps++;
        sched_yield();
    }
    pthread_join(pt, NULL); pthread_join(rt[0], NULL); pthread_join(rt[1], NULL);

    int64_t expectStart = 256;
    int64_t skips = 0, halves = 0, skipFrames = 0, halfFrames = 0, bothRan = 0;
    for (int64_t k = 0; k < gCycleCount; k++) {
        const uint32_t F = cycleF(k);
        for (int ch = 0; ch < 2; ch++) {
            if (ch == 1 && cycleSkipR(k)) { CHECK(gCycleStart[1][k] == -1, "cycle %lld: R was skipped", (long long)k); continue; }
            CHECK(gCycleServed[ch][k] == 1 && gCycleStart[ch][k] == expectStart, "cycle %lld ch%d: served from frame %lld, want %lld (a block asked after a fault must be back in step)", (long long)k, ch, (long long)gCycleStart[ch][k], (long long)expectStart);
        }
        if (!cycleSkipR(k)) bothRan++;
        if (cycleSkipR(k)) { skips++; skipFrames += F; }
        if (cycleHalfL(k)) { halves++; halfFrames += F / 2; }
        expectStart += F;
    }
    SARingSnapshot s;
    SARingTakeSnapshot(gRing, &s);
    const SARingReaderStats *L = &s.reader[0], *R = &s.reader[1];
    CHECK(gCycleBad[0] == 0 && gCycleBad[1] == 0, "cycles: %d / %d calls with wrong data, a written canary, a bad status or a broken cursor invariant", gCycleBad[0], gCycleBad[1]);
    CHECK(R->divergenceJumps == (uint64_t)skips && R->divergenceJumpFrames == (uint64_t)skipFrames, "R: %llu divergence jumps (%llu frames) for %lld skipped cycles (%lld frames)", (unsigned long long)R->divergenceJumps, (unsigned long long)R->divergenceJumpFrames, (long long)skips, (long long)skipFrames);
    CHECK(L->divergenceJumps == (uint64_t)halves && L->divergenceJumpFrames == (uint64_t)halfFrames, "L: %llu divergence jumps (%llu frames) for %lld half-frameCount cycles (%lld frames)", (unsigned long long)L->divergenceJumps, (unsigned long long)L->divergenceJumpFrames, (long long)halves, (long long)halfFrames);
    CHECK(R->phaseSelfChanges == (uint64_t)skips && L->phaseSelfChanges == (uint64_t)halves, "own phase changes: R %llu (want %lld), L %llu (want %lld)", (unsigned long long)R->phaseSelfChanges, (long long)skips, (unsigned long long)L->phaseSelfChanges, (long long)halves);
    CHECK(R->phaseMismatches >= R->divergenceJumps && L->phaseMismatches >= L->divergenceJumps, "every jump follows a counted mismatch");
    CHECK(L->calls == (uint64_t)gCycleCount && R->calls == (uint64_t)(gCycleCount - skips), "calls: L %llu R %llu", (unsigned long long)L->calls, (unsigned long long)R->calls);
    for (int c = 0; c < 2; c++) {
        const SARingReaderStats *x = &s.reader[c];
        CHECK(x->underrunBlocks == 0 && x->overrunBlocks == 0 && x->tornBlocks == 0 && x->oversizeBlocks == 0 && x->badBufferBlocks == 0 && x->servedBlocks == x->calls, "ch%d: every block served", c);
        CHECK(x->overrunJumps == 0 && x->refusedJumps == 0 && x->diverged == 0 && x->needsReprime == 0 && x->weakRuleViolations == 0 && x->phaseInvalidCalls == 0, "ch%d: no flag, no refused jump, no overrun jump", c);
        CHECK(x->calls == x->frameCountOverflowCalls + tableCalls(x), "ch%d: frame-count table sums to the call count", c);
        CHECK(x->fill == s.w - x->cursor, "ch%d: final fill", c);
    }
    CHECK(L->distinctFrameCounts == 8 && L->frameCountOverflowCalls == 0 && R->distinctFrameCounts == 5 && R->frameCountOverflowCalls == 0, "tables: L %u distinct (want 8: five frameCounts and their halves), R %u (want 5)", L->distinctFrameCounts, R->distinctFrameCounts);
    CHECK(s.needsReprime == 0 && s.w == 4 * 128 + (expectStart - 256), "ring: no request, producer total");
    printf("systemaudioring_stress cycles: %lld cycles (%lld with both blocks), %lld skipped-R and %lld half-frameCount-L faults, %ld control snapshots; R jumps %llu (%llu frames), L jumps %llu (%llu frames); %ld checks, %d failures\n",
           (long long)gCycleCount, (long long)bothRan, (long long)skips, (long long)halves, snaps, (unsigned long long)R->divergenceJumps, (unsigned long long)R->divergenceJumpFrames, (unsigned long long)L->divergenceJumps, (unsigned long long)L->divergenceJumpFrames, gChecks, gFailures);
    SARingFree(gRing);
    return gFailures == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "cycles") == 0) return runCycles(argc, argv);
    gPaced = argc > 1 && strcmp(argv[1], "paced") == 0;
    if (argc < 2 || (!gPaced && strcmp(argv[1], "lapping") != 0)) { fprintf(stderr, "usage: %s paced|lapping [frames] | cycles [cycles]\n", argv[0]); return 2; }
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
        CHECK(x->calls == q->blocks && x->framesRequested == (uint64_t)q->sumF && x->cursor == q->sumF + (int64_t)x->overrunJumpFrames + (int64_t)x->divergenceJumpFrames, "ch%d: calls %llu vs %llu blocks, cursor %lld vs frames asked %lld + jumps %llu", c, (unsigned long long)x->calls, (unsigned long long)q->blocks, (long long)x->cursor, (long long)q->sumF, (unsigned long long)(x->overrunJumpFrames + x->divergenceJumpFrames));
        CHECK(q->badInvariant == 0, "ch%d: %llu calls broke the cursor invariant (forward by exactly frameCount + counted jump frames)", c, (unsigned long long)q->badInvariant);
        CHECK(x->calls == x->frameCountOverflowCalls + tableCalls(x), "ch%d: frame-count table sums to the call count", c);
        CHECK(x->calls == x->servedBlocks + x->underrunBlocks + x->overrunBlocks + x->tornBlocks + x->oversizeBlocks + x->badBufferBlocks, "ch%d: outcome counters do not add up", c);
        CHECK(x->servedBlocks == q->servedSeen && x->underrunBlocks + x->overrunBlocks + x->tornBlocks == q->silentSeen, "ch%d: the library's counts differ from what the reader thread saw", c);
        CHECK(q->wrongData == 0, "ch%d: %llu blocks with wrong data or a written canary (a block reported served must have exactly the right frames)", c, (unsigned long long)q->wrongData);
        CHECK(q->nonZeroSilence == 0, "ch%d: %llu silent blocks were not all zeros", c, (unsigned long long)q->nonZeroSilence);
        CHECK(q->badFlag == 0 && x->badBufferBlocks == 0 && x->oversizeBlocks == 0, "ch%d: unexpected error status or bad buffer", c);
        CHECK(x->phaseValidCalls == x->calls && x->phaseInvalidCalls == 0, "ch%d: phase counters: every call has a valid sample time", c);
        CHECK(x->fill == s.w - x->cursor, "ch%d: final fill", c);
        CHECK((x->refusedJumps == 0 || x->needsReprime == 1) && x->divergenceJumps <= x->phaseMismatches && x->diverged == 0, "ch%d: a refused jump asks for a re-prime; a divergence jump follows a counted mismatch; the weak rule is not in play", c);
        if (gPaced) {
            CHECK(x->servedBlocks == x->calls && q->unexpectedSilence == 0 && x->underrunBlocks == 0 && x->overrunBlocks == 0 && x->tornBlocks == 0, "ch%d paced: every block must be served (silent %llu, under %llu over %llu torn %llu)", c, (unsigned long long)q->silentSeen, (unsigned long long)x->underrunBlocks, (unsigned long long)x->overrunBlocks, (unsigned long long)x->tornBlocks);
            CHECK(x->phaseSelfChanges == 0 && x->phaseMismatches == 0, "ch%d paced: both readers follow the same schedule, so the phase must be constant and equal (self %llu mismatch %llu)", c, (unsigned long long)x->phaseSelfChanges, (unsigned long long)x->phaseMismatches);
            CHECK(x->overrunJumps == 0 && x->divergenceJumps == 0 && x->refusedJumps == 0 && x->needsReprime == 0 && s.needsReprime == 0, "ch%d paced: no jump and no request when nothing is ever lapped", c);
        } else {
            CHECK(x->servedBlocks > 0, "ch%d lapping: nothing was served, the run proves nothing", c);
        }
    }
    if (!gPaced) {
        CHECK(s.reader[0].overrunBlocks + s.reader[1].overrunBlocks > 0, "lapping: no overrun happened: the lapping path was not exercised");
        CHECK(s.reader[0].overrunJumps + s.reader[1].overrunJumps > 0, "lapping: no overrun JUMP happened: the recovery path was not exercised");
    }
    printf("systemaudioring_stress %s: %lld frames, %llu commits, %ld control snapshots; L served %llu overrun %llu torn %llu underrun %llu; R served %llu overrun %llu torn %llu underrun %llu; %ld checks, %d failures\n",
           gPaced ? "paced" : "lapping", (long long)gTotal, (unsigned long long)gCommitCount, snaps,
           (unsigned long long)s.reader[0].servedBlocks, (unsigned long long)s.reader[0].overrunBlocks, (unsigned long long)s.reader[0].tornBlocks, (unsigned long long)s.reader[0].underrunBlocks,
           (unsigned long long)s.reader[1].servedBlocks, (unsigned long long)s.reader[1].overrunBlocks, (unsigned long long)s.reader[1].tornBlocks, (unsigned long long)s.reader[1].underrunBlocks, gChecks, gFailures);
    SARingFree(gRing);
    return gFailures == 0 ? 0 : 1;
}
