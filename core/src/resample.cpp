#include "resample.h"

#include <samplerate.h>

#include "error.h"

namespace bk {

std::vector<float> resample(const float *in, size_t n, double in_rate, double out_rate) {
    const double factor = (double)((float)out_rate / (float)in_rate);
    if (factor == 1.0) return std::vector<float>(in, in + n);
    if (n == 0) return {};

    SRC_DATA src = {};
    src.input_frames = (long)n;
    src.data_in = in;
    src.output_frames = (long)((double)n * factor + 100.0);
    std::vector<float> out((size_t)src.output_frames);
    src.data_out = out.data();
    src.src_ratio = factor;
    const int error = src_simple(&src, SRC_SINC_MEDIUM_QUALITY, 1);
    if (error) throw Error(std::string("resample ") + std::to_string(in_rate) + " -> " + std::to_string(out_rate) +
                           " Hz failed: " + src_strerror(error));
    out.resize((size_t)src.output_frames_gen);
    return out;
}

}  // namespace bk
