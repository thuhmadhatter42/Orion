/*
 * key.h: the key readout = bpm.py key_reading and everything under it (hpcp_to_pcp12, key_scores
 * against the bgate profiles, segment agreement, top3_with_confidence, estimate_tuning and the
 * retune rule).  One function for files and for live listening, as in bpm.py.
 */
#ifndef BK_KEY_H
#define BK_KEY_H

#include <array>
#include <string>
#include <vector>

#include "hpcp.h"

namespace bk {

struct KeyGuess {
    std::string name;            // Auto-Tune's spelling: "C", "F#", "Ebm"
    double percent = 0.0;        // rounded to 0.1 as bpm.py rounds it
};

struct KeyReading {
    KeyGuess keys[3];            // best first; NO_KEYS (C, Am, G at 0 %) when nothing tonal was heard
    bool has_tuning = false;     // false: under 50 % sure, or no peaks to measure
    double tuning_cents = 0.0;   // against A = 440, rounded to 0.1
    double chroma[12] = {0};     // C..B, 0..1, rounded to 0.001
    // --- what the parity runner compares layer by layer (not part of the readout) ---
    bool has_tuning_raw = false; // estimate_tuning before the 50 % gate
    double tuning_raw = 0.0;
    bool retuned = false;        // the HPCP was rebuilt at the track's own A
    float pcp12[12] = {0};       // the 12-bin profile the key came from, bin 0 = C
    double scores[24] = {0};     // correlation per key, index 2 * pitch class + (0 major, 1 minor)
    bool has_scores = false;
};

// frames: HPCP rows at A = 440; peaks: their spectral peaks (same count), or empty.
KeyReading key_reading(const std::vector<HpcpFrame> &frames, const std::vector<Peaks> &peaks);

// "C", "Db", ... / "Cm", "C#m", ...: index as in KeyReading::scores.
std::string key_name(int index);

}  // namespace bk

#endif
