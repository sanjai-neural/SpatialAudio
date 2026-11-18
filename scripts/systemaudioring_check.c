/* Deterministic, single-threaded checks of the Step 6b-1 ring, producer IOProc and the two readers (built by scripts/check-systemaudioring.sh,
 * ubsan-systemaudioring.sh). Every expectation is exact: data per channel and frame index, counters, cursors, fill, flags. Exit 0 = no check failed. */
#include "systemaudioring_common.h"

typedef struct { OSStatus status; bool silent; } RR;

/* The hook SARingRender calls between its copy and its second look at w (compiled in only with -DSA_RING_TEST_HOOKS, which the scripts pass for this
 * harness): scenario J asks it to run `gHookCommits` producer commits of 128 frames at exactly that moment. */
static int gHookCommits;
static int64_t *gHookProduced;
static int gUnpublished;          /* scenario L: frames written into the ring but NOT published (an in-flight commit), at the moment before the copy */
static int64_t *gUnpublishedAt;   /* the frame index those frames start at (= w) */
extern void SARingTestWriteUnpublished(SARing *ring, const float *in, uint32_t frames);   /* in the ring source, compiled in only with -DSA_RING_TEST_HOOKS */
void saTestBeforeCopy(const SARing *ring, SARingReader *reader) {
    (void)reader;
    if (gUnpublished == 0) return;
    float *buf = (float *)malloc((size_t)gUnpublished * 2 * sizeof(float));
    for (int i = 0; i < gUnpublished; i++) { buf[2 * i] = saSample(0, *gUnpublishedAt + i); buf[2 * i + 1] = saSample(1, *gUnpublishedAt + i); }
    SARingTestWriteUnpublished((SARing *)ring, buf, (uint32_t)gUnpublished);
    free(buf);
}
void saTestAfterCopy(const SARing *ring, SARingReader *reader) {
    (void)reader;
    for (int i = 0; i < gHookCommits; i++) { saCommit((SARing *)ring, *gHookProduced, 128); *gHookProduced += 128; }
}

/* The ring the current scenario uses: render() reads its snapshot before and after EVERY call and checks the one invariant of the recovery design for any
 * scenario that goes through it: the cursor moves FORWARD by exactly frameCount plus the frames the call counted as jumps (overrun jump + divergence jump),
 * the call count and framesRequested move by one call and frameCount, and a jump is never negative (no backward move, ever). */
static SARing *gInvRing;
static SARing *mkRing(uint32_t capacity) { SARing *r = SARingCreate(capacity); gInvRing = r; return r; }

static AudioTimeStamp mkTS(double sampleTime, bool valid) {
    AudioTimeStamp t = { 0 };
    t.mSampleTime = sampleTime;
    t.mFlags = valid ? kAudioTimeStampSampleTimeValid : 0;
    return t;
}

/* One render call. `dst` has room for F + 8 floats: the last 8 are a canary that must never be touched. `initSilent` is the value *isSilence has
 * before the call (the harness passes the OPPOSITE of what it expects, so a function that forgets to set it is caught). */
static SARingSnapshot snap(SARing *ring);
static void invariantAfter(const SARingSnapshot *b, const SARingSnapshot *a, int ch, uint32_t F) {
    const SARingReaderStats *x = &b->reader[ch], *y = &a->reader[ch];
    const int64_t jumped = (int64_t)(y->overrunJumpFrames - x->overrunJumpFrames) + (int64_t)(y->divergenceJumpFrames - x->divergenceJumpFrames);
    CHECK(y->cursor - x->cursor == (int64_t)F + jumped, "INVARIANT ch%d: cursor moved %lld, want frameCount %u + counted jump frames %lld", ch, (long long)(y->cursor - x->cursor), F, (long long)jumped);
    CHECK(y->cursor - x->cursor >= (int64_t)F, "INVARIANT ch%d: the cursor moved by less than frameCount (a backward or short move)", ch);
    CHECK(y->calls == x->calls + 1 && y->framesRequested == x->framesRequested + F, "INVARIANT ch%d: calls / framesRequested", ch);
}

static RR render(SARingReader *rd, uint32_t F, const AudioTimeStamp *ts, float *dst, bool initSilent) {
    for (uint32_t i = 0; i < F + 8; i++) dst[i] = SA_SENTINEL;
    AudioBufferList l = { 0 };
    l.mNumberBuffers = 1;
    l.mBuffers[0].mNumberChannels = 1;
    l.mBuffers[0].mDataByteSize = F * 4u;
    l.mBuffers[0].mData = dst;
    RR rr = { 0, initSilent };
    int ch = -1;
    SARingSnapshot before;
    if (gInvRing) {
        ch = SARingGetReader(gInvRing, 0) == rd ? 0 : (SARingGetReader(gInvRing, 1) == rd ? 1 : -1);
        if (ch >= 0) before = snap(gInvRing);
    }
    rr.status = SARingRender(rd, &rr.silent, ts, F, &l);
    if (ch >= 0) { const SARingSnapshot after = snap(gInvRing); invariantAfter(&before, &after, ch, F); }
    for (uint32_t i = F; i < F + 8; i++) CHECK(dst[i] == SA_SENTINEL, "canary after the output buffer was written (index %u)", i - F);
    return rr;
}

static void expectServed(const char *what, uint32_t ch, int64_t r, uint32_t F, const float *dst, RR rr) {
    CHECK(rr.status == 0, "%s ch%u r=%lld: status %d", what, ch, (long long)r, (int)rr.status);
    CHECK(!rr.silent, "%s ch%u r=%lld: isSilence set on a served block", what, ch, (long long)r);
    int bad = 0;
    for (uint32_t i = 0; i < F && bad < 3; i++)
        if (dst[i] != saSample(ch, r + i)) { saFail(__FILE__, __LINE__, "%s ch%u frame %lld: got %f want %f", what, ch, (long long)(r + i), dst[i], saSample(ch, r + i)); bad++; }
    CHECK(bad == 0, "%s ch%u r=%lld: served data wrong", what, ch, (long long)r);
}

static void expectSilence(const char *what, uint32_t F, const float *dst, RR rr) {
    CHECK(rr.status == 0, "%s: status %d", what, (int)rr.status);
    CHECK(rr.silent, "%s: isSilence not set on a silent block", what);
    int bad = 0;
    for (uint32_t i = 0; i < F; i++) if (dst[i] != 0.0f || signbit(dst[i])) bad++;
    CHECK(bad == 0, "%s: %d of %u samples are not zero (stale data left in the output)", what, bad, F);
}

static SARingSnapshot snap(SARing *ring) { SARingSnapshot s; memset(&s, 0xAB, sizeof s); CHECK(SARingTakeSnapshot(ring, &s), "snapshot"); return s; }

static void identity(const char *what, const SARingReaderStats *s) {
    CHECK(s->calls == s->servedBlocks + s->underrunBlocks + s->overrunBlocks + s->tornBlocks + s->oversizeBlocks + s->badBufferBlocks,
          "%s: calls %llu != sum of outcomes", what, (unsigned long long)s->calls);
    uint64_t tab = s->frameCountOverflowCalls;
    CHECK(s->distinctFrameCounts <= SA_RING_FRAME_TABLE_SLOTS, "%s: %u table slots in use", what, s->distinctFrameCounts);
    for (uint32_t k = 0; k < s->distinctFrameCounts && k < SA_RING_FRAME_TABLE_SLOTS; k++) tab += s->frameCountCalls[k];
    CHECK(tab == s->calls, "%s: frame-count table sums to %llu, calls %llu", what, (unsigned long long)tab, (unsigned long long)s->calls);
    CHECK(s->calls == 0 ? (s->minFrameCount == 0 && s->maxFrameCount == 0) : (s->minFrameCount <= s->maxFrameCount), "%s: min %u max %u", what, s->minFrameCount, s->maxFrameCount);
}

/* A: both orders, varied commit sizes (so commits straddle the wrap), several laps. Returns the final snapshot so the two orders can be compared.
 * Ring 1024 -> window 512; primed at T = 2 x 128 = 256 frames so that fill plus the next commit (at most 160) stays inside the window. */
static SARingSnapshot scenarioA(int order) {
    SARing *ring = mkRing(1024);
    CHECK(ring != NULL, "create");
    int64_t produced = 0;
    for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
    CHECK(SARingPrime(ring, 2), "A prime");
    SARingSnapshot p = snap(ring);
    CHECK(p.reader[0].cursor == 256 && p.reader[1].cursor == 256, "A: both readers start at 256 (w 512 - 2 x 128)");
    CHECK(p.reader[0].fill == 256 && p.reader[1].fill == 256, "A: standing fill 256");
    SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
    int64_t r = 256;
    double t = 1000;
    float dst[128 + 8];
    for (int cycle = 0; cycle < 40; cycle++) {
        const uint32_t K = (cycle % 2 == 0) ? 96u : 160u;
        saCommit(ring, produced, K);
        produced += K;
        const AudioTimeStamp ts = mkTS(t, true);
        for (int k = 0; k < 2; k++) {
            const uint32_t ch = order == 0 ? (uint32_t)k : 1u - (uint32_t)k;
            const RR rr = render(rd[ch], 128, &ts, dst, true);
            expectServed("A", ch, r, 128, dst, rr);
        }
        r += 128;
        t += 128;
    }
    const SARingSnapshot s = snap(ring);
    CHECK(s.w == produced && s.commits == 44 && s.rejectedCommits == 0 && s.rejectFlags == 0, "A producer counters");
    for (int c = 0; c < 2; c++) {
        const SARingReaderStats *x = &s.reader[c];
        identity("A", x);
        CHECK(x->calls == 40 && x->servedBlocks == 40 && x->servedFrames == 5120 && x->framesRequested == 5120, "A ch%d counters", c);
        CHECK(x->underrunBlocks == 0 && x->overrunBlocks == 0 && x->tornBlocks == 0 && x->oversizeBlocks == 0 && x->badBufferBlocks == 0 && x->silentFrames == 0, "A ch%d no silent blocks", c);
        CHECK(x->cursor == 5376 && x->fill == produced - 5376 && x->fill == 256, "A ch%d cursor %lld fill %lld", c, (long long)x->cursor, (long long)x->fill);
        CHECK(x->phaseValidCalls == 40 && x->phaseInvalidCalls == 0 && x->phaseSelfChanges == 0 && x->phaseMismatches == 0 && x->weakRuleViolations == 0, "A ch%d phase counters", c);
        CHECK(x->distinctFrameCounts == 1 && x->frameCountValue[0] == 128 && x->frameCountCalls[0] == 40 && x->frameCountOverflowCalls == 0 && x->minFrameCount == 128 && x->maxFrameCount == 128, "A ch%d frame-count table", c);
        CHECK(x->overrunJumps == 0 && x->overrunJumpFrames == 0 && x->divergenceJumps == 0 && x->divergenceJumpFrames == 0 && x->refusedJumps == 0 && x->largestJumpFrames == 0 && x->diverged == 0 && x->needsReprime == 0, "A ch%d: a healthy run makes no jump and sets no flag", c);
    }
    CHECK(s.standingFill == 256 && s.needsReprime == 0, "A: T is the primed depth (256), no re-prime asked");
    SARingFree(ring);
    return s;
}

/* B: underrun. The block is silent (zeros), the cursor still advances by exactly frameCount, late frames are dropped never played late, and
 * at equal producer and reader rate a reader that fell behind the producer STAYS starved (this spike counts only: no jump, no re-prime). */
static void scenarioB(void) {
    SARing *ring = mkRing(1024);
    int64_t produced = 0;
    for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
    CHECK(SARingPrime(ring, 4), "B prime");
    SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
    float dst[128 + 8];
    double t = 0;
    int64_t r = 0;
    for (int c = 0; c < 4; c++, r += 128, t += 128)
        for (uint32_t ch = 0; ch < 2; ch++) { const AudioTimeStamp ts = mkTS(t, true); expectServed("B serve", ch, r, 128, dst, render(rd[ch], 128, &ts, dst, true)); }
    CHECK(snap(ring).reader[0].fill == 0, "B: fill 0 after the 4 primed blocks");
    for (uint32_t ch = 0; ch < 2; ch++) { const AudioTimeStamp ts = mkTS(t, true); expectSilence("B underrun", 128, dst, render(rd[ch], 128, &ts, dst, false)); }
    r += 128; t += 128;
    SARingSnapshot s = snap(ring);
    for (int c = 0; c < 2; c++) {
        CHECK(s.reader[c].underrunBlocks == 1 && s.reader[c].silentFrames == 128 && s.reader[c].calls == 5 && s.reader[c].servedBlocks == 4, "B ch%d counters after the first underrun", c);
        CHECK(s.reader[c].cursor == 640 && s.reader[c].fill == -128, "B ch%d cursor advanced by frameCount, reader now AHEAD of the producer (cursor %lld fill %lld)", c, (long long)s.reader[c].cursor, (long long)s.reader[c].fill);
        identity("B", &s.reader[c]);
    }
    for (int k = 0; k < 5; k++) {   /* equal rate: producer commits 128, reader asks 128: starved every time */
        saCommit(ring, produced, 128); produced += 128;
        for (uint32_t ch = 0; ch < 2; ch++) { const AudioTimeStamp ts = mkTS(t, true); expectSilence("B starved", 128, dst, render(rd[ch], 128, &ts, dst, false)); }
        r += 128; t += 128;
    }
    s = snap(ring);
    CHECK(s.reader[0].underrunBlocks == 6 && s.reader[0].cursor == 1280 && s.reader[0].fill == -128 && s.w == 1152, "B: still starved after 5 equal-rate cycles (fill %lld)", (long long)s.reader[0].fill);
    for (int k = 0; k < 3; k++) { saCommit(ring, produced, 128); produced += 128; }   /* a burst: the producer gets ahead again */
    for (uint32_t ch = 0; ch < 2; ch++) { const AudioTimeStamp ts = mkTS(t, true); expectServed("B recovered at the CURSOR (late frames dropped)", ch, 1280, 128, dst, render(rd[ch], 128, &ts, dst, true)); }
    s = snap(ring);
    for (int c = 0; c < 2; c++) {
        identity("B end", &s.reader[c]);
        CHECK(s.reader[c].servedBlocks == 5 && s.reader[c].underrunBlocks == 6 && s.reader[c].calls == 11 && s.reader[c].silentFrames == 768 && s.reader[c].servedFrames == 640, "B ch%d final counters", c);
        CHECK(s.reader[c].cursor == 1408 && s.reader[c].fill == 128, "B ch%d final cursor/fill", c);
        CHECK(s.reader[c].overrunJumps == 0 && s.reader[c].divergenceJumps == 0 && s.reader[c].refusedJumps == 0 && s.reader[c].diverged == 0 && s.reader[c].needsReprime == 0,
              "B ch%d: an underrun is zeros-and-advance only: no jump, no flag (the control thread's re-prime ends a starvation)", c);
    }
    CHECK(s.needsReprime == 0, "B: an underrun does not ask for a re-prime by itself");
    SARingFree(ring);
}

/* C: overrun (lapped), the exact boundaries of its detection, oversize. window = capacity - capacity / 2 = 512 for a ring of 1024. Step 6b-3a-1: a lapped
 * reader now moves its OWN cursor FORWARD to w - T (zeros for the lapped call, a standing fill of T afterwards); the jump is refused above N - T (and asks
 * for a re-prime), and is never less than the normal advance. T is the primed depth (or the default capacity / 16 = 64 for an unprimed ring of 1024). */
static void scenarioC(void) {
    float dst[600 + 8];
    {   /* C1: lapped by a lot, T = 256. w - r = 1024 > 512: zeros, cursor to w - T = 1024 (not r + F = 384), then served at a fill of T, then the producer-less end: starved */
        SARing *ring = mkRing(1024);
        int64_t produced = 0;
        for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
        CHECK(SARingPrime(ring, 2), "C1 prime");                                 /* both readers at 256, T = 256 */
        CHECK(snap(ring).standingFill == 256, "C1: T = the primed depth");
        for (int i = 0; i < 6; i++) { saCommit(ring, produced, 128); produced += 128; }   /* w = 1280 while the readers were idle */
        SARingReader *L = SARingGetReader(ring, 0);
        const AudioTimeStamp t1 = mkTS(1000, true);
        expectSilence("C1 lapped", 128, dst, render(L, 128, &t1, dst, false));
        SARingSnapshot s = snap(ring);
        const SARingReaderStats *x = &s.reader[0];
        CHECK(x->overrunBlocks == 1 && x->overrunJumps == 1 && x->overrunJumpFrames == 640 && x->largestJumpFrames == 640 && x->refusedJumps == 0 && x->silentFrames == 128 && x->calls == 1,
              "C1 counters: overrun %llu jumps %llu frames %llu", (unsigned long long)x->overrunBlocks, (unsigned long long)x->overrunJumps, (unsigned long long)x->overrunJumpFrames);
        CHECK(x->cursor == 1024 && x->fill == 256, "C1: cursor to w - T = 1024, fill T (cursor %lld fill %lld)", (long long)x->cursor, (long long)x->fill);
        CHECK(x->needsReprime == 0 && x->diverged == 0 && s.needsReprime == 0 && x->divergenceJumps == 0, "C1: an ordinary lap asks for nothing");
        CHECK(s.reader[1].calls == 0 && s.reader[1].cursor == 256, "C1: the other reader is untouched");
        const AudioTimeStamp t2 = mkTS(1128, true);
        expectServed("C1 after the jump", 0, 1024, 128, dst, render(L, 128, &t2, dst, true));
        CHECK(snap(ring).reader[0].phaseSelfChanges == 0, "C1: the jump does not read as a phase change (the phase published at the jump is the one the next call computes)");
        const AudioTimeStamp t3 = mkTS(1256, true);
        expectServed("C1 second block", 0, 1152, 128, dst, render(L, 128, &t3, dst, true));   /* fill T = 256 = two blocks, then nothing new arrives */
        const AudioTimeStamp t4 = mkTS(1384, true);
        expectSilence("C1 starved again", 128, dst, render(L, 128, &t4, dst, false));
        s = snap(ring);
        CHECK(s.reader[0].underrunBlocks == 1 && s.reader[0].overrunJumps == 1 && s.reader[0].cursor == 1408, "C1: an underrun after the jump is still just zeros-and-advance (no jump)");
        identity("C1", &s.reader[0]);
        SARingFree(ring);
    }
    {   /* C2: the boundary of DETECTION: w - r == window (512) is served, w - r == 513 is an overrun with a jump to w - T (T = default 1024 / 16 = 64) */
        SARing *ring = mkRing(1024);
        int64_t produced = 0;
        for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
        const AudioTimeStamp ts = mkTS(0, true);
        CHECK(snap(ring).standingFill == 64, "C2: default T = capacity / 16");
        expectServed("C2 boundary w-r == window", 0, 0, 128, dst, render(SARingGetReader(ring, 0), 128, &ts, dst, true));
        SARingFree(ring);
        ring = mkRing(1024);
        produced = 0;
        for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
        saCommit(ring, produced, 1);                                              /* w = 513 */
        expectSilence("C2 513", 128, dst, render(SARingGetReader(ring, 1), 128, &ts, dst, false));
        const SARingSnapshot s = snap(ring);
        CHECK(s.reader[1].overrunBlocks == 1 && s.reader[1].servedBlocks == 0 && s.reader[1].underrunBlocks == 0, "C2: w - r == 513 must be an overrun");
        CHECK(s.reader[1].overrunJumps == 1 && s.reader[1].overrunJumpFrames == 513 - 64 - 128 && s.reader[1].cursor == 513 - 64, "C2: jump to w - T = 449 (frames beyond the normal advance: 321; cursor %lld)", (long long)s.reader[1].cursor);
        SARingFree(ring);
    }
    {   /* C3: the jump bound N - T. T = 256, N = 1024: a jump of EXACTLY 768 is made; 769 is refused (needsReprime, cursor advances by F only, largestJumpFrames records it) */
        for (int variant = 0; variant < 2; variant++) {
            SARing *ring = mkRing(1024);
            int64_t produced = 0;
            for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
            CHECK(SARingPrime(ring, 2), "C3 prime");                              /* r = 256, T = 256 */
            for (int i = 0; i < 7; i++) { saCommit(ring, produced, 128); produced += 128; }   /* w = 1408: w - r = 1152 */
            if (variant == 1) { saCommit(ring, produced, 1); produced += 1; }     /* w = 1409: 1153 */
            SARingReader *L = SARingGetReader(ring, 0);
            const AudioTimeStamp ts = mkTS(500, true);
            expectSilence("C3 lapped", 128, dst, render(L, 128, &ts, dst, false));
            SARingSnapshot s = snap(ring);
            const SARingReaderStats *x = &s.reader[0];
            if (variant == 0) {
                CHECK(x->overrunJumps == 1 && x->overrunJumpFrames == 768 && x->refusedJumps == 0 && x->cursor == 1152 && x->needsReprime == 0 && s.needsReprime == 0, "C3 exactly N - T: jump made (frames %llu cursor %lld)", (unsigned long long)x->overrunJumpFrames, (long long)x->cursor);
            } else {
                CHECK(x->overrunJumps == 0 && x->overrunJumpFrames == 0 && x->refusedJumps == 1 && x->largestJumpFrames == 769 && x->cursor == 384 && x->overrunBlocks == 1, "C3 N - T + 1: refused, the cursor only advances by F (cursor %lld)", (long long)x->cursor);
                CHECK(x->needsReprime == 1 && s.needsReprime == 1 && x->diverged == 0, "C3: a refused jump asks for a re-prime");
                const AudioTimeStamp t2 = mkTS(628, true);
                expectSilence("C3 next block, producer stalled", 128, dst, render(L, 128, &t2, dst, false));   /* the distance shrank by F, so now the jump is within the bound */
                s = snap(ring);
                CHECK(s.reader[0].overrunJumps == 1 && s.reader[0].overrunJumpFrames == 641 && s.reader[0].refusedJumps == 1 && s.reader[0].cursor == 1153 && s.reader[0].needsReprime == 1, "C3: the next call jumps (641 <= 768) and the request for a re-prime stays (sticky)");
            }
            identity("C3", &s.reader[0]);
            SARingFree(ring);
        }
    }
    {   /* C4: FORWARD ONLY. T = 512 (primed to the window): a lapped call whose target w - T is not beyond the normal advance r + F makes NO jump; one frame beyond makes a 1-frame jump */
        for (int variant = 0; variant < 2; variant++) {
            SARing *ring = mkRing(1024);
            int64_t produced = 0;
            for (int i = 0; i < 8; i++) { saCommit(ring, produced, 128); produced += 128; }
            CHECK(SARingPrime(ring, 4), "C4 prime");                              /* r = 512, T = 512 */
            saCommit(ring, produced, variant == 0 ? 1u : 129u);                   /* w = 1025 or 1153 */
            const AudioTimeStamp ts = mkTS(0, true);
            expectSilence("C4 lapped", 128, dst, render(SARingGetReader(ring, 0), 128, &ts, dst, false));
            const SARingSnapshot s = snap(ring);
            const SARingReaderStats *x = &s.reader[0];
            if (variant == 0) CHECK(x->overrunBlocks == 1 && x->overrunJumps == 0 && x->overrunJumpFrames == 0 && x->largestJumpFrames == 0 && x->cursor == 640, "C4: target 513 is behind r + F = 640: no jump, cursor %lld", (long long)x->cursor);
            else CHECK(x->overrunBlocks == 1 && x->overrunJumps == 1 && x->overrunJumpFrames == 1 && x->cursor == 641, "C4: target 641 is one frame beyond r + F = 640: a 1-frame jump, cursor %lld", (long long)x->cursor);
            SARingFree(ring);
        }
    }
    {   /* oversize: F > window is silent whatever the fill; F == window is served */
        SARing *ring = mkRing(1024);
        int64_t produced = 0;
        for (int i = 0; i < 8; i++) { saCommit(ring, produced, 128); produced += 128; }
        CHECK(SARingPrime(ring, 4), "C prime");
        SARingReader *L = SARingGetReader(ring, 0);
        const AudioTimeStamp ts = mkTS(0, true);
        expectSilence("C oversize 513", 513, dst, render(L, 513, &ts, dst, false));
        SARingSnapshot s = snap(ring);
        CHECK(s.reader[0].oversizeBlocks == 1 && s.reader[0].underrunBlocks == 0 && s.reader[0].overrunBlocks == 0 && s.reader[0].silentFrames == 513, "C oversize counters");
        CHECK(s.reader[0].overrunJumps == 0 && s.reader[0].cursor == 512 + 513, "C: oversize never jumps");
        SARingFree(ring);
        ring = mkRing(1024);
        produced = 0;
        for (int i = 0; i < 8; i++) { saCommit(ring, produced, 128); produced += 128; }
        CHECK(SARingPrime(ring, 4), "C prime 2");
        expectServed("C F == window", 0, 512, 512, dst, render(SARingGetReader(ring, 0), 512, &ts, dst, true));
        SARingFree(ring);
    }
}

/* D: output lists the block cannot trust: nothing is written, kAudio_ParamError, the cursor still advances. */
static void scenarioD(void) {
    SARing *ring = mkRing(1024);
    int64_t produced = 0;
    for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
    SARingReader *L = SARingGetReader(ring, 0);
    const uint32_t F = 128;
    float buf[128 + 8 + 8];
    SABigList l;
    const AudioTimeStamp ts = mkTS(0, true);
    for (int variant = 0; variant < 7; variant++) {
        for (size_t i = 0; i < sizeof buf / sizeof buf[0]; i++) buf[i] = SA_SENTINEL;
        memset(&l, 0, sizeof l);
        l.list.mNumberBuffers = 1;
        l.list.mBuffers[0].mNumberChannels = 1;
        l.list.mBuffers[0].mDataByteSize = F * 4u;
        l.list.mBuffers[0].mData = buf;
        AudioBufferList *use = &l.list;
        switch (variant) {
            case 0: use = NULL; break;
            case 1: l.list.mNumberBuffers = 0; break;
            case 2: l.list.mNumberBuffers = 2; break;
            case 3: l.list.mBuffers[0].mNumberChannels = 2; break;
            case 4: l.list.mBuffers[0].mData = NULL; break;
            case 5: l.list.mBuffers[0].mData = (char *)buf + 1; break;
            case 6: l.list.mBuffers[0].mDataByteSize = F * 4u - 1u; break;
        }
        bool silent = true;   /* must be left as set by the block: false */
        const uint64_t before = snap(ring).reader[0].badBufferBlocks;
        const OSStatus s = SARingRender(L, &silent, &ts, F, use);
        CHECK(s == kAudio_ParamError, "D variant %d: status %d, want kAudio_ParamError", variant, (int)s);
        CHECK(!silent, "D variant %d: isSilence must be false when nothing was written", variant);
        CHECK(snap(ring).reader[0].badBufferBlocks == before + 1, "D variant %d: badBufferBlocks not counted", variant);
        for (size_t i = 0; i < sizeof buf / sizeof buf[0]; i++) CHECK(buf[i] == SA_SENTINEL, "D variant %d: output written at %zu", variant, i);
    }
    const SARingSnapshot s = snap(ring);
    CHECK(s.reader[0].badBufferBlocks == 7 && s.reader[0].calls == 7 && s.reader[0].cursor == 7 * 128 && s.reader[0].silentFrames == 0 && s.reader[0].framesRequested == 7 * 128, "D counters and cursor");
    identity("D", &s.reader[0]);
    SARingFree(ring);
}

/* E: the producer refuses what it cannot read, counts it and never guesses; NaN, infinity and -0 pass through bit for bit. */
static void scenarioE(void) {
    SARing *ring = mkRing(1024);
    AudioTimeStamp now = { 0 };
    AudioBufferList out = { 0 };
    float good[2 * 600];
    for (int i = 0; i < 2 * 600; i++) good[i] = 0.5f;
    SABigList l;
    uint32_t wantFlags = 0;
    uint64_t wantRejected = 0;
    for (int variant = 0; variant < 11; variant++) {
        memset(&l, 0, sizeof l);
        l.list.mNumberBuffers = 1;
        l.list.mBuffers[0].mNumberChannels = 2;
        l.list.mBuffers[0].mDataByteSize = 128 * 8u;
        l.list.mBuffers[0].mData = good;
        const AudioBufferList *use = &l.list;
        uint32_t flag = 0;
        switch (variant) {
            case 0: use = NULL; flag = SA_RING_REJECT_NO_BUFFERS; break;
            case 1: l.list.mNumberBuffers = 0; flag = SA_RING_REJECT_NO_BUFFERS; break;
            case 2: l.list.mNumberBuffers = 2; flag = SA_RING_REJECT_BAD_LAYOUT; break;
            case 3: l.list.mBuffers[0].mNumberChannels = 1; flag = SA_RING_REJECT_BAD_LAYOUT; break;
            case 4: l.list.mBuffers[0].mNumberChannels = 4; flag = SA_RING_REJECT_BAD_LAYOUT; break;
            case 5: l.list.mBuffers[0].mNumberChannels = 0; flag = SA_RING_REJECT_BAD_LAYOUT; break;
            case 6: l.list.mBuffers[0].mData = NULL; flag = SA_RING_REJECT_NULL_DATA; break;
            case 7: l.list.mBuffers[0].mData = (char *)good + 1; flag = SA_RING_REJECT_MISALIGNED; break;
            case 8: l.list.mBuffers[0].mDataByteSize = 12; flag = SA_RING_REJECT_PARTIAL; break;
            case 9: l.list.mBuffers[0].mDataByteSize = 0; flag = SA_RING_REJECT_EMPTY; break;
            case 10: l.list.mBuffers[0].mDataByteSize = 513 * 8u; flag = SA_RING_REJECT_OVERSIZE; break;   /* ring 1024: at most 512 per commit */
        }
        const OSStatus s = SARingIOProc(0, &now, use, &now, &out, &now, ring);
        wantFlags |= flag; wantRejected++;
        const SARingSnapshot sn = snap(ring);
        CHECK(s == 0, "E variant %d: the IOProc must return 0, got %d", variant, (int)s);
        CHECK(sn.rejectedCommits == wantRejected, "E variant %d: rejected %llu want %llu", variant, (unsigned long long)sn.rejectedCommits, (unsigned long long)wantRejected);
        CHECK(sn.rejectFlags == wantFlags, "E variant %d: flags 0x%x want 0x%x", variant, sn.rejectFlags, wantFlags);
        CHECK(sn.w == 0 && sn.commits == 0, "E variant %d: a refused callback must write nothing (w %lld)", variant, (long long)sn.w);
    }
    CHECK(SARingIOProc(0, &now, &l.list, &now, &out, &now, NULL) == 0, "E: NULL inClientData");
    SARingWrite(ring, good, 0);
    SARingWrite(ring, good, 513);
    SARingSnapshot sn = snap(ring);
    CHECK(sn.rejectedCommits == wantRejected + 2 && sn.w == 0, "E: SARingWrite refuses 0 and 513 frames too");
    CHECK(saCommit(ring, 0, 128) == 0, "E: a good commit");
    sn = snap(ring);
    CHECK(sn.w == 128 && sn.commits == 1 && sn.lastCommitFrames == 128 && sn.rejectedCommits == wantRejected + 2 && sn.capacity == 1024 && sn.maxCommit == 512, "E: a good commit after the refusals");
    /* NaN, +inf, -inf, a denormal and -0 in both channels, frames 128 ..< 136: copied unchanged */
    uint32_t bits[2 * 8] = { 0x7fc00000u, 0x7fc00001u, 0x7f800000u, 0xff800000u, 0x00000001u, 0x80000000u, 0x80000000u, 0x00000001u,
                             0xff800000u, 0x7f800000u, 0x7fc00001u, 0x7fc00000u, 0x3f800000u, 0xbf800000u, 0x80000001u, 0x00800000u };
    float special[2 * 8];
    memcpy(special, bits, sizeof special);
    SARingWrite(ring, special, 8);
    SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
    float dst[136 + 8];
    const AudioTimeStamp ts = mkTS(0, true);
    for (uint32_t ch = 0; ch < 2; ch++) {
        const RR rr = render(rd[ch], 136, &ts, dst, true);
        CHECK(rr.status == 0 && !rr.silent, "E special values: block not served");
        int bad = 0;
        for (uint32_t i = 0; i < 128; i++) if (dst[i] != saSample(ch, i)) bad++;
        for (uint32_t i = 0; i < 8; i++) { uint32_t got; memcpy(&got, &dst[128 + i], 4); if (got != bits[2 * i + ch]) bad++; }
        CHECK(bad == 0, "E ch%u: %d samples differ (NaN/inf/denormal/-0 must pass through bit for bit)", ch, bad);
    }
    SARingFree(ring);
}

/* F: prime. */
static void scenarioF(void) {
    SARing *ring = mkRing(1024);
    float dst[128 + 8];
    SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
    CHECK(!SARingPrime(ring, 4), "F: nothing committed yet");
    CHECK(!SARingPrime(ring, 0), "F: zero callbacks");
    int64_t produced = 0;
    for (int i = 0; i < 3; i++) { saCommit(ring, produced, 128); produced += 128; }
    CHECK(!SARingPrime(ring, 4), "F: only 3 callbacks committed, T = 4");
    SARingSnapshot s = snap(ring);
    CHECK(s.reader[0].cursor == 0 && s.reader[1].cursor == 0, "F: a refused prime changes nothing");
    const AudioTimeStamp t1 = mkTS(1000, true);
    expectServed("F", 0, 0, 128, dst, render(rd[0], 128, &t1, dst, true));
    CHECK(SARingPrime(ring, 3), "F: prime(3) with 3 commits of 128");
    s = snap(ring);
    CHECK(s.reader[0].cursor == 0 && s.reader[1].cursor == 0 && s.reader[0].calls == 0 && s.reader[0].servedBlocks == 0, "F: prime resets the counters (cursor %lld)", (long long)s.reader[0].cursor);
    const AudioTimeStamp t2 = mkTS(99999, true);   /* a jump in sample time right after a prime must not count as a phase change */
    expectServed("F", 0, 0, 128, dst, render(rd[0], 128, &t2, dst, true));
    CHECK(snap(ring).reader[0].phaseSelfChanges == 0, "F: prime resets the published phase");
    saCommit(ring, produced, 256); produced += 256;   /* w = 640, 4 commits, the last one 256 frames */
    CHECK(!SARingPrime(ring, 4), "F: depth 4 x 256 = 1024 exceeds what was written (640)");
    CHECK(!SARingPrime(ring, 3), "F: depth 3 x 256 = 768 exceeds what the ring can serve (512)");
    CHECK(SARingPrime(ring, 2), "F: prime(2): depth 512");
    s = snap(ring);
    CHECK(s.reader[0].cursor == 128 && s.reader[1].cursor == 128, "F: start = 640 - 512 = 128 for BOTH readers (got %lld, %lld)", (long long)s.reader[0].cursor, (long long)s.reader[1].cursor);
    CHECK(s.reader[0].fill == 512 && s.reader[1].fill == 512, "F: fill after prime");
    CHECK(s.standingFill == 512, "F: T := the primed depth (512), got %u", s.standingFill);
    SARingFree(ring);
}

/* G: the snapshot. fill is w - cursor from the values IN the snapshot; the two readers keep separate counters. */
static void scenarioG(void) {
    SARing *ring = mkRing(1024);
    int64_t produced = 0;
    for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
    SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
    float dst[128 + 8];
    for (int i = 0; i < 5; i++) { const AudioTimeStamp ts = mkTS(128.0 * i, true); render(rd[0], 128, &ts, dst, true); }   /* L: 4 served then 1 underrun */
    for (int i = 0; i < 3; i++) { const AudioTimeStamp ts = mkTS(128.0 * i, true); render(rd[1], 128, &ts, dst, true); }   /* R: 3 served (same render times: equal phase, no divergence) */
    const SARingSnapshot s = snap(ring);
    CHECK(s.reader[0].calls == 5 && s.reader[1].calls == 3 && s.reader[0].underrunBlocks == 1 && s.reader[1].underrunBlocks == 0, "G separate counters");
    for (int c = 0; c < 2; c++) {
        CHECK(s.reader[c].fill == s.w - s.reader[c].cursor, "G ch%d fill %lld != w - cursor %lld", c, (long long)s.reader[c].fill, (long long)(s.w - s.reader[c].cursor));
        identity("G", &s.reader[c]);
    }
    CHECK(s.reader[0].fill == -128 && s.reader[1].fill == 128, "G: fill L %lld R %lld", (long long)s.reader[0].fill, (long long)s.reader[1].fill);
    CHECK(SARingGetReader(ring, 2) == NULL, "G: only channels 0 and 1");
    SARingFree(ring);
}

/* H: the phase check and the weaker rule, in both block orders, with a skipped block and an unusable timestamp. */
static void scenarioH(void) {
    float dst[192 + 8];
    for (int order = 0; order < 2; order++) {   /* H1: lockstep, F varying per cycle, valid sample times advancing by F: no change, no mismatch */
        SARing *ring = mkRing(4096);
        int64_t produced = 0;
        for (int i = 0; i < 16; i++) { saCommit(ring, produced, 128); produced += 128; }
        SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
        const uint32_t Fs[4] = { 128, 64, 192, 128 };
        double t = 5000;
        for (int c = 0; c < 12; c++) {
            const uint32_t F = Fs[c % 4];
            const AudioTimeStamp ts = mkTS(t, true);
            for (int k = 0; k < 2; k++) { const uint32_t ch = order == 0 ? (uint32_t)k : 1u - (uint32_t)k; render(rd[ch], F, &ts, dst, true); }
            t += F;
        }
        const SARingSnapshot s = snap(ring);
        for (int c = 0; c < 2; c++)
            CHECK(s.reader[c].phaseValidCalls == 12 && s.reader[c].phaseSelfChanges == 0 && s.reader[c].phaseMismatches == 0 && s.reader[c].weakRuleViolations == 0 && s.reader[c].phaseInvalidCalls == 0,
                  "H1 order %d ch%d: valid %llu self %llu mismatch %llu", order, c, (unsigned long long)s.reader[c].phaseValidCalls, (unsigned long long)s.reader[c].phaseSelfChanges, (unsigned long long)s.reader[c].phaseMismatches);
        SARingFree(ring);
    }
    {   /* H2: the right channel's block is skipped for one cycle: its own phase changes once (by one frameCount); at its next call it is BEHIND the left's published
         * phase, so it jumps FORWARD by that one frameCount (counted) and from then on both blocks read the same frames. (Step 6b-1 only counted; the jump is 6b-3a-1.) */
        SARing *ring = mkRing(4096);
        int64_t produced = 0;
        for (int i = 0; i < 16; i++) { saCommit(ring, produced, 128); produced += 128; }
        SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
        double t = 0;
        for (int c = 0; c < 6; c++, t += 128) {
            const AudioTimeStamp ts = mkTS(t, true);
            expectServed("H2 L", 0, 128 * c, 128, dst, render(rd[0], 128, &ts, dst, true));
            if (c != 2) {                                                    /* cycle 2: R is not asked; from cycle 3 it reads where L reads */
                expectServed("H2 R", 1, 128 * c, 128, dst, render(rd[1], 128, &ts, dst, true));
            }
        }
        const SARingSnapshot s = snap(ring);
        CHECK(s.reader[1].phaseSelfChanges == 1, "H2: R phaseSelfChanges %llu want 1", (unsigned long long)s.reader[1].phaseSelfChanges);
        CHECK(s.reader[0].phaseSelfChanges == 0, "H2: L phaseSelfChanges %llu want 0", (unsigned long long)s.reader[0].phaseSelfChanges);
        /* R sees L's phase at once (cycle 3), counts one mismatch and jumps; L never sees a different phase (R publishes the post-jump phase = L's). */
        CHECK(s.reader[0].phaseMismatches == 0 && s.reader[1].phaseMismatches == 1, "H2: mismatches L %llu R %llu want 0 and 1", (unsigned long long)s.reader[0].phaseMismatches, (unsigned long long)s.reader[1].phaseMismatches);
        CHECK(s.reader[1].divergenceJumps == 1 && s.reader[1].divergenceJumpFrames == 128 && s.reader[1].largestJumpFrames == 128 && s.reader[0].divergenceJumps == 0, "H2: R jumped once by 128, L never");
        CHECK(s.reader[0].cursor == 768 && s.reader[1].cursor == 768, "H2: both cursors end at 768 (L %lld, R %lld)", (long long)s.reader[0].cursor, (long long)s.reader[1].cursor);
        CHECK(s.reader[0].diverged == 0 && s.reader[1].diverged == 0 && s.reader[0].needsReprime == 0 && s.reader[1].needsReprime == 0 && s.needsReprime == 0, "H2: a repaired divergence asks for nothing");
        SARingFree(ring);
    }
    for (int order = 0; order < 2; order++) {   /* H3: unusable timestamps: counted as invalid, weaker rule (other cursor - mine must be 0 or frameCount) holds in lockstep */
        SARing *ring = mkRing(4096);
        int64_t produced = 0;
        for (int i = 0; i < 16; i++) { saCommit(ring, produced, 128); produced += 128; }
        SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
        AudioTimeStamp stamps[4];
        stamps[0] = mkTS(12345, false);                         /* flag not set, garbage value */
        stamps[1] = mkTS(NAN, true);                            /* flag set, value not finite */
        stamps[2] = mkTS(INFINITY, true);
        stamps[3] = mkTS(0, false);
        for (int c = 0; c < 8; c++)
            for (int k = 0; k < 2; k++) {
                const uint32_t ch = order == 0 ? (uint32_t)k : 1u - (uint32_t)k;
                if (c % 2 == 0) render(rd[ch], 128, &stamps[(c / 2) % 4], dst, true);
                else {   /* a NULL timestamp */
                    bool silent = true; float o[128 + 8]; AudioBufferList l = { 0 };
                    l.mNumberBuffers = 1; l.mBuffers[0].mNumberChannels = 1; l.mBuffers[0].mDataByteSize = 512; l.mBuffers[0].mData = o;
                    CHECK(SARingRender(rd[ch], &silent, NULL, 128, &l) == 0 && !silent, "H3: NULL timestamp must still serve");
                }
            }
        SARingSnapshot s = snap(ring);
        for (int c = 0; c < 2; c++) {
            CHECK(s.reader[c].phaseInvalidCalls == 8 && s.reader[c].phaseValidCalls == 0 && s.reader[c].weakRuleViolations == 0, "H3 order %d ch%d: invalid %llu valid %llu weak %llu", order, c,
                  (unsigned long long)s.reader[c].phaseInvalidCalls, (unsigned long long)s.reader[c].phaseValidCalls, (unsigned long long)s.reader[c].weakRuleViolations);
            CHECK(s.reader[c].diverged == 0 && s.reader[c].needsReprime == 0, "H3 order %d ch%d: d == 0 and d == frameCount are lockstep, not divergence (flags stay clear)", order, c);
        }
        CHECK(s.needsReprime == 0, "H3 order %d: no re-prime asked in lockstep", order);
        /* one cycle where R is skipped: the next cycle both blocks see a gap of 2 x frameCount or -frameCount */
        render(rd[0], 128, &stamps[0], dst, true);
        for (int k = 0; k < 2; k++) render(rd[k], 128, &stamps[0], dst, true);
        s = snap(ring);
        CHECK(s.reader[0].weakRuleViolations == 1 && s.reader[1].weakRuleViolations == 1, "H3 order %d: skipped block: weak violations L %llu R %llu want 1 and 1", order,
              (unsigned long long)s.reader[0].weakRuleViolations, (unsigned long long)s.reader[1].weakRuleViolations);
        /* with no usable phase the render thread cannot tell which block should move: it counts, sets the sticky diverged flag, asks for a re-prime, and NEVER jumps */
        for (int c = 0; c < 2; c++)
            CHECK(s.reader[c].diverged == 1 && s.reader[c].needsReprime == 1 && s.reader[c].divergenceJumps == 0 && s.reader[c].divergenceJumpFrames == 0 && s.reader[c].overrunJumps == 0 && s.reader[c].refusedJumps == 0,
                  "H3 order %d ch%d: invalid timestamp divergence: flag and request, no jump", order, c);
        CHECK(s.needsReprime == 1, "H3 order %d: the ring-level request", order);
        SARingFree(ring);
    }
}

/* I: creation guards and the producer's margin. */
static void scenarioI(void) {
    CHECK(SARingCreate(0) == NULL && SARingCreate(1) == NULL && SARingCreate(3) == NULL && SARingCreate(1000) == NULL && SARingCreate(SA_RING_MAX_CAPACITY_FRAMES * 2u) == NULL && SARingCreate(UINT32_MAX) == NULL,
          "I: capacities that are not a power of two in [2, max] must be refused");
    SARing *two = SARingCreate(2);
    CHECK(two != NULL, "I: capacity 2");
    SARingFree(two);
    SARingFree(NULL);
    SARing *def = SARingCreate(SA_RING_DEFAULT_CAPACITY_FRAMES);
    CHECK(def != NULL, "I: the default capacity");
    if (def) { const SARingSnapshot s = snap(def); CHECK(s.capacity == 32768 && s.maxCommit == 16384, "I: default capacity and margin"); }
    SARingFree(def);
}

/* J: the producer gets ahead WHILE a block is being copied (made deterministic with the hook). The block must be reported torn and be all zeros, whether the
 * producer only just crossed the margin (data still intact: conservative) or lapped the reader completely (data really overwritten). */
static void scenarioJ(void) {
    float dst[128 + 8];
    for (int variant = 0; variant < 3; variant++) {
        static const int commits[3] = { 0, 1, 5 };   /* 0: nothing happens (served); 1: w - r becomes 512 + 128 > window (margin crossed, data intact); 5: w - r = 1152, the copied frames were overwritten */
        SARing *ring = mkRing(1024);
        int64_t produced = 0;
        for (int i = 0; i < 8; i++) { saCommit(ring, produced, 128); produced += 128; }
        CHECK(SARingPrime(ring, 4), "J prime");                         /* r = 1024 - 512 = 512; w - r == window: served unless the producer moves */
        gHookProduced = &produced;
        gHookCommits = commits[variant];
        const AudioTimeStamp ts = mkTS(0, true);
        const RR rr = render(SARingGetReader(ring, 0), 128, &ts, dst, variant == 0);
        gHookCommits = 0;
        const SARingSnapshot s = snap(ring);
        if (variant == 0) {
            expectServed("J0", 0, 512, 128, dst, rr);
            CHECK(s.reader[0].tornBlocks == 0 && s.reader[0].servedBlocks == 1, "J0 counters");
        } else {
            expectSilence("J torn", 128, dst, rr);
            CHECK(s.reader[0].tornBlocks == 1 && s.reader[0].servedBlocks == 0 && s.reader[0].overrunBlocks == 0 && s.reader[0].silentFrames == 128 && s.reader[0].cursor == 640, "J%d counters: torn %llu served %llu", variant, (unsigned long long)s.reader[0].tornBlocks, (unsigned long long)s.reader[0].servedBlocks);
        }
        identity("J", &s.reader[0]);
        SARingFree(ring);
    }
}

/* K: a reader that is AHEAD of the producer at the moment of the call (r > w), by less than a block, by more than a block and by many blocks, on a ring that
 * has wrapped (so the slots it would read hold old data, never zeros). Every such block must be silent: never old data, never zeros passed off as served. */
static void scenarioK(void) {
    SARing *ring = mkRing(1024);
    int64_t produced = 0;
    for (int i = 0; i < 12; i++) { saCommit(ring, produced, 128); produced += 128; }   /* w = 1536: slots hold frames 512 ..< 1536 */
    CHECK(SARingPrime(ring, 4), "K prime");                                            /* start 1536 - 512 = 1024 */
    SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
    float dst[400 + 8];
    const AudioTimeStamp ts = mkTS(0, true);
    for (int c = 0; c < 4; c++) for (uint32_t ch = 0; ch < 2; ch++) expectServed("K serve", ch, 1024 + 128 * c, 128, dst, render(rd[ch], 128, &ts, dst, true));
    const uint32_t Fs[5] = { 128, 128, 64, 300, 1 };
    for (int i = 0; i < 5; i++)                                                        /* no commit in between: r - w = 128, 256, 320, 620, ... */
        for (uint32_t ch = 0; ch < 2; ch++) expectSilence("K ahead", Fs[i], dst, render(rd[ch], Fs[i], &ts, dst, false));
    const SARingSnapshot s = snap(ring);
    for (int c = 0; c < 2; c++) {
        CHECK(s.reader[c].underrunBlocks == 5 && s.reader[c].servedBlocks == 4 && s.reader[c].overrunBlocks == 0 && s.reader[c].tornBlocks == 0, "K ch%d counters", c);
        CHECK(s.reader[c].cursor == 1536 + 128 + 128 + 64 + 300 + 1 && s.reader[c].fill == -(128 + 128 + 64 + 300 + 1), "K ch%d cursor %lld fill %lld", c, (long long)s.reader[c].cursor, (long long)s.reader[c].fill);
    }
    SARingFree(ring);
}

/* L: the producer is caught between its sample stores and its release store of w: a maximal commit (capacity / 2 frames) is IN the ring but w has not moved.
 * A reader at the very edge of its window (w - r == window) must still get exactly its own frames: the in-flight commit overwrites only frames older than
 * w - capacity + maxCommit = r. This is the central claim of the margin. */
static void scenarioL(void) {
    for (int variant = 0; variant < 3; variant++) {
        const uint32_t F = variant == 2 ? 512u : 128u, ch = variant == 1 ? 1u : 0u;
        SARing *ring = mkRing(1024);
        int64_t produced = 0;
        for (int i = 0; i < 8; i++) { saCommit(ring, produced, 128); produced += 128; }
        CHECK(SARingPrime(ring, 4), "L prime");                                        /* r = 512 = w - window */
        gUnpublished = 512; gUnpublishedAt = &produced;
        float dst[512 + 8];
        const AudioTimeStamp ts = mkTS(0, true);
        const RR rr = render(SARingGetReader(ring, ch), F, &ts, dst, true);
        gUnpublished = 0;
        expectServed("L in-flight maximal commit", ch, 512, F, dst, rr);
        const SARingSnapshot s = snap(ring);
        CHECK(s.reader[ch].servedBlocks == 1 && s.reader[ch].tornBlocks == 0 && s.w == 1024, "L%d: served, not torn, w unchanged (w %lld)", variant, (long long)s.w);
        SARingFree(ring);
    }
}

/* F2: prime needs T COMMITTED callbacks, not just T x the latest size of data. Commits of 512 then 128 leave 4 x 128 <= w but only two callbacks. */
static void scenarioF2(void) {
    SARing *ring = mkRing(1024);
    saCommit(ring, 0, 512);
    saCommit(ring, 512, 128);
    CHECK(!SARingPrime(ring, 4), "F2: two callbacks committed, T = 4, even though 4 x 128 frames were written");
    CHECK(SARingPrime(ring, 2), "F2: prime(2): depth 256");
    const SARingSnapshot s = snap(ring);
    CHECK(s.reader[0].cursor == 384 && s.reader[1].cursor == 384, "F2: start = 640 - 256");
    SARingFree(ring);
}

/* ---- Step 6b-3a-1 scenarios ---- */

/* M: the per-call frame-count record: distinct values in order of first appearance with their call counts, the overflow counter, min and max (over EVERY call, the
 * overflow ones and the bad-buffer ones included), separate per reader, reset by prime. */
static void scenarioM(void) {
    SARing *ring = mkRing(4096);
    int64_t produced = 0;
    for (int i = 0; i < 16; i++) { saCommit(ring, produced, 128); produced += 128; }
    SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
    float dst[300 + 8];
    double t = 0;
    /* L: 1..9 then 1, 2, 3 again, with the sample time advancing by each F (a lone reader: no peer, no divergence). Eight slots: 1..8 in order; 9 overflows. */
    const uint32_t Ls[12] = { 5, 7, 5, 300, 2, 9, 11, 13, 17, 5, 7, 5 };
    for (int i = 0; i < 12; i++) { const AudioTimeStamp ts = mkTS(t, true); render(rd[0], Ls[i], &ts, dst, true); t += Ls[i]; }
    /* R: only two values, in the opposite order */
    t = 0;
    const uint32_t Rs[4] = { 64, 32, 64, 64 };
    for (int i = 0; i < 4; i++) { const AudioTimeStamp ts = mkTS(t, true); render(rd[1], Rs[i], &ts, dst, true); t += Rs[i]; }
    SARingSnapshot s = snap(ring);
    const SARingReaderStats *x = &s.reader[0], *y = &s.reader[1];
    /* distinct in order of appearance: 5, 7, 300, 2, 9, 11, 13, 17 (eight slots); the 12 calls are 5,7,5,300,2,9,11,13,17,5,7,5 -> all 8 distinct values fit, so no overflow yet */
    CHECK(x->distinctFrameCounts == 8 && x->frameCountOverflowCalls == 0, "M L: %u slots, overflow %llu", x->distinctFrameCounts, (unsigned long long)x->frameCountOverflowCalls);
    const uint32_t wantV[8] = { 5, 7, 300, 2, 9, 11, 13, 17 };
    const uint64_t wantC[8] = { 4, 2, 1, 1, 1, 1, 1, 1 };
    for (int k = 0; k < 8; k++) CHECK(x->frameCountValue[k] == wantV[k] && x->frameCountCalls[k] == wantC[k], "M L slot %d: value %u calls %llu want %u / %llu", k, x->frameCountValue[k], (unsigned long long)x->frameCountCalls[k], wantV[k], (unsigned long long)wantC[k]);
    CHECK(x->minFrameCount == 2 && x->maxFrameCount == 300 && x->calls == 12, "M L min %u max %u", x->minFrameCount, x->maxFrameCount);
    CHECK(y->distinctFrameCounts == 2 && y->frameCountValue[0] == 64 && y->frameCountCalls[0] == 3 && y->frameCountValue[1] == 32 && y->frameCountCalls[1] == 1 && y->frameCountValue[2] == 0 && y->frameCountCalls[2] == 0
          && y->minFrameCount == 32 && y->maxFrameCount == 64 && y->frameCountOverflowCalls == 0, "M R: its own table, not L's");
    identity("M L", x); identity("M R", y);
    /* a ninth DISTINCT value overflows: counted once, the table unchanged, but min / max still see it */
    { const AudioTimeStamp ts = mkTS(t, true); render(rd[0], 1, &ts, dst, true); }
    s = snap(ring);
    CHECK(s.reader[0].distinctFrameCounts == 8 && s.reader[0].frameCountOverflowCalls == 1 && s.reader[0].minFrameCount == 1 && s.reader[0].frameCountValue[7] == 17 && s.reader[0].frameCountCalls[7] == 1, "M: the ninth distinct value overflows");
    { const AudioTimeStamp ts = mkTS(t + 1, true); render(rd[0], 1, &ts, dst, true); }   /* the SAME unseen value again: overflow counts again, no slot is ever freed */
    { const AudioTimeStamp ts = mkTS(t + 2, true); render(rd[0], 5, &ts, dst, true); }   /* a value already in the table is still counted in its slot after the table filled */
    s = snap(ring);
    CHECK(s.reader[0].frameCountOverflowCalls == 2 && s.reader[0].frameCountCalls[0] == 5 && s.reader[0].calls == 15, "M: overflow 2, slot 0 now 5 calls");
    identity("M L2", &s.reader[0]);
    SARingFree(ring);

    /* every call is recorded, including a bad buffer and an oversize request; UINT32_MAX is a real value (min must not read "none") */
    ring = mkRing(1024);
    for (int i = 0; i < 4; i++) { saCommit(ring, 128 * i, 128); }
    SARingReader *L = SARingGetReader(ring, 0);
    bool silent = false;
    CHECK(SARingRender(L, &silent, NULL, 300, NULL) == kAudio_ParamError, "M: bad buffer");
    s = snap(ring);
    CHECK(s.reader[0].distinctFrameCounts == 1 && s.reader[0].frameCountValue[0] == 300 && s.reader[0].frameCountCalls[0] == 1 && s.reader[0].badBufferBlocks == 1 && s.reader[0].minFrameCount == 300 && s.reader[0].maxFrameCount == 300, "M: a bad-buffer call is in the table");
    SARingFree(ring);
    ring = mkRing(1024);
    L = SARingGetReader(ring, 0);
    { float big[8]; AudioBufferList l = { 0 }; l.mNumberBuffers = 1; l.mBuffers[0].mNumberChannels = 1; l.mBuffers[0].mDataByteSize = 32; l.mBuffers[0].mData = big;
      CHECK(SARingRender(L, &silent, NULL, 0xffffffffu, &l) == kAudio_ParamError, "M: absurd F is refused"); }
    s = snap(ring);
    CHECK(s.reader[0].minFrameCount == 0xffffffffu && s.reader[0].maxFrameCount == 0xffffffffu && s.reader[0].distinctFrameCounts == 1, "M: UINT32_MAX is a value, min %u max %u", s.reader[0].minFrameCount, s.reader[0].maxFrameCount);
    for (int i = 0; i < 4; i++) saCommit(ring, 128 * i, 128);
    { float d2[16 + 8]; const AudioTimeStamp ts = mkTS(0, true); render(L, 16, &ts, d2, true); }
    s = snap(ring);
    CHECK(s.reader[0].minFrameCount == 16 && s.reader[0].maxFrameCount == 0xffffffffu, "M: min follows, max stays");
    SARingFree(ring);

    /* prime clears the record */
    ring = mkRing(1024);
    for (int i = 0; i < 4; i++) saCommit(ring, 128 * i, 128);
    L = SARingGetReader(ring, 0);
    { const AudioTimeStamp ts = mkTS(0, true); render(L, 100, &ts, dst, true); render(L, 50, &ts, dst, true); }
    CHECK(SARingPrime(ring, 2), "M prime");
    s = snap(ring);
    CHECK(s.reader[0].distinctFrameCounts == 0 && s.reader[0].frameCountValue[0] == 0 && s.reader[0].frameCountCalls[0] == 0 && s.reader[0].frameCountOverflowCalls == 0 && s.reader[0].minFrameCount == 0 && s.reader[0].maxFrameCount == 0 && s.reader[0].calls == 0, "M: prime resets the table, min, max");
    SARingFree(ring);
}

/* One engine cycle for the pair scenarios: the producer commits `commit` frames (frames `*produced` ..), then the blocks run in `order` (0: L then R, 1: R then L)
 * with the given frame counts (0 = that block is not asked this cycle) and the valid sample time `t`. Served blocks are checked against the frame index the
 * block's cursor says it started at (cursor after the call - F). Returns the two results through rr. */
typedef struct { bool ran[2]; bool silent[2]; int64_t start[2]; } Cycle;
static Cycle pairCycle(SARing *ring, int64_t *produced, uint32_t commit, int order, uint32_t FL, uint32_t FR, double t, bool validTime) {
    Cycle cy = { { false, false }, { true, true }, { -1, -1 } };
    if (commit) { saCommit(ring, *produced, commit); *produced += commit; }
    const AudioTimeStamp ts = mkTS(t, validTime);
    static float dst[2][600 + 8];
    const uint32_t Fs[2] = { FL, FR };
    for (int k = 0; k < 2; k++) {
        const int ch = order == 0 ? k : 1 - k;
        if (Fs[ch] == 0) continue;
        const RR rr = render(SARingGetReader(ring, (uint32_t)ch), Fs[ch], &ts, dst[ch], true);
        cy.ran[ch] = true;
        cy.silent[ch] = rr.silent;
        const int64_t startIdx = snap(ring).reader[ch].cursor - (int64_t)Fs[ch];   /* a served block ends at the cursor */
        cy.start[ch] = startIdx;
        if (!rr.silent) {
            int bad = 0;
            for (uint32_t i = 0; i < Fs[ch]; i++) if (dst[ch][i] != saSample((uint32_t)ch, startIdx + i)) bad++;
            CHECK(bad == 0, "pairCycle ch%d: served block wrong at start %lld (%d samples)", ch, (long long)startIdx, bad);
        } else {
            int bad = 0;
            for (uint32_t i = 0; i < Fs[ch]; i++) if (dst[ch][i] != 0.0f) bad++;
            CHECK(bad == 0, "pairCycle ch%d: silent block not all zeros", ch);
        }
    }
    return cy;
}

/* N: two readers lapped in the same cycle, with a producer commit between the two blocks. Valid sample times (N1): the first block jumps to w - T and publishes the phase
 * it will have next; the second block, at its own first call, sees that phase, is BEHIND, divergence-jumps to the first block's position and is then served (it never
 * needs its own overrun jump). The first block's call has NO usable sample time (N2): nothing is published, so each block picks ITS OWN w - T, the two cursors differ by the
 * commit, and in the next cycle the behind block's divergence jump re-aligns them. Both in either block order. */
static void scenarioN(void) {
    for (int variant = 0; variant < 2; variant++) {
        for (int order = 0; order < 2; order++) {
            SARing *ring = mkRing(2048);
            int64_t produced = 0;
            for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
            CHECK(SARingPrime(ring, 2), "N prime");                               /* both at 256, T = 256, maxJump = 2048 - 256 */
            for (int i = 0; i < 10; i++) { saCommit(ring, produced, 128); produced += 128; }   /* w = 1792: lapped by 1536 > window 1024 */
            const uint32_t first = (uint32_t)order, second = 1u - (uint32_t)order;
            float dst[128 + 8];
            const AudioTimeStamp t1First = mkTS(1000, variant == 0), t1 = mkTS(1000, true);
            expectSilence("N first lapped", 128, dst, render(SARingGetReader(ring, first), 128, &t1First, dst, false));
            saCommit(ring, produced, 128); produced += 128;                       /* the producer commits BETWEEN the two blocks: w = 1920 for the second one */
            SARingSnapshot s = snap(ring);
            CHECK(s.reader[first].cursor == 1792 - 256 && s.reader[first].overrunJumps == 1 && s.reader[first].overrunJumpFrames == (1792 - 256) - (256 + 128), "N%d order %d: the first block jumped to ITS w - T = 1536", variant + 1, order);
            if (variant == 0) {
                expectServed("N1 second block: divergence jump, then served", second, 1408, 128, dst, render(SARingGetReader(ring, second), 128, &t1, dst, true));
                s = snap(ring);
                CHECK(s.reader[second].divergenceJumps == 1 && s.reader[second].divergenceJumpFrames == 1152 && s.reader[second].overrunBlocks == 0 && s.reader[second].overrunJumps == 0 && s.reader[second].cursor == 1536, "N1 order %d: the second block aligned itself to the first at its own first call", order);
                CHECK(s.reader[0].cursor == s.reader[1].cursor, "N1 order %d: equal cursors after the first cycle", order);
                saCommit(ring, produced, 128); produced += 128;                   /* w = 2048 */
                const AudioTimeStamp t2 = mkTS(1128, true);
                expectServed("N1 next cycle first block", first, 1536, 128, dst, render(SARingGetReader(ring, first), 128, &t2, dst, true));
                expectServed("N1 next cycle second block", second, 1536, 128, dst, render(SARingGetReader(ring, second), 128, &t2, dst, true));
                s = snap(ring);
                CHECK(s.reader[first].divergenceJumps == 0 && s.reader[first].phaseSelfChanges == 0 && s.reader[second].phaseSelfChanges == 0 && s.reader[first].phaseMismatches == 0, "N1 order %d: nothing further to repair", order);
            } else {
                expectSilence("N2 second lapped on its own", 128, dst, render(SARingGetReader(ring, second), 128, &t1, dst, false));
                s = snap(ring);
                CHECK(s.reader[second].cursor == 1920 - 256 && s.reader[second].overrunJumps == 1 && s.reader[second].overrunJumpFrames == (1920 - 256) - (256 + 128) && s.reader[second].divergenceJumps == 0,
                      "N2 order %d: the second block picked ITS OWN w - T = 1664 (cursor %lld)", order, (long long)s.reader[second].cursor);
                CHECK(s.reader[first].cursor != s.reader[second].cursor, "N2 order %d: the two cursors differ by the commit", order);
                saCommit(ring, produced, 128); produced += 128;                   /* w = 2048 */
                const AudioTimeStamp t2 = mkTS(1128, true);
                expectServed("N2 next cycle: the behind block, after its divergence jump", first, 1664, 128, dst, render(SARingGetReader(ring, first), 128, &t2, dst, true));
                expectServed("N2 next cycle: the ahead block", second, 1664, 128, dst, render(SARingGetReader(ring, second), 128, &t2, dst, true));
                s = snap(ring);
                CHECK(s.reader[first].divergenceJumps == 1 && s.reader[first].divergenceJumpFrames == 128 && s.reader[second].divergenceJumps == 0, "N2 order %d: only the behind block jumped, by one commit", order);
                CHECK(s.reader[first].phaseSelfChanges == 0 && s.reader[second].phaseSelfChanges == 0 && s.reader[first].phaseMismatches == 1 && s.reader[second].phaseMismatches == 0, "N2 order %d: neither jump reads as a phase change; one mismatch, seen by the behind block", order);
                CHECK(s.reader[0].cursor == s.reader[1].cursor && s.reader[0].cursor == 1664 + 128, "N2 order %d: equal cursors again (%lld, %lld)", order, (long long)s.reader[0].cursor, (long long)s.reader[1].cursor);
            }
            CHECK(s.needsReprime == 0 && s.reader[0].diverged == 0 && s.reader[1].diverged == 0, "N%d order %d: a re-alignment within the bound asks for nothing", variant + 1, order);
            identity("N0", &s.reader[0]); identity("N1", &s.reader[1]);
            SARingFree(ring);
        }
    }
}

/* O: divergence repaired by the BEHIND block's forward jump (valid timestamps), in both block orders. The producer commits 128 frames per cycle, the standing
 * fill is T = 256, and every served block is checked against the frame index its cursor says it started at AND, across the two blocks, against each other. */
static void scenarioO(void) {
    for (int order = 0; order < 2; order++) {
        {   /* O1: R is skipped in cycle 2. At cycle 3 it is 128 behind: it jumps forward 128 and from then on both read the same frames. */
            SARing *ring = mkRing(4096);
            int64_t produced = 0;
            for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
            CHECK(SARingPrime(ring, 2), "O1 prime");
            for (int c = 0; c < 8; c++) {
                const Cycle cy = pairCycle(ring, &produced, 128, order, 128, c == 2 ? 0 : 128, 1000 + 128.0 * c, true);
                CHECK(!cy.silent[0] && cy.start[0] == 256 + 128 * c, "O1 order %d c%d: L serves frame %lld", order, c, (long long)cy.start[0]);
                if (c != 2) CHECK(!cy.silent[1] && cy.start[1] == cy.start[0], "O1 order %d c%d: R serves the SAME frames as L (%lld vs %lld)", order, c, (long long)cy.start[1], (long long)cy.start[0]);
            }
            const SARingSnapshot s = snap(ring);
            CHECK(s.reader[1].divergenceJumps == 1 && s.reader[1].divergenceJumpFrames == 128 && s.reader[0].divergenceJumps == 0 && s.reader[1].phaseSelfChanges == 1 && s.reader[1].phaseMismatches == 1 && s.reader[0].phaseMismatches == 0,
                  "O1 order %d: R: jumps %llu frames %llu self %llu mismatch %llu; L: mismatch %llu", order, (unsigned long long)s.reader[1].divergenceJumps, (unsigned long long)s.reader[1].divergenceJumpFrames,
                  (unsigned long long)s.reader[1].phaseSelfChanges, (unsigned long long)s.reader[1].phaseMismatches, (unsigned long long)s.reader[0].phaseMismatches);
            CHECK(s.reader[0].cursor == s.reader[1].cursor && s.needsReprime == 0, "O1 order %d: both cursors equal at the end", order);
            SARingFree(ring);
        }
        {   /* O2: DIFFERENT frame counts: L asks 128, R asks 64, the render time advances by 128 per cycle. From the second cycle R jumps 64 forward EVERY cycle and reads
             * the first 64 frames of the range L reads: the design's "a block asked a different frame count" case. */
            SARing *ring = mkRing(4096);
            int64_t produced = 0;
            for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
            CHECK(SARingPrime(ring, 2), "O2 prime");
            for (int c = 0; c < 6; c++) {
                const Cycle cy = pairCycle(ring, &produced, 128, order, 128, 64, 1000 + 128.0 * c, true);
                CHECK(cy.start[0] == 256 + 128 * c && cy.start[1] == 256 + 128 * c && !cy.silent[0] && !cy.silent[1], "O2 order %d c%d: L from %lld, R from %lld (both must start at %d)", order, c, (long long)cy.start[0], (long long)cy.start[1], 256 + 128 * c);
            }
            const SARingSnapshot s = snap(ring);
            CHECK(s.reader[1].divergenceJumps == 5 && s.reader[1].divergenceJumpFrames == 5 * 64 && s.reader[1].phaseSelfChanges == 5 && s.reader[1].phaseMismatches == 5 && s.reader[0].divergenceJumps == 0 && s.reader[0].phaseMismatches == 0,
                  "O2 order %d: R jumps %llu (%llu frames) mismatch %llu", order, (unsigned long long)s.reader[1].divergenceJumps, (unsigned long long)s.reader[1].divergenceJumpFrames, (unsigned long long)s.reader[1].phaseMismatches);
            CHECK(s.reader[0].distinctFrameCounts == 1 && s.reader[0].frameCountValue[0] == 128 && s.reader[1].distinctFrameCounts == 1 && s.reader[1].frameCountValue[0] == 64, "O2 order %d: the tables show the two different frame counts", order);
            SARingFree(ring);
        }
    }
    {   /* O3: the jump bound for a DIVERGENCE jump. Ring 1024, T = 256, N - T = 768. R is skipped for 6 cycles (lag 768 = the bound: jump made); 7 and 8 cycles (lag 896 and 1024 > bound:
         * the divergence jump is refused, R is then also lapped and the overrun jump, which is exactly `lag` frames beyond r + F, is refused too: R stays lost, needsReprime). */
        const int skips[3] = { 6, 7, 8 };
        for (int v = 0; v < 3; v++) {
            SARing *ring = mkRing(1024);
            int64_t produced = 0;
            for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
            CHECK(SARingPrime(ring, 2), "O3 prime");
            const int first = 2, last = first + skips[v];                     /* R runs in cycles 0 and 1, is skipped in [first, last), runs again in cycle `last` */
            for (int c = 0; c <= last; c++) pairCycle(ring, &produced, 128, 0, 128, (c >= first && c < last) ? 0 : 128, 1000 + 128.0 * c, true);
            const SARingSnapshot s = snap(ring);
            const SARingReaderStats *R = &s.reader[1], *L = &s.reader[0];
            const int64_t lag = 128 * skips[v];
            if (v == 0) {
                CHECK(R->divergenceJumps == 1 && R->divergenceJumpFrames == 768 && R->refusedJumps == 0 && R->needsReprime == 0 && R->cursor == L->cursor, "O3 lag == N - T: the jump is made (frames %llu, cursor %lld vs %lld)", (unsigned long long)R->divergenceJumpFrames, (long long)R->cursor, (long long)L->cursor);
            } else {
                /* lag > N - T: the divergence jump is refused; R is then also lapped (w - r > window) and the overrun jump (target w - T, which this cycle's commit makes exactly `lag` frames
                 * beyond r + F) is refused too: R stays where it was, plays zeros, and asks for a re-prime. */
                CHECK(R->divergenceJumps == 0 && R->overrunJumps == 0 && R->refusedJumps == 2 && R->needsReprime == 1 && R->largestJumpFrames == (uint64_t)lag && R->overrunBlocks == 1 && R->cursor != L->cursor,
                      "O3 lag %lld: both refused (%llu), R stays where it was (cursor %lld vs L %lld)", (long long)lag, (unsigned long long)R->refusedJumps, (long long)R->cursor, (long long)L->cursor);
                CHECK(s.needsReprime == 1 && L->needsReprime == 0 && L->refusedJumps == 0, "O3: the request comes from R, L asks for nothing");
            }
            identity("O3 R", R); identity("O3 L", L);
            SARingFree(ring);
        }
    }
}

/* O4: the two blocks' RENDER TIMES differ by more than N - T while nothing is lapped (an engine timeline restart, say): the block that is behind by the phase rule would have to
 * jump further than the bound, so it REFUSES, counts it, and asks for a re-prime; no overrun is involved, so this is the only place a refused DIVERGENCE jump is seen on its own.
 * Ring 1024, T = 256, N - T = 768: R's render time is 1000 frames earlier than L's, so L (the smaller phase) is 1000 behind. */
static void scenarioO4(void) {
    SARing *ring = mkRing(1024);
    int64_t produced = 0;
    for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
    CHECK(SARingPrime(ring, 2), "O4 prime");
    float dst[128 + 8];
    for (int c = 0; c < 4; c++) {
        saCommit(ring, produced, 128); produced += 128;
        const AudioTimeStamp a = mkTS(5000 + 128.0 * c, true), b = mkTS(4000 + 128.0 * c, true);
        render(SARingGetReader(ring, 0), 128, &a, dst, true);
        render(SARingGetReader(ring, 1), 128, &b, dst, true);
    }
    const SARingSnapshot s = snap(ring);
    const SARingReaderStats *L = &s.reader[0], *R = &s.reader[1];
    CHECK(L->divergenceJumps == 0 && L->refusedJumps >= 1 && L->largestJumpFrames == 1000 && L->needsReprime == 1 && L->diverged == 0, "O4: L refuses a 1000-frame divergence jump: jumps %llu refused %llu largest %llu needsReprime %u",
          (unsigned long long)L->divergenceJumps, (unsigned long long)L->refusedJumps, (unsigned long long)L->largestJumpFrames, L->needsReprime);
    CHECK(L->overrunBlocks == 0 && L->overrunJumps == 0 && L->servedBlocks == L->calls, "O4: nobody was lapped, every block was served (the refusal is the divergence rule's alone)");
    CHECK(R->needsReprime == 0 && R->refusedJumps == 0 && s.needsReprime == 1 && L->cursor == R->cursor, "O4: R (ahead) asks for nothing; the ring-level request comes from L; the cursors are untouched");
    SARingFree(ring);
}

/* P: the flags. The weaker rule (no usable timestamp) sets `diverged` and `needsReprime` and never jumps; only a prime clears them; an ordinary underrun sets neither. */
static void scenarioP(void) {
    SARing *ring = mkRing(4096);
    int64_t produced = 0;
    for (int i = 0; i < 16; i++) { saCommit(ring, produced, 128); produced += 128; }
    CHECK(SARingPrime(ring, 4), "P prime");
    for (int c = 0; c < 4; c++) pairCycle(ring, &produced, 128, 0, 128, 128, 0, false);   /* lockstep, invalid sample time: d is 0 or F: nothing */
    SARingSnapshot s = snap(ring);
    CHECK(s.needsReprime == 0 && s.reader[0].diverged == 0 && s.reader[1].diverged == 0 && s.reader[0].weakRuleViolations == 0, "P: lockstep with no sample time sets no flag");
    pairCycle(ring, &produced, 128, 0, 128, 0, 0, false);                                   /* R skipped once */
    pairCycle(ring, &produced, 128, 0, 128, 128, 0, false);                                 /* R is now one frameCount behind: d = -128 for L, +256 for R */
    s = snap(ring);
    for (int c = 0; c < 2; c++) CHECK(s.reader[c].weakRuleViolations >= 1 && s.reader[c].diverged == 1 && s.reader[c].needsReprime == 1 && s.reader[c].divergenceJumps == 0 && s.reader[c].overrunJumps == 0, "P ch%d: weak rule: flagged, no jump", c);
    CHECK(s.needsReprime == 1, "P: ring-level request");
    CHECK(s.reader[0].cursor != s.reader[1].cursor, "P: with no phase the render thread leaves the divergence alone (cursors %lld vs %lld)", (long long)s.reader[0].cursor, (long long)s.reader[1].cursor);
    for (int c = 0; c < 4; c++) pairCycle(ring, &produced, 128, 0, 128, 128, 0, false);   /* later cycles do not clear a sticky flag */
    s = snap(ring);
    CHECK(s.needsReprime == 1 && s.reader[0].diverged == 1 && s.reader[1].needsReprime == 1, "P: the flags are sticky");
    CHECK(SARingPrime(ring, 4), "P prime again");
    s = snap(ring);
    CHECK(s.needsReprime == 0 && s.reader[0].diverged == 0 && s.reader[1].diverged == 0 && s.reader[0].needsReprime == 0 && s.reader[1].needsReprime == 0 && s.reader[0].weakRuleViolations == 0, "P: only a prime clears them");
    CHECK(s.reader[0].overrunJumps == 0 && s.reader[0].refusedJumps == 0 && s.reader[0].largestJumpFrames == 0 && s.reader[0].divergenceJumpFrames == 0 && s.reader[1].overrunJumpFrames == 0, "P: prime zeroes the jump counters");
    SARingFree(ring);
}

/* P2: a phase difference the render thread cannot turn into a whole number of frames (fractional, or beyond 9e15) is NOT jumped: the behind block flags it and asks for a re-prime. */
static void scenarioP2(void) {
    const double shifts[3] = { 0.5, 0.25, 1.0e16 };   /* the right block's render time is `shift` EARLIER than the left's, so the left is the one behind by `shift` frames */
    for (int v = 0; v < 3; v++) {
        SARing *ring = mkRing(4096);
        int64_t produced = 0;
        for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
        CHECK(SARingPrime(ring, 2), "P2 prime");
        float dst[128 + 8];
        const AudioTimeStamp tL = mkTS(1000, true), tR = mkTS(1000 - shifts[v], true);
        for (int c = 0; c < 3; c++) {
            saCommit(ring, produced, 128); produced += 128;
            const AudioTimeStamp a = mkTS(tL.mSampleTime + 128.0 * c, true), b = mkTS(tR.mSampleTime + 128.0 * c, true);
            render(SARingGetReader(ring, 0), 128, &a, dst, true);
            render(SARingGetReader(ring, 1), 128, &b, dst, true);
        }
        const SARingSnapshot s = snap(ring);
        CHECK(s.reader[0].diverged == 1 && s.reader[0].needsReprime == 1 && s.reader[0].divergenceJumps == 0 && s.reader[0].refusedJumps == 0 && s.reader[0].phaseMismatches >= 1,
              "P2 shift %g: the behind block flags it, no jump, not a 'refused' jump (diverged %u, needsReprime %u, jumps %llu)", shifts[v], s.reader[0].diverged, s.reader[0].needsReprime, (unsigned long long)s.reader[0].divergenceJumps);
        CHECK(s.reader[1].diverged == 0 && s.reader[1].needsReprime == 0 && s.needsReprime == 1, "P2 shift %g: the block that is ahead does nothing", shifts[v]);
        CHECK(s.reader[0].cursor == s.reader[1].cursor, "P2 shift %g: nothing moved a cursor (they were primed together)", shifts[v]);
        SARingFree(ring);
    }
}

/* Q: the standing fill T: the default before any prime, the primed depth after. */
static void scenarioQ(void) {
    const struct { uint32_t cap, want; } d[] = { { 2, 1 }, { 4, 1 }, { 16, 1 }, { 32, 2 }, { 1024, 64 }, { 32768, 2048 } };
    for (size_t i = 0; i < sizeof d / sizeof d[0]; i++) {
        SARing *ring = mkRing(d[i].cap);
        const SARingSnapshot s = snap(ring);
        CHECK(s.standingFill == d[i].want && s.standingFill <= s.capacity - s.maxCommit && s.needsReprime == 0, "Q: capacity %u: default T = %u, got %u", d[i].cap, d[i].want, s.standingFill);
        SARingFree(ring);
    }
    SARing *ring = mkRing(1024);
    for (int i = 0; i < 6; i++) saCommit(ring, 128 * i, 128);
    CHECK(SARingPrime(ring, 3), "Q prime(3)");
    CHECK(snap(ring).standingFill == 384, "Q: T = 3 x 128 after prime(3)");
    CHECK(!SARingPrime(ring, 5), "Q: a refused prime (depth 640 > window 512) changes nothing");
    CHECK(snap(ring).standingFill == 384, "Q: ... T included");
    SARingFree(ring);
}

int main(void) {
    const SARingSnapshot a0 = scenarioA(0), a1 = scenarioA(1);
    CHECK(memcmp(a0.reader, a1.reader, sizeof a0.reader) == 0 && a0.w == a1.w, "A: running the blocks L then R and R then L must give identical data AND identical counters");
    scenarioB(); scenarioC(); scenarioD(); scenarioE(); scenarioF(); scenarioG(); scenarioH(); scenarioI(); scenarioJ(); scenarioK(); scenarioL(); scenarioF2(); scenarioM(); scenarioN(); scenarioO(); scenarioO4(); scenarioP(); scenarioP2(); scenarioQ();
    printf("systemaudioring_check: %ld checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
