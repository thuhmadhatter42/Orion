#include "refine.h"

#include <Accelerate/Accelerate.h>
#include <cmath>
#include <vector>

#include "fft.h"
#include "mel.h"
#include "np.h"

namespace bk {

double refine_bpm(const float *audio, size_t len, double bpm) {
    const int hop = 128, n_fft = 1024, bins = n_fft / 2 + 1;
    const double span = 1.5, step = 0.01, sr = kTempoRate;
    if (bpm <= 0 || len < (size_t)(n_fft + 8 * hop)) return bpm;

    // log-magnitude spectral flux, one value per hop (rectified, summed over the bins)
    const size_t n = 1 + (len - n_fft) / hop;
    const std::vector<float> win = np::hanning_f32(n_fft);
    RealFFT fft(n_fft);
    std::vector<float> frame((size_t)n_fft);
    std::vector<double> mag((size_t)bins), logm((size_t)bins), prev((size_t)bins), diff((size_t)bins);
    std::vector<double> flux(n - 1);
    for (size_t i = 0; i < n; i++) {
        const float *x = audio + i * hop;
        for (int j = 0; j < n_fft; j++) frame[(size_t)j] = x[j] * win[(size_t)j];
        fft.magnitude_f64(frame.data(), mag.data());
        for (int b = 0; b < bins; b++) logm[(size_t)b] = std::log1p(100.0 * mag[(size_t)b]);
        if (i > 0) {
            for (int b = 0; b < bins; b++) {
                const double d = logm[(size_t)b] - prev[(size_t)b];
                diff[(size_t)b] = d > 0 ? d : 0.0;
            }
            flux[i - 1] = np::pairwise_sum(diff.data(), (size_t)bins);
        }
        prev.swap(logm);
    }
    const double mean = np::mean(flux);
    std::vector<double> env(flux.size());
    bool any = false;
    for (size_t i = 0; i < flux.size(); i++) {
        env[i] = flux[i] - mean;
        any = any || env[i] != 0.0;
    }
    if (!any) return bpm;

    // candidates: bpm + np.arange(-span, span + step / 2, step), numpy's own fill rule
    const double a0 = -span, a1 = -span + step, delta = a1 - a0;
    const size_t n_cands = (size_t)std::ceil((span + step / 2 - (-span)) / step);
    const size_t m = env.size();
    const double fps = sr / hop;
    std::vector<double> t(m), arg(m), s(m), c(m);
    for (size_t i = 0; i < m; i++) t[i] = (double)i / fps;
    std::vector<double> cands(n_cands), score(n_cands, 0.0);
    const int mi = (int)m;
    for (size_t k = 0; k < n_cands; k++) {
        cands[k] = bpm + (k == 1 ? a1 : a0 + (double)k * delta);
        const double f = cands[k] / 60.0;
        for (int h = 1; h <= 4; h++) {
            const double w = (-2.0 * M_PI) * h * f;
            for (size_t i = 0; i < m; i++) arg[i] = w * t[i];
            vvsincos(s.data(), c.data(), arg.data(), &mi);
            double re = 0, im = 0;
            for (size_t i = 0; i < m; i++) {
                re += c[i] * env[i];
                im += s[i] * env[i];
            }
            score[k] += std::hypot(re, im);
        }
    }
    size_t best = 0;
    for (size_t k = 1; k < n_cands; k++)
        if (score[k] > score[best]) best = k;
    if (best == 0 || best == n_cands - 1) return bpm;
    return np::py_round(cands[best], 2);
}

}  // namespace bk
