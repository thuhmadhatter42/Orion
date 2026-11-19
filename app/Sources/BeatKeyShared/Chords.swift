import Foundation

// BeatKeyShared: the chord maths the app's Advanced mode and the plug-in's MIDI variant both use (moved
// here from the app's Harmony.swift / Pocket.swift for plug-in plan step 15, one copy): the scale and
// its speller, chord qualities and voicings, the chord strip (Harmony), and the MIDI variant's notes
// (KeyNotes). Pure: no app state, no host.

/// The notes of a key's scale for the 12-note keyboard: tonic pitch class (C = 0), the seven
/// pitch classes of the major / natural minor scale, and whether the key is spelled with sharps.
public struct Scale: Equatable {
    public let tonic: Int
    public let minor: Bool
    public let notes: Set<Int>
    public let sharps: Bool
    /// The tonic as the key is written ("E♭", "D♯"); the scale line spells from it.
    public let tonicName: String

    public static let major = [0, 2, 4, 5, 7, 9, 11]
    public static let naturalMinor = [0, 2, 3, 5, 7, 8, 10]
    public static let letters = Array("CDEFGAB")
    private static let letterPC = [0, 2, 4, 5, 7, 9, 11]

    /// Pitch class `pc` written on letter `letter` (0 = C ... 6 = B), with the accidentals that
    /// takes: pc 3 on E = "E♭", pc 6 on E = "E♯", pc 5 on G = "G♭♭". The one speller for scales,
    /// chord roots and relative keys.
    public static func spell(_ pc: Int, letter: Int) -> String {
        let li = ((letter % 7) + 7) % 7
        var diff = (((pc - letterPC[li]) % 12) + 12) % 12
        if diff > 6 { diff -= 12 }
        let acc = diff > 0 ? String(repeating: "♯", count: diff) : String(repeating: "♭", count: -diff)
        return String(letters[li]) + acc
    }

    /// The tonic's letter (0 = C ... 6 = B).
    public var tonicLetter: Int { tonicName.first.flatMap { Scale.letters.firstIndex(of: $0) } ?? 0 }

    /// "Ebm", "F#", "Bb" → its scale; nil = not a key name.
    public static func of(_ key: String) -> Scale? {
        guard let k = KeyNames.parse(key) else { return nil }
        let steps = k.minor ? naturalMinor : major
        let t = key.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        let root = t.hasSuffix("m") ? String(t.dropLast()) : t
        let sharps = root.contains("#") ? true : root.contains("b") ? false : k.sharps > 0
        return Scale(tonic: k.pitchClass, minor: k.minor,
                     notes: Set(steps.map { ($0 + k.pitchClass) % 12 }), sharps: sharps,
                     tonicName: root.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭"))
    }

    /// The name of pitch class `pc` as this key spells it (for the keyboard's black keys).
    public func name(_ pc: Int) -> String { KeyNames.pitchName(pc, sharps: sharps) }

    /// The scale's notes from the tonic up, one letter per degree, so the spelling is the written
    /// one: E♭ minor is E♭ F G♭ A♭ B♭ C♭ D♭, D♯ minor is D♯ E♯ F♯ G♯ A♯ B C♯ (double accidentals
    /// where the key needs them, as in G♯ major's F♯♯).
    public var spelled: [String] {
        let steps = minor ? Scale.naturalMinor : Scale.major
        return steps.enumerated().map { i, step in Scale.spell((tonic + step) % 12, letter: tonicLetter + i) }
    }
}

/// How many notes each chord stacks.
public enum ChordQuality: String, CaseIterable {
    case triad, seventh, ninth
    public var size: Int { self == .triad ? 3 : self == .seventh ? 4 : 5 }
    public var label: String { self == .triad ? "TRIAD" : self == .seventh ? "7TH" : "9TH" }
    public var spoken: String { self == .triad ? "triads" : self == .seventh ? "sevenths" : "ninths" }
}

/// Which chord tone is in the bass, or the open spread.
public enum Voicing: String, CaseIterable {
    case root, first, second, open
    public var label: String {
        switch self {
        case .root: return "ROOT"
        case .first: return "1ST"
        case .second: return "2ND"
        case .open: return "OPEN"
        }
    }
    public var spoken: String {
        switch self {
        case .root: return "root position"
        case .first: return "first inversion"
        case .second: return "second inversion"
        case .open: return "open voicing"
        }
    }
}

/// One chord of the strip.
public struct Chord: Equatable {
    /// The root's pitch class (C = 0).
    public let root: Int
    /// Semitones above the root, ascending (C maj7 = 0 4 7 11; a 9th is 13 or 14).
    public let intervals: [Int]
    /// "Cm7", "E♭maj7", "B♭7(♭9)".
    public let name: String
    /// "i", "♭VII", "ii°": the degree in the detected key.
    public let roman: String
    /// Borrowed from the parallel key (or the Neapolitan), not in the key's own scale.
    public let borrowed: Bool

    /// The bass octave's C: roots sit in C3...B3 (MIDI 48...59).
    public static let baseC = 48

    /// MIDI notes, low to high. Inversions lift the bottom tone an octave once (1st) or twice
    /// (2nd), so the 3rd or the 5th is in the bass; open lifts the 3rd an octave (C: C G E, the
    /// spread piano voicing).
    public func notes(_ v: Voicing) -> [Int] {
        var n = intervals.map { Chord.baseC + root + $0 }
        switch v {
        case .root: break
        case .first, .second:
            for _ in 0..<(v == .first ? 1 : 2) { n.append(n.removeFirst() + 12) }
        case .open:
            if n.count > 1 { n[1] += 12 }
        }
        return n.sorted()   // a ninth's lifted root lands among its upper tones
    }

    /// The chord name in plain ASCII ("Ebmaj7", "Bb7(b9)"), for file names.
    public var asciiName: String {
        name.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
    }
}

public enum Harmony {
    public static let phrygian = [0, 1, 3, 5, 7, 8, 10]
    private static let numerals = ["I", "II", "III", "IV", "V", "VI", "VII"]

    /// The seven chords built on the key's own scale, I to VII.
    public static func diatonic(_ key: String, quality: ChordQuality) -> [Chord] {
        guard let s = Scale.of(key) else { return [] }
        let steps = s.minor ? Scale.naturalMinor : Scale.major
        return (0..<7).map { chord(in: s, steps: steps, degree: $0, quality: quality, borrowed: false) }
    }

    /// The four colour chords borrowed from outside the key (plan §2.3, the choice documented):
    /// a major key takes ♭III, iv, ♭VI and ♭VII from its parallel minor (the four standard
    /// modal-mixture chords of pop and film writing). A minor key takes I (the Picardy third),
    /// IV and V from its parallel major (dorian IV, the harmonic-minor dominant), and ♭II, the
    /// Neapolitan (from Phrygian), the fourth colour chord minor-key writers reach for.
    public static func borrowed(_ key: String, quality: ChordQuality) -> [Chord] {
        guard let s = Scale.of(key) else { return [] }
        return borrowedPicks(minor: s.minor).map {
            chord(in: s, steps: $0.steps, degree: $0.degree, quality: quality, borrowed: true)
        }
    }

    private static func borrowedPicks(minor: Bool) -> [(steps: [Int], degree: Int)] {
        minor
            ? [(Scale.major, 0), (Scale.major, 3), (Scale.major, 4), (phrygian, 1)]
            : [(Scale.naturalMinor, 2), (Scale.naturalMinor, 3), (Scale.naturalMinor, 5), (Scale.naturalMinor, 6)]
    }

    /// The chord grid's second row (J 2026-11-09, design audit F10): seven columns like the
    /// diatonic row, each borrowed chord under the degree it stands in for (C minor: I under i,
    /// ♭II under ii°, IV under iv, V under v), the other columns empty (nil). Empty for no key.
    public static func borrowedRow(_ key: String, quality: ChordQuality) -> [Chord?] {
        guard let s = Scale.of(key) else { return [] }
        var row = [Chord?](repeating: nil, count: 7)
        for (c, pick) in zip(borrowed(key, quality: quality), borrowedPicks(minor: s.minor)) { row[pick.degree] = c }
        return row
    }

    /// The borrowed chords left to right as the grid shows them, with their column (0...6).
    public static func borrowedByColumn(_ key: String, quality: ChordQuality) -> [(column: Int, chord: Chord)] {
        borrowedRow(key, quality: quality).enumerated().compactMap { i, c in c.map { (i, $0) } }
    }

    /// The chord on `degree` of `steps` (a 7-note scale on the key's tonic), stacked in thirds
    /// within that scale: triad 1 3 5, seventh + 7, ninth + 9.
    public static func chord(in key: Scale, steps: [Int], degree: Int, quality: ChordQuality, borrowed: Bool) -> Chord {
        let intervals = (0..<quality.size).map { k -> Int in
            let i = degree + 2 * k
            return steps[i % 7] + 12 * (i / 7) - steps[degree]
        }
        let root = (key.tonic + steps[degree]) % 12
        let rootName = Scale.spell(root, letter: key.tonicLetter + degree)
        // the numeral's accidental against the key's own scale (diatonic chords have none)
        let own = key.minor ? Scale.naturalMinor : Scale.major
        var off = ((steps[degree] - own[degree]) % 12 + 12) % 12
        if off > 6 { off -= 12 }
        let acc = off < 0 ? "♭" : off > 0 ? "♯" : ""
        let third = intervals[1], fifth = intervals[2]
        var numeral = numerals[degree]
        if third == 3 { numeral = numeral.lowercased() }
        if third == 3 && fifth == 6 { numeral += "°" }
        if third == 4 && fifth == 8 { numeral += "+" }
        return Chord(root: root, intervals: intervals, name: rootName + suffix(intervals),
                     roman: acc + numeral, borrowed: borrowed)
    }

    /// The chord symbol after the root, from its intervals.
    public static func suffix(_ iv: [Int]) -> String {
        let third = iv[1], fifth = iv[2]
        let triad: String
        switch (third, fifth) {
        case (4, 7): triad = ""
        case (3, 7): triad = "m"
        case (3, 6): triad = "dim"
        case (4, 8): triad = "aug"
        default: triad = "?"
        }
        guard iv.count >= 4 else { return triad }
        let seventh: String
        switch (third, fifth, iv[3]) {
        case (4, 7, 11): seventh = "maj7"
        case (4, 7, 10): seventh = "7"
        case (3, 7, 10): seventh = "m7"
        case (3, 6, 10): seventh = "m7♭5"
        case (3, 6, 9): seventh = "dim7"
        case (3, 7, 11): seventh = "m(maj7)"
        case (4, 8, 11): seventh = "maj7♯5"
        case (4, 8, 10): seventh = "7♯5"
        default: seventh = triad + "7"
        }
        guard iv.count >= 5 else { return seventh }
        switch iv[4] {
        case 14:   // a major 9th: the 7 becomes a 9 (maj9, 9, m9, m9♭5)
            return seventh.replacingOccurrences(of: "7", with: "9")
        case 13:
            return seventh + "(♭9)"
        default:
            return seventh + "(♯9)"
        }
    }
}

/// The MIDI variant's notes (plug-in plan step 15, §Q2 default: "the key in use as notes, tonic triad,
/// held while a key is shown"): the chord Harmony builds on the key's first degree, root position, in
/// the strip's own octave (Chord.baseC), at the chord clips' velocity (MidiExport.defaultVelocity).
public enum KeyNotes {
    public static func triad(_ key: String) -> [Int] {
        Harmony.diatonic(key, quality: .triad).first?.notes(.root) ?? []
    }
    public static var velocity: UInt8 { MidiExport.defaultVelocity }
}
