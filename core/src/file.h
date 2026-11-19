/*
 * file.h: a whole clip = bpm.py analyze_full without the decoding.  Mono float32 at the clip's own
 * rate comes in; it is resampled to 44.1 kHz for the key and to 11.025 kHz for the tempo (each
 * straight from the original, as load_audio_essentia does), then key_reading, TempoCNN and the
 * decimal BPM run on the result.  The plug-in's AudioSuite pass and, later, the app's file drops
 * come here, so a clip gets one answer wherever it is analyzed.
 */
#ifndef BK_FILE_H
#define BK_FILE_H

#include <cstddef>
#include <vector>

#include "hpcp.h"
#include "key.h"
#include "tempocnn.h"

namespace bk {

struct FileAnalysis {
    KeyReading key;
    Tempo tempo;
    double bpm = 0.0;                 // round(global_bpm, 1)
    double bpm_exact = 0.0;           // refine_bpm
    // the layers, kept for the parity runner (plan A5: a port bug is found by layer)
    std::vector<float> a_key, a_bpm;  // the 44.1 kHz and 11.025 kHz signals (only when keep_audio)
    size_t n_key = 0, n_bpm = 0;
    std::vector<HpcpFrame> hpcp;      // at A = 440
    std::vector<Peaks> peaks;
    std::vector<float> bands;         // n_mel_frames x 40
    size_t n_mel_frames = 0;
};

// Throws bk::Error (weights not loaded, resampler refusal).  rate: validated by the caller.
FileAnalysis analyze_buffer(const float *mono, size_t n, double rate, bool keep_audio);

}  // namespace bk

#endif
