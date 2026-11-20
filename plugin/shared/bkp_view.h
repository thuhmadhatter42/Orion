/*
 * bkp_view.h: the face every format hosts (plan step 9).  The face itself is SwiftUI (the Swift files in plugin/ui),
 * compiled into each format under its own Swift module name (BeatKeyAU, BeatKeyVST3), so the AU and the
 * VST3 loaded in one host never share a class (plan A6).  Default BKP_VIEW_W x BKP_VIEW_H; bkp_face_size.
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

/* The face's default size: the app window's face (FaceplateFace.pluginSize(advanced: false)); face_test
 * checks the two agree.  ADVANCED widens it: bkp_face_size gives the size now. */
#define BKP_VIEW_W 512
#define BKP_VIEW_H 750

#ifdef __cplusplus
extern "C" {
#endif

uint64_t bkp_view_register(bkp_instance *p);      /* 0 = could not (logged); the face then never opens */
void bkp_view_unregister(uint64_t token);
/* An autoreleased NSView * (void * so C++ shims need no Objective-C), or NULL (logged).  Implemented
 * by the Swift face (plugin/ui/FaceBridge.swift, @_cdecl). */
void *bkp_view_create(uint64_t token);
/* The face's size now (BKP_VIEW_W x BKP_VIEW_H, wider with ADVANCED on).  Implemented by the Swift face
 * (FaceBridge.swift, @_cdecl).  Main thread. */
void bkp_face_size(int32_t *w, int32_t *h);

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
    char        format[16];      /* "AU", "VST3", "AU-MIDI", "VST3-MIDI" */
    char        status[256];     /* "" when analyzing, else why not (the face shows it) */
    bk_snapshot snap;            /* top 3 with %, tuning, readings, song / reading_song, silent, ... */
    int         clip_state;      /* bkp_clip_state: 0 live, 1 reads whole clips (AudioSuite), 2 analyzing one now */
    int         midi;            /* 1 = the MIDI variant (plan step 15) */
    int         midi_route;      /* bkp_midi_route: 0 no audio yet, 1 the host takes MIDI, 2 it does not */
    int         midi_sounding;   /* bkp_midi_sounding: the key index whose chord is held, -1 none */
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

/* ---- the MIDI variant (plan step 15) ----
 * The shims of Beat Key MIDI call bkp_view_midi_enable(p) once, after bkp_create: it asks the face's
 * Swift for the chords (bkp_face_midi_chords: the app's Harmony, so the notes have one owner) and
 * hands them to bkp_midi_enable.  0 = ok, -1 = refused (logged; the instance then sends no MIDI). */
int bkp_view_midi_enable(bkp_instance *p);
/* Implemented by the Swift face (plugin/ui/MidiOut.swift, @_cdecl): fills notes[k] with the chord of
 * key index k (bk_key_index order), returns the notes per chord (0 = none) and sets *velocity. */
int bkp_face_midi_chords(uint8_t notes[BKP_MIDI_KEYS][BKP_MIDI_NOTES], int *velocity);

#ifdef __cplusplus
}
#endif

#endif
