/*
 * boundary.h: "a new song with no pause" = bpm.py BoundaryDetector, same numbers, same tuning.
 * Every 0.5 s it compares the last 3 s of audio with the 8 s before them:
 *   disappeared  share of the reference's sustained tonal peaks that are gone now
 *   grid         the reference's pulse continues ("same"), slipped ("phase"), or the audio pulses
 *                elsewhere ("tempo"); none when either side has no clear pulse
 *   harmonic     1 - correlation of the two windows' chroma
 * A candidate tick adds 0.5 s of evidence, any other tick drains it twice as fast; a boundary is
 * declared at 3 s.  While evidence builds the reference stays frozen at the moment it began.
 * Feed it non-silent mono audio at 44.1 kHz only.  Not thread-safe; one per LiveAnalyzer.
 */
#ifndef BK_BOUNDARY_H
#define BK_BOUNDARY_H

#include <complex>
#include <cstddef>
#include <deque>
#include <memory>
#include <vector>

#include "fft.h"

namespace bk {

enum class Grid { None, Same, Phase, Tempo };

struct BoundaryScores {            // rounded as bpm.py rounds them (3 decimals)
    double disappeared = 0, harmonic = 0, bpm_ref = 0, dphase = 0, grid_ref = 0, grid_cur = 0;
    Grid grid = Grid::None;
};

class BoundaryDetector {
public:
    BoundaryDetector();
    void reset();
    // Returns true when a boundary is declared by this push; *found then holds its scores.
    bool push(const float *x, size_t n, BoundaryScores *found);

private:
    struct Ref {                   // what the reference window holds
        std::vector<double> spec, weight, chroma;
        double grid = 0;
        size_t j = 0;
        std::complex<double> z;
    };
    struct Tick {
        BoundaryScores scores;
        std::shared_ptr<const Ref> ref;
    };

    void frames(const float *x, size_t n);
    bool scores(Tick *out);
    bool candidate(const BoundaryScores &s) const;
    void phasors(const std::vector<double> &o, size_t from, size_t count, long t0,
                 std::vector<double> &coherence, std::vector<std::complex<double>> &z) const;
    std::vector<double> chroma(size_t row_from, size_t row_to) const;
    std::shared_ptr<const Ref> ref_stats(size_t rows, const std::vector<double> &o, long t0) const;

    RealFFT fft_;
    std::vector<float> win_;
    size_t flux_bins_ = 0, spec_lo_ = 0, spec_n_ = 0;      // bins 0..flux_bins_-1; spec bins spec_lo_ .. +spec_n_
    std::vector<int> tonal_;                                // per spec bin: pitch class 0..11, or -1
    std::vector<double> bpms_, f_;                          // candidate tempos; cycles per frame

    std::vector<float> tail_;
    std::deque<std::vector<double>> spec_;                  // per frame: dB spectrum, 80 Hz - 4 kHz
    std::deque<double> flux_;                               // per frame: onset strength
    long frame_i_ = 0;
    std::vector<double> prev_;
    bool has_prev_ = false;
    double since_tick_ = 0.0, held_ = 0.0;
    std::shared_ptr<const Ref> frozen_;
};

}  // namespace bk

#endif
