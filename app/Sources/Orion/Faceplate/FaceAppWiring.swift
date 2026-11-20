import AppKit
import Combine
import SwiftUI

// The app's side of the shared face (app/Sources/Orion/Face/): what the face's plain values and
// closures are wired to here: the one Manual Key Selection state (SpellingSettings), the reading
// on show (engine + Listen), Advanced mode's saved choices (DisplaySettings), COLOR and REPORT.

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

extension SpellingSettings {
    /// Manual Key Selection: `key` (any spelling) becomes THE key of `result`. The one override
    /// path. A key name that does not resolve leaves the state as it was and is logged as an
    /// error (no alert: the click simply does nothing). False = not set.
    @discardableResult
    func setManualKey(_ key: String, of result: Result, from source: ManualKeySource) -> Bool {
        guard let k = KeyNames.parse(key) else {
            AppLog.log("ERROR manual key selection: could not resolve \"\(key)\" (from \(source.rawValue)); unchanged")
            return false
        }
        let was = manualKey.flatMap { $0.matches(result) ? KeyChoice.keyName($0.pitchClass, minor: $0.minor) : nil }
        // The slot it keeps: the same key re-picked from another path keeps its slot; otherwise
        // where the detector lists it right now (nil = not in the top 3: no slot, dial and wheel
        // show it).
        let slot: Int?
        if let m = manualKey, m.matches(result), m.pitchClass == k.pitchClass, m.minor == k.minor {
            slot = m.slot
        } else {
            slot = result.keys.prefix(3).firstIndex { KeyNames.parse($0.0).map { $0.pitchClass == k.pitchClass && $0.minor == k.minor } ?? false }
        }
        manualKey = KeyChoice(file: result.file, name: result.name, pitchClass: k.pitchClass, minor: k.minor, slot: slot)
        AppLog.log("manual key selection set: \(KeyChoice.keyName(k.pitchClass, minor: k.minor)) from \(source.rawValue)"
                   + (slot.map { " · pinned in slot \($0 + 1)" } ?? " · not in the detector's top 3, no slot (dial and wheel show it)")
                   + (was.map { " (was \($0))" } ?? ""))
        return true
    }

    /// Clears Manual Key Selection: detection takes over again. `result` = the reading on show; a
    /// selection that belongs to another reading is still cleared, but logged as an error (the view
    /// and the state disagreed). False = there was nothing to clear (logged as an error).
    @discardableResult
    func clearManualKey(of result: Result?, from source: ManualKeySource) -> Bool {
        guard let m = manualKey else {
            AppLog.log("ERROR manual key selection: clear from \(source.rawValue), but none is set")
            return false
        }
        let name = KeyChoice.keyName(m.pitchClass, minor: m.minor)
        if let r = result, !m.matches(r) {
            AppLog.log("ERROR manual key selection: \(name) no longer matches the reading on show (clear from \(source.rawValue))")
        }
        manualKey = nil
        AppLog.log("manual key selection cleared: \(name) from \(source.rawValue); detection resumes")
        return true
    }
}

extension Result {
    /// The reading as shown, with the app's Manual Key Selection (SpellingSettings.shared) attached.
    func respelled() -> Result { respelled(choice: SpellingSettings.shared.manualKey) }
}

extension PocketActions {
    /// The face's pin / unpin, wired to `settings` (the app's one Manual Key Selection state).
    func pinning(_ settings: SpellingSettings = .shared) -> PocketActions {
        var a = self
        a.pinKey = { key, result, source in _ = settings.setManualKey(key, of: result, from: source) }
        a.clearPin = { result, source in _ = settings.clearManualKey(of: result, from: source) }
        return a
    }

    /// COLOR and REPORT, the app's way: the colour wheel panel and the house kit's Report sheet.
    func appHouse() -> PocketActions {
        var a = self
        a.color = { AccentPanel.shared.toggle() }
        a.report = { MainActor.assumeIsolated { ReportCenter.shared.open() } }   // a click: always the main thread
        return a
    }
}

extension KeyStrip {
    static func topKeys(_ state: PocketState, settings: SpellingSettings) -> TopKeys {
        topKeys(state, actions: PocketActions().pinning(settings))
    }
}

extension HarmonyPanel {
    static func wheel(_ state: PocketState, settings: SpellingSettings) -> KeyWheel {
        wheel(state, actions: PocketActions().pinning(settings))
    }
}

extension Dial {
    /// The dial's reset against `settings` (tests; the face's own click goes through its actions).
    func resetManual(_ settings: SpellingSettings) {
        var d = self
        d.actions = actions.pinning(settings)
        d.resetManual()
    }
}

extension HarmonyPrefs {
    init(_ d: DisplaySettings) {
        self.init(quality: d.chordQuality, voicing: d.chordVoicing, bars: d.chordBars, matchKey: d.matchKey)
    }

    /// Writes the choices back.
    func apply(to d: DisplaySettings) {
        if d.chordQuality != quality { d.chordQuality = quality }
        if d.chordVoicing != voicing { d.chordVoicing = voicing }
        if d.chordBars != bars { d.chordBars = bars }
        if d.matchKey != matchKey { d.matchKey = matchKey }
    }
}

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

extension PocketActions {
    /// The harmony pieces' actions (chords heard and dragged, chord choices, MATCH TO, MINI), the
    /// same for the window's column and the pocket's. `surface` names the log lines.
    mutating func wireHarmony(surface: String, engine e: Engine, model m: FaceplateModel, live l: LiveController,
                              display d: DisplaySettings) {
        let shown = { PocketState.shown(e.state, live: l.state, page: m.pager) }
        playChord = { chord in
            let bpm = ChordClip.bpm(shown(), factor: m.tempoFactor)
            AppLog.log("\(surface): chord \(chord.asciiName) played (\(d.chordVoicing.rawValue), \(d.chordBars) bar)")
            NoteSynth.shared.play(chord.notes(d.chordVoicing), seconds: ChordClip.hearSeconds(bars: d.chordBars, bpm: bpm))
        }
        chordFile = { chord in
            let r = shown()
            let bpm = ChordClip.bpm(r, factor: m.tempoFactor)
            let url = ChordClip.write(chord, voicing: d.chordVoicing, bars: d.chordBars, bpm: bpm, key: r?.keyInUse?.name)
            if url != nil { AppLog.log("\(surface): chord \(chord.asciiName) dragged as a MIDI clip") }
            else { AppLog.log("\(surface): chord \(chord.asciiName) MIDI clip could not be written") }
            return url
        }
        toggleMini = {
            let sp = SpellingSettings.shared
            let changes = Publishers.MergeMany([e.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                                                l.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                                                m.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                                                d.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                                                sp.objectWillChange.map { _ in () }.eraseToAnyPublisher()])
                .eraseToAnyPublisher()
            MiniController.shared.toggle(source: {
                MiniFeed(key: shown()?.keyInUse?.name, quality: d.chordQuality, voicing: d.chordVoicing)
            }, changes: changes, display: d)
        }
        setHarmony = { p in
            AppLog.log("\(surface): chords \(p.quality.rawValue) \(p.voicing.rawValue) \(p.bars) bar")
            p.apply(to: d)
        }
        pickMatchKey = {
            AppLog.log("\(surface): match to menu")
            let items = KeyChoice.allKeys.enumerated().flatMap { i, k -> [PopupMenu.Item] in
                let item = PopupMenu.Item(title: k, checked: d.matchKey == k) {
                    AppLog.log("\(surface): match to \(k)")
                    d.matchKey = k
                }
                return i == 12 ? [.separator, item] : [item]
            }
            PopupMenu.show(items + [.separator, PopupMenu.Item(title: "None", checked: d.matchKey == nil) { d.matchKey = nil }])
        }
    }
}
