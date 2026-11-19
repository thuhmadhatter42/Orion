/*
 * hpcp.h: the key's front end = bpm.py hpcp_frames / hpcp_from_peaks, which are essentia's
 * KeyExtractor chain frame by frame (essentia commit 77a6a954, arithmetic in float as its Real is):
 *   frames     4096 samples, hop 4096, from sample 0; the last one zero-padded (FrameCutter,
 *              startFromZero = true): ceil(n / 4096) frames;
 *   window     hann, normalised (area 1, times 2), zero-phase; then |FFT| (Spectrum);
 *   peaks      SpectralPeaks: 25-3500 Hz, above 1e-4, parabolic interpolation, the 60 largest,
 *              largest first;
 *   whitening  SpectralWhitening(maxFrequency = 3500);
 *   HPCP       36 bins, 25-3500 Hz, 4 harmonics, cosine window of one semitone, no normalisation,
 *              bin 0 = A at the reference frequency.
 * One owner: files and live listening both come here.
 */
#ifndef BK_HPCP_H
#define BK_HPCP_H

#include <array>
#include <cstddef>
#include <vector>

namespace bk {

constexpr int kKeyRate = 44100, kKeyFrame = 4096, kHpcpSize = 36;

using HpcpFrame = std::array<float, kHpcpSize>;

// One frame's spectral peaks: what the tuning estimate and a rebuilt HPCP need.
struct Peaks {
    std::vector<float> freq, mag, white;       // same length, largest magnitude first
};

// audio at 44100 Hz -> one HPCP frame (A = 440) and one Peaks per 4096 samples.
void hpcp_frames(const float *audio_44k, size_t n, std::vector<HpcpFrame> &frames, std::vector<Peaks> &peaks);

// The same frames rebuilt from their peaks with A at `reference` Hz.
std::vector<HpcpFrame> hpcp_from_peaks(const std::vector<Peaks> &peaks, double reference);

}  // namespace bk

#endif
