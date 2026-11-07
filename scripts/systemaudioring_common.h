/* Shared helpers of the Step 6b-1 C harnesses (systemaudioring_check.c, _stress.c, _hostile.c). Built by scripts/check-systemaudioring.sh,
 * tsan-systemaudioring.sh and ubsan-systemaudioring.sh together with Sources/CSystemAudioRing/CSystemAudioRing.c (or a variant of it).
 * Nothing here sleeps or reads a clock: threads wait on counters the other side publishes. */
#ifndef SYSTEMAUDIORING_COMMON_H
#define SYSTEMAUDIORING_COMMON_H

#include "CSystemAudioRing.h"

#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The signal: a pure function of (channel, absolute frame index). Always >= 1.0 and exactly representable, so a zero (silence), the sentinel
 * below, or a sample of the other channel or of another frame can never be mistaken for the right one. */
static inline float saSample(uint32_t ch, int64_t j) {
    const uint32_t h = (uint32_t)j * 2654435761u + ch * 40503u + 12345u;
    return (float)((h >> 8) & 0xFFFFFu) / 1024.0f + 1.0f;
}
#define SA_SENTINEL (-777.0f)   /* what the harness leaves in an output buffer before the call: "stale data" */

static int gFailures;
static long gChecks;
static void saFail(const char *file, int line, const char *fmt, ...) {
    if (gFailures++ < 25) {
        fprintf(stderr, "FAIL %s:%d: ", file, line);
        va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
        fputc('\n', stderr);
    }
}
#define CHECK(cond, ...) do { gChecks++; if (!(cond)) saFail(__FILE__, __LINE__, __VA_ARGS__); } while (0)

/* An AudioBufferList with room for up to four buffers (the struct's own mBuffers[1] plus three, contiguous). */
typedef struct { AudioBufferList list; AudioBuffer extra[3]; } SABigList;

/* One producer callback through the REAL entry point, interleaved stereo, frames j0 ..< j0+frames of the saSample signal. Returns the call's status. */
static inline OSStatus saCommit(SARing *ring, int64_t j0, uint32_t frames) {
    float *buf = (float *)malloc((size_t)frames * 2 * sizeof(float) + 8);
    for (uint32_t i = 0; i < frames; i++) { buf[2 * (size_t)i] = saSample(0, j0 + i); buf[2 * (size_t)i + 1] = saSample(1, j0 + i); }
    SABigList in = { 0 };
    in.list.mNumberBuffers = 1;
    in.list.mBuffers[0].mNumberChannels = 2;
    in.list.mBuffers[0].mDataByteSize = frames * 8u;
    in.list.mBuffers[0].mData = buf;
    AudioBufferList out = { 0 };
    AudioTimeStamp now = { 0 };
    const OSStatus s = SARingIOProc(0, &now, &in.list, &now, &out, &now, ring);
    free(buf);
    return s;
}

#endif
