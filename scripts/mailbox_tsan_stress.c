// Standalone ThreadSanitizer stress harness for CPoseMailbox. Compiles the library source
// directly with -fsanitize=thread (see scripts/tsan-mailbox.sh). One producer, one consumer.
// Every sample's fields are derived from its sequence number so torn reads are detectable.
#include "CPoseMailbox.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define TOTAL 2000000u

static SAPoseMailbox *mb;

static void *producer(void *arg) {
    (void)arg;
    for (uint64_t s = 1; s <= TOTAL; s++) {
        double v = (double)s;
        SAPoseSample p = { v, v, v, v, v * 0.001, 0 };
        SAPoseMailboxPublish(mb, &p);
    }
    return NULL;
}

static struct { uint64_t torn, backwards, newReads, reads, last; } r;

static void *consumer(void *arg) {
    (void)arg;
    while (r.last < TOTAL) {
        SAPoseSample s;
        bool isNew = SAPoseMailboxRead(mb, &s);
        if (s.sequence == 0) continue;
        double v = (double)s.sequence;
        if (s.w != v || s.x != v || s.y != v || s.z != v || s.timestamp != v * 0.001) r.torn++;
        if (s.sequence < r.last) r.backwards++;
        if (isNew) r.newReads++;
        r.reads++;
        r.last = s.sequence;
    }
    return NULL;
}

int main(void) {
    mb = SAPoseMailboxCreate();
    if (!mb) return 2;
    pthread_t a, b;
    pthread_create(&a, NULL, producer, NULL);
    pthread_create(&b, NULL, consumer, NULL);
    pthread_join(a, NULL);
    pthread_join(b, NULL);
    SAPoseMailboxDestroy(mb);
    printf("published=%u reads=%llu distinctNew=%llu torn=%llu backwards=%llu last=%llu\n", TOTAL,
           (unsigned long long)r.reads, (unsigned long long)r.newReads, (unsigned long long)r.torn,
           (unsigned long long)r.backwards, (unsigned long long)r.last);
    return (r.torn || r.backwards || r.last != TOTAL) ? 1 : 0;
}
