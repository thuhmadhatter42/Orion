import Combine
import Foundation

/// THE key-name table and parser: every other file asks here. Auto-Tune's spelling is the rule
/// (J 2026-11-09): major C Db D Eb E F F# G Ab A Bb B, minor C C# D Eb E F F# G G# A Bb B.
enum KeyNames {
    /// Key names as DAWs print them, preferred (Auto-Tune) spelling first.
    static let major = [["C"], ["Db", "C#"], ["D"], ["Eb", "D#"], ["E"], ["F"], ["F#", "Gb"], ["G"], ["Ab", "G#"], ["A"], ["Bb", "A#"], ["B", "Cb"]]
    static let minor = [["C"], ["C#", "Db"], ["D"], ["Eb", "D#"], ["E"], ["F"], ["F#", "Gb"], ["G"], ["G#", "Ab"], ["A"], ["Bb", "A#"], ["B"]]

    static func roots(_ pc: Int, minor m: Bool) -> [String] { (m ? minor : major)[((pc % 12) + 12) % 12] }

    /// "Eb minor", "D# minor", plus the short forms some menus use ("Ebm", "Eb min").
    static func names(_ pc: Int, minor m: Bool) -> [String] {
        let r = roots(pc, minor: m)
        return r.map { "\($0) \(m ? "minor" : "major")" } + r.map { m ? "\($0) min" : "\($0) maj" } + r.map { m ? "\($0)m" : $0 }
    }

    /// Unicode-accidental spellings (Logic prints ♭/♯); AXText.norm folds them, kept for clarity.
    static func pretty(_ s: String) -> String { s.replacingOccurrences(of: "b", with: "♭").replacingOccurrences(of: "#", with: "♯") }

    /// Pitch class `pc` as one note name with ♯/♭ ("C♯" or "D♭"); a natural note has one name.
    /// Derived from the table above, never typed again (the pocket keyboard's black keys).
    static func pitchName(_ pc: Int, sharps: Bool) -> String {
        let i = ((pc % 12) + 12) % 12
        let all = major[i] + minor[i]
        let name = all.first { $0.count == 1 } ?? all.first { $0.contains(sharps ? "#" : "b") } ?? all[0]
        return pretty(name)
    }

    private static let letterPC = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    /// Sharps (+) or flats (-) a major key on this letter carries.
    private static let letterSharps = ["C": 0, "G": 1, "D": 2, "A": 3, "E": 4, "B": 5, "F": -1]

    /// A key name as the analyzer writes it ("Cm", "Ebm", "F#", "Bb", "G♯m", any accidentals) to its
    /// pitch class (C = 0), minor, and the key signature that SPELLING carries (G# major = 8 sharps,
    /// which no staff has: callers that need a real signature reduce it). nil = not a key name.
    static func parse(_ name: String) -> (pitchClass: Int, minor: Bool, sharps: Int)? {
        var s = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        var minor = false
        if s.hasSuffix("m") { minor = true; s.removeLast() }
        guard let first = s.first, let base = letterPC[String(first)], let fifths = letterSharps[String(first)] else { return nil }
        var accidentals = 0
        for c in s.dropFirst() {
            switch c {
            case "#": accidentals += 1
            case "b": accidentals -= 1
            default: return nil
            }
        }
        return ((((base + accidentals) % 12) + 12) % 12, minor, fifths - (minor ? 3 : 0) + 7 * accidentals)
    }
}

/// A key the user clicked to PIN as THE key (shown big, sent to Auto-Tune, the DAW and the MIDI
/// file) for one reading; the detector's own order never changes. Matched by the reading's file +
/// name, so the next file or song shows the analyzer's own reading again.
struct KeyChoice: Equatable {
    let file: URL
    let name: String
    let pitchClass: Int
    let minor: Bool
    /// The top-3 slot (0-2) the key sat in when it was pinned (the detector's order then); it keeps
    /// that slot while the other slots update. nil = it was not in the detector's top 3: no slot.
    var slot: Int? = nil

    /// A key as Auto-Tune's Key menu spells it: major C Db D Eb E F F# G Ab A Bb B, minor
    /// C C# D Eb E F F# G G# A Bb B (+ "m"). The analyzer's own spelling.
    static func keyName(_ pitchClass: Int, minor: Bool) -> String {
        KeyNames.roots(pitchClass, minor: minor)[0] + (minor ? "m" : "")
    }

    /// Any spelling of a key ("Gb", "D#m", "E♭") as Auto-Tune names it; a non-key comes back as given.
    static func autoTuneName(_ name: String) -> String {
        guard let k = KeyNames.parse(name) else { return name }
        return keyName(k.pitchClass, minor: k.minor)
    }

    /// All 24 keys in that spelling: the 12 majors from C, then the 12 minors from C.
    static let allKeys: [String] = (0..<12).map { keyName($0, minor: false) } + (0..<12).map { keyName($0, minor: true) }

    /// This choice belongs to reading `r` (same file and name).
    func matches(_ r: Result) -> Bool { file == r.file && name == r.name }

    /// This choice is key `name` (any spelling).
    func isKey(_ name: String) -> Bool {
        KeyNames.parse(name).map { $0.pitchClass == pitchClass && $0.minor == minor } ?? false
    }
}

extension Result {
    /// The reading as shown: every key name as Auto-Tune's Key menu spells it (J 2026-11-09), so
    /// readings saved before that rule match too, and the user's pick (if any) attached as `pin`.
    /// The detector's order and % are never touched: a pick PINS, it never moves up the list or
    /// counts as more likely (J 2026-11-18). "The key" for the dial, wheel, chords, sends and
    /// exports is `keyInUse`, nothing else.
    func respelled(choice: KeyChoice? = SpellingSettings.shared.manualKey) -> Result {
        Result(file: file, name: name, bpm: bpm, keys: keys.map { (KeyChoice.autoTuneName($0.0), $0.1) },
               readError: readError, bpmExact: bpmExact, tuningCents: tuningCents, chroma: chroma,
               pin: ManualKey.of(choice, raw: self), tagged: tagged)
    }

    /// THE key in use: the pin if there is one, else the detector's #1. The one accessor every
    /// "the key" reader goes through (ManualKey.inUse).
    var keyInUse: (name: String, percent: Int)? { ManualKey.inUse(keys: keys, pin: pin) }
}

/// Manual Key Selection's one state (ManualKeySelection.swift sets and clears it). Key names
/// themselves have one rule and no setting: Auto-Tune's Key menu (KeyChoice.keyName; J's
/// rock-solid rule, 2026-11-09 16:15: "We go off of what Auto-Tune shows. That's it.").
final class SpellingSettings: ObservableObject {
    static let shared = SpellingSettings()

    /// Manual Key Selection: the key the user forced for the reading on show (a key wheel click,
    /// a top-3 click, the MANUAL menu, play-to-find on the keyboard). The one state every path
    /// sets and clears (ManualKeySelection.swift); nil = Beat Key's own detection.
    @Published var manualKey: KeyChoice?
}
