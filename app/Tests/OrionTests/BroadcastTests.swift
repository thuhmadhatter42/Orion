import XCTest
@testable import Orion

/// Broadcast (Broadcast.swift, docs/protocol-beatkey-broadcast.md): what Beat Key tells Artemis.
/// Fed from ONE place (PocketState.shownReading), posts only changed values, answers a request
/// with one reading, never carries a song title or file name.
final class BroadcastTests: XCTestCase {
    final class Wire {
        var posts: [(name: Notification.Name, info: [String: Any])] = []
        var onRequest: (() -> Void)?
        var transport: Broadcast.Transport {
            Broadcast.Transport(post: { [self] n, i in posts.append((n, i)) },
                                observeRequests: { [self] h in onRequest = h })
        }
        var infos: [[String: Any]] { posts.map { $0.info } }
    }

    let wire = Wire()
    var clock = Date(timeIntervalSince1970: 1_000)
    var lines: [String] = []
    lazy var bc = Broadcast(transport: wire.transport, now: { [unowned self] in clock }, salt: "test-salt")

    override func setUp() { super.setUp(); lines = []; AppLog.sink = { [weak self] l in self?.lines.append(l) } }
    override func tearDown() { AppLog.sink = nil; super.tearDown() }

    let file = URL(fileURLWithPath: "/Users/someone/Secret Beats/Private Title.wav")
    func reading(_ keys: [(String, Int)] = [("Ebm", 80), ("F#", 12), ("Bbm", 8)], bpm: String? = "141.98",
                 exact: Double? = 141.98, file: URL? = nil, name: String = "Private Title.wav") -> Result {
        Result(file: file ?? self.file, name: name, bpm: bpm, keys: keys, bpmExact: exact)
    }
    func feedFile(_ r: Result?, factor: TempoFactor = .one, choice: KeyChoice? = nil) {
        bc.feed(state: r.map { .done($0) } ?? .idle, live: .off, page: Pager(), factor: factor, choice: choice)
    }
    func pin(_ key: String, of r: Result) -> KeyChoice? {
        let s = SpellingSettings(); s.setManualKey(key, of: r, from: .topKeys); return s.manualKey
    }

    // MARK: the contract's names

    func testNamesAreTheProtocolsNames() {
        XCTAssertEqual(Broadcast.readingName.rawValue, "com.jshriver.orion.reading")
        XCTAssertEqual(Broadcast.requestName.rawValue, "com.jshriver.orion.request")
    }

    // MARK: payload building

    func testFileReadingPayload() {
        feedFile(reading())
        XCTAssertEqual(wire.posts.count, 1)
        XCTAssertEqual(wire.posts[0].name, Broadcast.readingName)
        let i = wire.infos[0]
        XCTAssertEqual(i["key"] as? String, "Ebm")
        XCTAssertEqual(i["bpm"] as? Double, 141.98)
        XCTAssertEqual(i["source"] as? String, "file")
        XCTAssertEqual(i["confidence"] as? Double, 0.8)
        XCTAssertFalse((i["songID"] as? String ?? "").isEmpty)
        XCTAssertEqual(Set(i.keys), ["key", "bpm", "source", "songID", "confidence"])
    }

    func testListenReadingSaysListen() {
        let r = reading(file: LiveSession.songFile(3), name: "Listen")
        bc.feed(state: .idle, live: .reading(r), page: Pager(), factor: .one, choice: nil)
        XCTAssertEqual(wire.infos.last?["source"] as? String, "listen")
    }

    func testBpmWithoutExactUsesTheAnalyzersNumber() {
        feedFile(reading(bpm: "142.0", exact: nil))
        XCTAssertEqual(wire.infos[0]["bpm"] as? Double, 142.0)
    }

    func testTempoFactorIsWhatTheDialShows() {
        feedFile(reading(), factor: .double)
        XCTAssertEqual(wire.infos[0]["bpm"] as? Double, 283.96)
    }

    func testKeyOnlyAndBpmOnlyReadingsOmitTheMissingKeys() {
        feedFile(reading([], bpm: "120.0", exact: nil))
        XCTAssertNil(wire.infos[0]["key"]); XCTAssertNil(wire.infos[0]["confidence"])
        XCTAssertEqual(wire.infos[0]["bpm"] as? Double, 120)
        feedFile(reading(bpm: nil, exact: nil))
        XCTAssertNil(wire.infos[1]["bpm"])
        XCTAssertEqual(wire.infos[1]["key"] as? String, "Ebm")
    }

    func testNoReadingIsSourceNone() {
        feedFile(nil)
        let i = wire.infos[0]
        XCTAssertEqual(i["source"] as? String, "none")
        XCTAssertNil(i["key"]); XCTAssertNil(i["bpm"]); XCTAssertNil(i["confidence"])
        XCTAssertEqual(i["songID"] as? String, "")
    }

    func testPayloadIsAPropertyListWithNoNamesOrPaths() {
        feedFile(reading())
        let i = wire.infos[0]
        XCTAssertTrue(PropertyListSerialization.propertyList(i, isValidFor: .binary))
        let text = "\(i)"
        for secret in ["Private Title", "Secret Beats", "someone", ".wav", "/Users"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    func testSongIDIsOpaqueStablePerSongAndDifferentBetweenSongs() {
        let other = reading(file: URL(fileURLWithPath: "/x/Other.wav"), name: "Other.wav")
        feedFile(reading()); feedFile(other); feedFile(reading(bpm: "100.0", exact: 100))
        let ids = wire.infos.map { $0["songID"] as? String ?? "" }
        XCTAssertEqual(ids[0], ids[2])                  // same song, a new BPM: same id
        XCTAssertNotEqual(ids[0], ids[1])
        let mine = Broadcast(transport: Wire().transport, salt: "another launch")
        XCTAssertNotEqual(mine.songID(for: file), ids[0])
    }

    // MARK: the pin (what Artemis gets changes)

    func testPinnedKeyIsTheKeyBroadcastWithTheDetectorsOwnPercent() {
        let r = reading()
        feedFile(r, choice: pin("F#", of: r))
        XCTAssertEqual(wire.infos[0]["key"] as? String, "F#")
        XCTAssertEqual(wire.infos[0]["confidence"] as? Double, 0.12)
    }

    func testPinnedKeyTheDetectorDoesNotListHasConfidenceZero() {
        let r = reading()
        feedFile(r, choice: pin("Am", of: r))
        XCTAssertEqual(wire.infos[0]["key"] as? String, "Am")
        XCTAssertEqual(wire.infos[0]["confidence"] as? Double, 0)
    }

    func testSettingAndClearingAPinEachPostOnce() {
        let r = reading()
        feedFile(r)                                     // detector's #1
        feedFile(r, choice: pin("F#", of: r))           // pin set
        feedFile(r)                                     // pin cleared
        XCTAssertEqual(wire.infos.compactMap { $0["key"] as? String }, ["Ebm", "F#", "Ebm"])
    }

    // MARK: dedupe

    func testIdenticalConsecutivePayloadsPostOnce() {
        feedFile(reading()); feedFile(reading()); feedFile(reading())
        XCTAssertEqual(wire.posts.count, 1)
        XCTAssertEqual(bc.skipped, 2)
    }

    func testAChangedValuePostsAgain() {
        feedFile(reading()); feedFile(reading(bpm: "100.0", exact: 100))
        XCTAssertEqual(wire.posts.count, 2)
    }

    func testANewSongWithTheSameKeyAndBpmPosts() {
        feedFile(reading()); feedFile(reading(file: URL(fileURLWithPath: "/x/Next.wav"), name: "Next.wav"))
        XCTAssertEqual(wire.posts.count, 2)
    }

    func testAChangeInTheListenSongPosts() {
        let a = reading(file: LiveSession.songFile(1), name: "Listen")
        let b = reading(file: LiveSession.songFile(2), name: "Listen")
        bc.feed(state: .idle, live: .reading(a), page: Pager(), factor: .one, choice: nil)
        bc.feed(state: .idle, live: .reading(b), page: Pager(), factor: .one, choice: nil)
        XCTAssertEqual(wire.posts.count, 2)
    }

    func testListenStoppingPostsNone() {
        let a = reading(file: LiveSession.songFile(1), name: "Listen")
        bc.feed(state: .idle, live: .locked(a), page: Pager(), factor: .one, choice: nil)
        bc.feed(state: .idle, live: .off, page: Pager(), factor: .one, choice: nil)
        XCTAssertEqual(wire.infos.map { $0["source"] as? String }, ["listen", "none"])
    }

    // MARK: request -> reply

    func testRequestIsAnsweredWithTheCurrentReadingEvenIfUnchanged() {
        bc.startListening()
        feedFile(reading())
        wire.onRequest?()
        XCTAssertEqual(wire.posts.count, 2)
        XCTAssertEqual(wire.posts[1].name, Broadcast.readingName)
        XCTAssertEqual(wire.infos[1]["key"] as? String, "Ebm")
        XCTAssertEqual(wire.infos[1]["bpm"] as? Double, 141.98)
        wire.onRequest?()
        XCTAssertEqual(wire.posts.count, 3)             // every request gets its answer, never deduped
        XCTAssertEqual(bc.skipped, 0)
    }

    func testRequestWithNoReadingGetsSourceNone() {
        bc.startListening()
        wire.onRequest?()
        XCTAssertEqual(wire.posts.count, 1)
        XCTAssertEqual(wire.infos[0]["source"] as? String, "none")
        XCTAssertNil(wire.infos[0]["key"]); XCTAssertNil(wire.infos[0]["bpm"])
    }

    func testAReplyDoesNotCountAsTheLastPost() {
        bc.startListening()
        feedFile(reading()); wire.onRequest?(); feedFile(reading())
        XCTAssertEqual(wire.posts.count, 2)             // the feed's repeat is still a dedupe skip
        XCTAssertEqual(bc.skipped, 1)
    }

    // MARK: logging

    func testEveryPostAndRequestIsLoggedWithoutNames() {
        bc.startListening()
        feedFile(reading()); wire.onRequest?()
        let log = lines.filter { $0.hasPrefix("[Broadcast]") }.joined(separator: "\n")
        XCTAssertTrue(log.contains("post: key Ebm bpm 141.98 source file"), log)
        XCTAssertTrue(log.contains("request answered: key Ebm bpm 141.98 source file"), log)
        for secret in ["Private Title", "Secret Beats", ".wav"] { XCTAssertFalse(log.contains(secret), secret) }
    }

    func testDedupeSkipsAreCountedAndLoggedAtMostOncePerMinute() {
        func skipLines() -> [String] { lines.filter { $0.contains("identical readings skipped") } }
        feedFile(reading())                                 // posts
        for _ in 0..<5 { feedFile(reading()) }              // 5 skips at t = 0: the first one logs
        XCTAssertEqual(skipLines().count, 1)
        XCTAssertTrue(skipLines()[0].contains("1 identical"), skipLines()[0])
        clock += 30; feedFile(reading())
        XCTAssertEqual(skipLines().count, 1)                // inside the minute: counted, not logged
        clock += 31; feedFile(reading())
        XCTAssertEqual(skipLines().count, 2)
        XCTAssertTrue(skipLines()[1].contains("6 identical"), skipLines()[1])   // 4 + 1 + 1 since the first log
        XCTAssertEqual(bc.skipped, 7)
    }

    func testAnUnusableValueIsLeftOutAndLogged() {
        feedFile(reading(bpm: "nan", exact: .nan))
        XCTAssertNil(wire.infos[0]["bpm"])
        XCTAssertTrue(lines.contains { $0.contains("ERROR") && $0.contains("bpm") })
    }

    // MARK: the one feed point

    func testFeedPointIsTheShownReading() {
        // Broadcast reads PocketState.shownReading, the same reading Send / Auto-Tune / MIDI use.
        let rs = [reading(), reading(bpm: "90.0", exact: 90, file: URL(fileURLWithPath: "/x/B.wav"), name: "B.wav")]
        var pager = Pager(); pager.reset(count: 2); pager.previous()
        bc.feed(state: .analyzed(rs), live: .off, page: pager, factor: .one, choice: nil)
        XCTAssertEqual(wire.infos[0]["bpm"] as? Double, 141.98)
        XCTAssertEqual(PocketState.shownReading(.analyzed(rs), live: .off, page: pager)?.source, .file)
    }

    /// install() wiring: the real Engine / FaceplateModel / LiveController / SpellingSettings feed it.
    func testInstalledPipelinePostsNewReadingsAndPinChanges() {
        let engine = Engine()
        let model = FaceplateModel()
        let live = LiveController(settings: LiveSettings(defaults: UserDefaults(suiteName: "bc-\(UUID())")!),
                                  launch: { _, _, _ in nil }, makeCapture: { _ in nil })
        let shared = SpellingSettings.shared
        shared.manualKey = nil
        defer { shared.manualKey = nil }
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        bc.install(engine: engine, model: model, live: live)
        pump()
        XCTAssertEqual(wire.infos.last?["source"] as? String, "none")        // launch: nothing yet
        let r = reading()
        engine.state = .done(r)
        pump()
        XCTAssertEqual(wire.infos.last?["key"] as? String, "Ebm")
        shared.setManualKey("F#", of: r, from: .topKeys)
        pump()
        XCTAssertEqual(wire.infos.last?["key"] as? String, "F#")             // pin set posts
        shared.clearManualKey(of: r, from: .topKeys)
        pump()
        XCTAssertEqual(wire.infos.last?["key"] as? String, "Ebm")            // pin cleared posts
        model.tempoFactor = .half
        pump()
        XCTAssertEqual(wire.infos.last?["bpm"] as? Double, 70.99)           // the x0.5 click posts
        wire.onRequest?()
        XCTAssertEqual(wire.infos.last?["key"] as? String, "Ebm")            // request answered by the same pipeline
        XCTAssertEqual(wire.posts.count, 6)                                  // none, Ebm, F#, Ebm, 70.99, reply
    }

    // MARK: the real center

    func testRealDistributedCenterRoundTrip() {
        let name = Notification.Name("com.jshriver.orion.test-\(UUID().uuidString)")
        let got = expectation(description: "delivered")
        let o = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { n in
            XCTAssertEqual(n.userInfo?["key"] as? String, "Cm"); got.fulfill()
        }
        defer { DistributedNotificationCenter.default().removeObserver(o) }
        Broadcast.Transport.distributed.post(name, ["key": "Cm", "source": "file"])
        wait(for: [got], timeout: 5)
    }
}
