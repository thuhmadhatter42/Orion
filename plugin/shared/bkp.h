/*
 * bkp.h: the Beat Key plug-in's instance layer (plan step 7, A3 "plugin/shared").
 *
 * One object, bkp_instance, that every format shim (AU, VST3, later AAX) owns exactly one of.  The
 * shims know host types and nothing of the core; this layer knows the core (beatkey.h) and no host
 * types.  It owns, and nothing else does:
 *   - bring-up: the weights (bk_load_weights, once per process) and the analyzer for the host's rate
 *   - THE audio function (bkp_process): pass-through copy, then the tap into the core's ring
 *   - bypass and the host-tempo slot (both audio-thread safe atomics)
 *   - the session state blob (pin, x2 / /2, last reading): encode / decode, version, size cap
 *   - the values the two buttons send (key in use, BPM in use) and their log lines
 *   - the "host died with Beat Key in it" marker (house kit crash catcher for a plug-in, A7)
 * Plain C API so the shims (C++ / Objective-C) and the SwiftUI face (step 9) call the same thing.
 *
 * Threads:
 *   bkp_process, bkp_set_host_tempo                 the AUDIO thread: no allocation, no lock, no log,
 *                                                   no system call (the tripwire test proves it).
 *   bkp_host_tempo, bkp_bypass                      any thread, lock-free.
 *   everything else                                 any NON-audio thread (host main thread, UI); they
 *                                                   share one per-instance lock, never taken by the
 *                                                   audio thread.
 * bkp_prepare may be called while the host still calls bkp_process from the audio thread: the
 * analyzer is swapped out under a hand-over that never makes the audio thread wait.
 */
#ifndef BKP_H
#define BKP_H

#include <stddef.h>
#include <stdint.h>

#include "beatkey.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct bkp_instance bkp_instance;

typedef struct bkp_config {
    const char *format;        /* "AU", "VST3", "AAX": for the log and the marker */
    const char *weights_path;  /* <bundle>/Contents/Resources/deeptemp-k16-3.bkw */
    const char *host;          /* host bundle id or name; NULL = the main bundle's id, else the process name */
} bkp_config;

/* Never NULL unless out of memory.  An instance whose weights could not load still passes audio
 * through; bkp_status says why it does not analyze (the sentence the face shows). */
bkp_instance *bkp_create(const bkp_config *cfg);
/* The host is done with the instance (it no longer calls bkp_process).  May join the core's worker
 * when this was the last analyzer in the process (up to one reading, ~0.1-0.2 s). */
void bkp_destroy(bkp_instance *p);

/* The host's sample rate.  Creates the analyzer, or replaces it when the rate changed (the reading
 * so far is kept for the face and the state).  0 = ok; else the reason is in bkp_status and the log. */
int bkp_prepare(bkp_instance *p, double sample_rate);

/* AUDIO THREAD.  THE audio function of every format.  Copies in[c] to out[c] (in place is fine),
 * zeroes outputs that have no input, then (unless bypassed) pushes the inputs into the analyzer.
 * f64 = 1: the buffers are double (VST3 kSample64), else float.  Never fails, never waits. */
void bkp_process(bkp_instance *p, const void *const *in, int n_in, void *const *out, int n_out,
                 uint32_t frames, int f64);

/* Bypass: audio still passes through untouched; the analyzer hears nothing while it is on. */
void bkp_set_bypass(bkp_instance *p, int on);
int bkp_bypass(const bkp_instance *p);

/* Host tempo (VST3 process context, AU host callback, AAX transport).  bpm <= 0 or not finite = unknown.
 * Setter: audio thread (or any).  Getter: any thread; returns 0 when unknown. */
void bkp_set_host_tempo(bkp_instance *p, double bpm);
double bkp_host_tempo(const bkp_instance *p);

/* The face's view of the instance: the core's newest snapshot, or, while the analyzer has none yet
 * (fresh session, after a rate change), the last reading the instance held or the session restored
 * (then has_reading = 1 and readings = 0). */
void bkp_snapshot(bkp_instance *p, bk_snapshot *out);
/* "New song, start over" (the face's button). */
void bkp_new_song(bkp_instance *p);
/* One plain sentence: "" when analyzing, else why not (weights missing, no rate yet, ...). */
const char *bkp_status(bkp_instance *p, char *buf, size_t cap);

/* ---- session choices ---- */
/* Pin a key (one of the 24 names the core reads out: bk_key_index), or
 * NULL / "" to unpin.  0 = ok, -1 = not a key name (logged, pin unchanged). */
int bkp_set_pin(bkp_instance *p, const char *key);
/* The pinned key into buf ("" = none). */
const char *bkp_pin(bkp_instance *p, char *buf, size_t cap);
/* -1 = halve, 0 = as read, +1 = double.  0 = ok, -1 = refused (logged). */
int bkp_set_tempo_mult(bkp_instance *p, int mult);
int bkp_tempo_mult(bkp_instance *p);

/* ---- the two buttons: what they send ---- */
/* The key in use: the pin if set, else the detector's first.  0 = ok, -1 = nothing to send yet. */
int bkp_key_in_use(bkp_instance *p, char *buf, size_t cap);
/* The BPM in use: the refined BPM (else the whole one) with x2 / /2 applied.  0 = ok, -1 = none yet. */
int bkp_bpm_in_use(bkp_instance *p, double *bpm);
/* One log line per send: what ("BPM", "AUTO-TUNE"), the value sent, and the outcome sentence. */
void bkp_log_send(bkp_instance *p, const char *what, const char *value, int ok, const char *outcome);

/* ---- session state (the host's chunk) ---- */
#define BKP_STATE_MAGIC   0x53504B42u   /* "BKPS" little-endian */
#define BKP_STATE_VERSION 1
#define BKP_STATE_CAP     4096          /* any blob over this is refused before it is read */

/* Writes the state into buf.  Returns its length, or 0 when cap is too small (logged).
 * BKP_STATE_CAP bytes is always enough. */
size_t bkp_state_save(bkp_instance *p, uint8_t *buf, size_t cap);
/* Restores a saved state.  0 = ok.  -1 = refused (garbage, cut short, over the cap, newer version,
 * a value out of range); the instance keeps what it had, the reason goes to err and the log.
 * len 0 = the host has nothing saved: ok, nothing changes. */
int bkp_state_load(bkp_instance *p, const uint8_t *buf, size_t len, char *err, size_t err_cap);

/* ---- the instance's identity, for the face and the shims' log lines ---- */
const char *bkp_format(const bkp_instance *p);
/* The log through the core's one writer, with this instance's area ("AU 3f2a", ...).  NEVER from
 * the audio thread. */
void bkp_log(bkp_instance *p, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

#ifdef __cplusplus
}
#endif

#endif
