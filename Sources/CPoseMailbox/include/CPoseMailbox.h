#ifndef CPOSEMAILBOX_H
#define CPOSEMAILBOX_H

#include <stdbool.h>
#include <stdint.h>

/*
 * Single-producer / single-consumer "latest value" mailbox (triple buffer) for handing the head
 * pose from the tracking thread to the audio render thread.
 *
 *  - Wait-free for both sides: no locks, no allocation, no syscalls, no loops in Publish/Read.
 *  - Exactly ONE thread may call SAPoseMailboxPublish and exactly ONE (other) thread may call
 *    SAPoseMailboxRead. Create/Destroy are NOT real-time safe and must not race with either.
 *  - Built on C11 <stdatomic.h> because Swift's Synchronization.Atomic needs macOS 15 and the
 *    package minimum is macOS 14.0.
 */

typedef struct {
    double w, x, y, z;      /* orientation quaternion, stored as given (not normalized here) */
    double timestamp;       /* seconds, caller-defined clock */
    uint64_t sequence;      /* assigned by Publish, starting at 1; 0 means "never published" */
} SAPoseSample;

typedef struct SAPoseMailbox SAPoseMailbox;

/* Allocates. Returns NULL on allocation failure. Not real-time safe. */
SAPoseMailbox *SAPoseMailboxCreate(void);

/* Frees. Not real-time safe. Caller guarantees no concurrent Publish/Read. */
void SAPoseMailboxDestroy(SAPoseMailbox *mb);

/* Producer thread only. Wait-free. The sample's `sequence` field is ignored and overwritten. */
void SAPoseMailboxPublish(SAPoseMailbox *mb, const SAPoseSample *sample);

/* Consumer thread only. Wait-free. Always fills `out` with the most recent published sample
 * (sequence 0 and identity orientation if none yet). Returns true iff it is newer than the
 * sample returned by the previous call. */
bool SAPoseMailboxRead(SAPoseMailbox *mb, SAPoseSample *out);

#endif
