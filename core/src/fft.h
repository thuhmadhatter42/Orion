/*
 * fft.h: the core's one FFT (Accelerate vDSP, double precision, power-of-two sizes).
 * The reference uses FFTW single precision (essentia) and pocketfft double (numpy); a double FFT
 * sits within float rounding of both.  vDSP picks the right code path on arm64 and on an Intel
 * Mac without AVX2 by itself (plan A6).
 */
#ifndef BK_FFT_H
#define BK_FFT_H

#include <Accelerate/Accelerate.h>
#include <cstddef>
#include <vector>

namespace bk {

class RealFFT {
public:
    explicit RealFFT(int size);          // size: a power of two >= 8; anything else throws bk::Error
    ~RealFFT();
    RealFFT(const RealFFT &) = delete;
    RealFFT &operator=(const RealFFT &) = delete;

    int size() const { return n_; }
    int bins() const { return n_ / 2 + 1; }

    // in: size() samples.  re / im: bins() values each (im[0] = im[size/2] = 0).
    void forward(const float *in, double *re, double *im);
    // essentia Spectrum: |FFT| computed in float from the float-rounded real and imaginary parts.
    void magnitude_f32(const float *in, float *mag);
    // numpy np.abs(np.fft.rfft(x)): |FFT| in double.
    void magnitude_f64(const float *in, double *mag);

private:
    int n_, log2n_;
    FFTSetupD setup_;
    std::vector<double> ev_, od_, re_, im_;
};

}  // namespace bk

#endif
