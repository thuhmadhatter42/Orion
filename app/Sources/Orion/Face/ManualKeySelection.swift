import SwiftUI

// Manual Key Selection (J, 2026-11-09 15:19): a key the user forced, from the key wheel, a top-3
// click, the MANUAL menu or play-to-find on the keyboard. One state holds it
// (SpellingSettings.manualKey); every path sets it with setManualKey and clears it with
// clearManualKey, and every set / clear goes to beatkey.log with where it came from.
//
// A pick PINS (J 2026-11-18): the detector's list is never reordered or re-weighted (Result.keys);
// the key in use is the pin, else the detector's #1, read only through Result.keyInUse
// (ManualKey.inUse). The pinned key keeps the top-3 slot it was clicked in (KeyChoice.slot, drawn
// by TopKeys.arranged) while the other slots update live; a key outside the detector's top 3 takes
// no slot (the dial and wheel show it). A click on the pinned slot clears it.
//
// How it shows: WHITE instead of the display colour. The wheel's section is lit white; the pinned
// top-3 slot shows the name in white and MANUAL in place of a % (the other keys keep their real %);
// the dial's key, ring and status line (MANUAL, no lamp, no %) go white. Hovering the wheel's
// white section or the dial swaps the key name for the reset arrow (NEW SONG's glyph), and a click
// clears the selection: detection takes over again.

/// Where a Manual Key Selection was set or cleared (the log names it).
enum ManualKeySource: String, CaseIterable {
    case wheel = "key wheel"
    case topKeys = "top-3"
    case dropdown = "MANUAL menu"
    case keyboard = "keyboard"
    /// A click on the white section of the wheel: clears.
    case wheelReset = "key wheel re-click"
    /// A click on the pinned top-3 slot: clears.
    case topKeysReset = "top-3 re-click"
    /// A click on the dial while manual: clears.
    case dialReset = "dial reset"
    // A new live song needs no clear: the selection holds the song's identity (LiveSession.song).
}

/// The Manual Key Selection on show, as a plain value for the views (PocketState.manualKey).
struct ManualKey: Equatable {
    let pitchClass: Int
    let minor: Bool
    /// The analyzer's own % for this key; nil = it was not in the analyzer's list (never a
    /// made-up number: the views show MANUAL, not a %).
    let detected: Int?
    /// The top-3 slot it was pinned in and keeps (KeyChoice.slot); nil = no slot.
    var slot: Int? = nil

    /// This is key `name` (any spelling).
    func isKey(_ name: String) -> Bool {
        KeyNames.parse(name).map { $0.pitchClass == pitchClass && $0.minor == minor } ?? false
    }

    func isKey(_ pc: Int, minor m: Bool) -> Bool { pc == pitchClass && m == minor }

    /// The selection `choice` as shown on reading `raw` (the detector's list, never reordered);
    /// nil = no selection, or it belongs to another reading.
    static func of(_ choice: KeyChoice?, raw: Result?) -> ManualKey? {
        guard let c = choice, let r = raw, c.matches(r) else { return nil }
        let pct = r.keys.first(where: { c.isKey($0.0) })?.1
        return ManualKey(pitchClass: c.pitchClass, minor: c.minor, detected: pct, slot: c.slot)
    }

    private static var logged = Set<String>()
    private static let loggedLock = NSLock()

    /// One log line per distinct problem, not one per redraw (views call the pin code often).
    static func logOnce(_ line: String) {
        loggedLock.lock(); defer { loggedLock.unlock() }
        guard logged.insert(line).inserted else { return }
        AppLog.log(line)
    }

    /// THE key in use (the one accessor behind `Result.keyInUse`, and what the wheel reads from its
    /// own `keys` + pin): the pin, in Auto-Tune's spelling, with the detector's own % for it (0 =
    /// the detector does not list it: never a made-up number), else the detector's #1.
    static func inUse(keys: [(String, Int)], pin: ManualKey?) -> (name: String, percent: Int)? {
        if let p = pin { return (KeyChoice.keyName(p.pitchClass, minor: p.minor), p.detected ?? 0) }
        return keys.first.map { (name: $0.0, percent: $0.1) }
    }
}
/// The colours of a Manual Key Selection: white instead of the display colour (the cap white, leaning toward the accent by CapWhite.tint).
/// High Contrast: pure white, no glow (white is already the most contrast the LCD has):
/// that white is the palette's (`palette.manualWhite`); its glow is the house glow module's (`paletteGlow`).
enum ManualLook {
    /// Ink on a white fill (the wheel's lit section): near black in every accent.
    static let ink = Theme.hex(0x111113)
    /// The reset arrow: NEW SONG's glyph (the reset key beside HOLD).
    static let resetSymbol = "arrow.counterclockwise"
    /// The status line under the dial's key, and the top-3 slot's label.
    static let word = "MANUAL"
}

private struct ManualHoverForcedKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// Offscreen renders: "dial" = the dial hovered, "wheel" = the wheel's manual section hovered.
    var manualHoverForced: String? {
        get { self[ManualHoverForcedKey.self] }
        set { self[ManualHoverForcedKey.self] = newValue }
    }
}
