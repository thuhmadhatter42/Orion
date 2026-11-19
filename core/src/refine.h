/*
 * refine.h: the decimal BPM = bpm.py refine_bpm.  TempoCNN answers in whole BPM; this looks for
 * the tempo within +-1.5 of it that the onset envelope's periodicity (four harmonics) fits best,
 * in 0.01 steps.  The whole number comes back when there is too little audio, no onsets, or the
 * best fit sits on the edge of the search.
 */
#ifndef BK_REFINE_H
#define BK_REFINE_H

#include <cstddef>

namespace bk {

// audio at 11025 Hz; bpm: TempoCNN's answer (already rounded to 0.1 as bpm.py passes it).
double refine_bpm(const float *audio_11k, size_t n, double bpm);

}  // namespace bk

#endif
