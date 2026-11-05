/*
 * Hostile-input harness for the frame arithmetic of CTapProbe's IO callback (Step 6a correction). Built by scripts/ubsan-tapprobe.sh
 * with clang -fsanitize=integer-divide-by-zero -fno-sanitize-recover=integer-divide-by-zero.
 *
 * Why it exists: the callback divides a byte count by (bytes per sample x channels in the buffer). The channel count comes from the
 * HAL, not from us. With a 32-bit product, bytesPerSample = 4 and mNumberChannels = 0x40000000 wrap to 0 and the division is a
 * division by zero, which is undefined behaviour in C. On arm64 it happens to return 0, so NO behavioural test can see it; only a
 * sanitizer can. This harness feeds that input (and a normal one) and exits non-zero if the sanitizer fires (the sanitizer aborts) or
 * if a result is wrong.
 */
#include "CTapProbe.h"

#include <stdio.h>

static int gFailures;

static uint32_t framesFor(SATapProbe *p, uint32_t channels, uint32_t byteSize, float *samples) {
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = channels;
    list.mBuffers[0].mDataByteSize = byteSize;
    list.mBuffers[0].mData = samples;
    AudioBufferList out = { 0 };
    AudioTimeStamp now = { 0 };
    now.mHostTime = 1;
    AudioTimeStamp other = now;
    SATapProbeIOProc(0, &now, &list, &other, &out, &other, p);
    SATapProbeRecord r;
    if (!SATapProbeReadRecord(p, SATapProbeCommitted(p) - 1, &r)) { fprintf(stderr, "no record published\n"); gFailures++; return 0; }
    return r.frames;
}

static void expect(const char *what, uint32_t got, uint32_t want) {
    printf("%-58s frames = %u (expected %u)\n", what, got, want);
    if (got != want) gFailures++;
}

int main(void) {
    float samples[64] = { 0 };
    SATapProbe *p = SATapProbeCreate(16, 4, true);
    if (!p) { fprintf(stderr, "create failed\n"); return 3; }

    expect("normal: 2 channels, 64 bytes", framesFor(p, 2, 64, samples), 8);
    expect("zero channel count is treated as 1", framesFor(p, 0, 64, samples), 16);
    expect("channels = 0xFFFFFFFF (product wraps to a non-zero)", framesFor(p, 0xFFFFFFFFu, 64, samples), 0);
    /* The case a 32-bit product turns into a division by zero: 4 * 0x40000000 == 2^32 == 0 (mod 2^32). */
    expect("channels = 0x40000000 (32-bit product wraps to ZERO)", framesFor(p, 0x40000000u, 64, samples), 0);
    SATapProbeFree(p);

    /* A zero sample size: the fixed library refuses to create such a probe; the older one accepted it and guarded in the callback. */
    SATapProbe *zero = SATapProbeCreate(16, 0, false);
    if (zero) {
        expect("bytesPerSample = 0 accepted by create: frames", framesFor(zero, 2, 64, samples), 0);
        SATapProbeFree(zero);
    } else {
        printf("bytesPerSample = 0: creation refused (NULL)\n");
    }
    printf(gFailures ? "FAIL: %d wrong result(s)\n" : "PASS: no division by zero reported, results as expected\n", gFailures);
    return gFailures ? 1 : 0;
}
