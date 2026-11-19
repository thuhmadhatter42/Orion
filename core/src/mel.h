/*
 * mel.h: TempoCNN's input bands = tempocnn_np.mel_bands, which runs essentia's streaming
 * FrameCutter(1024, 512) into TensorflowInputTempoCNN (essentia commit 77a6a954):
 *   frames   frame i = samples [512 i - 512, 512 i + 512), zero-padded at both ends; n >= 1 samples
 *            give ceil(n / 512) + 1 frames, no samples give none (measured against essentia for
 *            23 lengths, 2026-11-19);
 *   silence  a frame whose mean power is under 1e-10 gets uniform noise of +-1e-10 added, from a
 *            Mersenne Twister seeded from the clock (NoiseAdder, fixSeed = false).  So a frame of
 *            digital silence is random in the reference too; the core does the same thing;
 *   window   hann, NOT normalised, zero-phase (the frame's halves swapped), then |FFT|;
 *   bands    40 triangular bands, 20-5000 Hz, slaney mel spacing, linear weighting, "unit_tri"
 *            normalisation, magnitude (not power), at 11025 Hz.
 */
#ifndef BK_MEL_H
#define BK_MEL_H

#include <cstddef>
#include <vector>

namespace bk {

constexpr int kMelBands = 40;
constexpr double kTempoRate = 11025.0;       // the rate TempoCNN and the decimal BPM read

// audio at 11025 Hz -> rows of 40 bands, row-major.  *n_frames receives the row count.
std::vector<float> mel_bands(const float *audio_11k, size_t n, size_t *n_frames);

}  // namespace bk

#endif
