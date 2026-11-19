/*
 * worker.h: the live half's plumbing (plan A4).
 *   bk_analyzer   one per plug-in instance: the ring the audio thread fills, the LiveAnalyzer the
 *                 worker runs, and the snapshot the face reads.
 *   Worker        ONE low-priority thread per process, serving every analyzer.  It starts with
 *                 the first analyzer and is joined when the last one is destroyed, so no thread of
 *                 ours outlives the plug-in's instances.  Every 20 ms it takes each whole 0.5 s
 *                 chunk out of each ring (what `bpm.py --stream` feeds LiveAnalyzer) and publishes
 *                 what the chunk caused.  Audio waits in the ring and nowhere else.
 *   snapshot      a seqlock: the worker is the only writer, readers never block and never lock.
 * Threads: push = audio thread (ring only).  snapshot = any thread.  create / destroy / new_song =
 * any non-audio thread.  Nothing here logs or allocates on the audio thread.
 */
#ifndef BK_WORKER_H
#define BK_WORKER_H

#include <atomic>
#include <chrono>
#include <memory>
#include <string>
#include <vector>

#include "beatkey.h"
#include "live.h"
#include "ring.h"

struct bk_analyzer {
    bk_analyzer(double rate, const char *host, const char *format);

    // fixed at create
    const double rate;
    const size_t chunk;                    // LiveAnalyzer::chunk_samples(rate)
    const std::string host, format, id;    // for the log

    bk::Ring ring;                         // audio thread -> worker
    std::atomic<bool> new_song_request{false};
    std::atomic<double> gap_request{0.0};  // bk_analyzer_set_silence_gap; 0 = nothing asked

    // the snapshot (seqlock: odd = being written)
    mutable std::atomic<uint64_t> seq{0};
    bk_snapshot snap{};

    // worker-only state
    bk::LiveAnalyzer live;
    std::vector<float> scratch;            // one chunk, popped whole from the ring
    bool failed = false;                   // an analysis error stopped this analyzer (logged once)
    uint64_t bad_chunks = 0, drops_logged = 0, bad_logged = 0;
    std::chrono::steady_clock::time_point last_drop_log{}, last_bad_log{};
};

namespace bk {

// Registers the analyzer and makes sure the worker runs.  Throws bk::Error when no thread can start.
void worker_add(const std::shared_ptr<bk_analyzer> &a);
// Unregisters it; joins the worker when it was the last one.  The analyzer is freed when the
// worker has let go of it (never while it is being served).
void worker_remove(bk_analyzer *a);

}  // namespace bk

#endif
