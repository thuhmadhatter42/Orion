/*
 * api.cpp: beatkey.h's C entry points.  This file owns three things and nothing else does them:
 * checking what callers hand in, turning bk::Error into a result code + sentence + log line, and
 * copying the core's C++ results into the public structs.  No analysis happens here.
 */
#include "beatkey.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <memory>
#include <new>

#include "error.h"
#include "file.h"
#include "key.h"
#include "log.h"
#include "midi.h"
#include "sane.h"
#include "tempocnn.h"
#include "worker.h"

#ifndef BK_VERSION
#error "BK_VERSION is not defined: build the core with core/build.sh (it reads the repo's VERSION)"
#endif

namespace {

const char *const kIncomplete = "The analyzer is incomplete: the tempo weights are not loaded.";

bool rate_ok(double rate) { return std::isfinite(rate) && rate >= 8000.0 && rate <= 384000.0; }

void put_key(const bk::KeyGuess &k, bk_key &out) {
    snprintf(out.name, sizeof out.name, "%s", k.name.c_str());
    out.percent = k.percent;
}

}  // namespace

extern "C" {

const char *bk_version(void) { return BK_VERSION; }

int bk_load_weights(const char *path, char *err, size_t err_cap) {
    if (err && err_cap) err[0] = 0;
    try {
        return bk::weights_load(path, err, err_cap);
    } catch (const std::exception &e) {
        bk::fail("weights", err, err_cap, "loading the weights failed: %s", e.what());
        return BK_ERR_INTERNAL;
    }
}

int bk_key_index(const char *name) {
    if (!name) return -1;
    for (int i = 0; i < 24; i++)
        if (strcmp(bk::key_name_c(i), name) == 0) return i;
    return -1;
}

const char *bk_key_name(int index) { return bk::key_name_c(index); }

int bk_ready(void) { return bk::weights_ready() ? 1 : 0; }

void bk_log_set_dir(const char *dir) { bk::log_set_dir(dir); }

const char *bk_log_path(char *buf, size_t cap) {
    if (!buf || !cap) return "";
    snprintf(buf, cap, "%s", bk::log_path().c_str());
    return buf;
}

void bk_log_set_sink(bk_log_sink sink, void *ctx) { bk::log_set_sink(sink, ctx); }

void bk_log(const char *area, const char *fmt, ...) {
    if (!fmt) return;
    va_list ap;
    va_start(ap, fmt);
    bk::logv(area, fmt, ap);
    va_end(ap);
}

int bk_analyze_buffer(const float *mono, size_t n, double sample_rate, bk_reading *out, char *err, size_t err_cap) {
    if (err && err_cap) err[0] = 0;
    if (!out || (!mono && n)) {
        bk::fail("file", err, err_cap, "bk_analyze_buffer was called without audio or without a place for the answer");
        return BK_ERR_BAD_ARG;
    }
    if (!rate_ok(sample_rate)) {
        bk::fail("file", err, err_cap, "sample rate %.1f Hz is outside 8000..384000", sample_rate);
        return BK_ERR_BAD_ARG;
    }
    if (!bk::weights_ready()) {
        bk::fail("file", err, err_cap, "%s", kIncomplete);
        return BK_ERR_NO_WEIGHTS;
    }
    const size_t bad = bk::first_bad_sample(mono, n);
    if (bad != bk::kAllAudio) {
        bk::fail("file", err, err_cap, "sample %zu of %zu is not audio (not a number, or over +60 dB)", bad, n);
        return BK_ERR_BAD_ARG;
    }
    try {
        const bk::FileAnalysis a = bk::analyze_buffer(mono, n, sample_rate, false);
        *out = bk_reading{};
        for (int i = 0; i < 3; i++) put_key(a.key.keys[i], out->keys[i]);
        out->has_tuning = a.key.has_tuning;
        out->tuning_cents = a.key.tuning_cents;
        for (int i = 0; i < 12; i++) out->chroma[i] = a.key.chroma[i];
        out->has_bpm = 1;
        out->bpm = a.bpm;
        out->has_bpm_exact = 1;
        out->bpm_exact = a.bpm_exact;
        out->secs = (double)n / sample_rate;
        bk::logf("file", "clip of %.1f s at %.0f Hz: %s %.1f%% / %s %.1f%% / %s %.1f%%, bpm %.1f (%.2f)",
                 out->secs, sample_rate, out->keys[0].name, out->keys[0].percent, out->keys[1].name,
                 out->keys[1].percent, out->keys[2].name, out->keys[2].percent, out->bpm, out->bpm_exact);
        return BK_OK;
    } catch (const std::exception &e) {
        bk::fail("file", err, err_cap, "the clip could not be analyzed: %s", e.what());
        return BK_ERR_INTERNAL;
    }
}

int bk_analyze_midi(const uint8_t *data, size_t n, bk_reading *out, char *err, size_t err_cap) {
    if (err && err_cap) err[0] = 0;
    if (!out || (!data && n)) {
        bk::fail("midi", err, err_cap, "bk_analyze_midi was called without a file or without a place for the answer");
        return BK_ERR_BAD_ARG;
    }
    try {
        const bk::MidiAnalysis m = bk::analyze_midi(data, n);
        *out = bk_reading{};
        for (int i = 0; i < 3; i++) put_key(m.keys[i], out->keys[i]);
        out->has_bpm = 1;
        out->bpm = m.bpm;
        out->has_bpm_exact = 1;
        out->bpm_exact = m.bpm_exact;
        bk::logf("midi", "MIDI file, %zu notes: %s %.1f%% / %s %.1f%% / %s %.1f%%, bpm %.1f (%.2f)", m.notes,
                 out->keys[0].name, out->keys[0].percent, out->keys[1].name, out->keys[1].percent,
                 out->keys[2].name, out->keys[2].percent, out->bpm, out->bpm_exact);
        return BK_OK;
    } catch (const bk::Error &e) {
        bk::fail("midi", err, err_cap, "the MIDI file could not be read: %s", e.what());
        return BK_ERR_BAD_ARG;
    } catch (const std::exception &e) {
        bk::fail("midi", err, err_cap, "the MIDI file could not be analyzed: %s", e.what());
        return BK_ERR_INTERNAL;
    }
}

bk_analyzer *bk_analyzer_create(const bk_analyzer_config *cfg, char *err, size_t err_cap) {
    if (err && err_cap) err[0] = 0;
    if (!cfg) {
        bk::fail("live", err, err_cap, "bk_analyzer_create was called without a configuration");
        return nullptr;
    }
    if (!rate_ok(cfg->sample_rate)) {
        bk::fail("live", err, err_cap, "sample rate %.1f Hz is outside 8000..384000", cfg->sample_rate);
        return nullptr;
    }
    if (!bk::weights_ready()) {
        bk::fail("live", err, err_cap, "%s", kIncomplete);
        return nullptr;
    }
    try {
        std::shared_ptr<bk_analyzer> a = std::make_shared<bk_analyzer>(cfg->sample_rate, cfg->host, cfg->format);
        bk::worker_add(a);
        bk::logf(a->id.c_str(), "instance created: host %s, format %s, version %s, %.0f Hz", a->host.c_str(),
                 a->format.c_str(), BK_VERSION, a->rate);
        return a.get();                    // the worker's list keeps it alive until bk_analyzer_destroy
    } catch (const std::exception &e) {
        bk::fail("live", err, err_cap, "the analyzer could not be created: %s", e.what());
        return nullptr;
    }
}

void bk_analyzer_destroy(bk_analyzer *a) {
    if (!a) return;
    char id[16];
    snprintf(id, sizeof id, "%s", a->id.c_str());
    bk_snapshot last;
    bk_analyzer_snapshot(a, &last);
    bk::worker_remove(a);                  // `a` may be gone from here on
    bk::logf(id, "instance destroyed: %llu readings, %llu frames dropped", (unsigned long long)last.readings,
             (unsigned long long)last.dropped_frames);
}

size_t bk_analyzer_push(bk_analyzer *a, const float *mono, size_t frames) {
    if (!a || !mono) return 0;
    return a->ring.push(mono, frames);
}

size_t bk_analyzer_push_channels(bk_analyzer *a, const float *const *channels, int n_channels, size_t frames) {
    if (!a || !channels || n_channels < 1 || n_channels > 64) return 0;
    if (n_channels == 1) return a->ring.push(channels[0], frames);
    float block[512];
    const float inv = (float)n_channels;
    size_t done = 0, taken = 0;
    while (done < frames) {
        const size_t n = frames - done < 512 ? frames - done : 512;
        for (size_t i = 0; i < n; i++) {
            float sum = channels[0][done + i];
            for (int c = 1; c < n_channels; c++) sum += channels[c][done + i];
            block[i] = sum / inv;          // stereo: 0.5 * (L + R), MonoMixer's mix
        }
        taken += a->ring.push(block, n);
        done += n;
    }
    return taken;
}

void bk_analyzer_snapshot(const bk_analyzer *a, bk_snapshot *out) {
    if (!out) return;
    if (!a) {
        *out = bk_snapshot{};
        return;
    }
    for (;;) {
        const uint64_t before = a->seq.load(std::memory_order_acquire);
        if (before & 1) continue;          // the worker is mid-write (a few dozen nanoseconds)
        memcpy(out, &a->snap, sizeof *out);
        if (a->seq.load(std::memory_order_acquire) == before) break;
    }
    out->dropped_frames = a->ring.dropped();
}

int bk_analyzer_set_silence_gap(bk_analyzer *a, double seconds) {
    if (!a || !std::isfinite(seconds) || seconds < 1.0 || seconds > 30.0) {
        bk::logf(a ? a->id.c_str() : "live", "REFUSED: silence gap %.2f s is outside 1..30", seconds);
        return BK_ERR_BAD_ARG;
    }
    a->gap_request.store(seconds);
    return BK_OK;
}

void bk_analyzer_new_song(bk_analyzer *a) {
    if (a) a->new_song_request.store(true);
}

}  // extern "C"
