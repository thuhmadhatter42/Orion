/*
 * midi.h: key and tempo of a Standard MIDI File = midi_analyze.py analyze_midi, same rules:
 *   key    note durations summed per pitch class (drums, channel 10, left out), scored against the
 *          same bgate profiles as audio (key.h), agreement over four equal slices of the piece;
 *          fewer than 4 pitched notes = NO_KEYS.  Key-signature meta events are ignored on purpose.
 *   tempo  the set-tempo event covering the most ticks; 120 BPM when the file has none.
 */
#ifndef BK_MIDI_H
#define BK_MIDI_H

#include <cstddef>
#include <cstdint>

#include "key.h"

namespace bk {

struct MidiAnalysis {
    KeyGuess keys[3];
    double bpm = 0.0;        // round(60e6 / us, 1)
    double bpm_exact = 0.0;  // round(60e6 / us, 2)
    size_t notes = 0;        // pitched notes found (for the log)
};

// Throws bk::Error with midi_analyze.py's MidiError sentence for a file that is not MIDI.
MidiAnalysis analyze_midi(const uint8_t *data, size_t n);

}  // namespace bk

#endif
