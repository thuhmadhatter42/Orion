#include "live.h"

#include <algorithm>
#include <cmath>

#include "mel.h"
#include "np.h"
#include "refine.h"
#include "resample.h"
#include "tempocnn.h"

namespace bk {

namespace {

constexpr double kMinKeySecs = 4.0;      // STREAM_MIN_KEY_SECS
constexpr double kTempoSecs = 12.0;      // STREAM_TEMPO_SECS (also the tempo window)
constexpr double kHopSecs = 2.0, kGapSecs = 3.0, kKeyWindowSecs = 30.0, kSilenceDb = -50.0, kKeepAfterSecs = 2.0;
const size_t kTempoSamples = (size_t)(kTempoSecs * kKeyRate);                 // 529200
const size_t kFrameLimit = (size_t)(kKeyWindowSecs * kKeyRate / kKeyFrame);   // 322

}  // namespace

LiveAnalyzer::LiveAnalyzer(double rate, double gap) : rate_(rate), gap_(gap > 0 ? gap : kGapSecs) { clear(); }

void LiveAnalyzer::clear() {
    audio_.clear();
    carry_.clear();
    frames_.clear();
    peaks_.clear();
    heard_ = 0.0;
    since_reading_ = 0.0;
    detector_.reset();
}

size_t LiveAnalyzer::chunk_samples(double rate) { return std::max<size_t>(1, (size_t)(rate * 0.5)); }

double LiveAnalyzer::level_db(const float *x, size_t n) {
    if (n == 0) return -120.0;
    std::vector<double> sq(n);
    for (size_t i = 0; i < n; i++) sq[i] = (double)x[i] * (double)x[i];
    const double rms = std::sqrt(np::pairwise_sum(sq.data(), n) / (double)n);
    return 20 * std::log10(std::max(rms, 1e-6));
}

void LiveAnalyzer::push(const float *chunk, size_t n, std::vector<LiveEvent> &events) {
    std::vector<float> resampled;
    const float *x = chunk;
    if (rate_ != (double)kKeyRate && n) {
        resampled = resample(chunk, n, rate_, (double)kKeyRate);
        x = resampled.data();
        n = resampled.size();
    }
    const double secs = (double)n / kKeyRate;
    const double db = level_db(x, n);
    last_db_ = db;
    if (db < kSilenceDb) {
        const double was = silent_run_;
        silent_run_ += secs;
        if (was < gap_ && gap_ <= silent_run_) {
            LiveEvent e;
            e.type = LiveEvent::Silence;
            e.db = np::py_round(db, 1);
            events.push_back(e);
        }
        if (silent_run_ >= gap_ && heard_ > 0) {
            if (since_reading_ > 0) {             // a song's final word is never lost
                LiveEvent r;
                if (reading(&r)) events.push_back(r);
            }
            clear();
            LiveEvent e;
            e.type = LiveEvent::Reset;
            events.push_back(e);
        }
        return;
    }
    if (silent_run_ >= gap_) {
        LiveEvent e;
        e.type = LiveEvent::Sound;
        e.db = np::py_round(db, 1);
        e.after = np::py_round(silent_run_, 1);
        events.push_back(e);
    }
    silent_run_ = 0.0;
    BoundaryScores found;
    if (detector_.push(x, n, &found)) {
        // a new song with no pause: drop the old one, rebuild from the new one's first seconds
        std::vector<float> tail(audio_);
        tail.insert(tail.end(), x, x + n);
        const size_t keep = (size_t)(kKeepAfterSecs * kKeyRate);
        if (tail.size() > keep) tail.erase(tail.begin(), tail.end() - (long)keep);
        clear();
        LiveEvent e;
        e.type = LiveEvent::Boundary;
        e.reason = "audio";
        e.has_scores = true;
        e.scores = found;
        events.push_back(e);
        feed(tail.data(), tail.size(), events);
        return;
    }
    feed(x, n, events);
}

void LiveAnalyzer::new_song(const std::string &reason, std::vector<LiveEvent> &events) {
    clear();
    LiveEvent e;
    e.type = LiveEvent::Boundary;
    e.reason = reason;
    events.push_back(e);
}

// Non-silent 44.1 kHz audio into the tempo / key buffers; a reading every 2 s.
void LiveAnalyzer::feed(const float *x, size_t n, std::vector<LiveEvent> &events) {
    const double secs = (double)n / kKeyRate;
    heard_ += secs;
    since_reading_ += secs;
    audio_.insert(audio_.end(), x, x + n);
    if (audio_.size() > kTempoSamples) audio_.erase(audio_.begin(), audio_.end() - (long)kTempoSamples);
    carry_.insert(carry_.end(), x, x + n);
    const size_t whole = (carry_.size() / kKeyFrame) * kKeyFrame;
    if (whole) {
        hpcp_frames(carry_.data(), whole, frames_, peaks_);
        const size_t limit = std::max<size_t>(1, kFrameLimit);
        if (frames_.size() > limit) {
            const long cut = (long)(frames_.size() - limit);
            frames_.erase(frames_.begin(), frames_.begin() + cut);
            peaks_.erase(peaks_.begin(), peaks_.begin() + cut);
        }
        carry_.erase(carry_.begin(), carry_.begin() + (long)whole);
    }
    if (since_reading_ >= kHopSecs) {
        LiveEvent r;
        if (reading(&r)) events.push_back(r);
    }
}

// The reading for what is buffered now; false while there is too little to say.
bool LiveAnalyzer::reading(LiveEvent *out) {
    if (heard_ < kMinKeySecs || frames_.empty()) return false;
    since_reading_ = 0.0;
    const KeyReading k = key_reading(frames_, peaks_);
    out->type = LiveEvent::Reading;
    LiveReading &r = out->reading;
    for (int i = 0; i < 3; i++) {
        r.keys[i].name = k.keys[i].name;
        r.keys[i].percent = (double)np::py_round_int(k.keys[i].percent);
    }
    r.secs = np::py_round(heard_, 1);
    r.has_tuning = k.has_tuning;
    r.tuning_cents = k.tuning_cents;
    for (int i = 0; i < 12; i++) r.chroma[i] = k.chroma[i];
    if (audio_.size() >= kTempoSamples) {
        const std::vector<float> a11 = resample(audio_.data(), audio_.size(), (double)kKeyRate, kTempoRate);
        r.bpm = np::py_round(tempo(a11.data(), a11.size()).global_bpm, 1);
        r.has_bpm = true;
        r.bpm_exact = refine_bpm(a11.data(), a11.size(), r.bpm);
        r.has_bpm_exact = true;
    }
    return true;
}

void LiveAnalyzer::finish(std::vector<LiveEvent> &events) {
    if (since_reading_ > 0) {
        LiveEvent r;
        if (reading(&r)) events.push_back(r);
    }
}

}  // namespace bk
