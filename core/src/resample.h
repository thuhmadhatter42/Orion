/*
 * resample.h: the core's one resampler = essentia.standard.Resample as bpm.py calls it
 * (essentia src/algorithms/standard/resample.cpp, commit 77a6a954):
 *   - libsamplerate src_simple(), converter 1 = SRC_SINC_MEDIUM_QUALITY (Resample's default
 *     "quality"), one call for the whole array, a fresh converter every call;
 *   - ratio = (float)out_rate / (float)in_rate, a FLOAT division widened to double;
 *   - equal rates: the input comes back untouched; an empty input gives an empty output.
 * A live chunk is resampled on its own, exactly as LiveAnalyzer does it, edge effects included.
 */
#ifndef BK_RESAMPLE_H
#define BK_RESAMPLE_H

#include <cstddef>
#include <vector>

namespace bk {

// Throws bk::Error when libsamplerate refuses (it names the reason).
std::vector<float> resample(const float *in, size_t n, double in_rate, double out_rate);

}  // namespace bk

#endif
