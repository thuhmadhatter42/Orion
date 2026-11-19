#include "key.h"

#include <algorithm>
#include <cmath>
#include <complex>

#include "log.h"
#include "np.h"

namespace bk {

namespace {

// Note names as Auto-Tune's Key menu spells them (bpm.py MAJOR_NOTES / MINOR_NOTES)
const char *const kMajor[12] = {"C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"};
const char *const kMinor[12] = {"C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"};

// Faraldo's 'bgate' profiles, index 0 = tonic (bpm.py BGATE; essentia key.cpp)
const double kBgateMajor[12] = {1.00, 0.00, 0.42, 0.00, 0.53, 0.37, 0.00, 0.77, 0.00, 0.38, 0.21, 0.30};
const double kBgateMinor[12] = {1.00, 0.00, 0.36, 0.39, 0.00, 0.38, 0.00, 0.74, 0.27, 0.00, 0.42, 0.23};

const float kPcpThreshold = 0.2f;        // PCP_THRESHOLD, compared in float32 as numpy does
const int kSegmentFrames = 107;          // int(SEGMENT_SECS * KEY_SR / HOP) = int(10 * 44100 / 4096)
const double kRetuneCents = 5.0;         // TUNING_RETUNE_CENTS
const double kTuningMinConf = 50.0;      // TUNING_MIN_CONF
const double kTuningMinHz = 200.0;       // TUNING_MIN_HZ

using Scores = KeyScores;

// H[a:b].mean(axis=0): float32, frame after frame (numpy reduces along axis 0 in row order)
HpcpFrame mean_frames(const std::vector<HpcpFrame> &H, size_t a, size_t b) {
    HpcpFrame sum;
    sum.fill(0.0f);
    for (size_t i = a; i < b; i++)
        for (int j = 0; j < kHpcpSize; j++) sum[(size_t)j] += H[i][(size_t)j];
    const float n = (float)(b - a);
    for (float &v : sum) v /= n;
    return sum;
}

// hpcp_to_pcp12: normalise, gate, detuning shift, fold 36 -> 12, rotate so bin 0 = C
std::array<float, 12> hpcp_to_pcp12(const HpcpFrame &avg) {
    float top = avg[0];
    for (float v : avg) top = std::max(top, v);
    const float div = (float)((double)top + 1e-12);
    float p[kHpcpSize];
    int peak = 0;
    for (int i = 0; i < kHpcpSize; i++) {
        p[i] = avg[(size_t)i] / div;
        if (p[i] < kPcpThreshold) p[i] = 0.0f;
    }
    for (int i = 1; i < kHpcpSize; i++)
        if (p[i] > p[peak]) peak = i;
    const int res = kHpcpSize / 12;
    const int i = peak % res;
    const int shift = i <= res / 2 ? -i : res - i;       // np.roll(p, shift)
    float r[kHpcpSize];
    for (int k = 0; k < kHpcpSize; k++) r[((k + shift) % kHpcpSize + kHpcpSize) % kHpcpSize] = p[k];
    std::array<float, 12> p12, out;
    for (int k = 0; k < 12; k++) {
        float s = 0.0f;
        for (int j = k * res - res / 2; j < k * res - res / 2 + res; j++) s += r[((j % kHpcpSize) + kHpcpSize) % kHpcpSize];
        p12[(size_t)k] = s;
    }
    for (int k = 0; k < 12; k++) out[(size_t)((k + 9) % 12)] = p12[(size_t)k];   // np.roll(p12, 9)
    return out;
}

// key_scores: Pearson r of the profile against all 24 keys, in the reference's own order:
// (0, major), (0, minor), (1, major), ...
template <typename T>
Scores key_scores(const T *pcp) {
    Scores s;
    double rolled[12];
    for (int i = 0; i < 12; i++) {
        for (int k = 0; k < 12; k++) rolled[(k + i) % 12] = kBgateMajor[k];
        s[(size_t)(2 * i)] = np::corrcoef(pcp, rolled, 12);
        for (int k = 0; k < 12; k++) rolled[(k + i) % 12] = kBgateMinor[k];
        s[(size_t)(2 * i + 1)] = np::corrcoef(pcp, rolled, 12);
    }
    return s;
}

int winner(const Scores &s) {             // max(scores, key=scores.get): the first of the largest
    int best = 0;
    for (int i = 1; i < 24; i++)
        if (s[(size_t)i] > s[(size_t)best]) best = i;
    return best;
}

// top3_with_confidence
void top3(const Scores &scores, double agree, KeyGuess out[3]) {
    int order[24];
    for (int i = 0; i < 24; i++) order[i] = i;
    std::stable_sort(order, order + 24, [&](int a, int b) { return -scores[(size_t)a] < -scores[(size_t)b]; });
    const double r1 = scores[(size_t)order[0]], r2 = scores[(size_t)order[1]];
    const double margin = (r1 - r2) / std::max(r1, 1e-6);
    double conf1 = 0.65 + 0.25 * agree + (margin >= 0.20 ? 0.08 : 0.0);
    if (order[0] % 2 == 0) conf1 = std::min(conf1, 0.85);           // majors capped
    if (r1 < 0.5 || agree < 0.4) conf1 = std::min(conf1, 0.40);
    // softmax_probs: softmax over the z-scored correlations
    std::vector<double> v(24), tmp(24);
    for (int i = 0; i < 24; i++) v[(size_t)i] = scores[(size_t)order[i]];
    const double mean = np::mean(v);
    for (int i = 0; i < 24; i++) {
        const double d = std::abs(v[(size_t)i] - mean);
        tmp[(size_t)i] = d * d;
    }
    const double sd = std::sqrt(np::mean(tmp));
    std::vector<double> p(24);
    for (int i = 0; i < 24; i++) p[(size_t)i] = std::exp(3.0 * ((v[(size_t)i] - mean) / (sd + 1e-9)));
    const double psum = np::pairwise_sum(p.data(), 24);
    for (double &x : p) x /= psum;
    const double rest = 1.0 - conf1;
    const double denom = std::max(1.0 - p[0], 1e-9);
    out[0].name = key_name(order[0]);
    out[0].percent = np::py_round(100 * conf1, 1);
    for (int i = 1; i <= 2; i++) {
        out[i].name = key_name(order[i]);
        out[i].percent = np::py_round(100 * rest * p[(size_t)i] / denom, 1);
    }
}

// estimate_tuning: the magnitude-weighted circular mean of every peak's distance from the 440 Hz
// semitone grid, peaks under 200 Hz left out.  false = nothing to measure.
bool estimate_tuning(const std::vector<Peaks> &peaks, double &cents_out) {
    std::complex<double> z(0.0, 0.0);
    bool any = false;
    for (const Peaks &pk : peaks) {
        for (size_t i = 0; i < pk.freq.size(); i++) {
            const double f = (double)pk.freq[i], m = (double)pk.mag[i];
            if (!(f >= kTuningMinHz && m > 0)) continue;
            any = true;
            const double dev = 1200 * std::log2(f / 440.0);
            const double a = 2 * M_PI * dev / 100;
            z += std::complex<double>(m * std::cos(a), m * std::sin(a));
        }
    }
    if (!any || std::abs(z) == 0) return false;
    const double cents = std::arg(z) / (2 * M_PI) * 100;
    if (!std::isfinite(cents)) {
        logf("key", "tuning skipped: the estimate is not a number");
        return false;
    }
    cents_out = np::py_round(cents, 1);
    return true;
}

}  // namespace

KeyScores key_scores_f64(const double pcp[12]) { return key_scores(pcp); }
int key_winner(const KeyScores &s) { return winner(s); }
void key_top3(const KeyScores &s, double agree, KeyGuess out[3]) { top3(s, agree, out); }

namespace {
// The 24 names, built once at load from kMajor / kMinor (never at first use: no guard lock, so the
// audio thread may read them through bk_key_name).
std::array<std::array<char, 4>, 24> make_names() {
    std::array<std::array<char, 4>, 24> t{};
    for (int i = 0; i < 24; i++) {
        const std::string n = i % 2 == 0 ? std::string(kMajor[i / 2]) : std::string(kMinor[i / 2]) + "m";
        for (size_t c = 0; c < n.size() && c < 3; c++) t[(size_t)i][c] = n[c];
    }
    return t;
}
const std::array<std::array<char, 4>, 24> kNames = make_names();
}  // namespace

const char *key_name_c(int index) { return index >= 0 && index < 24 ? kNames[(size_t)index].data() : nullptr; }

std::string key_name(int index) { return key_name_c(index); }

KeyReading key_reading(const std::vector<HpcpFrame> &frames_440, const std::vector<Peaks> &peaks) {
    KeyReading out;
    if (!peaks.empty()) out.has_tuning_raw = estimate_tuning(peaks, out.tuning_raw);

    // detune-robust: 5+ cents off, the HPCP is rebuilt with A at the track's own pitch
    const std::vector<HpcpFrame> *H = &frames_440;
    std::vector<HpcpFrame> rebuilt;
    if (out.has_tuning_raw && std::abs(out.tuning_raw) >= kRetuneCents && peaks.size() == frames_440.size()) {
        rebuilt = hpcp_from_peaks(peaks, 440.0 * std::pow(2.0, out.tuning_raw / 1200));
        H = &rebuilt;
        out.retuned = true;
    }

    // _keys_and_pcp
    float top = 0.0f;
    for (const HpcpFrame &f : *H)
        for (float v : f) top = std::max(top, v);
    if (H->empty() || top == 0.0f) {
        out.keys[0] = {"C", 0.0};                          // NO_KEYS
        out.keys[1] = {"Am", 0.0};
        out.keys[2] = {"G", 0.0};
    } else {
        const std::array<float, 12> pcp = hpcp_to_pcp12(mean_frames(*H, 0, H->size()));
        const Scores scores = key_scores(pcp.data());
        const int win = winner(scores);
        // agreement of the 10 s windows (a partial last window counts from half a window up)
        size_t wins = 0, count = 0;
        for (size_t i = 0; i < H->size(); i += (size_t)kSegmentFrames) {
            const size_t end = std::min(H->size(), i + (size_t)kSegmentFrames);
            if (end - i < (size_t)(kSegmentFrames / 2) && count > 0) break;
            const std::array<float, 12> seg = hpcp_to_pcp12(mean_frames(*H, i, end));
            const Scores s = key_scores(seg.data());
            wins += winner(s) == win;
            count++;
        }
        const double agree = count ? (double)wins / (double)count : 1.0;
        top3(scores, agree, out.keys);
        for (int i = 0; i < 12; i++) out.pcp12[i] = pcp[(size_t)i];
        for (int i = 0; i < 24; i++) out.scores[i] = scores[(size_t)i];
        out.has_scores = true;
    }

    float ptop = out.pcp12[0];
    for (float v : out.pcp12) ptop = std::max(ptop, v);
    for (int i = 0; i < 12; i++) out.chroma[i] = ptop > 0 ? np::py_round((double)(out.pcp12[i] / ptop), 3) : 0.0;
    out.has_tuning = out.has_tuning_raw && !(out.keys[0].percent < kTuningMinConf);
    out.tuning_cents = out.has_tuning ? out.tuning_raw : 0.0;
    return out;
}

}  // namespace bk
