/*
 * beatkey.h: the Beat Key analysis core, C API (bk_*).
 *
 * What the core is: key + BPM from mono audio, the same answers the Python analyzer (bpm.py) gives.
 * It knows no host types and has no UI.  The plug-in shims (AU, VST3, AAX) and, later, the app call
 * this header and nothing else.  C++17 inside; nothing C++ crosses this boundary and no call throws.
 *
 * Three ways in:
 *   bk_analyze_buffer   a whole clip at once (AudioSuite, a dropped file): bpm.py's analyze_full.
 *   bk_analyze_midi     a Standard MIDI File (a dropped .mid): midi_analyze.py's analyze_midi.
 *   bk_analyzer_*       live: one analyzer per plug-in instance.  The audio thread pushes into a
 *                       lock-free ring; ONE worker thread per process serves every analyzer and
 *                       publishes snapshots.  bpm.py's LiveAnalyzer (Listen), same rules.
 *   bk_log              the one log writer (file + os_log); the shims log through it.
 *
 * Bring-up is rigid: bk_load_weights must succeed before anything analyzes.  There is no key-only
 * or other fallback mode; a damaged install is refused with BK_ERR_NO_WEIGHTS and a log line.
 *
 * Threads:
 *   bk_analyzer_push / bk_analyzer_push_channels   the AUDIO thread.  No allocation, no lock, no
 *       log, no system call.  A full ring drops the audio and counts it; it never waits.
 *   everything else                                 any non-audio thread.
 */
#ifndef BEATKEY_H
#define BEATKEY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BK_API_VERSION 1

/* ---- result codes ---- */
enum {
    BK_OK = 0,
    BK_ERR_NO_WEIGHTS = 1,   /* bk_load_weights has not succeeded: "The analyzer is incomplete." */
    BK_ERR_BAD_WEIGHTS = 2,  /* the weights file is missing, damaged, or not the layout this core needs */
    BK_ERR_BAD_ARG = 3,      /* a NULL, a sample rate outside 8000..384000, a non-finite sample */
    BK_ERR_INTERNAL = 4      /* an analysis step failed; the reason is in the log and in `err` */
};

/* The repo's VERSION, compiled in by core/build.sh ("0.1.77"). */
const char *bk_version(void);

/* ---- bring-up ---- */

/* Load the TempoCNN weights (models/deeptemp-k16-3.bkw; a separate CC BY-NC-SA 4.0 data file that
 * ships beside the binary, never inside it).  Once per process.  Calling it again with weights
 * already loaded is a no-op that returns BK_OK.  `err` (may be NULL) gets one plain sentence. */
int bk_load_weights(const char *path, char *err, size_t err_cap);
int bk_ready(void);                       /* 1 once the weights are loaded */

/* ---- the log ---- */

/* The log folder.  NULL or "" = $BEATKEY_LOG_DIR, else ~/Library/Logs/Beat Key (the account's real
 * home, so a sandboxed host does not hide it).  File: plugin.log, rolled at 1 MB (plugin.log.1). */
void bk_log_set_dir(const char *dir);
/* Path of the current log file, written into buf; returns buf ("" when no folder can be found). */
const char *bk_log_path(char *buf, size_t cap);
/* Where the lines go instead of plugin.log: the Mac app hands its own log writer here, so the core's
 * lines land in beatkey.log beside the app's (os_log still gets every line).  sink(area, message,
 * ctx) is called on whatever thread logged (the worker, an analysis queue), never the audio thread.
 * NULL = back to the file.  Set it before the first analysis; it is not changed while one runs. */
typedef void (*bk_log_sink)(const char *area, const char *message, void *ctx);
void bk_log_set_sink(bk_log_sink sink, void *ctx);
/* One line: "<local time> <offset> pid <p> <area> <message>".  NEVER from the audio thread. */
void bk_log(const char *area, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

/* ---- a reading ---- */

typedef struct bk_key {
    char   name[4];          /* "C", "F#", "Ebm": Auto-Tune's spelling, NUL-terminated */
    double percent;          /* 0..100 */
} bk_key;

typedef struct bk_reading {
    bk_key keys[3];          /* best first.  Files: 0.1 steps.  Live: whole numbers */
    int    has_tuning;       /* 0 while the key is under 50 % sure (atonal, drums) or nothing tonal was heard */
    double tuning_cents;     /* against A = 440, -50..+50, + = sharp */
    double chroma[12];       /* C..B, 0..1: the notes heard */
    int    has_bpm;          /* live: 0 until 12 s have been heard.  Files: always 1 */
    double bpm;              /* TempoCNN's whole BPM (0 = clip too short for a tempo) */
    int    has_bpm_exact;
    double bpm_exact;        /* refined to 0.01 BPM */
    double secs;             /* live: seconds of sound behind the reading.  Files: the clip's length */
} bk_reading;

/* The 24 key names the core reads out ("C".."B", "Cm".."Bm" in Auto-Tune's spelling): the index
 * 2 * pitch class + (0 major, 1 minor), or -1 for anything else (NULL included).  Any thread. */
int bk_key_index(const char *name);
/* The other way: index 0..23 to its name (a static string), NULL out of range.  No allocation, no
 * lock: any thread, the AUDIO thread included (bk_key_index too, from this version on). */
const char *bk_key_name(int index);

/* ---- a whole clip (bpm.py analyze_full, without the decoding) ---- */

/* mono: n float32 samples at sample_rate (any rate 8000..384000; resampled inside as bpm.py does).
 * Blocks for the length of the analysis; call it from an offline / worker thread. */
int bk_analyze_buffer(const float *mono, size_t n, double sample_rate, bk_reading *out,
                      char *err, size_t err_cap);

/* ---- a MIDI file (midi_analyze.py analyze_midi) ---- */

/* data: the whole .mid / .midi file.  out: keys (0.1 steps; C / Am / G at 0 % when the file has
 * under 4 pitched notes), bpm (0.1) and bpm_exact (0.01) from the tempo covering the most ticks
 * (120 when none); no tuning, chroma all 0.  Needs no weights.  BK_ERR_BAD_ARG = not a MIDI file
 * (the reason in `err` and the log). */
int bk_analyze_midi(const uint8_t *data, size_t n, bk_reading *out, char *err, size_t err_cap);

/* ---- live ---- */

typedef struct bk_analyzer bk_analyzer;

typedef struct bk_analyzer_config {
    double      sample_rate; /* the host's rate */
    const char *host;        /* for the log: the host's bundle id or name (may be NULL) */
    const char *format;      /* for the log: "AU", "VST3", "AAX" (may be NULL) */
} bk_analyzer_config;

typedef struct bk_snapshot {
    uint64_t   seq;            /* changes whenever anything below changed */
    int        has_reading;
    bk_reading reading;        /* the newest reading */
    uint64_t   readings;       /* readings made since create */
    uint64_t   song;           /* goes up at every new song: a silence gap, a change found in the
                                  audio, or bk_analyzer_new_song */
    uint64_t   reading_song;   /* the song the reading belongs to (older than `song` = stale) */
    int        silent;         /* 1 from "3 s under -50 dB" until sound comes back */
    double     level_db;       /* the last half-second's RMS level */
    uint64_t   dropped_frames; /* audio the ring had no room for (worker behind, offline bounce) */
    uint64_t   refused_chunks; /* half-seconds refused because the host's samples were not audio
                                  (not a number, or over +60 dB); they were heard as silence */
    double     last_reading_ms;/* worker time the newest reading cost */
    int        error;          /* 1 = analysis stopped for this analyzer after an error (see the log) */
    int        song_why;       /* what began the newest song (BK_SONG_*): the gap, the audio, or new_song */
    double     silence_db;     /* the level of the chunk that tripped the newest silence (0.1 dB) */
    double     sound_after;    /* seconds of silence the newest return of sound ended (0.1 s) */
} bk_snapshot;

/* bk_snapshot.song_why */
enum {
    BK_SONG_NONE = 0,        /* still the first song */
    BK_SONG_SILENCE = 1,     /* 3 s of silence: everything heard was dropped (bpm.py "reset") */
    BK_SONG_AUDIO = 2,       /* a change found in the audio (bpm.py "boundary", reason "audio") */
    BK_SONG_ANNOUNCED = 3    /* bk_analyzer_new_song (bpm.py "boundary", reason "title") */
};

/* NULL on refusal (no weights, bad rate, out of memory); the reason goes to `err` and the log. */
bk_analyzer *bk_analyzer_create(const bk_analyzer_config *cfg, char *err, size_t err_cap);
/* Safe from any non-audio thread.  The host must have stopped calling push for this analyzer. */
void bk_analyzer_destroy(bk_analyzer *a);

/* AUDIO THREAD.  Returns the frames taken; the rest were dropped and counted. */
size_t bk_analyzer_push(bk_analyzer *a, const float *mono, size_t frames);
/* AUDIO THREAD.  Downmix inside: the plain mean of the channels (stereo = 0.5 * (L + R), the
 * analyzer's MonoMixer).  channels: 1..64 pointers to `frames` samples each. */
size_t bk_analyzer_push_channels(bk_analyzer *a, const float *const *channels, int n_channels, size_t frames);

/* The newest snapshot.  Lock-free for the reader; safe from the UI thread at any rate. */
void bk_analyzer_snapshot(const bk_analyzer *a, bk_snapshot *out);
/* Seconds under -50 dB that mean a new song (bpm.py --gap): 1..30.  Default 3, what the goldens
 * were made with; the app's Listen setting changes it, the plug-ins leave it.  Any non-audio thread;
 * it takes effect from the next half-second the worker reads.  BK_ERR_BAD_ARG outside 1..30. */
int bk_analyzer_set_silence_gap(bk_analyzer *a, double seconds);
/* "New song, start over" (the user, or a host that knows): everything heard is dropped. */
void bk_analyzer_new_song(bk_analyzer *a);

#ifdef __cplusplus
}
#endif

#endif
