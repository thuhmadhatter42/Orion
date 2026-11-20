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
    /// The link field (DOWNLOAD), its focus, and the Open Audio field's (hidden in a plug-in).
    @Published var url = ""
    @Published var fieldFocused = false
    @Published var pickFocused = false
    /// A DOWNLOAD is under way (the caps go dark).
    @Published private(set) var downloading = false
    /// The DOWNLOAD menu is open (Pro Tools: where the beat goes).
    @Published var downloadMenuOpen = false
    /// The colour swatches are open (COLOR lights).
    @Published var colorOpen = false
    /// The clipboard holds a link (PASTE + DOWNLOAD lights).
    @Published private(set) var clipboardLink: String?
    private var pasteboardCount = -1

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
        let n = NSPasteboard.general.changeCount
        if n != pasteboardCount {
            pasteboardCount = n
            let link = PluginDownload.isLink(NSPasteboard.general.string(forType: .string) ?? "")
                ? NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if link != clipboardLink { clipboardLink = link }
        }
    }

    // MARK: DOWNLOAD (overnight plan §4-§5)

    /// The host: Pro Tools imports (the menu); any other host saves and shows the file in Finder.
    var hostIsProTools: Bool {
        let h = bpmEnv.host()
        return PluginDownload.isProTools(bundleID: h.bundleID, name: h.name)
    }

    /// DOWNLOAD pressed with a link in the field: in Pro Tools the menu opens (nothing is pre-selected,
    /// nothing runs until a pick); elsewhere the file is saved and shown in Finder.
    func downloadPressed() {
        guard !downloading else { NSSound.beep(); return }
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PluginDownload.isLink(link) else {
            show("Paste a YouTube link first.", kind: .error)
            FaceLog.line(token, "download: pressed with no link in the field or on the clipboard")
            return
        }
        if hostIsProTools { downloadMenuOpen.toggle() } else { startDownload(nil) }
    }

    /// A pick from the menu (nil = Save Only): the download starts.
    func startDownload(_ placement: DownloadPlacement?, settings: FaceSettings = .shared) {
        downloadMenuOpen = false
        guard !downloading else { return }
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PluginDownload.isLink(link) else { return }
        if let p = placement { settings.recordPlacement(p) }
        downloading = true
        let token = self.token
        DownloadSend(token: token, url: link, placement: placement, env: bpmEnv,
                     progress: { [weak self] p in self?.show(p, kind: .info, hold: 60) },
                     done: { [weak self] r in
                         guard let self else { return }
                         self.downloading = false
                         if !r.path.isEmpty { settings.recordDownload(r.path) }
                         if r.ok { self.url = "" }
                         self.show(r.message, kind: r.ok ? .ok : .error, detail: r.path.isEmpty ? nil : r.path, hold: r.ok ? 10 : 20)
                     }).start()
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
    /// $BKP_FACE_SUITE moves the settings to another defaults domain (plugin/test.sh: never the user's own).
    static let shared = FaceSettings(defaults: UserDefaults(suiteName: ProcessInfo.processInfo.environment["BKP_FACE_SUITE"] ?? suite))
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
        loadChoices()
    }

    func set(_ a: Accent) {
        let shown = a.readable().accent
        accent = shown
        if a == .amber { defaults?.removeObject(forKey: FaceSettings.key) }
        else { defaults?.set([a.r, a.g, a.b], forKey: FaceSettings.key) }
        FaceLog.line(0, "face: colour \(a.described)" + (shown != a ? " (shown as \(shown.described))" : ""))
    }

    // MARK: the face's other remembered choices (same suite, every Beat Key plug-in on this Mac)

    /// ADVANCED: the harmony column (the view grows wider, never taller, as the app's window does).
    @Published var advanced = false { didSet { save("advanced", advanced) } }
    /// HELP: hovering a control explains it.
    @Published var help = false { didSet { save("helpMode", help) } }
    /// Advanced mode's chord and MATCH TO choices.
    @Published var harmony = HarmonyPrefs() {
        didSet {
            save("chordQuality", harmony.quality.rawValue); save("chordVoicing", harmony.voicing.rawValue)
            save("chordBars", harmony.bars); save("matchKey", harmony.matchKey ?? "")
        }
    }
    /// The DOWNLOAD menu's history (never pre-selected).
    @Published private(set) var placements = DownloadHistory() { didSet { save("downloadPlacements", placements.wires) } }
    /// RECENT ▾: the files DOWNLOAD saved, newest first.
    @Published private(set) var downloads: [String] = [] { didSet { save("recentDownloads", downloads) } }
    static let downloadLimit = 10
    private var loading = false

    private func save(_ key: String, _ value: Any) {
        guard !loading else { return }
        defaults?.set(value, forKey: key)
    }

    /// Reads the choices back (called once from init).
    private func loadChoices() {
        loading = true
        defer { loading = false }
        guard let d = defaults else { return }
        advanced = d.bool(forKey: "advanced")
        help = d.bool(forKey: "helpMode")
        var p = HarmonyPrefs()
        if let q = d.string(forKey: "chordQuality").flatMap(ChordQuality.init(rawValue:)) { p.quality = q }
        if let v = d.string(forKey: "chordVoicing").flatMap(Voicing.init(rawValue:)) { p.voicing = v }
        let bars = d.integer(forKey: "chordBars")
        if ChordClip.barChoices.contains(bars) { p.bars = bars }
        if let m = d.string(forKey: "matchKey"), KeyNames.parse(m) != nil { p.matchKey = m }
        harmony = p
        placements = DownloadHistory(wires: d.stringArray(forKey: "downloadPlacements") ?? [])
        downloads = Array((d.stringArray(forKey: "recentDownloads") ?? []).prefix(FaceSettings.downloadLimit))
    }

    func recordPlacement(_ p: DownloadPlacement) { placements.record(p) }

    func recordDownload(_ path: String) {
        var d = downloads.filter { $0 != path }
        d.insert(path, at: 0)
        downloads = Array(d.prefix(FaceSettings.downloadLimit))
    }
}
