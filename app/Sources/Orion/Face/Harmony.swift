import Foundation

// Advanced mode's music logic (docs/plans/orra-parity.md §2): the Camelot code, the chord strip
// (diatonic + borrowed chords, triads / 7ths / 9ths, four voicings), the MATCH TO transpose
// shift and the chord's MIDI clip. Pure, so it can be tested; the views are in HarmonyView.swift.

/// The DJ wheel's code: 1...12 round the circle of fifths, A = minor, B = major. C = 8B, Am = 8A.
enum Camelot {
    /// "8B" for C major, "5A" for C minor.
    static func code(pitchClass pc: Int, minor: Bool) -> String {
        // a minor key shares its relative major's number
        let majorPC = minor ? (pc + 3) % 12 : ((pc % 12) + 12) % 12
        let n = (majorPC * 7 % 12 + 7) % 12 + 1
        return "\(n)\(minor ? "A" : "B")"
    }

    /// The code for a key name as shown ("Ebm" → "2A"); nil = not a key name.
    static func code(_ key: String) -> String? {
        guard let k = KeyNames.parse(key) else { return nil }
        return code(pitchClass: k.pitchClass, minor: k.minor)
    }

    /// The relative key, spelled from the key's own letters: Ebm → "Gb", D#m → "F#", C → "Am".
    static func relative(_ key: String) -> String? {
        guard let s = Scale.of(key) else { return nil }
        // relative major = the minor scale's 3rd degree; relative minor = the major scale's 6th
        let degree = s.minor ? 2 : 5
        let pc = (s.tonic + (s.minor ? Scale.naturalMinor : Scale.major)[degree]) % 12
        let name = Scale.spell(pc, letter: s.tonicLetter + degree)
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        return name + (s.minor ? "" : "m")
    }
}

/// A key as the wheel holds it: pitch class 0...11 and major / minor.
struct WheelKey: Hashable {
    let pc: Int
    let minor: Bool
    init(_ pc: Int, minor: Bool) { self.pc = ((pc % 12) + 12) % 12; self.minor = minor }
}

/// The keys that fit a pick (J 2026-11-09, design pass): its two neighbours on the circle of
/// fifths (same ring, a fifth up and down: one note apart) and its relative (other ring, the same
/// seven notes). The key wheel outlines them faintly.
enum KeyFit {
    static func keys(_ k: WheelKey) -> Set<WheelKey> {
        let relative = k.minor ? WheelKey(k.pc + 3, minor: false) : WheelKey(k.pc + 9, minor: true)
        return [WheelKey(k.pc + 7, minor: k.minor), WheelKey(k.pc + 5, minor: k.minor), relative]
    }

    /// The fits for a key name as shown ("Cm"); empty = not a key name.
    static func keys(_ name: String) -> Set<WheelKey> {
        guard let c = KeyNames.parse(name) else { return [] }
        return keys(WheelKey(c.pitchClass, minor: c.minor))
    }
}


/// MATCH TO: how far to pitch the beat so its key lands on the project's key.
enum Transpose {
    /// Semitones (-5...+6) that move `from` onto `to`. A relative major / minor counts as a
    /// match: Cm onto Eb is 0. nil = a name that is not a key.
    static func shift(from: String, to: String) -> Int? {
        guard let a = KeyNames.parse(from), let b = KeyNames.parse(to) else { return nil }
        // compare in the target's mode: the detected key, or its relative
        var pc = a.pitchClass
        if a.minor != b.minor { pc = a.minor ? (pc + 3) % 12 : (pc + 9) % 12 }
        var s = ((b.pitchClass - pc) % 12 + 12) % 12
        if s > 6 { s -= 12 }
        return s
    }

    /// The row's cells.
    static let range = -6...6

    /// Whether the row's cell `cell` is the shift (a tritone lights both ends, -6 and +6).
    static func lit(_ cell: Int, shift: Int?) -> Bool {
        guard let s = shift else { return false }
        return ((cell - s) % 12 + 12) % 12 == 0
    }

    /// "+3", "−2", "0".
    static func label(_ n: Int) -> String { n > 0 ? "+\(n)" : n < 0 ? "−\(-n)" : "0" }
}

/// A chord as a MIDI clip: the reading's tempo, the chord held for 1, 2 or 4 bars of 4/4.
enum ChordClip {
    static let barChoices = [1, 2, 4]
    /// A click plays the chord this long at most, so a 4-bar slow chord does not drone.
    static let maxHearSeconds = 6.0
    static let velocity: UInt8 = MidiExport.defaultVelocity

    static func ticks(bars: Int) -> UInt32 { UInt32(max(1, bars) * 4) * UInt32(MidiExport.ticksPerQuarter) }

    /// The tempo the clip and the click use: the BPM on show (with its ×2 / ×0.5), else 120.
    static func bpm(_ r: Result?, factor: TempoFactor) -> Double {
        if let r, let v = Tempo.text(r, factor: factor).flatMap(Double.init), (1...1000).contains(v) { return v }
        return 120
    }

    /// How long a click sounds: the clip's length at `bpm`, at most maxHearSeconds.
    static func hearSeconds(bars: Int, bpm: Double) -> Double {
        min(maxHearSeconds, Double(max(1, bars) * 4) * 60 / max(1, bpm))
    }

    /// The .mid bytes (MidiExport's one writer): tempo, 4/4, the key, the chord held `bars`.
    static func data(_ chord: Chord, voicing: Voicing, bars: Int, bpm: Double, key: String?) -> Data {
        MidiExport.data(bpm: bpm, key: key, trackName: chord.asciiName,
                        notes: chord.notes(voicing), noteTicks: ticks(bars: bars), velocity: velocity)
    }

    /// "Cm7 root 2 bars 140 BPM.mid" (ASCII: every DAW takes it).
    static func fileName(_ chord: Chord, voicing: Voicing, bars: Int, bpm: Double) -> String {
        let b = bpm == bpm.rounded() ? String(Int(bpm)) : String(format: "%.2f", bpm)
        return "\(chord.asciiName) \(voicing.rawValue) \(bars) bar\(bars == 1 ? "" : "s") \(b) BPM.mid"
    }

    /// Where dragged clips are written (the system temp folder; macOS clears it).
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Beat Key Chords", isDirectory: true)
    }

    /// Writes the clip for a drag; nil (and a log line) when it could not be written.
    static func write(_ chord: Chord, voicing: Voicing, bars: Int, bpm: Double, key: String?,
                      in dir: URL = ChordClip.directory) -> URL? {
        let url = dir.appendingPathComponent(fileName(chord, voicing: voicing, bars: bars, bpm: bpm))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data(chord, voicing: voicing, bars: bars, bpm: bpm, key: key).write(to: url, options: .atomic)
            return url
        } catch {
            AppLog.log("chord clip: could not write \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}
