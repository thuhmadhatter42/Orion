import Foundation

// SEND BPM from the plug-in, the app's half (plan §S1). The plug-in posts `com.jshriver.orion.send`
// with the BPM and its host; this listener picks the host's DAW and sends through Send to DAW's own
// drivers (DAWSendController.sendQuiet: same queue, same busy rule, no alert), then answers
// `com.jshriver.orion.sent` with the driver's one-line result. Contract: BeatKeyShared/PluginSend.swift;
// full text docs/protocol-beatkey-broadcast.md (keep the three in step).
//
//   host is a DAW Beat Key drives  -> sendQuiet, tempo only (§Q3 default) -> sent(ok, driver's line)
//   host is Artemis                -> Broadcast.relayPlugin (the `reading` Artemis listens to) -> sent(ok)
//   anything else                  -> sent(no, "Beat Key can't set the tempo in <host>.")
//   a bad payload                  -> sent(no, the reason) when it has a requestID, else only logged
//   a driver still busy at PluginSend.appDeadline -> sent(no, "<DAW> didn't answer in 7 s."); its late
//                                     result is logged, never sent twice
// Every request and every answer is a line in beatkey.log ([PluginSendListener]).

final class PluginSendListener {
    static let shared = PluginSendListener()

    struct Transport {
        var post: (Notification.Name, [String: Any]) -> Void
        var observe: (Notification.Name, @escaping ([AnyHashable: Any]?) -> Void) -> Void

        static let distributed = Transport(
            post: { name, info in
                DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info,
                                                                             deliverImmediately: true)
            },
            observe: { name, handler in
                _ = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { n in
                    handler(n.userInfo)
                }
            })
    }

    static let artemisPrefix = "com.jshriver.artemis"

    private let transport: Transport
    private let driverFor: (DAW) -> DAWDriver
    private let relay: (Double, Int) -> Void
    private let deadline: TimeInterval
    private var installed = false

    init(transport: Transport = .distributed, driverFor: @escaping (DAW) -> DAWDriver = DAWDrivers.driver,
         relay: @escaping (Double, Int) -> Void = { Broadcast.shared.relayPlugin(bpm: $0, hostPid: $1) },
         deadline: TimeInterval = PluginSend.appDeadline) {
        self.transport = transport
        self.driverFor = driverFor
        self.relay = relay
        self.deadline = deadline
    }

    /// Once, from OrionApp.launch (beside Broadcast.install).
    func install() {
        guard !installed else { return }
        installed = true
        transport.observe(PluginSend.sendName) { [weak self] info in self?.handle(info) }
        AppLog.log("plug-in sends on: listening for \(PluginSend.sendName.rawValue), answering \(PluginSend.sentName.rawValue)")
    }

    /// One request (main thread).
    func handle(_ info: [AnyHashable: Any]?) {
        let d = PluginSend.Request.decode(info)
        guard let req = d.request else {
            AppLog.log("ERROR plug-in send refused: \(d.refusal ?? "unreadable")")
            if let rid = d.requestID { answer(rid, ok: false, "Beat Key app refused it: \(d.refusal ?? "unreadable").") }
            return
        }
        let bpm = PluginSend.bpmText(req.bpm)
        let host = req.hostBundleID.isEmpty ? req.hostName : req.hostBundleID
        AppLog.log("plug-in send: BPM \(bpm) from \(host) (pid \(req.hostPid), request \(req.requestID.prefix(8)))")

        if req.hostBundleID.lowercased().hasPrefix(PluginSendListener.artemisPrefix) {
            relay(req.bpm, req.hostPid)
            answer(req.requestID, ok: true, "Posted \(bpm) to Artemis.")
            return
        }
        guard let daw = DAW.from(bundleID: req.hostBundleID, name: req.hostName) else {
            answer(req.requestID, ok: false, "Beat Key can't set the tempo in \(req.hostName.isEmpty ? "this host" : req.hostName).")
            return
        }
        var replied = false
        let timer = Timer(timeInterval: deadline, repeats: false) { [weak self] _ in
            guard !replied else { return }
            replied = true
            self?.answer(req.requestID, ok: false, "\(daw.name) didn't answer in \(String(format: "%g", self?.deadline ?? 0)) s.")
        }
        RunLoop.main.add(timer, forMode: .common)
        DAWSendController.sendQuiet(SendPayload(bpm: req.bpm, key: nil), to: daw, driver: driverFor(daw)) { [weak self] o in
            timer.invalidate()
            guard !replied else {
                AppLog.log("plug-in send: \(daw.name) finished after the deadline (\(o.ok ? "ok" : "failed"): \(o.message)); the plug-in was already told")
                return
            }
            replied = true
            let msg = o.permission != nil ? "Allow Accessibility for Beat Key, then send again." : o.message
            self?.answer(req.requestID, ok: o.ok, msg)
        }
    }

    private func answer(_ requestID: String, ok: Bool, _ message: String) {
        AppLog.log("plug-in send answered (request \(requestID.prefix(8))): \(ok ? "ok" : "FAILED"): \(message)")
        transport.post(PluginSend.sentName, PluginSend.Reply(requestID: requestID, ok: ok, message: message).userInfo)
    }
}
