import AppKit
import Foundation

// The menu-bar popover ("the pocket faceplate"): its logic, kept out of the views so it can be
// tested. The views are in PocketView.swift; the status item and popover in MenuBar.swift.

/// The input meter: a peak sample (0...1 linear) on a -54...0 dB scale, as 0...1.
enum LevelMeter {
    static let floorDB: Float = -54

    static func scale(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(min(peak, 1))
        return max(0, min(1, (db - floorDB) / -floorDB))
    }

    /// How many of `count` segments are lit for `level`.
    static func lit(_ level: Float, count: Int) -> Int {
        Int((max(0, min(1, level)) * Float(count)).rounded())
    }
}

/// The clipboard holds a link to download: an http(s) URL on its own (whitespace trimmed).
enum Clipboard {
    static func link(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !t.contains(where: { $0.isWhitespace }),
              let u = URL(string: t), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return t
    }

    static func currentLink(_ pb: NSPasteboard = .general) -> String? { link(pb.string(forType: .string)) }
}

/// Everything the popover draws, as plain values (so it can be rendered offscreen and tested).
struct PocketState {
    var readout: Readout = .idle
    /// A file hovers over the WINDOW (the drop ring and DROP TO GET BPM AND KEY cover the readout).
    /// The popover never sets it.
    var dropTargeted = false
    /// Listen is on (listening, reading or locked).
    var listening = false
    /// "System Audio", "Scarlett 4i4 · Ch 3".
    var source = "System Audio"
    var level: Float = 0
    var url = ""
    /// A download or an analysis is running (the caps go dark).
    var busy = false
    /// The YouTube link waiting needs a login (the window's LOG IN cap takes over).
    var needsLogin = false
    /// The clipboard holds a link (PASTE + GO lights).
    var clipboardLink: String? = nil
    /// The DAW Send to DAW would go to; nil = none open.
    var daw: String? = nil
    var recents: [Reading] = []
    /// New Song's global shortcut as printed ("⌃⌥⌘R"); nil = none set.
    var newSongKeys: String? = nil
    /// Hold is on: the reading is frozen (a button, never automatic).
    var held = false
    /// Hold's global shortcut as printed; nil = none set.
    var holdKeys: String? = nil
    /// Advanced mode of the surface drawn: the window's harmony column, or the pocket's harmony
    /// pieces (PocketContainer puts the pocket's own setting in).
    var advanced = false
    /// Advanced mode's chord and MATCH TO choices.
    var harmony = HarmonyPrefs()
    /// Beat Key Mini's panel is open (the MINI chip lights).
    var miniOpen = false
    /// Help mode: hovering a control explains it (HelpSettings; the HELP chip lights).
    var help = false
    /// The pinned key on the reading shown (`result.pin`: one state, not a copy); nil = detection.
    var manualKey: ManualKey? { result?.pin }

    /// The reading on the readout, if there is one.
    var result: Result? {
        if case .result(let r, _, _, _, _) = readout { return r }
        return nil
    }
    var options: ResultOptions? {
        if case .result(_, _, _, _, let o) = readout { return o }
        return nil
    }

    /// DOWNLOAD lights for a link while nothing runs (the window's rule).
    var downloadLit: Bool { Faceplate.isLit(url, busy: busy) && !needsLogin }
    /// The field is empty and the clipboard holds a link: DOWNLOAD lights and takes that link.
    var clipboardReady: Bool {
        !busy && !needsLogin && clipboardLink != nil && url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// A reading with a tempo or a key: the send / export caps light.
    /// Hold has a reading to freeze (or is on and can be released).
    var canHold: Bool { listening && (held || result != nil) }
    var canSend: Bool { result.map { $0.bpm != nil || !$0.keys.isEmpty } ?? false }
    var canAutoTune: Bool { result?.keyInUse.flatMap { KeyNames.parse($0.name) } != nil }

    /// The lamp beside the hero key: Listen's own choice, else the key's confidence.
    var lamp: Lamp? {
        guard let r = result else {
            if case .listening = readout { return .listening }
            if case .working = readout { return .listening }
            return nil
        }
        return options?.live?.lamp ?? Lamp.of(r.keys)
    }

    /// The top key's confidence as 0...1 for the ring (nil = no key).
    var confidence: Double? { result?.keyInUse.map { Double(max(0, min(100, $0.percent))) / 100 } }

    var scale: Scale? { result?.keyInUse.flatMap { Scale.of($0.name) } }

    /// The lamp's word: LOCKED / UNSURE / LISTENING.
    var lampWord: String? {
        guard let l = lamp else { return nil }
        return (held ? "HELD · " : "") + l.spoken.uppercased()
    }
}

/// Where the reading on show came from (Broadcast.swift sends it as `source`).
enum ShownSource: Equatable { case listen, file }

extension PocketState {
    /// The reading the popover acts on (send, export, Auto-Tune, Broadcast): Listen's while it is
    /// on, else the finished download or the file paged to (what the readout shows), with where it
    /// came from. THE one place the app's current reading is chosen. `choice` = the picked key,
    /// passed in by a caller that holds the new value before the property has changed.
    static func shownReading(_ state: ViewState, live: LiveState, page: Pager,
                             choice: KeyChoice? = SpellingSettings.shared.manualKey) -> (result: Result, source: ShownSource)? {
        if live.isActive, let r = live.result { return (r.respelled(choice: choice), .listen) }
        switch state {
        case .done(let r): return (r.respelled(choice: choice), .file)
        case .analyzed(let rs) where !rs.isEmpty:
            return (rs[min(max(page.index, 0), rs.count - 1)].respelled(choice: choice), .file)
        default: return nil
        }
    }

    static func shown(_ state: ViewState, live: LiveState, page: Pager) -> Result? {
        shownReading(state, live: live, page: page)?.result
    }
}
