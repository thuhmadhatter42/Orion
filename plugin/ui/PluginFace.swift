import AppKit
import SwiftUI

// The plug-in's face = the app window's face (overnight plan 2026-11-20 §3, J: "the plug-in looks like
// the app window"). FaceplateFace (app/Sources/Orion/Face/) draws it; this file feeds it the instance's
// reading as PocketState and wires PocketActions to the instance (bkp_view_*), the sends, DOWNLOAD,
// COLOR, REPORT and the menus. What a host can't use is hidden by FaceSurface.plugin, never left dead:
// page arrows / SHOW IN FINDER, Open Audio + FIND, HOLD, LISTEN, SETTINGS, MINI.

/// Board Talk tips the plug-in adds (docs/BOARD-TALK.md: 60 characters at most). face_test checks them.
enum FaceTips {
    static let download = "Paste a link. Pick where it goes in Pro Tools."
    static let source = "The plug-in listens to its own track."
    static let all = [download, source]
    static let maxBody = 60
}

/// The root: the colour in the environment, the face at the plug-in's size.
struct FaceRoot: View {
    @ObservedObject var model: FaceModel
    @ObservedObject var settings = FaceSettings.shared

    var body: some View {
        let s = PluginFace.state(model, settings: settings)
        let size = FaceplateFace.pluginSize(advanced: s.advanced)
        FaceplateFace(state: s, picked: [], url: $model.url, fieldFocused: $model.fieldFocused,
                      pickFocused: $model.pickFocused, actions: PluginFace.actions(model, settings: settings))
            .padding(.top, FaceplateFace.pluginTopInset)
            .frame(width: size.width, height: size.height)
            .background(Theme.desk)
            .environment(\.palette, Palette(accent: settings.accent, highContrast: false))
            .environment(\.accent, settings.accent)
            .environment(\.highContrast, false)
            .preferredColorScheme(.dark)
    }
}

enum PluginFace {
    /// The song's identity as a reading's file (a pin belongs to the song it was made on).
    static func songFile(_ song: UInt64) -> URL { URL(fileURLWithPath: "/plugin-song-\(song)") }

    /// The instance's reading as the face's Result: the detector's top 3 in Auto-Tune's spelling, the
    /// BPM before the ×2 / ÷2 (the face applies the factor, as the app does), tuning, notes heard, pin.
    static func result(_ s: FaceState) -> Result? {
        guard s.alive, s.hasReading else { return nil }
        let keys = s.top.map { (KeyChoice.autoTuneName($0.name), $0.percent) }
        let raw = s.bpm.map { $0 / s.factor.multiplier }
        let file = songFile(s.song)
        var r = Result(file: file, name: "Track input", bpm: raw.map { String(format: "%.1f", $0) }, keys: keys,
                       bpmExact: s.bpmExact ? raw : nil, tuningCents: s.tuningCents, chroma: s.chroma)
        if let pin = s.pin, let k = KeyNames.parse(pin) {
            let slot = keys.prefix(3).firstIndex { KeyNames.parse($0.0).map { $0.pitchClass == k.pitchClass && $0.minor == k.minor } ?? false }
            r.pin = ManualKey(pitchClass: k.pitchClass, minor: k.minor, detected: slot.map { keys[$0].1 }, slot: slot)
        }
        return r
    }

    /// The LCD for the instance's state. Amber two-line messages (the login readout's look) for the
    /// states that are not a reading and not a failure.
    static func readout(_ s: FaceState, cycle: @escaping () -> Void) -> Readout {
        if !s.alive { return .error("THIS INSTANCE IS CLOSED", download: false, hint: "CLOSE THIS WINDOW AND OPEN IT AGAIN") }
        if !s.status.isEmpty { return .error(s.status, download: false, hint: "REPORT SENDS THE LOG") }
        if s.error { return .error("ANALYSIS STOPPED", download: false, hint: "REPORT SENDS THE LOG") }
        if let r = result(s) {
            let lamp: Lamp = s.stale ? .listening : (Lamp.of(r.keys) ?? .listening)
            let status = s.stale ? "NEW SONG · LISTENING" : (Faceplate.confidenceLine(r.keys) ?? "LISTENING")
            let source = s.clips ? "AUDIOSUITE SELECTION" : "TRACK INPUT"
            return .result(r, page: nil, download: false, options: ResultOptions(
                factor: s.factor, tuning: Tuning.meter(r.tuningCents, reference: AutoTuneButton.referencePitch()),
                onCycleTempo: cycle, live: (lamp: lamp, status: status, source: source)))
        }
        if s.clips {
            return s.analyzing ? .working(stage: "analyzing", download: false)
                               : .login("SELECT A CLIP", "THEN PRESS ANALYZE", caption: nil)
        }
        if s.bypass { return .login("BYPASSED", "NOT LISTENING", caption: nil) }
        if s.silent { return .listening(status: "SILENCE · PLAY THE TRACK") }
        return .listening(status: "LISTENING · TRACK INPUT")
    }

    /// The status line: a message just shown, else the instance's own state, else the MIDI route,
    /// else the session tempo.
    static func status(_ m: FaceModel) -> FaceStatus? {
        if let l = m.line { return FaceStatus(text: l.text, kind: kind(l.kind), detail: l.detail) }
        let st = m.statusText
        if st.1 != .error, !m.state.bypass, let x = MidiOut.line(m.state) { return FaceStatus(text: x.text, kind: kind(x.kind), detail: x.detail) }
        if !st.0.isEmpty { return FaceStatus(text: st.0, kind: kind(st.1)) }
        if let host = m.state.hostTempo { return FaceStatus(text: "Session \(PluginSend.bpmText(host))") }
        return nil
    }

    static func kind(_ k: FaceLine.Kind) -> FaceStatus.Kind {
        switch k {
        case .info: return .info
        case .ok: return .ok
        case .error: return .error
        }
    }

    static func state(_ m: FaceModel, settings: FaceSettings) -> PocketState {
        let s = m.state
        var p = PocketState()
        p.surface = .plugin
        p.readout = readout(s, cycle: { m.setFactor(s.factor.next) })
        p.listening = s.alive && !s.bypass && !s.clips
        p.source = s.clips ? "AudioSuite selection" : "Track input"
        p.level = s.level
        p.url = m.url
        p.busy = m.downloading
        p.clipboardLink = m.clipboardLink
        let host = m.bpmEnv.host().name
        p.daw = host.isEmpty ? nil : host
        p.recents = settings.downloads.map { path in
            let u = URL(fileURLWithPath: path)
            return Reading(Result(file: u, name: u.lastPathComponent, bpm: nil, keys: []))
        }
        p.advanced = settings.advanced
        p.harmony = settings.harmony
        p.help = settings.help
        p.colorOpen = m.colorOpen
        p.status = status(m)
        if m.downloadMenuOpen {
            p.downloadMenu = DownloadMenu(history: settings.placements.picks, canImport: m.hostIsProTools)
        }
        return p
    }

    // MARK: the controls

    static func actions(_ m: FaceModel, settings: FaceSettings) -> PocketActions {
        var a = PocketActions()
        a.setFactor = { m.setFactor($0) }
        a.download = { m.downloadPressed() }
        a.pasteAndDownload = { link in m.url = link; m.downloadPressed() }
        a.pickPlacement = { m.startDownload($0, settings: settings) }
        a.closeDownloadMenu = { m.downloadMenuOpen = false }
        a.openLogin = { m.show("Log in to YouTube from the Beat Key app.", kind: .info) }
        a.newSong = { m.newSong() }
        a.pickSource = { m.show(FaceTips.source, kind: .info) }
        a.manualMenu = {
            menu(KeyNames.all.map { k in (k, m.state.pin == k, { m.togglePin(k) }) }
                 + (m.state.pin != nil ? [("Unpin", false, { m.unpin() })] : []))
        }
        a.pinKey = { key, _, _ in m.pin(key) }
        a.clearPin = { _, _ in m.unpin() }
        a.sendDAW = { m.sendBPM() }
        a.sendAutoTune = { m.sendAutoTune(); return m.line?.kind != .error }
        a.exportMidi = {
            guard let u = MidiOut.write(token: m.token, state: m.state) else {
                m.show("No key or BPM yet.", kind: .error)
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([u])
            m.show("MIDI saved: \(u.lastPathComponent). Drag it in.", kind: .ok, detail: u.path)
        }
        a.midiDrag = { MidiOut.provider(token: m.token, state: m.state) }
        a.showRecents = {
            menu(settings.downloads.map { path in
                (URL(fileURLWithPath: path).lastPathComponent, false, {
                    let u = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                    else { m.show("Moved or deleted: \(u.lastPathComponent)", kind: .error) }
                })
            })
        }
        a.chordFile = { chord in
            let r = result(m.state)
            let bpm = ChordClip.bpm(r, factor: m.state.factor)
            let p = settings.harmony
            let url = ChordClip.write(chord, voicing: p.voicing, bars: p.bars, bpm: bpm, key: r?.keyInUse?.name)
            FaceLog.line(m.token, url != nil ? "face: chord \(chord.asciiName) dragged as a MIDI clip"
                                            : "face: chord \(chord.asciiName) MIDI clip could not be written")
            return url
        }
        a.setHarmony = { settings.harmony = $0 }
        a.pickMatchKey = {
            menu(KeyChoice.allKeys.map { k in (k, settings.harmony.matchKey == k, { settings.harmony.matchKey = k }) }
                 + [("None", settings.harmony.matchKey == nil, { settings.harmony.matchKey = nil })])
        }
        a.toggleHelp = { settings.help.toggle() }
        a.toggleAdvanced = { settings.advanced.toggle() }
        a.color = {
            m.colorOpen = true
            menu(FaceSettings.swatches.map { c in
                (c == .amber ? "Amber" : c.described, settings.accent == c.readable().accent, { settings.set(c) })
            }, swatches: FaceSettings.swatches)
            m.colorOpen = false
        }
        a.report = { m.report() }
        return a
    }

    /// A pop-up menu at the mouse (a plug-in has no menu bar of its own). Blocks until it closes.
    static func menu(_ items: [(String, Bool, () -> Void)], swatches: [Accent]? = nil) {
        guard !items.isEmpty else { NSSound.beep(); return }
        let menu = NSMenu()
        let target = MenuTarget(items.map(\.2))
        for (i, it) in items.enumerated() {
            let mi = NSMenuItem(title: it.0, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            mi.target = target
            mi.tag = i
            mi.state = it.1 ? .on : .off
            if let sw = swatches, i < sw.count {
                let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                    sw[i].nsColor.setFill(); NSBezierPath(ovalIn: r).fill(); return true
                }
                mi.image = img
            }
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(target) {}
    }

    private final class MenuTarget: NSObject {
        let actions: [() -> Void]
        init(_ a: [() -> Void]) { actions = a }
        @objc func pick(_ sender: NSMenuItem) { actions[sender.tag]() }
    }
}

extension FaceModel {
    func report() {
        let l = FaceHouse.report(token: token, state: state, version: version)
        show(l.text, kind: l.kind)
    }

    func openPage(_ name: String, _ title: String) {
        if !FaceHouse.open(page: name, title: title, token: token) { show("\(title) missing. Reinstall Beat Key.", kind: .error) }
    }

    /// Pins `name` (a top-3 or wheel click; the face clears with clearPin).
    func pin(_ name: String) {
        guard state.pin != name else { return }
        togglePin(name)
    }
}
