#include "fft.h"

#include <cmath>

#include "error.h"

namespace bk {

RealFFT::RealFFT(int size) : n_(size), log2n_(0), setup_(nullptr) {
    while ((1 << log2n_) < size) log2n_++;
    if (size < 8 || (1 << log2n_) != size) throw Error("FFT size " + std::to_string(size) + " is not a power of two >= 8");
    setup_ = vDSP_create_fftsetupD((vDSP_Length)log2n_, kFFTRadix2);
    if (!setup_) throw Error("vDSP_create_fftsetupD failed for size " + std::to_string(size) + " (out of memory)");
    ev_.resize((size_t)n_ / 2);
    od_.resize((size_t)n_ / 2);
    re_.resize((size_t)n_ / 2 + 1);
    im_.resize((size_t)n_ / 2 + 1);
}

RealFFT::~RealFFT() {
    if (setup_) vDSP_destroy_fftsetupD(setup_);
}

void RealFFT::forward(const float *in, double *re, double *im) {
    const int h = n_ / 2;
    for (int i = 0; i < h; i++) {
        ev_[(size_t)i] = (double)in[2 * i];
        od_[(size_t)i] = (double)in[2 * i + 1];
    }
    DSPDoubleSplitComplex sc = {ev_.data(), od_.data()};
    vDSP_fft_zripD(setup_, &sc, 1, (vDSP_Length)log2n_, kFFTDirection_Forward);
    // packed result, scaled by 2: ev[0] = DC, od[0] = the Nyquist bin, (ev[k], od[k]) = bin k
    re[0] = ev_[0] * 0.5;
    im[0] = 0.0;
    re[h] = od_[0] * 0.5;
    im[h] = 0.0;
    for (int k = 1; k < h; k++) {
        re[k] = ev_[(size_t)k] * 0.5;
        im[k] = od_[(size_t)k] * 0.5;
    }
}

void RealFFT::magnitude_f32(const float *in, float *mag) {
    forward(in, re_.data(), im_.data());
    for (int k = 0; k <= n_ / 2; k++) {
        const float r = (float)re_[(size_t)k], i = (float)im_[(size_t)k];
        mag[k] = std::sqrt(r * r + i * i);
    }
}

void RealFFT::magnitude_f64(const float *in, double *mag) {
    forward(in, re_.data(), im_.data());
    for (int k = 0; k <= n_ / 2; k++) mag[k] = std::hypot(re_[(size_t)k], im_[(size_t)k]);
}

}  // namespace bk
