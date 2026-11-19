/*
 * bkp_view.h: the face every format hosts (plan step 9).  The face itself is SwiftUI (the Swift files in plugin/ui),
 * compiled into each format under its own Swift module name (BeatKeyAU, BeatKeyVST3), so the AU and the
 * VST3 loaded in one host never share a class (plan A6).  Fixed BKP_VIEW_W x BKP_VIEW_H.
 *
 * This header is the face's whole reach into the instance:
 *   - the shims call bkp_view_register / unregister / create (unchanged since step 8);
 *   - the Swift face calls bkp_view_read and the bkp_view_* actions below, by TOKEN, never by pointer.
 *
 * Lifetime: a view never holds the instance, only a token.  bkp_view_register(p) when the instance is
 * made, bkp_view_unregister(token) BEFORE bkp_destroy(p): from then on every call with that token says
 * "closed" and never touches p, even when the host keeps the view alive after the instance (unregister
 * waits out a call that is reading p).  Register / unregister / read / actions: any non-audio thread.
 * bkp_view_create: main thread.
 */
#ifndef BKP_VIEW_H_INCLUDED
#define BKP_VIEW_H_INCLUDED

#include <stdint.h>

#include "bkp.h"

#define BKP_VIEW_W 360
#define BKP_VIEW_H 120

#ifdef __cplusplus
extern "C" {
#endif

uint64_t bkp_view_register(bkp_instance *p);      /* 0 = could not (logged); the face then never opens */
void bkp_view_unregister(uint64_t token);
/* An autoreleased NSView * (void * so C++ shims need no Objective-C), or NULL (logged).  Implemented
 * by the Swift face (plugin/ui/FaceBridge.swift, @_cdecl). */
void *bkp_view_create(uint64_t token);

/* ---- what the face reads, in one go (one lock) ---- */
typedef struct bkp_view_state {
    int         alive;           /* 0 = the instance is closed: nothing below is set */
    int         has_key;         /* the key in use (the pin, else the detector's first) */
    char        key[8];
    char        pin[8];          /* "" = no pin */
    int         has_bpm;         /* the BPM in use (refined, else whole; x2 / /2 applied) */
    double      bpm;
    int         bpm_exact;       /* 1 = the BPM is the refined (decimal) one */
    int         tempo_mult;      /* -1 halve, 0 as read, +1 double */
    double      host_tempo;      /* the session's tempo; 0 = the host did not say */
    int         bypass;
    char        format[8];       /* "AU", "VST3" */
    char        status[256];     /* "" when analyzing, else why not (the face shows it) */
    bk_snapshot snap;            /* top 3 with %, tuning, readings, song / reading_song, silent, ... */
} bkp_view_state;

/* 0 = filled; -1 = closed (out->alive = 0) or a NULL out. */
int bkp_view_read(uint64_t token, bkp_view_state *out);

/* ---- what the face does (each: 0 = done, -1 = closed or refused; refusals are logged) ---- */
int bkp_view_set_pin(uint64_t token, const char *key);    /* NULL / "" = unpin */
int bkp_view_set_tempo_mult(uint64_t token, int mult);
int bkp_view_new_song(uint64_t token);
/* The send log line (bkp_log_send) for this instance; a closed token logs under "plugin". */
void bkp_view_log_send(uint64_t token, const char *what, const char *value, int ok, const char *outcome);
/* One plain line into plugin.log under this instance's area (token 0 or closed: area "plugin"). */
void bkp_view_log(uint64_t token, const char *line);
/* The plug-in's version (the repo's VERSION, compiled in). */
const char *bkp_view_version(void);

#ifdef __cplusplus
}
#endif

#endif
