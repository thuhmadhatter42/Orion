/*
 * tripwire.c: a test dylib that interposes malloc / calloc / realloc / free / pthread_mutex_lock
 * for every image in the test process and counts the calls made by an ARMED thread.  A test arms
 * the thread that plays the audio thread, runs the real push path, and requires both counts to be
 * zero (plan A4.1: no allocation, no lock on the audio thread).  Other threads (the worker) are
 * never counted.  Linked, not injected: no DYLD_INSERT_LIBRARIES.
 */
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

static __thread int t_armed;
static volatile long g_mallocs, g_locks;

void tw_arm(void)     { g_mallocs = 0; g_locks = 0; t_armed = 1; }
void tw_disarm(void)  { t_armed = 0; }
long tw_mallocs(void) { return g_mallocs; }
long tw_locks(void)   { return g_locks; }

static void *my_malloc(size_t n)             { if (t_armed) __sync_fetch_and_add(&g_mallocs, 1); return malloc(n); }
static void *my_calloc(size_t a, size_t b)   { if (t_armed) __sync_fetch_and_add(&g_mallocs, 1); return calloc(a, b); }
static void *my_realloc(void *p, size_t n)   { if (t_armed) __sync_fetch_and_add(&g_mallocs, 1); return realloc(p, n); }
static void  my_free(void *p)                { if (t_armed) __sync_fetch_and_add(&g_mallocs, 1); free(p); }
static int   my_lock(pthread_mutex_t *m)     { if (t_armed) __sync_fetch_and_add(&g_locks, 1); return pthread_mutex_lock(m); }

#define INTERPOSE(rep, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } _ip_##orig \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&rep, (const void *)(uintptr_t)&orig }
INTERPOSE(my_malloc, malloc);
INTERPOSE(my_calloc, calloc);
INTERPOSE(my_realloc, realloc);
INTERPOSE(my_free, free);
INTERPOSE(my_lock, pthread_mutex_lock);
