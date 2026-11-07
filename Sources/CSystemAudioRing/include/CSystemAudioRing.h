#ifndef CSYSTEMAUDIORING_H
#define CSYSTEMAUDIORING_H

#include <stdbool.h>
#include <stdint.h>
#include <CoreAudio/AudioHardware.h>

/*
 * Step 6b-1: the real-time core of "system audio to renderer" (docs/ARCHITECTURE.md, "System audio to renderer (Step 6b design)" and
 * "Step 6b-1: what was built"). IMPLEMENTED-UNVERIFIED: built and tested offline, never connected to a real tap or an engine.
 *
 * One producer (the tap's IO thread, `SARingIOProc`) splits the interleaved Float32 stereo tap buffer into two per-channel planes of
 * a ring and then publishes ONE producer index `w` (a 64-bit frame counter) with a release store. Two readers (one per channel, each
 * served by its own mono AVAudioSourceNode block, `SARingRender`) keep their OWN cursor and counters. A reader never changes what the
 * other reads. This spike COUNTS only: it never jumps a cursor and never re-primes (see the four departures in the docs).
 *
 * Real-time rule (docs/ARCHITECTURE.md): SARingIOProc, SARingWrite and SARingRender touch only raw pointers, plain structs and C11
 * atomics. No allocation, locks, logging, Objective-C, Swift or calls. scripts/scan-rt-block.sh checks the generated code.
 *
 * Threads: ONE producer thread, one render thread per reader (the two readers may run on different threads, in any order, or
 * concurrently), and a control thread (create, prime, snapshot, free). SARingFree is legal only when no callback and no render block
 * can run any more; this header does not say how the engine and the IO proc are stopped (Step 6b-2 needs that protocol).
 */

/* GUESSES, not measured and not derived from the tap data: they are named constants so they can be changed in one place.
 *  - SA_RING_DEFAULT_CAPACITY_FRAMES: frames per channel plane (N). Must be a power of two.
 *  - SA_RING_DEFAULT_PRIME_CALLBACKS: how many tap callbacks of data the readers start behind the producer (T). */
#define SA_RING_DEFAULT_CAPACITY_FRAMES 32768u   /* GUESS */
#define SA_RING_DEFAULT_PRIME_CALLBACKS 4u       /* GUESS */

#define SA_RING_CHANNELS 2u
#define SA_RING_MAX_CAPACITY_FRAMES (1u << 24)   /* sanity bound on the allocation, not a tuned value */

/* Bits of SARingSnapshot.rejectFlags: why the producer refused a tap callback (nothing is written for a refused callback). */
#define SA_RING_REJECT_NO_BUFFERS   1u    /* NULL list, or no buffer */
#define SA_RING_REJECT_BAD_LAYOUT   2u    /* not exactly one buffer of two interleaved channels */
#define SA_RING_REJECT_NULL_DATA    4u    /* mData == NULL */
#define SA_RING_REJECT_PARTIAL      8u    /* byte size is not a whole number of 8-byte (two Float32) frames */
#define SA_RING_REJECT_OVERSIZE    16u    /* more frames than capacity / 2 (the in-flight margin, see CSystemAudioRing.c) */
#define SA_RING_REJECT_EMPTY       32u    /* zero frames */
#define SA_RING_REJECT_MISALIGNED  64u    /* mData is not 4-byte aligned */

#pragma clang assume_nonnull begin

typedef struct SARing SARing;
typedef struct SARingReader SARingReader;

typedef struct {
    uint64_t calls;            /* every SARingRender call: calls == served + underrun + overrun + torn + oversize + badBuffer */
    uint64_t framesRequested;  /* sum of the frameCounts asked for */
    uint64_t servedBlocks;
    uint64_t servedFrames;
    uint64_t underrunBlocks;   /* some requested frame was not yet written (includes a cursor already ahead of the producer) */
    uint64_t overrunBlocks;    /* the reader was lapped before it started copying (seen with the w it loaded first) */
    uint64_t tornBlocks;       /* the producer got within the margin while the block was being copied (seen after the copy) */
    uint64_t oversizeBlocks;   /* frameCount larger than the ring can serve (capacity - capacity/2) */
    uint64_t badBufferBlocks;  /* the output list was not one mono Float32 buffer of at least frameCount frames: nothing written */
    uint64_t silentFrames;     /* frames output as zeros for any of the four silent reasons */
    uint64_t phaseValidCalls;    /* timestamp had kAudioTimeStampSampleTimeValid and a finite sample time */
    uint64_t phaseInvalidCalls;  /* it did not: the weaker rule was used */
    uint64_t phaseSelfChanges;   /* this reader's own phase (cursor - sample time) differed from its previous valid call's */
    uint64_t phaseMismatches;    /* this reader's phase differed from the other reader's last published phase */
    uint64_t weakRuleViolations; /* invalid timestamp and (other cursor - mine) was neither 0 nor frameCount */
    int64_t  cursor;           /* published, AFTER the last call advanced it by exactly its frameCount */
    int64_t  fill;             /* w - cursor, signed, from the w and cursor loaded in THIS snapshot: negative = reader ahead of the producer */
} SARingReaderStats;

typedef struct {
    int64_t  w;                /* frames committed by the producer */
    uint64_t commits;          /* tap callbacks committed */
    uint64_t rejectedCommits;
    uint32_t rejectFlags;      /* OR of SA_RING_REJECT_* since creation or the last prime */
    uint32_t lastCommitFrames;
    uint32_t capacity;
    uint32_t maxCommit;
    SARingReaderStats reader[SA_RING_CHANNELS];   /* [0] = left, [1] = right */
} SARingSnapshot;

/* Control thread. capacityFrames must be a power of two in [2, SA_RING_MAX_CAPACITY_FRAMES]; otherwise NULL. Allocates. */
SARing *_Nullable SARingCreate(uint32_t capacityFrames);

/* Control thread. Only when no producer callback and no render block can run any more. */
void SARingFree(SARing *_Nullable ring);

/* The reader for channel 0 (left) or 1 (right); NULL for any other channel. Valid until SARingFree. */
SARingReader *_Nullable SARingGetReader(SARing *ring, uint32_t channel);

/* Control thread, readers not running (engine stopped or not yet started); the producer may be running. Starts BOTH readers at the same
 * frame index, `primeCallbacks` x (frames of the latest tap callback) behind the producer index, and zeroes their counters and the
 * producer's reject record. Returns false and changes nothing if fewer than `primeCallbacks` callbacks were committed yet, if the depth is
 * zero, exceeds what was written, or exceeds what the ring can serve. It never waits: the caller waits for the commit count and retries. */
bool SARingPrime(SARing *ring, uint32_t primeCallbacks);

/* Control thread. Atomic loads of w, of each published cursor and of each counter, copied field by field; fill = w - cursor is computed ONCE per
 * channel from the w and cursor loaded in this call. The snapshot is not an atomic cut: counters may be from slightly different instants. */
bool SARingTakeSnapshot(const SARing *ring, SARingSnapshot *out);

/* Producer, real time. Commits `frames` interleaved stereo frames (L, R, L, R, ...). Refuses (counts, flags) zero frames and more than
 * capacity / 2 frames. Single producer only. */
void SARingWrite(SARing *ring, const float *interleavedStereo, uint32_t frames) CA_REALTIME_API;

/* Producer, real time. An AudioDeviceIOProc (CoreAudio/AudioHardware.h; nullability as in CTapProbe.h so Swift accepts it). `inClientData`
 * is the SARing. Accepts exactly one interleaved two-channel Float32 buffer in inInputData; anything else is refused and counted, never
 * guessed. Sample values are copied unchanged (a NaN or infinity in the tap is NOT filtered here). */
OSStatus SARingIOProc(AudioObjectID inDevice,
                      const AudioTimeStamp *inNow,
                      const AudioBufferList *inInputData,
                      const AudioTimeStamp *inInputTime,
                      AudioBufferList *outOutputData,
                      const AudioTimeStamp *inOutputTime,
                      void *__nullable inClientData) CA_REALTIME_API;

/* Render side, real time. One call per AVAudioSourceNode block call; the block's single call. Output must be one mono Float32 buffer with
 * room for frameCount frames, otherwise nothing is written and kAudio_ParamError is returned. If every requested frame is available the block
 * copies it; otherwise it writes frameCount zeros and sets *isSilence. The cursor advances by exactly frameCount on EVERY call. */
OSStatus SARingRender(SARingReader *reader,
                      bool *isSilence,
                      const AudioTimeStamp *__nullable timestamp,
                      uint32_t frameCount,
                      AudioBufferList *__nullable outputData) CA_REALTIME_API;

#pragma clang assume_nonnull end

#if defined(__OBJC__)
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN
/* Control thread, Objective-C (never from Swift). A mono Float32 AVAudioSourceNode whose render block makes exactly one call, SARingRender(reader, ...).
 * `format` must be mono Float32 (else nil). The block captures only the raw `reader` pointer: the reader (and its ring) must outlive the node.
 * Uses initWithFormat:renderBlock: (macOS 10.15+), not the macOS 27 realtime-safe initializer. */
AVAudioSourceNode *_Nullable SACreateSourceNode(SARingReader *reader, AVAudioFormat *format);
NS_ASSUME_NONNULL_END
#endif

#endif
