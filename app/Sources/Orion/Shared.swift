// The app sees BeatKeyShared (Sources/BeatKeyShared: key names, tempo text, tuning maths, the
// Auto-Tune hand-off, the SEND BPM contract, Accent / CapWhite / PlateGrey) as if it were its own code,
// and so do the tests that import Orion. One line, so no file has to name the module.
@_exported import BeatKeyShared
