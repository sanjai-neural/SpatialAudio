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

static AudioTimeStamp mkTS(double sampleTime, bool valid) {
    AudioTimeStamp t = { 0 };
    t.mSampleTime = sampleTime;
    t.mFlags = valid ? kAudioTimeStampSampleTimeValid : 0;
    return t;
}

/* One render call. `dst` has room for F + 8 floats: the last 8 are a canary that must never be touched. `initSilent` is the value *isSilence has
 * before the call (the harness passes the OPPOSITE of what it expects, so a function that forgets to set it is caught). */
static RR render(SARingReader *rd, uint32_t F, const AudioTimeStamp *ts, float *dst, bool initSilent) {
    for (uint32_t i = 0; i < F + 8; i++) dst[i] = SA_SENTINEL;
    AudioBufferList l = { 0 };
    l.mNumberBuffers = 1;
    l.mBuffers[0].mNumberChannels = 1;
    l.mBuffers[0].mDataByteSize = F * 4u;
    l.mBuffers[0].mData = dst;
    RR rr = { 0, initSilent };
    rr.status = SARingRender(rd, &rr.silent, ts, F, &l);
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
}

/* A: both orders, varied commit sizes (so commits straddle the wrap), several laps. Returns the final snapshot so the two orders can be compared.
 * Ring 1024 -> window 512; primed at T = 2 x 128 = 256 frames so that fill plus the next commit (at most 160) stays inside the window. */
static SARingSnapshot scenarioA(int order) {
    SARing *ring = SARingCreate(1024);
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
    }
    SARingFree(ring);
    return s;
}

/* B: underrun. The block is silent (zeros), the cursor still advances by exactly frameCount, late frames are dropped never played late, and
 * at equal producer and reader rate a reader that fell behind the producer STAYS starved (this spike counts only: no jump, no re-prime). */
static void scenarioB(void) {
    SARing *ring = SARingCreate(1024);
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
    }
    SARingFree(ring);
}

/* C: overrun (lapped, pre-check), the exact boundary, oversize. window = capacity - capacity / 2 = 512 for a ring of 1024. */
static void scenarioC(void) {
    float dst[600 + 8];
    {   /* lapped: w - r = 1024, 896, 768, 640 all > 512; the fifth call is at w - r == 512, which is served */
        SARing *ring = SARingCreate(1024);
        int64_t produced = 0;
        for (int i = 0; i < 8; i++) { saCommit(ring, produced, 128); produced += 128; }
        SARingReader *L = SARingGetReader(ring, 0);
        const AudioTimeStamp ts = mkTS(0, true);
        for (int i = 0; i < 4; i++) expectSilence("C overrun", 128, dst, render(L, 128, &ts, dst, false));
        SARingSnapshot s = snap(ring);
        CHECK(s.reader[0].overrunBlocks == 4 && s.reader[0].tornBlocks == 0 && s.reader[0].underrunBlocks == 0 && s.reader[0].cursor == 512 && s.reader[0].silentFrames == 512, "C overrun counters");
        expectServed("C boundary w-r == window", 0, 512, 128, dst, render(L, 128, &ts, dst, true));
        s = snap(ring);
        CHECK(s.reader[0].servedBlocks == 1 && s.reader[1].calls == 0 && s.reader[1].cursor == 0, "C: the other reader is untouched");
        identity("C", &s.reader[0]);
        SARingFree(ring);
    }
    {   /* one frame further: w - r == 513 is overrun */
        SARing *ring = SARingCreate(1024);
        int64_t produced = 0;
        for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
        saCommit(ring, produced, 1);
        const AudioTimeStamp ts = mkTS(0, true);
        expectSilence("C 513", 128, dst, render(SARingGetReader(ring, 1), 128, &ts, dst, false));
        const SARingSnapshot s = snap(ring);
        CHECK(s.reader[1].overrunBlocks == 1 && s.reader[1].servedBlocks == 0 && s.reader[1].underrunBlocks == 0, "C: w - r == 513 must be an overrun");
        SARingFree(ring);
    }
    {   /* oversize: F > window is silent whatever the fill; F == window is served */
        SARing *ring = SARingCreate(1024);
        int64_t produced = 0;
        for (int i = 0; i < 8; i++) { saCommit(ring, produced, 128); produced += 128; }
        CHECK(SARingPrime(ring, 4), "C prime");
        SARingReader *L = SARingGetReader(ring, 0);
        const AudioTimeStamp ts = mkTS(0, true);
        expectSilence("C oversize 513", 513, dst, render(L, 513, &ts, dst, false));
        SARingSnapshot s = snap(ring);
        CHECK(s.reader[0].oversizeBlocks == 1 && s.reader[0].underrunBlocks == 0 && s.reader[0].overrunBlocks == 0 && s.reader[0].silentFrames == 513, "C oversize counters");
        SARingFree(ring);
        ring = SARingCreate(1024);
        produced = 0;
        for (int i = 0; i < 8; i++) { saCommit(ring, produced, 128); produced += 128; }
        CHECK(SARingPrime(ring, 4), "C prime 2");
        expectServed("C F == window", 0, 512, 512, dst, render(SARingGetReader(ring, 0), 512, &ts, dst, true));
        SARingFree(ring);
    }
}

/* D: output lists the block cannot trust: nothing is written, kAudio_ParamError, the cursor still advances. */
static void scenarioD(void) {
    SARing *ring = SARingCreate(1024);
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
    SARing *ring = SARingCreate(1024);
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
    SARing *ring = SARingCreate(1024);
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
    SARingFree(ring);
}

/* G: the snapshot. fill is w - cursor from the values IN the snapshot; the two readers keep separate counters. */
static void scenarioG(void) {
    SARing *ring = SARingCreate(1024);
    int64_t produced = 0;
    for (int i = 0; i < 4; i++) { saCommit(ring, produced, 128); produced += 128; }
    SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
    float dst[128 + 8];
    const AudioTimeStamp ts = mkTS(0, true);
    for (int i = 0; i < 5; i++) render(rd[0], 128, &ts, dst, true);   /* L: 4 served then 1 underrun */
    for (int i = 0; i < 3; i++) render(rd[1], 128, &ts, dst, true);   /* R: 3 served */
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
        SARing *ring = SARingCreate(4096);
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
    {   /* H2: the right channel's block is skipped for one cycle: its own phase changes once (by one frameCount) and it then differs from the left's for every later call */
        SARing *ring = SARingCreate(4096);
        int64_t produced = 0;
        for (int i = 0; i < 16; i++) { saCommit(ring, produced, 128); produced += 128; }
        SARingReader *rd[2] = { SARingGetReader(ring, 0), SARingGetReader(ring, 1) };
        double t = 0;
        for (int c = 0; c < 6; c++, t += 128) {
            const AudioTimeStamp ts = mkTS(t, true);
            render(rd[0], 128, &ts, dst, true);
            if (c != 2) render(rd[1], 128, &ts, dst, true);   /* cycle 2: R is not asked */
        }
        const SARingSnapshot s = snap(ring);
        CHECK(s.reader[1].phaseSelfChanges == 1, "H2: R phaseSelfChanges %llu want 1", (unsigned long long)s.reader[1].phaseSelfChanges);
        CHECK(s.reader[0].phaseSelfChanges == 0, "H2: L phaseSelfChanges %llu want 0", (unsigned long long)s.reader[0].phaseSelfChanges);
        /* Each block compares its phase with the other's LAST PUBLISHED one. L always runs first: in cycle 3 it still sees R's old phase (equal), so it first
         * notices in cycle 4 (L: cycles 4 and 5 = 2); R runs second and sees L's phase at once (R: cycles 3, 4, 5 = 3). These COUNTS depend on the order
         * the blocks run in (they are diagnostics); the data and the cursors never do. */
        CHECK(s.reader[0].phaseMismatches == 2 && s.reader[1].phaseMismatches == 3, "H2: mismatches L %llu R %llu want 2 and 3", (unsigned long long)s.reader[0].phaseMismatches, (unsigned long long)s.reader[1].phaseMismatches);
        SARingFree(ring);
    }
    for (int order = 0; order < 2; order++) {   /* H3: unusable timestamps: counted as invalid, weaker rule (other cursor - mine must be 0 or frameCount) holds in lockstep */
        SARing *ring = SARingCreate(4096);
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
        for (int c = 0; c < 2; c++)
            CHECK(s.reader[c].phaseInvalidCalls == 8 && s.reader[c].phaseValidCalls == 0 && s.reader[c].weakRuleViolations == 0, "H3 order %d ch%d: invalid %llu valid %llu weak %llu", order, c,
                  (unsigned long long)s.reader[c].phaseInvalidCalls, (unsigned long long)s.reader[c].phaseValidCalls, (unsigned long long)s.reader[c].weakRuleViolations);
        /* one cycle where R is skipped: the next cycle both blocks see a gap of 2 x frameCount or -frameCount */
        render(rd[0], 128, &stamps[0], dst, true);
        for (int k = 0; k < 2; k++) render(rd[k], 128, &stamps[0], dst, true);
        s = snap(ring);
        CHECK(s.reader[0].weakRuleViolations == 1 && s.reader[1].weakRuleViolations == 1, "H3 order %d: skipped block: weak violations L %llu R %llu want 1 and 1", order,
              (unsigned long long)s.reader[0].weakRuleViolations, (unsigned long long)s.reader[1].weakRuleViolations);
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
        SARing *ring = SARingCreate(1024);
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
    SARing *ring = SARingCreate(1024);
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
        SARing *ring = SARingCreate(1024);
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
    SARing *ring = SARingCreate(1024);
    saCommit(ring, 0, 512);
    saCommit(ring, 512, 128);
    CHECK(!SARingPrime(ring, 4), "F2: two callbacks committed, T = 4, even though 4 x 128 frames were written");
    CHECK(SARingPrime(ring, 2), "F2: prime(2): depth 256");
    const SARingSnapshot s = snap(ring);
    CHECK(s.reader[0].cursor == 384 && s.reader[1].cursor == 384, "F2: start = 640 - 256");
    SARingFree(ring);
}

int main(void) {
    const SARingSnapshot a0 = scenarioA(0), a1 = scenarioA(1);
    CHECK(memcmp(a0.reader, a1.reader, sizeof a0.reader) == 0 && a0.w == a1.w, "A: running the blocks L then R and R then L must give identical data AND identical counters");
    scenarioB(); scenarioC(); scenarioD(); scenarioE(); scenarioF(); scenarioG(); scenarioH(); scenarioI(); scenarioJ(); scenarioK(); scenarioL(); scenarioF2();
    printf("systemaudioring_check: %ld checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
