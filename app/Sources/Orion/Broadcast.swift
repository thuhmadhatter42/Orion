import Combine
import CryptoKit
import Foundation

// BROADCAST: what Beat Key tells other apps (Artemis) it is hearing. One chair, one contract.
// Full text: docs/protocol-beatkey-broadcast.md (keep the two in step).
//
// CONTRACT (macOS distributed notifications, name = reverse-DNS, userInfo = property list)
//
//   com.jshriver.orion.reading   Beat Key -> everyone
//     userInfo:
//       source      String   "listen" | "file" | "none"      always present
//       songID      String   opaque id of the song or file   always present ("" when source is "none")
//       key         String   the key IN USE, Auto-Tune's spelling ("Ebm", "F#")   omitted = no key
//       bpm         Double   the BPM as the dial shows it (x2 / x0.5 included)    omitted = no BPM
//       confidence  Double   0...1, the detector's own % for `key`; 0 when the key is a pick the
//                            detector does not list; omitted when there is no key
//     Posted when the reading Beat Key shows changes in any of those values: a new reading, a
//     song change (new songID), a pick set or cleared (key changes), the BPM x2 / x0.5 click, a
//     reading gone (source "none"). Identical consecutive payloads are never posted twice.
//
//   com.jshriver.orion.request   anyone -> Beat Key (no userInfo)
//     Beat Key answers with exactly one `reading` (the current one; source "none" and no key/bpm
//     when there is none). The answer is posted even if nothing changed.
//
//   source "plugin": a Beat Key plug-in's SEND BPM inside Artemis, relayed by PluginSendListener
//     (relayPlugin): bpm only, songID = salted hash of the host process. Not the app's own reading.
//
//   com.jshriver.orion.send / .sent   plug-in <-> app (SEND BPM): BeatKeyShared/PluginSend.swift and
//     PluginSendListener.swift; the full text is in the same doc.
//
//   Never in a payload: a song title, a file name or a path (songID is a salted hash, new each launch).
//   Beat Key not running: nothing is posted and nobody answers.
//
// SCORE (who plays what)
//   The reading itself: PocketState.shownReading (the one place the app's current reading is
//   chosen: Listen's, else the file result paged to, with a picked key pinned). Broadcast is fed
//   ONLY from there: install() subscribes to the same sources the menu bar does and calls feed().
//   No view posts; no second copy of the reading is kept (`last` is the one thing said last).

/// A reading as it goes out (the payload, before it is a dictionary).
struct BroadcastReading: Equatable {
    /// `plugin`: a Beat Key plug-in's SEND BPM inside a host that is not a DAW Beat Key drives (Artemis),
    /// relayed by PluginSendListener. Never fed from the app's own reading; never deduped.
    enum Source: String { case listen, file, none, plugin }
    var source: Source
    var songID: String
    var key: String?
    var bpm: Double?
    var confidence: Double?

    var userInfo: [String: Any] {
        var i: [String: Any] = ["source": source.rawValue, "songID": songID]
        if let key { i["key"] = key }
        if let bpm { i["bpm"] = bpm }
        if let confidence { i["confidence"] = confidence }
        return i
    }

    /// The log line: values only, no names.
    var logText: String {
        "key \(key ?? "-") bpm \(bpm.map { "\($0)" } ?? "-") source \(source.rawValue)"
            + (confidence.map { " conf \(Int(($0 * 100).rounded()))" } ?? "")
            + (songID.isEmpty ? "" : " song \(songID)")
    }
}

final class Broadcast {
    static let shared = Broadcast()
    static let readingName = Notification.Name("com.jshriver.orion.reading")
    static let requestName = Notification.Name("com.jshriver.orion.request")

    /// The wire. Tests pass their own; the app uses `.distributed`.
    struct Transport {
        var post: (Notification.Name, [String: Any]) -> Void
        /// Calls the handler (on the main queue) for every `request`.
        var observeRequests: (@escaping () -> Void) -> Void

        static let distributed = Transport(
            post: { name, info in
                DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info,
                                                                             deliverImmediately: true)
            },
            observeRequests: { handler in
                // the center keeps the observer for the life of the app
                _ = DistributedNotificationCenter.default().addObserver(forName: Broadcast.requestName, object: nil,
                                                                        queue: .main) { _ in handler() }
            })
    }

    private let transport: Transport
    private let now: () -> Date
    private let salt: String
    /// What Artemis was told last = the current reading (every change is posted at once). Nil
    /// until the first feed.
    private var last: BroadcastReading?
    private var listening = false
    private var bag = Set<AnyCancellable>()
    /// Identical payloads not posted, ever / since the last log line, and when that line was.
    private(set) var skipped = 0
    private var pendingSkips = 0
    private var lastSkipLog: Date?
    static let skipLogEvery: TimeInterval = 60

    init(transport: Transport = .distributed, now: @escaping () -> Date = Date.init,
         salt: String = UUID().uuidString) {
        self.transport = transport
        self.now = now
        self.salt = salt
    }

    // MARK: the feed (the one way in)

    /// Called with what the app shows now. Builds the payload from the shown reading and posts it
    /// when it differs from the last one posted.
    func feed(state: ViewState, live: LiveState, page: Pager, factor: TempoFactor, choice: KeyChoice?) {
        let shown = PocketState.shownReading(state, live: live, page: page, choice: choice)
        let next = reading(shown?.result, source: shown?.source, factor: factor)
        guard next != last else {
            skipped += 1
            pendingSkips += 1
            let t = now()
            if lastSkipLog.map({ t.timeIntervalSince($0) >= Broadcast.skipLogEvery }) ?? true {
                AppLog.log("dedupe: \(pendingSkips) identical readings skipped (\(skipped) in all)")
                pendingSkips = 0
                lastSkipLog = t
            }
            return
        }
        last = next
        AppLog.log("post: \(next.logText)")
        transport.post(Broadcast.readingName, next.userInfo)
    }

    /// Subscribes to what the app shows and starts answering requests. Once, from OrionApp.launch.
    func install(engine: Engine, model: FaceplateModel, live: LiveController) {
        guard bag.isEmpty else { return }
        Publishers.CombineLatest(
            Publishers.CombineLatest4(engine.$state, model.$pager, model.$tempoFactor, live.$state),
            SpellingSettings.shared.$manualKey)
            .receive(on: DispatchQueue.main)   // @Published fires before it changes: values come from the sink
            .sink { [weak self] a, choice in
                self?.feed(state: a.0, live: a.3, page: a.1, factor: a.2, choice: choice)
            }
            .store(in: &bag)
        startListening()
        AppLog.log("broadcast on: posting \(Broadcast.readingName.rawValue), answering \(Broadcast.requestName.rawValue)")
    }

    /// A plug-in's SEND BPM in Artemis (plan §S1.5): one `reading` with source "plugin" and the plug-in's
    /// BPM, the contract Artemis's Beat Key button listens to. It does not touch `last` (the app's own
    /// reading, which `request` still answers with). songID = a salted hash of the host process, no name.
    func relayPlugin(bpm: Double, hostPid: Int) {
        let r = BroadcastReading(source: .plugin,
                                 songID: SHA256.hash(data: Data((salt + "|plugin|\(hostPid)").utf8)).prefix(6)
                                    .map { String(format: "%02x", $0) }.joined(),
                                 key: nil, bpm: bpm, confidence: nil)
        AppLog.log("post (plug-in relay): \(r.logText)")
        transport.post(Broadcast.readingName, r.userInfo)
    }

    // MARK: request -> reply

    func startListening() {
        guard !listening else { return }
        listening = true
        transport.observeRequests { [weak self] in self?.answer() }
    }

    /// One `reading` with the current state, deduped never.
    private func answer() {
        let r = last ?? BroadcastReading(source: .none, songID: "")
        AppLog.log("request answered: \(r.logText)")
        transport.post(Broadcast.readingName, r.userInfo)
    }

    // MARK: payload building

    /// An opaque id for a song or file: a salted hash of its identity, never the name.
    func songID(for file: URL) -> String {
        SHA256.hash(data: Data((salt + "|" + file.path).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    func reading(_ r: Result?, source: ShownSource?, factor: TempoFactor) -> BroadcastReading {
        guard let r, let source else { return BroadcastReading(source: .none, songID: "") }
        var out = BroadcastReading(source: source == .listen ? .listen : .file, songID: songID(for: r.file))
        if let k = r.keyInUse {
            if KeyNames.parse(k.name) != nil {
                out.key = k.name
                out.confidence = Double(max(0, min(100, k.percent))) / 100
            } else {
                AppLog.log("ERROR broadcast: key \"\(k.name)\" is not a key; left out")
            }
        }
        if let text = Tempo.text(r, factor: factor) {
            if let v = Double(text), v.isFinite, v > 0 {
                out.bpm = v
            } else {
                AppLog.log("ERROR broadcast: bpm \"\(text)\" is not a tempo; left out")
            }
        }
        return out
    }
}
