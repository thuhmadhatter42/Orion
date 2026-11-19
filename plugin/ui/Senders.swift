import AppKit
import Foundation

// The face's two buttons (plan §S).
//   SEND AUTO-TUNE: the plug-in writes Auto-Key's hand-off itself, through the shared writer
//                   (BeatKeyShared/AutoTuneSend.swift, the app's own code). No app needed.
//   SEND BPM:       the plug-in asks the Beat Key app, the app's Send to DAW drivers set the tempo,
//                   the app answers, the face reads the session tempo back as the proof.
//                   Contract: BeatKeyShared/PluginSend.swift, docs/protocol-beatkey-broadcast.md.
// Every outcome is one log line (bkp_log_send) and one short line on the face. Never silent.

/// What a send ends with, for the face: one short line, a longer detail (tooltip + log), an optional link.
struct SendResult: Equatable {
    var ok: Bool
    var line: String
    var detail: String
    var link: URL? = nil
}

enum AutoTuneButton {
    /// The reference pitch the app would send: the app's own setting (read only, from its domain),
    /// else A = 440.
    static func referencePitch(_ defaults: UserDefaults? = UserDefaults(suiteName: PluginSend.appBundleID)) -> Double {
        guard let v = defaults?.object(forKey: Tuning.defaultsKey) as? Double, v.isFinite else { return Tuning.defaultReference }
        return Tuning.clamp(v)
    }

    /// Writes the key to Auto-Tune's hand-off. `key` = the key in use (Auto-Tune's spelling).
    static func send(token: UInt64, key: String?, reference: Double = referencePitch(),
                     to url: URL = AutoTuneSend.handoffURL) -> SendResult {
        guard let key, KeyNames.parse(key) != nil else {
            let r = SendResult(ok: false, line: "No key yet.", detail: "SEND AUTO-TUNE: no key to send yet; nothing written")
            FaceLog.send(token, what: "AUTO-TUNE", value: key ?? "-", ok: false, outcome: r.detail)
            return r
        }
        let ref = Tuning.refText(reference)
        if AutoTuneSend.write(key: key, referencePitch: reference, to: url) {
            let r = SendResult(ok: true, line: "Auto-Tune ← \(key) · A=\(ref)",
                               detail: "wrote \(url.path) (key \(key), A=\(ref))")
            FaceLog.send(token, what: "AUTO-TUNE", value: key, ok: true, outcome: r.detail)
            return r
        }
        let r = SendResult(ok: false, line: "Auto-Tune hand-off failed. See log.",
                           detail: "could not write \(url.path) (the reason is the line above)")
        FaceLog.send(token, what: "AUTO-TUNE", value: key, ok: false, outcome: r.detail)
        return r
    }
}

/// One SEND BPM press, from the press to the read-back. Lives until it is done, even if the face closes.
final class BPMSend {
    /// The outside world, swappable for tests (plugin/test/face_test.swift).
    struct Env {
        var appURL: () -> URL?
        var appRunning: () -> Bool
        /// Opens the app without bringing it forward; calls back with nil or the reason it failed.
        var launch: (URL, @escaping (String?) -> Void) -> Void
        var post: (Notification.Name, [String: Any]?) -> Void
        var observe: (Notification.Name, @escaping ([AnyHashable: Any]?) -> Void) -> NSObjectProtocol
        var unobserve: (NSObjectProtocol) -> Void
        var sandboxed: () -> Bool
        var host: () -> (bundleID: String, name: String, pid: Int)
        var pluginTimeout: TimeInterval = PluginSend.pluginTimeout
        var launchWait: TimeInterval = PluginSend.launchWait
        /// How long a running app gets to answer the "are you listening" ping before the send goes anyway.
        var pingWait: TimeInterval = 3
        var readBackWait: TimeInterval = 2

        static var live: Env {
            Env(appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: PluginSend.appBundleID) },
                appRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: PluginSend.appBundleID).isEmpty },
                launch: { url, done in
                    let c = NSWorkspace.OpenConfiguration()
                    c.activates = false
                    c.addsToRecentItems = false
                    NSWorkspace.shared.openApplication(at: url, configuration: c) { _, error in
                        DispatchQueue.main.async { done(error.map { "\($0.localizedDescription)" }) }
                    }
                },
                post: { name, info in
                    DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info,
                                                                                 deliverImmediately: true)
                },
                observe: { name, handler in
                    DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { n in
                        handler(n.userInfo)
                    }
                },
                unobserve: { DistributedNotificationCenter.default().removeObserver($0) },
                sandboxed: { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil },
                host: {
                    let b = Bundle.main
                    let name = (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ProcessInfo.processInfo.processName
                    return (b.bundleIdentifier ?? "", name, Int(ProcessInfo.processInfo.processIdentifier))
                })
        }
    }

    private static var running: [ObjectIdentifier: BPMSend] = [:]

    let token: UInt64
    let bpm: Double
    let requestID = UUID().uuidString
    private let env: Env
    private let readHostTempo: () -> Double?
    private let hostTempoBefore: Double?
    private let progress: (String) -> Void
    private let done: (SendResult) -> Void
    private var observers: [NSObjectProtocol] = []
    private var timers: [Timer] = []
    private var finished = false
    private var pinged = false

    init(token: UInt64, bpm: Double, hostTempo: @escaping () -> Double?, env: Env = .live,
         progress: @escaping (String) -> Void, done: @escaping (SendResult) -> Void) {
        self.token = token
        self.bpm = bpm
        self.env = env
        self.readHostTempo = hostTempo
        self.hostTempoBefore = hostTempo()
        self.progress = progress
        self.done = done
    }

    var bpmText: String { PluginSend.bpmText(bpm) }

    /// Main thread.
    func start() {
        BPMSend.running[ObjectIdentifier(self)] = self
        FaceLog.line(token, "send BPM \(bpmText): pressed (request \(requestID.prefix(8)))")
        if env.sandboxed() {
            finish(SendResult(ok: false, line: "Sandboxed host: SEND BPM can't reach the app.",
                              detail: "the host is sandboxed (APP_SANDBOX_CONTAINER_ID set): a distributed notification cannot carry the BPM to the Beat Key app"))
            return
        }
        guard let app = env.appURL() else {
            finish(SendResult(ok: false, line: "SEND BPM needs the Beat Key app.",
                              detail: "the Beat Key app (\(PluginSend.appBundleID)) is not installed; SEND AUTO-TUNE and the reading work without it",
                              link: PluginSend.downloadURL))
            return
        }
        // the app answers `request` with a `reading`: that is how we know it is listening
        observers.append(env.observe(Notification.Name("com.jshriver.orion.reading")) { [weak self] _ in self?.heard() })
        observers.append(env.observe(PluginSend.sentName) { [weak self] info in self?.reply(info) })
        if env.appRunning() {
            ping(for: env.pingWait, launched: false)
        } else {
            progress("Opening Beat Key…")
            FaceLog.line(token, "send BPM \(bpmText): the Beat Key app is not running; opening \(app.path)")
            env.launch(app) { [weak self] err in
                guard let self, !self.finished else { return }
                if let err {
                    self.finish(SendResult(ok: false, line: "Couldn't open Beat Key.", detail: "opening \(app.path) failed: \(err)"))
                } else {
                    self.ping(for: self.env.launchWait, launched: true)
                }
            }
        }
    }

    /// Posts `request` every half second until the app answers or `wait` passes.
    private func ping(for wait: TimeInterval, launched: Bool) {
        let started = Date()
        env.post(Notification.Name("com.jshriver.orion.request"), nil)
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self, !self.finished, !self.pinged else { t.invalidate(); return }
            if Date().timeIntervalSince(started) >= wait {
                t.invalidate()
                if launched {
                    self.finish(SendResult(ok: false, line: "Beat Key didn't start listening.",
                                           detail: "the app was opened but did not answer within \(Int(wait)) s"))
                } else {
                    // a running app that does not answer `request` may still take `send`; the send's own timeout judges
                    FaceLog.line(self.token, "send BPM \(self.bpmText): the app did not answer the ping in \(Int(wait)) s; sending anyway")
                    self.pinged = true
                    self.post()
                }
                return
            }
            self.env.post(Notification.Name("com.jshriver.orion.request"), nil)
        }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func heard() {
        guard !finished, !pinged else { return }
        pinged = true
        post()
    }

    private func post() {
        let h = env.host()
        let req = PluginSend.Request(requestID: requestID, bpm: bpm, hostBundleID: h.bundleID, hostName: h.name, hostPid: h.pid)
        progress("Sending \(bpmText)…")
        FaceLog.line(token, "send BPM \(bpmText): posted to the app (host \(h.bundleID.isEmpty ? h.name : h.bundleID), pid \(h.pid))")
        env.post(PluginSend.sendName, req.userInfo)
        let t = Timer(timeInterval: env.pluginTimeout, repeats: false) { [weak self] _ in
            guard let self, !self.finished else { return }
            self.finish(SendResult(ok: false, line: "Beat Key app didn't answer. Update it?",
                                   detail: "no answer from the Beat Key app in \(Int(self.env.pluginTimeout)) s (an app older than the plug-in does not know SEND BPM)"))
        }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func reply(_ info: [AnyHashable: Any]?) {
        guard !finished, let r = PluginSend.Reply.decode(info), r.requestID == requestID else { return }
        guard r.ok else {
            finish(SendResult(ok: false, line: r.message.isEmpty ? "The DAW didn't take it." : r.message,
                              detail: "the app answered: \(r.message)"))
            return
        }
        readBack(appMessage: r.message, started: Date())
    }

    /// The proof: the session tempo, read from the host, moves to the BPM sent.
    private func readBack(appMessage: String, started: Date) {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, !self.finished else { t.invalidate(); return }
            let now = self.readHostTempo()
            if let now, abs(now - self.bpm) < 0.005 {
                t.invalidate()
                self.finish(SendResult(ok: true, line: "Session tempo \(PluginSend.bpmText(now))",
                                       detail: "the app: \(appMessage); the host now reports \(PluginSend.bpmText(now))"))
            } else if Date().timeIntervalSince(started) >= self.env.readBackWait {
                t.invalidate()
                if let now {
                    self.finish(SendResult(ok: false, line: "Session still \(PluginSend.bpmText(now))",
                                           detail: "the app said: \(appMessage); but the host still reports \(PluginSend.bpmText(now)) after \(self.env.readBackWait) s"))
                } else {
                    self.finish(SendResult(ok: true, line: "Sent \(self.bpmText). Host won't say its tempo.",
                                           detail: "the app: \(appMessage); this host does not report its tempo to plug-ins, so it cannot be read back"))
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func finish(_ r: SendResult) {
        guard !finished else { return }
        finished = true
        timers.forEach { $0.invalidate() }
        timers = []
        observers.forEach(env.unobserve)
        observers = []
        let before = hostTempoBefore.map { " (session was \(PluginSend.bpmText($0)))" } ?? ""
        FaceLog.send(token, what: "BPM", value: bpmText, ok: r.ok, outcome: r.detail + before)
        done(r)
        BPMSend.running[ObjectIdentifier(self)] = nil
    }
}
