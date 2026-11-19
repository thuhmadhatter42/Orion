#include "boundary.h"

#include <algorithm>
#include <cmath>

#include "hpcp.h"
#include "np.h"

namespace bk {

namespace {

constexpr int kNFft = 4096, kFHop = 1024;                  // 93 ms frames, 23 ms hop at 44.1 kHz
constexpr double kRefSecs = 8.0, kCurSecs = 3.0, kTick = 0.5, kSustain = 3.0, kDisappear = 0.35;
constexpr double kHarm = 0.6, kHarmGrid = 0.3, kPhaseTol = 0.15, kGridMin = 0.3, kLeak = 2.0;
const double kFps = (double)kKeyRate / kFHop;
const size_t kNCur = (size_t)(kCurSecs * kFps);            // 129 frames
const size_t kNRef = (size_t)(kRefSecs * kFps);            // 344 frames
const size_t kKeep = (size_t)((kRefSecs + kCurSecs) * kFps) + 2;

// np.exp(-2j * pi * f[:, None] * arange(n)[None, :]) for the 441 candidate tempos: one table per
// process, read-only once built.
struct PhasorTable {
    size_t n = 0, tempos = 0;
    std::vector<double> cos_, sin_;
    PhasorTable(const std::vector<double> &f) {
        n = (size_t)((kRefSecs + kCurSecs) * kFps) + 4;
        tempos = f.size();
        cos_.resize(tempos * n);
        sin_.resize(tempos * n);
        for (size_t b = 0; b < tempos; b++)
            for (size_t k = 0; k < n; k++) {
                const double a = (-2.0 * M_PI) * f[b] * (double)k;
                cos_[b * n + k] = std::cos(a);
                sin_[b * n + k] = std::sin(a);
            }
    }
};

std::vector<double> column(const std::deque<std::vector<double>> &rows, size_t from, size_t to, size_t col) {
    std::vector<double> v(to - from);
    for (size_t r = from; r < to; r++) v[r - from] = rows[r][col];
    return v;
}

}  // namespace

BoundaryDetector::BoundaryDetector() : fft_(kNFft), win_(np::hanning_f32(kNFft)) {
    // np.fft.rfftfreq(N_FFT, 1.0 / KEY_SR)
    const double val = 1.0 / (kNFft * (1.0 / kKeyRate));
    const size_t bins = kNFft / 2 + 1;
    bool in_spec = false;
    for (size_t k = 0; k < bins; k++) {
        const double f = (double)k * val;
        if (f <= 8000) flux_bins_ = k + 1;
        if (f >= 80 && f <= 4000) {
            if (!in_spec) { spec_lo_ = k; in_spec = true; }
            spec_n_++;
            int pc = -1;
            if (f >= 110 && f <= 3500) {
                const long r = std::lrint(std::nearbyint(12 * std::log2(f / 440.0))) + 9;
                pc = (int)(((r % 12) + 12) % 12);
            }
            tonal_.push_back(pc);
        }
    }
    // np.arange(70, 180 + 1e-9, 0.25) -> 441 tempos; cycles per frame
    const size_t n = (size_t)std::ceil((180.0 + 1e-9 - 70.0) / 0.25);
    for (size_t i = 0; i < n; i++) {
        bpms_.push_back(70.0 + (double)i * 0.25);
        f_.push_back(bpms_.back() / 60.0 / kFps);
    }
    reset();
}

void BoundaryDetector::reset() {
    tail_.clear();
    spec_.clear();
    flux_.clear();
    frame_i_ = 0;
    has_prev_ = false;
    since_tick_ = 0.0;
    held_ = 0.0;
    frozen_.reset();
}

void BoundaryDetector::frames(const float *x, size_t len) {
    tail_.insert(tail_.end(), x, x + len);
    const size_t n = tail_.size() < (size_t)kNFft ? 0 : 1 + (tail_.size() - kNFft) / kFHop;
    if (n == 0) return;
    const size_t bins = kNFft / 2 + 1;
    std::vector<float> frame((size_t)kNFft);
    std::vector<double> mag(bins), logm(flux_bins_), d(flux_bins_);
    for (size_t i = 0; i < n; i++) {
        const float *src = &tail_[i * kFHop];
        for (int j = 0; j < kNFft; j++) frame[(size_t)j] = src[j] * win_[(size_t)j];
        fft_.magnitude_f64(frame.data(), mag.data());
        std::vector<double> row(spec_n_);
        for (size_t b = 0; b < spec_n_; b++) row[b] = 20 * std::log10(mag[spec_lo_ + b] + 1e-5);
        spec_.push_back(std::move(row));
        for (size_t b = 0; b < flux_bins_; b++) logm[b] = std::log1p(100.0 * mag[b]);
        if (!has_prev_) { prev_ = logm; has_prev_ = true; }           // the first frame: flux 0
        for (size_t b = 0; b < flux_bins_; b++) {
            const double v = logm[b] - prev_[b];
            d[b] = v > 0 ? v : 0.0;
        }
        flux_.push_back(np::pairwise_sum(d.data(), flux_bins_));
        prev_ = logm;
    }
    tail_.erase(tail_.begin(), tail_.begin() + (long)(n * kFHop));
    frame_i_ += (long)n;
    while (spec_.size() > kKeep) spec_.pop_front();
    while (flux_.size() > kKeep) flux_.pop_front();
}

// Coherence (0..1) and phasor, per tempo, of the onset envelope o[from .. from + count) whose first
// frame is frame t0 since the reset (absolute time, so phases of different windows compare).
void BoundaryDetector::phasors(const std::vector<double> &o, size_t from, size_t count, long t0,
                               std::vector<double> &coherence, std::vector<std::complex<double>> &z) const {
    static const PhasorTable table(f_);
    const double *seg = o.data() + from;
    const double mean = np::pairwise_sum(seg, count) / (double)count;
    const double norm = std::max(np::pairwise_sum(seg, count), 1e-9);
    std::vector<double> om(count);
    for (size_t k = 0; k < count; k++) om[k] = seg[k] - mean;
    coherence.resize(f_.size());
    z.resize(f_.size());
    for (size_t b = 0; b < f_.size(); b++) {
        const double *c = &table.cos_[b * table.n], *s = &table.sin_[b * table.n];
        double re = 0, im = 0;
        for (size_t k = 0; k < count; k++) {
            re += c[k] * om[k];
            im += s[k] * om[k];
        }
        const double a = (-2.0 * M_PI) * f_[b] * (double)t0;
        z[b] = std::complex<double>(std::cos(a), std::sin(a)) * std::complex<double>(re, im);
        coherence[b] = std::abs(z[b]) / norm;
    }
}

// Chroma of spectrum rows [from, to): bincount of the pitch classes, weighted by RMS amplitude.
std::vector<double> BoundaryDetector::chroma(size_t from, size_t to) const {
    std::vector<double> out(12, 0.0);
    const double rows = (double)(to - from);
    for (size_t b = 0; b < spec_n_; b++) {
        if (tonal_[b] < 0) continue;
        double sum = 0;
        for (size_t r = from; r < to; r++) sum += std::pow(10.0, spec_[r][b] / 10);
        out[(size_t)tonal_[b]] += std::sqrt(sum / rows);
    }
    return out;
}

// What the reference window (the first `rows` spectrum rows) holds: its sustained spectrum, chroma, pulse.
std::shared_ptr<const BoundaryDetector::Ref> BoundaryDetector::ref_stats(size_t rows, const std::vector<double> &o, long t0) const {
    auto r = std::make_shared<Ref>();
    r->spec.resize(spec_n_);
    for (size_t b = 0; b < spec_n_; b++) r->spec[b] = np::percentile(column(spec_, 0, rows, b), 30);   // there throughout
    const std::vector<double> smooth = np::smooth15(r->spec);
    const double top = *std::max_element(r->spec.begin(), r->spec.end());
    r->weight.resize(spec_n_);
    for (size_t b = 0; b < spec_n_; b++) {
        const double prom = r->spec[b] - smooth[b];
        r->weight[b] = std::min(12.0, std::max(0.0, prom - 6)) * (r->spec[b] > top - 50 ? 1.0 : 0.0);
    }
    std::vector<double> c;
    std::vector<std::complex<double>> z;
    phasors(o, 0, rows, t0, c, z);
    size_t j = 0;
    for (size_t b = 1; b < c.size(); b++)
        if (c[b] > c[j]) j = b;
    r->chroma = chroma(0, rows);
    r->grid = c[j];
    r->j = j;
    r->z = z[j];
    return r;
}

// Scores for the windows buffered now; false while there is too little history.
bool BoundaryDetector::scores(Tick *out) {
    const size_t total = flux_.size();
    if (total < kNCur + (size_t)(0.75 * (double)kNRef)) return false;
    std::vector<double> o(flux_.begin(), flux_.end());
    const std::vector<double> local = np::smooth15(o);
    for (size_t i = 0; i < total; i++) o[i] = std::max(o[i] - local[i], 0.0);       // onsets above the local mean
    const size_t rows = total - kNCur;
    std::shared_ptr<const Ref> r = frozen_ ? frozen_ : ref_stats(rows, o, frame_i_ - (long)total);

    std::vector<double> cur(spec_n_);
    for (size_t b = 0; b < spec_n_; b++) cur[b] = np::percentile(column(spec_, rows, total, b), 50);
    const std::vector<double> smooth = np::smooth15(cur);
    std::vector<double> gone(spec_n_);
    for (size_t b = 0; b < spec_n_; b++) {
        const double prom = cur[b] - smooth[b];
        const bool g = prom < 2 && cur[b] < r->spec[b] + 3;                          // not a peak any more, not masked
        gone[b] = g ? r->weight[b] : 0.0;
    }
    const double disappeared = np::pairwise_sum(gone.data(), spec_n_) / std::max(np::pairwise_sum(r->weight.data(), spec_n_), 1e-9);
    const std::vector<double> ch = chroma(rows, total);
    const double harmonic = 1 - np::corrcoef(r->chroma.data(), ch.data(), 12);
    std::vector<double> c_cur;
    std::vector<std::complex<double>> z_cur;
    phasors(o, rows, kNCur, frame_i_ - (long)kNCur, c_cur, z_cur);
    const size_t j = r->j;
    const double dphase = std::arg(z_cur[j] * std::conj(r->z)) / (2 * M_PI);
    const double c_max = *std::max_element(c_cur.begin(), c_cur.end());
    Grid grid;
    if (r->grid < kGridMin || c_max < kGridMin) grid = Grid::None;
    else if (c_cur[j] < 0.5 * c_max) grid = Grid::Tempo;
    else if (std::abs(dphase) > kPhaseTol) grid = Grid::Phase;
    else grid = Grid::Same;

    out->scores.disappeared = np::py_round(disappeared, 3);
    out->scores.grid = grid;
    out->scores.harmonic = np::py_round(harmonic, 3);
    out->scores.bpm_ref = bpms_[j];
    out->scores.dphase = np::py_round(dphase, 3);
    out->scores.grid_ref = np::py_round(r->grid, 3);
    out->scores.grid_cur = np::py_round(c_max, 3);
    out->ref = r;
    return true;
}

bool BoundaryDetector::candidate(const BoundaryScores &s) const {
    if (s.disappeared < kDisappear) return false;
    if (s.grid == Grid::Phase || s.grid == Grid::Tempo) return s.harmonic >= kHarmGrid;
    return s.grid == Grid::None && s.harmonic >= kHarm;
}

bool BoundaryDetector::push(const float *x, size_t n, BoundaryScores *found) {
    frames(x, n);
    since_tick_ += (double)n / kKeyRate;
    bool declared = false;
    while (since_tick_ >= kTick) {
        since_tick_ -= kTick;
        Tick t;
        const bool have = scores(&t);
        if (have && candidate(t.scores)) {
            if (!frozen_) frozen_ = t.ref;
            held_ += kTick;
        } else {                                   // leaky: one odd tick doesn't wipe the evidence
            held_ = std::max(0.0, held_ - kLeak * kTick);
            if (held_ == 0.0) frozen_.reset();
        }
        if (held_ >= kSustain && !declared) {
            // bpm.py: `found = s` (None while there is too little history, which cannot hold 3 s of evidence)
            if (have) *found = t.scores;
            declared = have;
        }
    }
    return declared;
}

}  // namespace bk
