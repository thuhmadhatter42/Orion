import AppKit
import SwiftUI

/// One face's state: what the instance says (polled 4 times a second while on screen), the line under
/// the reading, and the two buttons' work. Main thread only.
final class FaceModel: ObservableObject {
    let token: UInt64
    @Published private(set) var state = FaceState()
    /// The face's message line (a send's outcome, a refusal); nil = the instance's own status.
    @Published private(set) var line: FaceLine?
    @Published private(set) var sendingBPM = false

    private var timer: Timer?
    private var lineExpiry: Timer?
    /// Tests swap these (plugin/test/face_test.swift).
    var bpmEnv: BPMSend.Env = .live
    var autoTuneURL: URL = AutoTuneSend.handoffURL

    init(token: UInt64) {
        self.token = token
        state = FaceState.read(token)
    }

    deinit {
        timer?.invalidate()
        lineExpiry?.invalidate()
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let s = FaceState.read(token)
        if s != state { state = s }
    }

    // MARK: the line

    func show(_ text: String, kind: FaceLine.Kind, detail: String? = nil, link: URL? = nil, hold: TimeInterval? = nil) {
        lineExpiry?.invalidate()
        line = FaceLine(text: text, kind: kind, detail: detail, link: link)
        let secs = hold ?? (kind == .error ? 12 : 6)
        let t = Timer(timeInterval: secs, repeats: false) { [weak self] _ in self?.line = nil }
        RunLoop.main.add(t, forMode: .common)
        lineExpiry = t
    }

    /// What the line says when no message is up: the instance's status, else the reading's state.
    var statusText: (String, FaceLine.Kind) {
        if !state.alive { return ("This instance is closed.", .error) }
        if !state.status.isEmpty { return (state.status, .error) }
        if state.error { return ("Analysis stopped. Report sends the log.", .error) }
        if state.clips {
            // AudioSuite: readings come from Analyze on a selection; playback, bypass and silence play no part
            if state.analyzing { return ("Reading the selection…", .info) }
            if !state.hasReading { return ("Select a clip, then press Analyze.", .info) }
            return ("", .info)
        }
        if state.bypass { return ("Bypassed. Not listening.", .info) }
        if state.stale { return ("New song. Listening…", .info) }
        if state.silent { return ("Silence. Play the track.", .info) }
        if !state.hasReading { return ("Play the track. Key + BPM in seconds.", .info) }
        return ("", .info)
    }

    // MARK: the buttons

    func sendAutoTune() {
        let r = AutoTuneButton.send(token: token, key: state.key, to: autoTuneURL)
        show(r.line, kind: r.ok ? .ok : .error, detail: r.detail)
    }

    func sendBPM() {
        guard !sendingBPM else { return }
        guard let bpm = state.bpm else {
            show("No BPM yet.", kind: .error)
            FaceLog.send(token, what: "BPM", value: "-", ok: false, outcome: "SEND BPM pressed with no BPM yet; nothing sent")
            return
        }
        sendingBPM = true
        let token = self.token
        let send = BPMSend(token: token, bpm: bpm,
                           hostTempo: { FaceState.read(token).hostTempo }, env: bpmEnv,
                           progress: { [weak self] p in self?.show(p, kind: .info, hold: 30) },
                           done: { [weak self] r in
                               self?.sendingBPM = false
                               self?.show(r.line, kind: r.ok ? .ok : .error, detail: r.detail, link: r.link)
                           })
        send.start()
    }

    // MARK: one click away

    /// Pins `name`, or unpins when it is the pin already (Board Talk: "Click to pin, again to unpin").
    func togglePin(_ name: String) {
        let unpin = state.pin == name
        let rc = unpin ? bkp_view_set_pin(token, nil) : name.withCString { bkp_view_set_pin(token, $0) }
        if rc != 0 { show("Couldn't pin \(name).", kind: .error) }
        FaceLog.line(token, unpin ? "face: unpinned \(name)" : "face: pinned \(name)\(rc != 0 ? " REFUSED" : "")")
        refresh()
    }

    func unpin() {
        _ = bkp_view_set_pin(token, nil)
        FaceLog.line(token, "face: unpinned")
        refresh()
    }

    func setFactor(_ f: TempoFactor) {
        if bkp_view_set_tempo_mult(token, f.mult) != 0 { show("Couldn't set \(f.label ?? "×1").", kind: .error) }
        FaceLog.line(token, "face: tempo \(f.label ?? "×1")")
        refresh()
    }

    func newSong() {
        _ = bkp_view_new_song(token)
        FaceLog.line(token, "face: new song")
        show(state.clips ? "Cleared. Analyze a clip." : "New song. Listening…", kind: .info)
        refresh()
    }

    var version: String { String(cString: bkp_view_version()) }
}

struct FaceLine: Equatable {
    enum Kind { case info, ok, error }
    var text: String
    var kind: Kind
    var detail: String?
    var link: URL?
}

/// The face's own settings: the display colour (house kit accent), remembered for every Beat Key
/// plug-in on this Mac (UserDefaults suite com.jshriver.orion.plugin, key accentColor: [r, g, b]).
final class FaceSettings: ObservableObject {
    static let shared = FaceSettings()
    static let suite = "com.jshriver.orion.plugin"
    static let key = "accentColor"
    /// The swatches (amber first). The app's colour wheel is an app window; a plug-in in someone
    /// else's window gets a row of colours instead.
    static let swatches: [Accent] = [.amber, Accent(255, 96, 64), Accent(255, 64, 160), Accent(160, 120, 255),
                                     Accent(64, 170, 255), Accent(64, 220, 200), Accent(120, 230, 90), Accent(240, 240, 235)]

    private let defaults: UserDefaults?
    @Published private(set) var accent: Accent = .amber

    init(defaults: UserDefaults? = UserDefaults(suiteName: FaceSettings.suite)) {
        self.defaults = defaults
        if let raw = defaults?.object(forKey: FaceSettings.key) {
            if let a = raw as? [Double], a.count == 3, a.allSatisfy({ $0.isFinite }) {
                accent = Accent(a[0], a[1], a[2]).readable().accent
            } else {
                FaceLog.line(0, "face: stored \(FaceSettings.key) unreadable (\(raw)); amber")
            }
        }
    }

    func set(_ a: Accent) {
        let shown = a.readable().accent
        accent = shown
        if a == .amber { defaults?.removeObject(forKey: FaceSettings.key) }
        else { defaults?.set([a.r, a.g, a.b], forKey: FaceSettings.key) }
        FaceLog.line(0, "face: colour \(a.described)" + (shown != a ? " (shown as \(shown.described))" : ""))
    }
}
