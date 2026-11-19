#include "worker.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <pthread.h>
#include <thread>

#include "error.h"
#include "hpcp.h"
#include "log.h"
#include "sane.h"

namespace {

std::string make_id() {
    char b[16];
    snprintf(b, sizeof b, "%08x", (unsigned)arc4random());
    return b;
}

// The ring is the ONE place audio waits for the worker.  10 s (rounded up to a power of two: 11-12 s
// at the usual rates, 2 MB at 44.1 / 48 kHz) rides out a worker that is starved for a few seconds
// on a busy Mac; a 4 s ring lost audio to a 6 s stall in the soak (2026-11-19).
size_t ring_frames(double rate) { return (size_t)(rate * 10.0); }

// The worker's scheduling class.  UTILITY = the plan's "low priority": below the host's UI and far
// below its real-time audio threads.  Measured cost of that choice (soak, 2026-11-19): on a Mac whose
// load average was 20-30 (a Time Machine backup plus other builds) the worker was starved for up to
// 8.6 s at a time; readings came late, none were lost (the ring holds ~11 s).
#ifndef BK_WORKER_QOS
#define BK_WORKER_QOS QOS_CLASS_UTILITY
#endif

const auto kPoll = std::chrono::milliseconds(20);
const auto kLogEvery = std::chrono::seconds(60);

}  // namespace

bk_analyzer::bk_analyzer(double rate_, const char *host_, const char *format_)
    : rate(rate_),
      chunk(bk::LiveAnalyzer::chunk_samples(rate_)),
      host(host_ && host_[0] ? host_ : "-"),
      format(format_ && format_[0] ? format_ : "-"),
      id(make_id()),
      ring(ring_frames(rate_)),
      live(rate_) {
    scratch.resize(chunk);
    snap.level_db = -120.0;
}

namespace bk {

namespace {

std::mutex g_mu;                                   // guards the list and the thread handle
std::vector<std::shared_ptr<bk_analyzer>> g_list;
std::thread g_thread;                              // the running worker, if any
std::shared_ptr<std::atomic<bool>> g_stop;         // that worker's own stop flag (set under g_mu)

void publish(bk_analyzer &a, const bk_snapshot &next) {
    a.seq.fetch_add(1, std::memory_order_acq_rel);          // odd: readers retry
    a.snap = next;
    a.seq.fetch_add(1, std::memory_order_release);
}

void to_public(const LiveReading &r, bk_reading &out) {
    out = bk_reading{};
    for (int i = 0; i < 3; i++) {
        snprintf(out.keys[i].name, sizeof out.keys[i].name, "%s", r.keys[i].name.c_str());
        out.keys[i].percent = r.keys[i].percent;
    }
    out.has_tuning = r.has_tuning;
    out.tuning_cents = r.tuning_cents;
    for (int i = 0; i < 12; i++) out.chroma[i] = r.chroma[i];
    out.has_bpm = r.has_bpm;
    out.bpm = r.bpm;
    out.has_bpm_exact = r.has_bpm_exact;
    out.bpm_exact = r.bpm_exact;
    out.secs = r.secs;
}

void apply(bk_analyzer &a, const std::vector<LiveEvent> &events, bk_snapshot &s, double ms) {
    for (const LiveEvent &e : events) {
        switch (e.type) {
        case LiveEvent::Reading: {
            to_public(e.reading, s.reading);
            s.has_reading = 1;
            s.readings++;
            s.reading_song = s.song;
            s.last_reading_ms = ms;
            const LiveReading &r = e.reading;
            char bpm[64] = "bpm -", tune[32] = "tuning -";
            if (r.has_bpm) snprintf(bpm, sizeof bpm, "bpm %.1f (%.2f)", r.bpm, r.bpm_exact);
            if (r.has_tuning) snprintf(tune, sizeof tune, "tuning %+.1f", r.tuning_cents);
            logf(a.id.c_str(), "reading: %s %.0f%% / %s %.0f%% / %s %.0f%%, %s, %s, %.1f s heard, %.1f ms",
                 r.keys[0].name.c_str(), r.keys[0].percent, r.keys[1].name.c_str(), r.keys[1].percent,
                 r.keys[2].name.c_str(), r.keys[2].percent, bpm, tune, r.secs, ms);
            break;
        }
        case LiveEvent::Reset:
            s.song++;
            s.song_why = BK_SONG_SILENCE;
            logf(a.id.c_str(), "new song: %g s of silence, everything heard was dropped", a.live.gap());
            break;
        case LiveEvent::Boundary:
            s.song++;
            s.song_why = e.reason == "audio" ? BK_SONG_AUDIO : BK_SONG_ANNOUNCED;
            if (e.has_scores)
                logf(a.id.c_str(), "new song: found in the audio (disappeared %.3f, harmonic %.3f, pulse %.2f BPM)",
                     e.scores.disappeared, e.scores.harmonic, e.scores.bpm_ref);
            else
                logf(a.id.c_str(), "new song: announced (%s)", e.reason.c_str());
            break;
        case LiveEvent::Silence:
            s.silent = 1;
            s.silence_db = e.db;
            logf(a.id.c_str(), "silence: %g s under -50 dB (%.1f dB)", a.live.gap(), e.db);
            break;
        case LiveEvent::Sound:
            s.silent = 0;
            s.sound_after = e.after;
            logf(a.id.c_str(), "sound again at %.1f dB after %.1f s of silence", e.db, e.after);
            break;
        }
    }
}

// One visit to one analyzer: ONE whole half-second from its ring goes through LiveAnalyzer and what
// it caused is published.  One chunk a visit, so analyzers take turns and a backlog (the worker was
// starved for a while) is worked off in order, each reading shown as it is made.
// Returns true when it had a chunk to work on (the worker then comes straight back).
bool serve(bk_analyzer &a) {
    const auto now = std::chrono::steady_clock::now();
    const uint64_t dropped = a.ring.dropped();
    if (dropped > a.drops_logged && (a.drops_logged == 0 || now - a.last_drop_log >= kLogEvery)) {
        logf(a.id.c_str(), "ring full: %llu frames dropped so far (the worker fell behind, or an offline bounce ran faster than real time)",
             (unsigned long long)dropped);
        a.drops_logged = dropped;
        a.last_drop_log = now;
    }
    if (a.failed) {                          // keep the ring from filling; nothing is analyzed any more
        bool got = false;
        while (a.ring.pop(a.scratch.data(), a.scratch.size())) got = true;
        return got;
    }

    bk_snapshot s = a.snap;                 // the worker is the only writer: a plain read is safe here
    bool changed = false, worked = false;
    std::vector<LiveEvent> events;
    try {
        const double gap = a.gap_request.exchange(0.0);
        if (gap > 0 && gap != a.live.gap()) {
            a.live.set_gap(gap);
            logf(a.id.c_str(), "a new song after %g s of silence from now on", gap);
        }
        if (a.new_song_request.exchange(false)) {
            a.live.new_song("title", events);
            apply(a, events, s, 0.0);
            events.clear();
            changed = true;
        }
        // a chunk leaves the ring only whole, so the ring alone holds whatever is waiting
        float *x = a.scratch.data();
        if (a.ring.available() >= a.chunk) {
            a.ring.pop(x, a.chunk);
            worked = true;
            if (first_bad_sample(x, a.chunk) != kAllAudio) {
                // a refused chunk is heard as silence; counted and said in the log, never passed on
                std::fill(x, x + a.chunk, 0.0f);
                a.bad_chunks++;
                s.refused_chunks = a.bad_chunks;
                if (a.bad_logged == 0 || now - a.last_bad_log >= kLogEvery) {
                    logf(a.id.c_str(), "REFUSED: the host sent samples that are not audio (not a number, or over +60 dB); %llu half-second chunks treated as silence so far",
                         (unsigned long long)a.bad_chunks);
                    a.bad_logged = a.bad_chunks;
                    a.last_bad_log = now;
                }
            }
            const auto t0 = std::chrono::steady_clock::now();
            a.live.push(x, a.chunk, events);
            const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
            apply(a, events, s, ms);
            events.clear();
            s.level_db = a.live.last_level_db();
            changed = true;
        }
    } catch (const std::exception &e) {
        a.failed = true;
        s.error = 1;
        changed = true;
        logf(a.id.c_str(), "REFUSED: analysis stopped for this instance after an error: %s", e.what());
    }
    if (changed) {
        s.seq = a.snap.seq + 1;
        publish(a, s);
    }
    return worked;
}

void run(std::shared_ptr<std::atomic<bool>> stop) {
    pthread_setname_np("Beat Key analysis");
    pthread_set_qos_class_self_np(BK_WORKER_QOS, 0);
    for (;;) {
        std::vector<std::shared_ptr<bk_analyzer>> list;
        {
            std::lock_guard<std::mutex> lock(g_mu);
            if (stop->load()) return;              // set under g_mu: this worker never sees a later list
            list = g_list;
        }
        bool worked = false;
        for (const auto &a : list) worked = serve(*a) || worked;
        if (!worked) std::this_thread::sleep_for(kPoll);
    }
}

}  // namespace

void worker_add(const std::shared_ptr<bk_analyzer> &a) {
    std::lock_guard<std::mutex> lock(g_mu);
    g_list.push_back(a);
    if (g_thread.joinable()) return;
    try {
        g_stop = std::make_shared<std::atomic<bool>>(false);
        g_thread = std::thread(run, g_stop);
    } catch (const std::exception &e) {
        g_list.pop_back();
        throw Error(std::string("the analysis thread could not start: ") + e.what());
    }
}

void worker_remove(bk_analyzer *a) {
    std::thread last;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        g_list.erase(std::remove_if(g_list.begin(), g_list.end(),
                                    [a](const std::shared_ptr<bk_analyzer> &p) { return p.get() == a; }),
                     g_list.end());
        if (g_list.empty() && g_thread.joinable()) {
            g_stop->store(true);
            last = std::move(g_thread);            // a later worker_add starts a fresh worker
        }
    }
    if (last.joinable()) last.join();              // no thread of ours outlives the last instance
}

}  // namespace bk
