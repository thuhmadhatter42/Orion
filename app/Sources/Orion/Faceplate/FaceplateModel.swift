import Combine
import Foundation
import UniformTypeIdentifiers

extension Faceplate {
    /// The prompt to show: only while the link in the field is the one that asked for it.
    static func loginPrompt(_ state: ViewState, url: String) -> LoginPrompt? {
        guard case .needsLogin(let p) = state,
              url.trimmingCharacters(in: .whitespacesAndNewlines) == p.url else { return nil }
        return p
    }
}

/// UI state that is not the engine's: the field, focus, drag hover, paging.
final class FaceplateModel: ObservableObject {
    @Published var url = ""
    @Published var fieldFocused = false
    /// Audio chosen with the Open Audio... field, waiting for FIND KEY/BPM.
    @Published var picked: [URL] = []
    @Published var pickFocused = false
    @Published var dropTargeted = false
    @Published var pager = Pager()
    @Published var lastAction: LastAction = .download
    /// The BPM click's x1 / x2 / x0.5; back to x1 whenever another reading comes up.
    @Published var tempoFactor: TempoFactor = .one
    /// ORION_FAKE_STATE=drop pins the drag highlight for screenshots.
    @Published var pinnedDrop = false

    private var songWatch: AnyCancellable?

    /// Listen's songs: every song change (Listen on or off, New Song, a gap, a boundary, the
    /// player's title) puts the tempo factor back to x1. The one place a live song resets it.
    func follow(_ live: LiveController) {
        songWatch = live.$songChange.dropFirst().sink { [weak self] c in self?.songChanged(c) }
    }

    /// One log line per song change: what changed it, and what it cleared. A key picked for the
    /// song that ended no longer applies (KeyChoice.matches: it holds that song's identity).
    func songChanged(_ c: LiveSongChange, choice: KeyChoice? = SpellingSettings.shared.manualKey) {
        func name(_ u: URL?) -> String { u.map { $0.lastPathComponent } ?? "off" }
        var line = "listen: song \(name(c.from)) -> \(name(c.to)) (\(c.why))"
        if let k = choice, let from = c.from, k.file == from {
            line += " · manual key \(KeyChoice.keyName(k.pitchClass, minor: k.minor)) cleared"
        }
        if tempoFactor != .one {
            line += " · tempo factor \(tempoFactor.label ?? "") back to x1"
            tempoFactor = .one
        }
        AppLog.log(line)
    }
}

/// ORION_FAKE_STATE=needs-login|needs-login-off|idle|working|done|drop|error|lit|multi|picked|picked-multi|eperm|
/// analyze-error|doctor-working|doctor-ok|doctor-fixed|doctor-failed pins the faceplate for screenshots (no Python).
/// needs-login-off = the fallback readout (YouTubeLogin.inApp off).
enum FakeState {
    static func apply(_ name: String, engine: Engine, model: FaceplateModel) {
        let dl = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        switch name {
        case "idle":
            engine.state = .idle
        case "working":
            model.url = "https://www.youtube.com/watch?v=xxxxxxxxxxx"
            engine.state = .working(stage: "analyzing")
        case "done":
            let name = "Track Title (142.0 BPM Cm Eb Gm).mp3"
            engine.state = .done(Result(file: dl.appendingPathComponent(name), name: name, bpm: "142.0",
                                        keys: [("Cm", 64), ("Eb", 18), ("Gm", 9)], tuningCents: 12,
                                        chroma: [1.0, 0.08, 0.42, 0.81, 0.06, 0.37, 0.1, 0.93, 0.62, 0.05, 0.48, 0.12]))
        case "drop":
            model.pinnedDrop = true
        case "error":
            model.url = "https://youtu.be/xxxxxxxxxxx"
            engine.state = .failed("That video is private or was removed.")
        case "multi":   // three dropped files, paged with the arrow keys
            model.lastAction = .analyze
            let rs = [("Beat A.wav", "90.0", "Am"), ("Beat B.wav", "120.0", "F#m"), ("Beat C.wav", "142.0", "Cm")]
                .map { n, b, k in Result(file: dl.appendingPathComponent(n), name: n, bpm: b,
                                         keys: [(k, 61), ("Eb", 18), ("Gm", 9)]) }
            engine.state = .analyzed(rs)
        case "needs-login", "needs-login-off", "login-window":
            if name == "needs-login-off" { YouTubeLogin.inApp = false }
            model.url = "https://www.youtube.com/watch?v=xxxxxxxxxxx"
            engine.state = .needsLogin(LoginPrompt(url: model.url, reason: "age"))
        case "lit":
            model.url = "https://www.youtube.com/watch?v=xxxxxxxxxxx"
        case "picked":
            model.picked = [dl.appendingPathComponent("Beat A.wav")]
        case "picked-multi":
            model.picked = ["Beat A.wav", "Beat B.wav", "Beat C.wav"].map { dl.appendingPathComponent($0) }
        case "eperm":
            model.url = "https://youtu.be/xxxxxxxxxxx"
            engine.state = .failed("Download failed: [Errno 1] Operation not permitted: '/Users/x/Downloads'")
        case "analyze-error":
            model.lastAction = .analyze
            engine.state = .failed("The helper stopped unexpectedly (exit 9).")
        case "doctor-working":
            engine.state = .working(stage: "doctor-ffmpeg")
        case "doctor-ok":
            engine.state = .doctor(DoctorReport(outcome: .ok, title: "DOCTOR OK",
                                                line: "YT-DLP 2026.10.26 · ALL CHECKS PASSED"))
        case "doctor-fixed":
            engine.state = .doctor(DoctorReport(outcome: .fixed, title: "DOCTOR FIXED IT",
                                                line: "RESTORED YT-DLP · YT-DLP 2026.10.26"))
        case "doctor-failed":
            engine.state = .doctor(DoctorReport(outcome: .failed, title: "DOCTOR FOUND A PROBLEM",
                                                line: Doctor.permissionHint.uppercased()))
        default:
            break
        }
    }
}
