#include "file.h"

#include "log.h"
#include "mel.h"
#include "np.h"
#include "refine.h"
#include "resample.h"

namespace bk {

FileAnalysis analyze_buffer(const float *mono, size_t n, double rate, bool keep_audio) {
    FileAnalysis out;
    std::vector<float> a_key = resample(mono, n, rate, (double)kKeyRate);
    std::vector<float> a_bpm = resample(mono, n, rate, kTempoRate);
    out.n_key = a_key.size();
    out.n_bpm = a_bpm.size();

    hpcp_frames(a_key.data(), a_key.size(), out.hpcp, out.peaks);
    out.key = key_reading(out.hpcp, out.peaks);

    out.bands = mel_bands(a_bpm.data(), a_bpm.size(), &out.n_mel_frames);
    out.tempo = tempo_from_bands(out.bands, out.n_mel_frames);
    out.bpm = np::py_round(out.tempo.global_bpm, 1);
    out.bpm_exact = refine_bpm(a_bpm.data(), a_bpm.size(), out.bpm);

    if (keep_audio) {
        out.a_key = std::move(a_key);
        out.a_bpm = std::move(a_bpm);
    }
    return out;
}

}  // namespace bk
