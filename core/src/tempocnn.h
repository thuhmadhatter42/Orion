/*
 * tempocnn.h: TempoCNN (deeptemp-k16-3) = tempocnn_np.py, the numpy network the app ships.
 *   weights   models/deeptemp-k16-3.bkw, a flat binary made from the .npz by
 *             core/tools/make_weights.py.  A separate CC BY-NC-SA 4.0 data file, loaded at run
 *             time, never compiled in (plan L8).  One copy per process, read-only after load.
 *   patches   256 mel frames, hop 128, the last partial one dropped; per-patch z-score in float32
 *             with numpy's pairwise sums.
 *   network   12 x [conv 1xk over time (SAME) + bias -> ReLU -> BatchNorm], 2x2 max-pool after conv
 *             1/3/5/7/9, 1x2 (time) after conv 11, 1x1 conv to 256 + ReLU, mean, softmax.
 *   answer    class i = (30 + i) BPM per patch; the most-voted wins, ties go to the first seen.
 * The matrix products run on Accelerate's BLAS (sgemm).
 */
#ifndef BK_TEMPOCNN_H
#define BK_TEMPOCNN_H

#include <cstddef>
#include <vector>

namespace bk {

constexpr int kPatchFrames = 256, kPatchHop = 128, kTempoClasses = 256, kBpmOffset = 30;

// Process-wide weights.  load: BK_OK, or BK_ERR_BAD_WEIGHTS with the sentence in err (and the log).
int weights_load(const char *path, char *err, size_t err_cap);
bool weights_ready();

struct Tempo {
    double global_bpm = 0.0;           // 0.0 = no patch (clip under ~12 s), as essentia answers
    std::vector<int> classes;          // per patch, 0..255
    std::vector<float> pred;           // n_patches x 256 softmax rows
};

// tempocnn_np.tempo(audio_11k).  Throws bk::Error when the weights are not loaded.
Tempo tempo(const float *audio_11k, size_t n);

// The same from bands already computed (rows of 40); what tempo() does after mel_bands().
Tempo tempo_from_bands(const std::vector<float> &bands, size_t n_frames);

}  // namespace bk

#endif
