import Foundation

// BeatKeyShared: Swift that the app (target Orion) and every plug-in format (compiled by plugin/build.sh
// under the format's own module name, BeatKeyAU / BeatKeyVST3) both compile. One copy of each owner:
// key names and spelling (this file), tempo text, tuning maths, the Auto-Tune hand-off, the plug-in send
// contract, the look primitives (Accent, CapWhite, plate greys) and the log hook (SharedLog).
// Nothing here knows the app's state or a host: values, maths and the hand-off writer.

/// THE key-name table and parser: every other file asks here. Auto-Tune's spelling is the rule
/// (J 2026-11-09): major C Db D Eb E F F# G Ab A Bb B, minor C C# D Eb E F F# G G# A Bb B.
/// The plug-in core reads out the same 24 names (core bk_key_index); plugin/test checks they agree.
public enum KeyNames {
    /// Key names as DAWs print them, preferred (Auto-Tune) spelling first.
    public static let major = [["C"], ["Db", "C#"], ["D"], ["Eb", "D#"], ["E"], ["F"], ["F#", "Gb"], ["G"], ["Ab", "G#"], ["A"], ["Bb", "A#"], ["B", "Cb"]]
    public static let minor = [["C"], ["C#", "Db"], ["D"], ["Eb", "D#"], ["E"], ["F"], ["F#", "Gb"], ["G"], ["G#", "Ab"], ["A"], ["Bb", "A#"], ["B"]]

    public static func roots(_ pc: Int, minor m: Bool) -> [String] { (m ? minor : major)[((pc % 12) + 12) % 12] }

    /// A key as Auto-Tune's Key menu spells it ("Ebm", "F#", "Bb"): the analyzer's own spelling.
    public static func name(_ pc: Int, minor m: Bool) -> String { roots(pc, minor: m)[0] + (m ? "m" : "") }

    /// All 24 keys in that spelling: the 12 majors from C, then the 12 minors from C.
    public static let all: [String] = (0..<12).map { name($0, minor: false) } + (0..<12).map { name($0, minor: true) }

    /// "Eb minor", "D# minor", plus the short forms some menus use ("Ebm", "Eb min").
    public static func names(_ pc: Int, minor m: Bool) -> [String] {
        let r = roots(pc, minor: m)
        return r.map { "\($0) \(m ? "minor" : "major")" } + r.map { m ? "\($0) min" : "\($0) maj" } + r.map { m ? "\($0)m" : $0 }
    }

    /// Unicode-accidental spellings (Logic prints ♭/♯); AXText.norm folds them, kept for clarity.
    public static func pretty(_ s: String) -> String { s.replacingOccurrences(of: "b", with: "♭").replacingOccurrences(of: "#", with: "♯") }

    /// Pitch class `pc` as one note name with ♯/♭ ("C♯" or "D♭"); a natural note has one name.
    /// Derived from the table above, never typed again (the pocket keyboard's black keys).
    public static func pitchName(_ pc: Int, sharps: Bool) -> String {
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
    public static func parse(_ name: String) -> (pitchClass: Int, minor: Bool, sharps: Int)? {
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
