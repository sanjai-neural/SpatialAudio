#include "CPoseMailbox.h"

#include <stdatomic.h>
#include <stdlib.h>

/*
 * Classic triple buffer. Three slots; at any moment each belongs to exactly one of:
 *   writer ("back"), reader ("front"), or the shared "middle" slot.
 * `middle` holds the middle slot's index in bits 0-1 and a DIRTY flag (bit 2) meaning
 * "the writer has published something the reader has not taken yet".
 *
 *  Publish: fill slots[back]; old = exchange(middle, back|DIRTY); back = old & MASK.
 *  Read:    if middle is DIRTY: old = exchange(middle, front); front = old & MASK.
 *           then read slots[front].
 *
 * The exchanges are acq_rel: the writer's slot writes happen-before the reader's reads of that
 * slot, and the reader's reads of a slot happen-before the writer reuses it.
 */
#define SA_DIRTY 4u
#define SA_INDEX_MASK 3u

/* Field-by-field copy on purpose: ThreadSanitizer's runtime did not race-check the bulk memcpy
 * that a plain struct assignment compiles to (verified by mutation testing, see docs/STATUS.md),
 * so scalar accesses keep the sanitizer able to see ordering bugs. Same cost for 6 fields. */
static inline void sa_copy(SAPoseSample *dst, const SAPoseSample *src) {
    dst->w = src->w; dst->x = src->x; dst->y = src->y; dst->z = src->z;
    dst->timestamp = src->timestamp; dst->sequence = src->sequence;
}

struct SAPoseMailbox {
    SAPoseSample slots[3];
    _Atomic uint32_t middle;
    uint32_t back;               /* writer-owned */
    uint64_t nextSequence;       /* writer-owned */
    uint32_t front;              /* reader-owned */
    uint64_t lastReadSequence;   /* reader-owned */
};

SAPoseMailbox *SAPoseMailboxCreate(void) {
    SAPoseMailbox *mb = calloc(1, sizeof(SAPoseMailbox));
    if (!mb) return NULL;
    for (int i = 0; i < 3; i++) mb->slots[i].w = 1.0;   /* identity until first publish */
    mb->back = 0;
    atomic_init(&mb->middle, 1u);
    mb->front = 2;
    return mb;
}

void SAPoseMailboxDestroy(SAPoseMailbox *mb) {
    free(mb);
}

void SAPoseMailboxPublish(SAPoseMailbox *mb, const SAPoseSample *sample) {
    SAPoseSample *slot = &mb->slots[mb->back];
    sa_copy(slot, sample);
    slot->sequence = ++mb->nextSequence;
    uint32_t old = atomic_exchange_explicit(&mb->middle, mb->back | SA_DIRTY, memory_order_acq_rel);
    mb->back = old & SA_INDEX_MASK;
}

bool SAPoseMailboxRead(SAPoseMailbox *mb, SAPoseSample *out) {
    if (atomic_load_explicit(&mb->middle, memory_order_relaxed) & SA_DIRTY) {
        uint32_t old = atomic_exchange_explicit(&mb->middle, mb->front, memory_order_acq_rel);
        mb->front = old & SA_INDEX_MASK;
    }
    sa_copy(out, &mb->slots[mb->front]);
    bool isNew = out->sequence > mb->lastReadSequence;
    mb->lastReadSequence = out->sequence;
    return isNew;
}
