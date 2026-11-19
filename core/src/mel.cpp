#include "mel.h"

#include <cmath>
#include <ctime>
#include <random>

#include "fft.h"

namespace bk {

namespace {

constexpr int kFrame = 1024, kHop = 512, kBins = kFrame / 2 + 1;
constexpr float kSampleRate = (float)kTempoRate;

// essentiamath.h hz2melSlaney / mel2hzSlaney, in float as essentia's Real is
float hz2mel_slaney(float hz) {
    const float minLogHz = 1000.0f;
    const float linSlope = (float)(3 / 200.);
    if (hz < minLogHz) return hz * linSlope;
    const float minLogMel = minLogHz * linSlope;
    const float logStep = (float)(std::log(6.4) / 27.0);
    return minLogMel + std::log(hz / minLogHz) / logStep;
}

float mel2hz_slaney(float mel) {
    const float minLogHz = 1000.0f;
    const float linSlope = (float)(3 / 200.);
    const float minLogMel = minLogHz * linSlope;
    if (mel < minLogMel) return mel / linSlope;
    const float logStep = (float)(std::log(6.4) / 27.0);
    return minLogHz * std::exp((mel - minLogMel) * logStep);
}

// MelBands::calculateFilterFrequencies + TriangularBands::createFilters, for the fixed TempoCNN set-up
struct FilterBank {
    int begin[kMelBands], end[kMelBands];              // spectrum bins jbegin..jend, inclusive
    std::vector<float> coeff;                          // kMelBands x kBins

    FilterBank() : coeff((size_t)kMelBands * kBins, 0.0f) {
        float freqs[kMelBands + 2];
        const float low = hz2mel_slaney(20.0f), high = hz2mel_slaney(5000.0f);
        const float incr = (high - low) / (kMelBands + 1);
        float mel = low;
        for (int i = 0; i < kMelBands + 2; i++) {
            freqs[i] = mel2hz_slaney(mel);
            mel += incr;
        }
        const float scale = (float)((kSampleRate / 2.0) / (kBins - 1));
        for (int i = 0; i < kMelBands; i++) {
            const float fstep1 = freqs[i + 1] - freqs[i];
            const float fstep2 = freqs[i + 2] - freqs[i + 1];
            const int jbegin = (int)std::ceil(freqs[i] / scale);
            const int jend = (int)std::floor(freqs[i + 2] / scale);
            begin[i] = jbegin;
            end[i] = jend;
            float *c = &coeff[(size_t)i * kBins];
            for (int j = jbegin; j <= jend; j++) {
                const float binfreq = (float)j * scale;
                if (binfreq < freqs[i + 1]) c[j] = (binfreq - freqs[i]) / fstep1;
                else c[j] = (freqs[i + 2] - binfreq) / fstep2;
            }
            const float weight = (float)((fstep1 + fstep2) / 2.);      // "unit_tri"
            for (int j = jbegin; j <= jend; j++) c[j] = c[j] / weight;
        }
    }
};

const FilterBank &bank() {
    static const FilterBank b;
    return b;
}

// Windowing(type = hann, normalized = false), size 1024
const std::vector<float> &window() {
    static const std::vector<float> w = [] {
        std::vector<float> v((size_t)kFrame);
        for (int i = 0; i < kFrame; i++) v[(size_t)i] = (float)(0.5 - 0.5 * std::cos((2.0 * M_PI * i) / (kFrame - 1.0)));
        return v;
    }();
    return w;
}

}  // namespace

std::vector<float> mel_bands(const float *audio, size_t n, size_t *n_frames) {
    const size_t frames = n == 0 ? 0 : (n + kHop - 1) / kHop + 1;
    *n_frames = frames;
    std::vector<float> out(frames * kMelBands, 0.0f);
    if (frames == 0) return out;

    const FilterBank &fb = bank();
    const std::vector<float> &win = window();
    RealFFT fft(kFrame);
    std::mt19937 noise((unsigned)(time(nullptr) ^ clock()));       // NoiseAdder: seeded from the clock
    const float level = std::pow(10.0f, -100.0f / 10.0f);          // db2pow(-100)
    float frame[kFrame], windowed[kFrame], spectrum[kBins];

    for (size_t f = 0; f < frames; f++) {
        const long start = (long)f * kHop - kHop;
        for (int j = 0; j < kFrame; j++) {
            const long at = start + j;
            frame[j] = (at >= 0 && at < (long)n) ? audio[at] : 0.0f;
        }
        // isSilent: instantPower < 1e-10, summed in float in sample order
        float energy = 0.0f;
        for (int j = 0; j < kFrame; j++) energy += frame[j] * frame[j];
        if (energy / kFrame < 1e-10) {
            // FrameCutter's ADD_NOISE copies frame[0 .. acquired) to offset `zero-pad`; for the one
            // left-padded frame (the first) that moves its 512 padding zeros over its audio, so a
            // silent first frame is noise alone.  Kept: it is what the reference feeds the network.
            if (f == 0)
                for (int j = 0; j < kFrame; j++) frame[j] = 0.0f;
            for (int j = 0; j < kFrame; j++)
                frame[j] = frame[j] + level * ((float)noise() / (float)std::mt19937::max() * 2.0f - 1.0f);
        }
        // zero-phase: the second half of the windowed frame first
        int k = 0;
        for (int j = kFrame / 2; j < kFrame; j++) windowed[k++] = frame[j] * win[(size_t)j];
        for (int j = 0; j < kFrame / 2; j++) windowed[k++] = frame[j] * win[(size_t)j];
        fft.magnitude_f32(windowed, spectrum);

        float *bands = &out[f * kMelBands];
        for (int i = 0; i < kMelBands; i++) {
            const float *c = &fb.coeff[(size_t)i * kBins];
            float acc = 0.0f;
            for (int j = fb.begin[i]; j <= fb.end[i]; j++) acc += spectrum[j] * c[j];
            bands[i] = acc;
        }
    }
    return out;
}

}  // namespace bk
