import XCTest
@testable import Orion

/// SEND BPM from the plug-in, the app's half (PluginSendListener + DAWSendController.sendQuiet).
/// A fake transport and fake drivers: nothing is posted to other apps, no DAW is touched.
final class PluginSendTests: XCTestCase {
    final class Wire {
        var posts: [(Notification.Name, [String: Any])] = []
        var handler: (([AnyHashable: Any]?) -> Void)?
        var transport: PluginSendListener.Transport {
            PluginSendListener.Transport(post: { self.posts.append(($0, $1)) },
                                         observe: { _, h in self.handler = h })
        }
        var replies: [PluginSend.Reply] {
            posts.filter { $0.0 == PluginSend.sentName }.compactMap { PluginSend.Reply.decode($0.1) }
        }
    }

    struct FakeDriver: DAWDriver {
        let daw: DAW
        var delay: TimeInterval = 0
        var result: Swift.Result<String, Error> = .success("tempo set")
        static var sent: [SendPayload] = []
        func send(_ p: SendPayload) throws -> String {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            FakeDriver.sent.append(p)
            return try result.get()
        }
    }

    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        FakeDriver.sent = []
        lines = []
        AppLog.sink = { [weak self] l in self?.lines.append(l) }
    }

    override func tearDown() {
        AppLog.sink = nil
        super.tearDown()
    }

    private func request(_ id: String, bpm: Double = 141.98, bundle: String = "com.ableton.live", name: String = "Live") -> [AnyHashable: Any] {
        PluginSend.Request(requestID: id, bpm: bpm, hostBundleID: bundle, hostName: name, hostPid: 7).userInfo
    }

    private func wait(_ secs: Double, until: () -> Bool) {
        let end = Date().addingTimeInterval(secs)
        while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testDAWHostSendsTempoOnlyThroughTheDriverAndAnswers() {
        let w = Wire()
        let l = PluginSendListener(transport: w.transport, driverFor: { FakeDriver(daw: $0) })
        l.install()
        w.handler?(request("r1"))
        wait(3) { !w.replies.isEmpty }
        XCTAssertEqual(w.replies, [PluginSend.Reply(requestID: "r1", ok: true, message: "tempo set")])
        XCTAssertEqual(FakeDriver.sent, [SendPayload(bpm: 141.98, key: nil)], "tempo only (§Q3 default)")
        XCTAssertTrue(lines.contains { $0.contains("plug-in send: BPM 141.98 from com.ableton.live") })
        XCTAssertTrue(lines.contains { $0.contains("plug-in send answered (request r1): ok: tempo set") })
    }

    func testHostFoundByNameWhenNoBundleID() {
        let w = Wire()
        var daws: [DAW] = []
        let l = PluginSendListener(transport: w.transport, driverFor: { daws.append($0); return FakeDriver(daw: $0) })
        l.handle(request("r2", bundle: "", name: "Logic Pro"))
        wait(3) { !w.replies.isEmpty }
        XCTAssertEqual(daws, [.logic])
        XCTAssertEqual(w.replies.first?.ok, true)
    }

    func testUnknownHostIsRefusedPlainly() {
        let w = Wire()
        let l = PluginSendListener(transport: w.transport, driverFor: { XCTFail("no driver for an unknown host"); return FakeDriver(daw: $0) })
        l.handle(request("r3", bundle: "com.example.host", name: "Example Host"))
        XCTAssertEqual(w.replies, [PluginSend.Reply(requestID: "r3", ok: false, message: "Beat Key can't set the tempo in Example Host.")])
    }

    func testArtemisGetsTheReadingRelay() {
        let w = Wire()
        var relayed: [(Double, Int)] = []
        let l = PluginSendListener(transport: w.transport, driverFor: { FakeDriver(daw: $0) }, relay: { relayed.append(($0, $1)) })
        l.handle(request("r4", bpm: 128, bundle: "com.jshriver.artemis", name: "Artemis"))
        XCTAssertEqual(relayed.count, 1)
        XCTAssertEqual(relayed.first?.0, 128)
        XCTAssertEqual(relayed.first?.1, 7)
        XCTAssertEqual(w.replies, [PluginSend.Reply(requestID: "r4", ok: true, message: "Posted 128.00 to Artemis.")])
    }

    func testRelayPostsAPluginReadingWithoutTouchingTheAppsReading() {
        var posts: [[String: Any]] = []
        let b = Broadcast(transport: Broadcast.Transport(post: { _, i in posts.append(i) }, observeRequests: { _ in }), salt: "s")
        b.relayPlugin(bpm: 128, hostPid: 7)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?["source"] as? String, "plugin")
        XCTAssertEqual(posts.first?["bpm"] as? Double, 128)
        XCTAssertNil(posts.first?["key"])
        XCTAssertEqual((posts.first?["songID"] as? String)?.count, 12)
    }

    func testBadPayloadAnsweredWhenItHasARequestID() {
        let w = Wire()
        let l = PluginSendListener(transport: w.transport, driverFor: { FakeDriver(daw: $0) })
        l.handle(["requestID": "r5", "proto": 1, "bpm": 5000.0])
        XCTAssertEqual(w.replies.first?.ok, false)
        XCTAssertTrue(w.replies.first?.message.contains("is not a tempo") ?? false)
        l.handle(["bpm": 120.0])   // no requestID: nobody to answer
        XCTAssertEqual(w.replies.count, 1)
        XCTAssertTrue(lines.contains { $0.contains("ERROR plug-in send refused: no requestID") })
    }

    func testBusyRefusesTheSecondSend() {
        let w = Wire()
        let l = PluginSendListener(transport: w.transport, driverFor: { FakeDriver(daw: $0, delay: 0.4) })
        l.handle(request("a"))
        l.handle(request("b"))
        wait(3) { w.replies.count == 2 }
        XCTAssertEqual(w.replies.first { $0.requestID == "b" }, PluginSend.Reply(requestID: "b", ok: false, message: "Beat Key is already sending. Try again."))
        XCTAssertEqual(w.replies.first { $0.requestID == "a" }?.ok, true)
    }

    func testAppSideDeadlineAnswersOnceAndLogsTheLateResult() {
        let w = Wire()
        let l = PluginSendListener(transport: w.transport, driverFor: { FakeDriver(daw: $0, delay: 0.5) }, deadline: 0.15)
        l.handle(request("slow"))
        wait(3) { lines.contains { $0.contains("finished after the deadline") } }
        XCTAssertEqual(w.replies, [PluginSend.Reply(requestID: "slow", ok: false, message: "Ableton Live didn't answer in 0.15 s.")])
        XCTAssertTrue(lines.contains { $0.contains("finished after the deadline (ok: tempo set)") })
    }

    func testDriverErrorGoesBackAsTheMessage() {
        let w = Wire()
        let l = PluginSendListener(transport: w.transport,
                                   driverFor: { FakeDriver(daw: $0, result: .failure(DAWError("Live's Remote Script is not on."))) })
        l.handle(request("e"))
        wait(3) { !w.replies.isEmpty }
        XCTAssertEqual(w.replies, [PluginSend.Reply(requestID: "e", ok: false, message: "Live's Remote Script is not on.")])
    }
}
