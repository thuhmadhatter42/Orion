#include "hpcp.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include "fft.h"

namespace bk {

namespace {

constexpr int kBins = kKeyFrame / 2 + 1;              // 2049
constexpr float kSpectralRange = 22050.0f;            // sampleRate / 2

// essentiamath.h lin2db / db2lin (Real = float)
inline float lin2db(float v) { return v < 1e-10 ? -100.0f : 10.0f * std::log10(v); }
inline float db2lin(float v) { return std::pow(10.0f, v / 10.0f); }

// Windowing(type = hann, size = 4096): normalised to area 1, times 2
std::vector<float> make_window() {
    std::vector<float> w((size_t)kKeyFrame);
    for (int i = 0; i < kKeyFrame; i++) w[(size_t)i] = (float)(0.5 - 0.5 * std::cos((2.0 * M_PI * i) / (kKeyFrame - 1.0)));
    float sum = 0.0f;
    for (float v : w) sum += std::abs(v);
    const float scale = (float)(2.0 / sum);
    for (float &v : w) v *= scale;
    return w;
}

struct Peak {
    float position, magnitude;
};

// PeakDetection::interpolate
inline void interpolate(float left, float mid, float right, int bin, float &val, float &pos) {
    const float delta_x = (float)(0.5 * ((left - right) / (left - 2 * mid + right)));
    pos = (float)bin + delta_x;
    val = (float)(mid - 0.25 * (left - right) * delta_x);
}

// SpectralPeaks(orderBy = magnitude, magnitudeThreshold = 1e-4, minFrequency = 25, maxFrequency = 3500,
// maxPeaks = 60, sampleRate = 44100) = PeakDetection with interpolation over 0..22050 Hz
void spectral_peaks(const float *array, std::vector<float> &freq, std::vector<float> &mag) {
    const int size = kBins;
    const float minPos = 25.0f, maxPos = 3500.0f, threshold = 1e-4f;
    const size_t maxPeaks = 60;
    const float scale = kSpectralRange / (float)(size - 1);
    std::vector<Peak> peaks;
    peaks.reserve(512);

    int i = std::max(0, (int)std::ceil(minPos / scale));
    if (i + 1 < size && array[i] > array[i + 1]) {
        if (array[i] > threshold) peaks.push_back({(float)i * scale, array[i]});
    }
    while (true) {
        while (i + 1 < size - 1 && array[i] >= array[i + 1]) i++;      // going down
        while (i + 1 < size - 1 && array[i] < array[i + 1]) i++;       // climbing
        int j = i;
        while (j + 1 < size - 1 && array[j] == array[j + 1]) j++;      // plateau
        if (j + 1 < size - 1 && array[j + 1] < array[j] && array[j] > threshold) {
            float resultBin = 0.0f, resultVal = 0.0f;
            if (j != i) {
                resultBin = (float)((i + j) * 0.5);
                resultVal = array[i];
            } else {
                interpolate(array[j - 1], array[j], array[j + 1], j, resultVal, resultBin);
            }
            const float resultPos = resultBin * scale;
            if (resultPos > maxPos) break;
            peaks.push_back({resultPos, resultVal});
        }
        i = j;
        if (i + 1 >= size - 1) {                                       // the bin before the last one
            if (i == size - 2 && array[i - 1] < array[i] && array[i + 1] < array[i] && array[i] > threshold) {
                float resultBin = 0.0f, resultVal = 0.0f;
                interpolate(array[i - 1], array[i], array[i + 1], j, resultVal, resultBin);
                peaks.push_back({resultBin * scale, resultVal});
            }
            break;
        }
    }
    const float pos = maxPos / scale;
    if ((float)(size - 2) < pos && pos <= (float)(size - 1) && array[size - 1] > array[size - 2]) {
        if (array[size - 1] > threshold) peaks.push_back({(float)(size - 1) * scale, array[size - 1]});
    }
    // by magnitude, largest first; equal magnitudes by position, lowest first
    std::sort(peaks.begin(), peaks.end(), [](const Peak &a, const Peak &b) {
        if (a.magnitude > b.magnitude) return true;
        if (b.magnitude > a.magnitude) return false;
        return a.position < b.position;
    });
    const size_t n = std::min(maxPeaks, peaks.size());
    freq.resize(n);
    mag.resize(n);
    for (size_t k = 0; k < n; k++) {
        freq[k] = peaks[k].position;
        mag[k] = peaks[k].magnitude;
    }
}

// SpectralWhitening(maxFrequency = 3500, sampleRate = 44100)
void whiten(const float *spectrum, const std::vector<float> &freq, const std::vector<float> &mag, std::vector<float> &white) {
    const float maxFreq = (float)(3500.0f * 1.2);
    const float incr = 100.0f;                           // bpfResolution
    const int specSize = kBins;
    const int nPeaks = (int)mag.size();
    white.assign((size_t)nPeaks, 0.0f);
    if (nPeaks == 0) return;

    std::vector<float> dB((size_t)nPeaks);
    for (int i = 0; i < nPeaks; i++) dB[(size_t)i] = 2.0f * lin2db(mag[(size_t)i]);
    float maxAmp = -std::numeric_limits<float>::max();
    for (int i = 0; i < nPeaks; i++)
        if (freq[(size_t)i] <= maxFreq) maxAmp = std::max(maxAmp, dB[(size_t)i]);

    // the envelope, one point every 100 Hz
    std::vector<float> xs, ys;
    xs.reserve(64);
    ys.reserve(64);
    for (float f = 0.0f; f <= maxFreq && f <= kSpectralRange; f += incr) {
        const float bf = (float)(f - std::max(50.0, f * 0.34));
        const float ef = (float)(f + std::max(50.0, f * 0.58));
        int b = (int)(bf / kSpectralRange * (specSize - 1.0) + 0.5);
        int e = (int)(ef / kSpectralRange * (specSize - 1.0) + 0.5);
        b = std::max(b, 0);
        b = std::min(specSize - 1, b);
        e = std::max(e, b + 1);
        e = std::min(specSize, e);
        const float c = (float)(b / 2.0 + e / 2.0);
        const float halfwindowlength = (float)e - c;
        float n = 0.0f, wavg = 0.0f;
        for (int i = b; i < e; ++i) {
            float weight = (float)(1.0 - std::abs((float)i - c) / halfwindowlength);
            weight *= weight;
            weight *= weight;
            const float energy = spectrum[i] * spectrum[i];
            weight *= energy;
            wavg += energy * weight;
            n += weight;
        }
        if (n != 0.0) wavg /= n;
        xs.push_back(f);
        ys.push_back(wavg);
    }
    ys[ys.size() - 1] = ys[ys.size() - 2];
    for (float &y : ys) y = 2.0f * lin2db(std::sqrt(y));
    std::vector<float> slopes(xs.size() - 1);
    for (size_t j = 1; j < xs.size(); j++) slopes[j - 1] = (ys[j] - ys[j - 1]) / (xs[j] - xs[j - 1]);

    for (int i = 0; i < nPeaks; i++) {
        const float f = freq[(size_t)i], amp = dB[(size_t)i];
        float w;
        if (f > maxFreq - incr) {
            w = amp;
        } else {
            size_t j = 0;                                 // the break-point function at f
            while (f > xs[j + 1]) j += 1;
            const float ampEnv = (f - xs[j]) * slopes[j] + ys[j];
            if (amp > ampEnv) w = 0.0f;
            else if (amp > ampEnv - 30.0) w = amp - ampEnv;
            else w = -200.0f;
            w = (float)(w - 20.0 * f / 4000.0);
        }
        white[(size_t)i] = db2lin((float)(w / 2.0));
    }
}

// HPCP::initHarmonicContributionTable for harmonics = 4
struct Harmonic {
    float semitone, strength;
};

std::vector<Harmonic> harmonic_table() {
    const float precision = 0.00001f;
    std::vector<Harmonic> t;
    for (int i = 0; i <= 4; i++) {
        float semitone = (float)(12.0 * std::log2(i + 1.0));
        const float octweight = (float)std::max(1.0, (semitone / 12.0) * 0.5);
        while (semitone >= 12.0 - precision) semitone = (float)(semitone - 12.0);
        size_t at = 0;
        for (; at < t.size(); at++)
            if (t[at].semitone > semitone - precision && t[at].semitone < semitone + precision) break;
        if (at == t.size()) t.push_back({semitone, (float)(1.0 / octweight)});
        else t[at].strength = (float)(t[at].strength + (1.0 / octweight));
    }
    return t;
}

// HPCP(size = 36, harmonics = 4, 25-3500 Hz, weightType = cosine, windowSize = 1, normalized = none)
HpcpFrame hpcp(const std::vector<float> &freq, const std::vector<float> &mags, float reference) {
    static const std::vector<Harmonic> table = harmonic_table();
    const float windowSize = 1.0f, minFrequency = 25.0f, maxFrequency = 3500.0f;
    const int pcpSize = kHpcpSize;
    const float resolution = (float)(pcpSize / 12);
    HpcpFrame out;
    out.fill(0.0f);
    for (size_t p = 0; p < freq.size(); p++) {
        const float f0 = freq[p], mag_lin = mags[p];
        if (!(f0 >= minFrequency && f0 <= maxFrequency)) continue;
        for (const Harmonic &h : table) {
            const float f = (float)(f0 * std::pow(2., -h.semitone / 12.0));
            const float hw = h.strength;
            const float pcpBinF = std::log2(f / reference) * (float)pcpSize;
            const int leftBin = (int)std::ceil(pcpBinF - resolution * windowSize / 2.0);
            const int rightBin = (int)std::floor(pcpBinF + resolution * windowSize / 2.0);
            for (int i = leftBin; i <= rightBin; i++) {
                const float distance = std::abs(pcpBinF - (float)i) / resolution;
                const float normalizedDistance = distance / windowSize;
                const float weight = (float)std::cos(M_PI * normalizedDistance);
                int iw = i % pcpSize;
                if (iw < 0) iw += pcpSize;
                out[(size_t)iw] += weight * (mag_lin * mag_lin) * hw * hw;
            }
        }
    }
    return out;
}

struct FrontEnd {
    RealFFT fft{kKeyFrame};
    std::vector<float> window = make_window();
    std::vector<float> windowed = std::vector<float>((size_t)kKeyFrame);
    std::vector<float> spectrum = std::vector<float>((size_t)kBins);
};

}  // namespace

void hpcp_frames(const float *audio, size_t n, std::vector<HpcpFrame> &frames, std::vector<Peaks> &peaks) {
    thread_local FrontEnd fe;
    const size_t count = (n + kKeyFrame - 1) / kKeyFrame;
    float frame[kKeyFrame];
    for (size_t fi = 0; fi < count; fi++) {
        const size_t start = fi * kKeyFrame;
        const size_t have = std::min((size_t)kKeyFrame, n - start);
        for (size_t j = 0; j < have; j++) frame[j] = audio[start + j];
        for (size_t j = have; j < (size_t)kKeyFrame; j++) frame[j] = 0.0f;
        int k = 0;                                        // zero-phase windowing
        for (int j = kKeyFrame / 2; j < kKeyFrame; j++) fe.windowed[(size_t)k++] = frame[j] * fe.window[(size_t)j];
        for (int j = 0; j < kKeyFrame / 2; j++) fe.windowed[(size_t)k++] = frame[j] * fe.window[(size_t)j];
        fe.fft.magnitude_f32(fe.windowed.data(), fe.spectrum.data());
        Peaks pk;
        spectral_peaks(fe.spectrum.data(), pk.freq, pk.mag);
        whiten(fe.spectrum.data(), pk.freq, pk.mag, pk.white);
        frames.push_back(hpcp(pk.freq, pk.white, 440.0f));
        peaks.push_back(std::move(pk));
    }
}

std::vector<HpcpFrame> hpcp_from_peaks(const std::vector<Peaks> &peaks, double reference) {
    std::vector<HpcpFrame> out;
    out.reserve(peaks.size());
    const float ref = (float)reference;
    for (const Peaks &pk : peaks) out.push_back(hpcp(pk.freq, pk.white, ref));
    return out;
}

}  // namespace bk
