/*
 * live.h: key + BPM of a live signal = bpm.py LiveAnalyzer (Beat Key's Listen), same rules:
 *   - mono float32 arrives in chunks at the source's rate (the worker feeds 0.5 s at a time, as
 *     `bpm.py --stream` does); a rate other than 44.1 kHz is resampled chunk by chunk;
 *   - the last 12 s are kept for TempoCNN and the last 30 s of HPCP frames for the key;
 *   - a reading every 2 s of sound, once 4 s have been heard; a BPM once 12 s are buffered;
 *   - 3 s under -50 dB = a new song: one last reading, then everything is dropped ("reset")
 *     (bpm.py --gap: another length of silence may be given; 0 = 3 s);
 *   - a new song with no pause is found by BoundaryDetector, or announced by new_song().
 * It returns events, exactly the dicts bpm.py prints.  Not thread-safe: the worker owns it.
 */
#ifndef BK_LIVE_H
#define BK_LIVE_H

#include <cstddef>
#include <string>
#include <vector>

#include "boundary.h"
#include "hpcp.h"
#include "key.h"

namespace bk {

struct LiveReading {
    KeyGuess keys[3];              // percent: whole numbers (int(round(p)))
    bool has_tuning = false;
    double tuning_cents = 0.0;
    double chroma[12] = {0};
    bool has_bpm = false;
    double bpm = 0.0;              // TempoCNN's answer rounded to 0.1 (bpm.py prints it as "128.0")
    bool has_bpm_exact = false;
    double bpm_exact = 0.0;
    double secs = 0.0;             // seconds of sound behind it, rounded to 0.1
};

struct LiveEvent {
    enum Type { Reading, Reset, Boundary, Silence, Sound } type = Reading;
    LiveReading reading;           // Reading
    double db = 0.0;               // Silence, Sound: that chunk's RMS level, rounded to 0.1
    double after = 0.0;            // Sound: seconds of silence it ended, rounded to 0.1
    std::string reason;            // Boundary: "audio" or "title"
    bool has_scores = false;       // Boundary found in the audio
    BoundaryScores scores;
};

class LiveAnalyzer {
public:
    explicit LiveAnalyzer(double rate, double gap = 0.0);
    double gap() const { return gap_; }
    void set_gap(double seconds) { gap_ = seconds; }   // 1..30, checked by the caller
    // Feed mono float32 at `rate`; the events it causes are appended to `events`.
    void push(const float *chunk, size_t n, std::vector<LiveEvent> &events);
    // "New song, start over" (the player's title changed, or the user said so).
    void new_song(const std::string &reason, std::vector<LiveEvent> &events);
    // End of input: the last reading, if sound came in since the previous one.
    void finish(std::vector<LiveEvent> &events);

    // Samples per push when a stream is cut the way `bpm.py --stream` cuts it: 0.5 s at `rate`
    // (STREAM_CHUNK_SECS).  The worker and every test feed chunks of exactly this size.
    static size_t chunk_samples(double rate);

    static double level_db(const float *x, size_t n);
    double last_level_db() const { return last_db_; }

private:
    void clear();
    void feed(const float *x, size_t n, std::vector<LiveEvent> &events);
    bool reading(LiveEvent *out);

    double rate_;
    double gap_;                           // seconds of silence that mean a new song
    BoundaryDetector detector_;
    std::vector<float> audio_;             // last 12 s at 44.1 kHz (tempo)
    std::vector<float> carry_;             // samples not yet framed for HPCP
    std::vector<HpcpFrame> frames_;        // last 30 s of HPCP frames
    std::vector<Peaks> peaks_;             // their spectral peaks
    double heard_ = 0.0, since_reading_ = 0.0, silent_run_ = 0.0, last_db_ = -120.0;
};

}  // namespace bk

#endif
