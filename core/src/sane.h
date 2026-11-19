/*
 * sane.h: the one rule for "this sample is not audio": not a number, or more than 60 dB over full
 * scale.  A host (or a damaged clip) that hands such samples in is refused: the clip with
 * BK_ERR_BAD_ARG, a live half-second by being heard as silence, both with a log line.  Without the
 * rule a NaN would travel into the peak sort and the FFTs.
 */
#ifndef BK_SANE_H
#define BK_SANE_H

#include <cmath>
#include <cstddef>

namespace bk {

constexpr float kSampleLimit = 1000.0f;
constexpr size_t kAllAudio = (size_t)-1;

// Index of the first sample that is not audio, or kAllAudio.
inline size_t first_bad_sample(const float *x, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (!(std::fabs(x[i]) <= kSampleLimit)) return i;      // NaN fails the comparison too
    return kAllAudio;
}

}  // namespace bk

#endif
