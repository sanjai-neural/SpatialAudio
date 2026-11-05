#ifndef CTAPPROBE_H
#define CTAPPROBE_H

#include <stdbool.h>
#include <stdint.h>
#include <CoreAudio/AudioHardware.h>

/*
 * Step 6a: the real-time half of the system-audio capture probe.
 *
 * `SATapProbeIOProc` is an `AudioDeviceIOProc` (CoreAudio/AudioHardware.h, marked CA_REALTIME_API there). It runs on Core
 * Audio's IO thread, so it follows the project's Real-time rule (docs/ARCHITECTURE.md): plain structs, raw pointers and
 * C11 atomics only. No allocation, locks, logging, Objective-C, Swift or calls into any library. It only MEASURES: for
 * every callback it stores one SATapProbeRecord (host time, frames, sample count, peak, sum of squares, flags) into a
 * buffer that the control thread allocated up front. It never touches the audio itself.
 *
 *  - Exactly one thread (Core Audio's IO thread, or the simulated source's thread) calls SATapProbeIOProc for a given probe.
 *  - The control thread creates and frees the probe and reads records. It may read record i only after
 *    SATapProbeCommitted() returned more than i (acquire/release pairing); records are copied field by field.
 *  - Free is only legal when no callback can still run. The header of AudioDeviceDestroyIOProcID does not say that it waits
 *    for a running callback, so the real backend never frees (the process exits right after the probe).
 */

/* Flags in SATapProbeRecord.flags (the measurement could not be taken exactly as asked, and says so). */
#define SA_TAP_FLAG_UNSUPPORTED_FORMAT  1u   /* samples are not 32-bit float: frames counted, levels not computed */
#define SA_TAP_FLAG_NULL_BUFFER         2u   /* a buffer had mData == NULL (a disabled stream): skipped */
#define SA_TAP_FLAG_NON_FINITE_SAMPLE   4u   /* at least one NaN or infinite sample: left out of peak and RMS */
#define SA_TAP_FLAG_NO_BUFFERS          8u   /* the callback got no input buffers at all */
#define SA_TAP_FLAG_NO_TIMESTAMP       16u   /* inNow was NULL: hostTime is 0 */

#pragma clang assume_nonnull begin

typedef struct {
    uint64_t hostTime;      /* inNow->mHostTime, host-clock ticks (AudioGetHostClockFrequency() ticks per second) */
    double   sumSquares;    /* sum of squares of every finite sample of every buffer */
    uint32_t frames;        /* frames in the first buffer (bytes / (bytesPerSample * channels in that buffer)) */
    uint32_t samples;       /* finite samples that went into peak and sumSquares (so RMS = sqrt(sumSquares / samples)) */
    float    peak;          /* largest absolute finite sample */
    uint32_t flags;         /* SA_TAP_FLAG_* */
} SATapProbeRecord;         /* 32 bytes */

typedef struct SATapProbe SATapProbe;

/* Control thread. Allocates (the record buffer holds `capacity` records). `bytesPerSample` and `isFloat32` come from the
 * tap's AudioStreamBasicDescription; levels are computed only for 32-bit float. Returns NULL on failure. */
SATapProbe *_Nullable SATapProbeCreate(uint32_t capacity, uint32_t bytesPerSample, bool isFloat32);

/* Control thread. Frees. Only when no callback can run any more (see above). */
void SATapProbeFree(SATapProbe *_Nullable probe);

/* The IO callback. Real-time. Nullability matches AudioDeviceIOProc in AudioHardware.h (inside assume_nonnull there, with
 * inClientData __nullable) so that Swift accepts the function as an AudioDeviceIOProc; the body still checks for NULL. */
OSStatus SATapProbeIOProc(AudioObjectID inDevice,
                          const AudioTimeStamp *inNow,
                          const AudioBufferList *inInputData,
                          const AudioTimeStamp *inInputTime,
                          AudioBufferList *outOutputData,
                          const AudioTimeStamp *inOutputTime,
                          void *__nullable inClientData) CA_REALTIME_API;

/* Control thread. Number of records published so far (acquire). */
uint32_t SATapProbeCommitted(const SATapProbe *probe);

/* Control thread. Callbacks that found the buffer full and stored nothing. */
uint64_t SATapProbeDropped(const SATapProbe *probe);

uint32_t SATapProbeCapacity(const SATapProbe *probe);

/* Control thread. Copies record `index` field by field. Returns false if index >= SATapProbeCommitted(). */
bool SATapProbeReadRecord(const SATapProbe *probe, uint32_t index, SATapProbeRecord *out);

#pragma clang assume_nonnull end

#endif
