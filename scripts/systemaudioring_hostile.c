/* Hostile inputs for the Step 6b-1 ring (built by scripts/ubsan-systemaudioring.sh with -fsanitize=undefined and recovery disabled, so the first
 * undefined behaviour aborts the program). Every buffer the code is given is placed so that it ENDS exactly at a PROT_NONE guard page: reading or
 * writing one byte past what the AudioBufferList honestly describes faults at once (no sleeping bug, no silent corruption). Frame counts and byte
 * sizes that would overflow a 32-bit product, wrap a size, or describe more memory than exists are fed to both the render side and the producer.
 * Exit 0 = nothing crashed, nothing undefined, every refusal as expected. */
#include "systemaudioring_common.h"

#include <sys/mman.h>
#include <unistd.h>

/* A region of `bytes` usable bytes that ends exactly at a guard page. Never freed (the process is short-lived). */
static void *guarded(size_t bytes) {
    const size_t page = (size_t)getpagesize();
    const size_t pages = (bytes + page - 1) / page + 1;
    char *base = (char *)mmap(NULL, pages * page, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (base == MAP_FAILED) { perror("mmap"); exit(3); }
    mprotect(base + (pages - 1) * page, page, PROT_NONE);
    return base + (pages - 1) * page - bytes;
}

static OSStatus renderRaw(SARingReader *rd, bool *silent, const AudioTimeStamp *ts, uint32_t F, void *data, uint32_t byteSize) {
    AudioBufferList l = { 0 };
    l.mNumberBuffers = 1; l.mBuffers[0].mNumberChannels = 1; l.mBuffers[0].mDataByteSize = byteSize; l.mBuffers[0].mData = data;
    return SARingRender(rd, silent, ts, F, &l);
}

int main(void) {
    SARing *ring = SARingCreate(1024);
    CHECK(ring != NULL, "create");
    for (int i = 0; i < 4; i++) saCommit(ring, i * 128, 128);
    SARingReader *rd = SARingGetReader(ring, 0);
    AudioTimeStamp ts = { 0 };
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    bool silent;

    /* ---- render side: sizes that must be refused without touching the buffer ---- */
    float *tiny = (float *)guarded(64);
    const uint32_t hugeF[] = { 0x40000000u, 0x40000001u, 0x7fffffffu, 0x80000000u, 0xfffffffeu, 0xffffffffu, 0x20000001u };
    for (size_t i = 0; i < sizeof hugeF / sizeof hugeF[0]; i++) {
        silent = true;
        const OSStatus s = renderRaw(rd, &silent, &ts, hugeF[i], tiny, 64);   /* F x 4 wraps a 32-bit product for 0x40000000 and 0x80000000 and up */
        CHECK(s == kAudio_ParamError && !silent, "hostile F=0x%x with a 64-byte buffer: status %d silent %d", hugeF[i], (int)s, silent);
    }
    silent = true;
    CHECK(renderRaw(rd, &silent, &ts, 17, tiny, 67) == kAudio_ParamError, "one byte short of 17 frames");
    {   /* zero frames, zero bytes */
        float *none = (float *)guarded(0 + 4);
        silent = false;
        const OSStatus s = renderRaw(rd, &silent, &ts, 0, none, 0);
        CHECK(s == 0, "F = 0 with a zero-byte buffer: status %d", (int)s);
    }
    /* exact-size buffers at the guard: oversize (zero-filled, not one float more), underrun, served */
    for (uint32_t F = 1; F <= 600; F += (F < 40 ? 1 : 71)) {
        float *exact = (float *)guarded((size_t)F * 4);
        silent = false;
        const OSStatus s = renderRaw(rd, &silent, &ts, F, exact, F * 4u);
        CHECK(s == 0, "exact buffer F=%u: status %d", F, (int)s);
        (void)silent;
    }
    /* ---- timestamps that are not numbers, are huge, or are denormal: counted as invalid or valid, never undefined ---- */
    const double weird[] = { NAN, INFINITY, -INFINITY, 1e300, -1e300, 4.9e-324, 9007199254740993.0, -0.0, 1.0e18 };
    for (size_t i = 0; i < sizeof weird / sizeof weird[0]; i++) {
        AudioTimeStamp w = { 0 };
        w.mSampleTime = weird[i]; w.mFlags = kAudioTimeStampSampleTimeValid;
        float *exact = (float *)guarded(64 * 4);
        silent = false;
        CHECK(renderRaw(rd, &silent, &w, 64, exact, 64 * 4u) == 0, "weird sample time %zu", i);
    }
    CHECK(SARingRender(rd, &silent, NULL, 8, NULL) == kAudio_ParamError, "NULL list and NULL timestamp");
    /* ---- Step 6b-3a-1: the divergence-jump arithmetic with absurd sample times on BOTH blocks (infinite, enormous, denormal differences between the two phases; a block
     *      that is far behind; fractional differences). Whatever happens (a jump, a refusal, a flag), nothing may be undefined: UBSan runs with float-cast-overflow and
     *      recovery off, and every buffer ends at a guard page. The cursor must only ever move forward. ---- */
    {
        SARing *ring2 = SARingCreate(1024);
        for (int i = 0; i < 4; i++) saCommit(ring2, i * 128, 128);
        SARingReader *a = SARingGetReader(ring2, 0), *b = SARingGetReader(ring2, 1);
        const double ts2[] = { 0.0, 1.0, 0.5, -0.5, 1e300, -1e300, 1.7976931348623157e308, -1.7976931348623157e308, 9007199254740993.0, -9007199254740993.0, 4.9e-324, 9.0e15, 8.999999999999e15, 1.0e15, 63.5, 128.25 };
        int64_t lastA = 0, lastB = 0;
        for (size_t i = 0; i < sizeof ts2 / sizeof ts2[0]; i++)
            for (size_t j = 0; j < sizeof ts2 / sizeof ts2[0]; j++) {
                AudioTimeStamp ta = { 0 }, tb = { 0 };
                ta.mSampleTime = ts2[i]; ta.mFlags = kAudioTimeStampSampleTimeValid;
                tb.mSampleTime = ts2[j]; tb.mFlags = kAudioTimeStampSampleTimeValid;
                float *ba = (float *)guarded(64 * 4), *bb = (float *)guarded(64 * 4);
                silent = false;
                CHECK(renderRaw(a, &silent, &ta, 64, ba, 64 * 4u) == 0, "absurd phases L %zu/%zu", i, j);
                CHECK(renderRaw(b, &silent, &tb, 64, bb, 64 * 4u) == 0, "absurd phases R %zu/%zu", i, j);
                SARingSnapshot sa;
                SARingTakeSnapshot(ring2, &sa);
                CHECK(sa.reader[0].cursor >= lastA + 64 && sa.reader[1].cursor >= lastB + 64, "absurd phases %zu/%zu: a cursor moved backward or by less than frameCount", i, j);
                lastA = sa.reader[0].cursor; lastB = sa.reader[1].cursor;
                CHECK(sa.reader[0].refusedJumps == 0 || sa.reader[0].needsReprime == 1, "refused jump without a request");
            }
        SARingFree(ring2);
    }

    /* ---- producer: lists that lie or describe nothing ---- */
    AudioTimeStamp now = { 0 };
    AudioBufferList out = { 0 };
    SABigList l;
    uint64_t before = 0;
    SARingSnapshot sn;
    SARingTakeSnapshot(ring, &sn);
    before = sn.rejectedCommits;
    const uint32_t sizes[] = { 0xfffffff8u, 0xffffffffu, 0xfffffffcu, 0x80000000u, 513u * 8u, 4097u, 1u, 7u, 12u };
    uint64_t refused = 0;
    float *small = (float *)guarded(32);
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {   /* a byte size that claims far more than the 32 bytes behind mData: refused before it is read */
        memset(&l, 0, sizeof l);
        l.list.mNumberBuffers = 1; l.list.mBuffers[0].mNumberChannels = 2; l.list.mBuffers[0].mDataByteSize = sizes[i]; l.list.mBuffers[0].mData = small;
        CHECK(SARingIOProc(0, &now, &l.list, &now, &out, &now, ring) == 0, "producer size 0x%x", sizes[i]);
        refused++;
    }
    const uint32_t counts[] = { 0u, 2u, 0xffffffffu };   /* mNumberBuffers: 0 = no buffers, 2 and UINT32_MAX = a layout that is not one buffer (buffer [1] must not be read) */
    for (size_t i = 0; i < 3; i++) {
        memset(&l, 0, sizeof l);
        l.list.mNumberBuffers = counts[i]; l.list.mBuffers[0].mNumberChannels = 2; l.list.mBuffers[0].mDataByteSize = 32; l.list.mBuffers[0].mData = small;
        CHECK(SARingIOProc(0, &now, &l.list, &now, &out, &now, ring) == 0, "producer buffer count");
        refused++;
    }
    const uint32_t chans[] = { 0u, 1u, 3u, 0x40000000u, 0xffffffffu };
    for (size_t i = 0; i < sizeof chans / sizeof chans[0]; i++) {
        memset(&l, 0, sizeof l);
        l.list.mNumberBuffers = 1; l.list.mBuffers[0].mNumberChannels = chans[i]; l.list.mBuffers[0].mDataByteSize = 32; l.list.mBuffers[0].mData = small;
        CHECK(SARingIOProc(0, &now, &l.list, &now, &out, &now, ring) == 0, "producer channels");
        refused++;
    }
    SARingTakeSnapshot(ring, &sn);
    CHECK(sn.rejectedCommits == before + refused && sn.w == 512, "every hostile list refused and counted, nothing written (rejected %llu want %llu, w %lld)", (unsigned long long)sn.rejectedCommits, (unsigned long long)(before + refused), (long long)sn.w);
    {   /* a valid, maximal commit whose data ends exactly at the guard page: reads exactly what the list describes */
        float *exact = (float *)guarded(512 * 8);
        for (int i = 0; i < 512 * 2; i++) exact[i] = 0.25f;
        memset(&l, 0, sizeof l);
        l.list.mNumberBuffers = 1; l.list.mBuffers[0].mNumberChannels = 2; l.list.mBuffers[0].mDataByteSize = 512 * 8u; l.list.mBuffers[0].mData = exact;
        CHECK(SARingIOProc(0, &now, &l.list, &now, &out, &now, ring) == 0, "valid maximal commit");
        SARingTakeSnapshot(ring, &sn);
        CHECK(sn.w == 1024 && sn.lastCommitFrames == 512, "valid maximal commit published");
    }
    CHECK(!SARingPrime(ring, UINT32_MAX) && !SARingPrime(ring, 0x80000000u), "prime with absurd T");
    SARingFree(ring);

    /* ---- creation at the limits ---- */
    SARing *big = SARingCreate(SA_RING_MAX_CAPACITY_FRAMES);
    CHECK(big != NULL, "create at the maximum capacity");
    if (big) { SARingTakeSnapshot(big, &sn); CHECK(sn.capacity == SA_RING_MAX_CAPACITY_FRAMES && sn.maxCommit == SA_RING_MAX_CAPACITY_FRAMES / 2u, "maximum capacity margin"); }
    SARingFree(big);
    printf("systemaudioring_hostile: %ld checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
