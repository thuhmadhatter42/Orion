import Combine
import Foundation

// KeyNames (the key-name table and parser) lives in BeatKeyShared/KeyNames.swift: the app and the
// plug-in share that one copy.

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
    static func keyName(_ pitchClass: Int, minor: Bool) -> String { KeyNames.name(pitchClass, minor: minor) }

    /// Any spelling of a key ("Gb", "D#m", "E♭") as Auto-Tune names it; a non-key comes back as given.
    static func autoTuneName(_ name: String) -> String {
        guard let k = KeyNames.parse(name) else { return name }
        return keyName(k.pitchClass, minor: k.minor)
    }

    /// All 24 keys in that spelling: the 12 majors from C, then the 12 minors from C.
    static let allKeys: [String] = KeyNames.all

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
