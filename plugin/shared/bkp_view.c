/*
 * bkp_view.c: the face's token table and its one doorway into the instance (see bkp_view.h).
 * The SwiftUI face (plugin/ui) calls only these functions; each takes the table's lock, finds the
 * instance by token, and calls the instance layer.  bkp_view_unregister takes the same lock, so it
 * waits out a call that is reading the instance, and every later call sees "closed".
 * Never the audio thread: nothing here is called from bkp_process.
 */
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include "bkp_view.h"

#ifndef BKP_VERSION
#error "BKP_VERSION is not defined: build the plug-in with plugin/build.sh (it reads the repo's VERSION)"
#endif

#define BKP_VIEW_SLOTS 256
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static struct { uint64_t token; bkp_instance *p; } g_slots[BKP_VIEW_SLOTS];
static uint64_t g_next = 1;

uint64_t bkp_view_register(bkp_instance *p) {
    if (!p) return 0;
    pthread_mutex_lock(&g_mu);
    uint64_t t = 0;
    for (int i = 0; i < BKP_VIEW_SLOTS; i++)
        if (g_slots[i].token == 0) {
            t = g_next++;
            g_slots[i].token = t;
            g_slots[i].p = p;
            break;
        }
    pthread_mutex_unlock(&g_mu);
    if (!t) bkp_log(p, "REFUSED: %d instances already have a face in this host; this one will not open its face", BKP_VIEW_SLOTS);
    return t;
}

void bkp_view_unregister(uint64_t token) {
    if (!token) return;
    pthread_mutex_lock(&g_mu);   /* waits out a call reading the instance */
    for (int i = 0; i < BKP_VIEW_SLOTS; i++)
        if (g_slots[i].token == token) g_slots[i].token = 0, g_slots[i].p = NULL;
    pthread_mutex_unlock(&g_mu);
}

/* The instance for `token`, with the lock HELD (the caller unlocks), or NULL with the lock released. */
static bkp_instance *lock_token(uint64_t token) {
    if (!token) return NULL;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < BKP_VIEW_SLOTS; i++)
        if (g_slots[i].token == token) return g_slots[i].p;
    pthread_mutex_unlock(&g_mu);
    return NULL;
}

int bkp_view_read(uint64_t token, bkp_view_state *out) {
    if (!out) return -1;
    memset(out, 0, sizeof *out);
    bkp_instance *p = lock_token(token);
    if (!p) return -1;
    out->alive = 1;
    out->has_key = bkp_key_in_use(p, out->key, sizeof out->key) == 0;
    bkp_pin(p, out->pin, sizeof out->pin);
    out->has_bpm = bkp_bpm_in_use(p, &out->bpm) == 0;
    out->tempo_mult = bkp_tempo_mult(p);
    out->host_tempo = bkp_host_tempo(p);
    out->bypass = bkp_bypass(p);
    snprintf(out->format, sizeof out->format, "%s", bkp_format(p));
    bkp_status(p, out->status, sizeof out->status);
    bkp_snapshot(p, &out->snap);
    out->bpm_exact = out->has_bpm && out->snap.has_reading && out->snap.reading.has_bpm_exact;
    out->midi = bkp_midi(p);
    out->midi_route = bkp_midi_route(p);
    out->midi_sounding = bkp_midi_sounding(p);
    if (out->midi) bkp_midi_log_route(p);   /* one line per route change, while the face is open */
    pthread_mutex_unlock(&g_mu);
    return 0;
}

int bkp_view_set_pin(uint64_t token, const char *key) {
    bkp_instance *p = lock_token(token);
    if (!p) return -1;
    int r = bkp_set_pin(p, key);
    pthread_mutex_unlock(&g_mu);
    return r;
}

int bkp_view_set_tempo_mult(uint64_t token, int mult) {
    bkp_instance *p = lock_token(token);
    if (!p) return -1;
    int r = bkp_set_tempo_mult(p, mult);
    pthread_mutex_unlock(&g_mu);
    return r;
}

int bkp_view_new_song(uint64_t token) {
    bkp_instance *p = lock_token(token);
    if (!p) return -1;
    bkp_new_song(p);
    pthread_mutex_unlock(&g_mu);
    return 0;
}

void bkp_view_log_send(uint64_t token, const char *what, const char *value, int ok, const char *outcome) {
    bkp_instance *p = lock_token(token);
    if (!p) {
        bk_log("plugin", "SEND %s %s: %s (%s; the instance closed before the answer)", what ? what : "?",
               value ? value : "", ok ? "ok" : "FAILED", outcome ? outcome : "");
        return;
    }
    bkp_log_send(p, what, value, ok, outcome);
    pthread_mutex_unlock(&g_mu);
}

void bkp_view_log(uint64_t token, const char *line) {
    if (!line) return;
    bkp_instance *p = lock_token(token);
    if (!p) {
        bk_log("plugin", "%s", line);
        return;
    }
    bkp_log(p, "%s", line);
    pthread_mutex_unlock(&g_mu);
}

const char *bkp_view_version(void) { return BKP_VERSION; }

int bkp_view_midi_enable(bkp_instance *p) {
    if (!p) return -1;
    uint8_t notes[BKP_MIDI_KEYS][BKP_MIDI_NOTES];
    memset(notes, 0, sizeof notes);
    int velocity = 0;
    const int n = bkp_face_midi_chords(notes, &velocity);
    if (n <= 0) {
        bkp_log(p, "REFUSED: the face gave no chords for the MIDI variant; this instance sends no MIDI");
        return -1;
    }
    return bkp_midi_enable(p, (const uint8_t (*)[BKP_MIDI_NOTES])notes, n, velocity);
}
