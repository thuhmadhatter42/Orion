import XCTest
@testable import Orion

/// Drop / open / Dock files: ONE entry (Intake.receive), one FIFO queue in Engine while a job runs.
final class DropQueueTests: XCTestCase {
    func rt() -> Runtime {
        Runtime(root: URL(fileURLWithPath: "/R/runtime"), arch: "arm64",
                support: URL(fileURLWithPath: "/S/Orion"), osMajor: 14)
    }
    func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    func waitLaunch(_ f: FakeLauncher, _ n: Int) {
        let deadline = Date().addingTimeInterval(5)
        while f.launches.count < n && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    func u(_ n: String) -> URL { URL(fileURLWithPath: "/music/\(n)") }
    func line(_ n: String, bpm: String? = "100.0") -> String {
        let b = bpm.map { "\"\($0)\"" } ?? "null"
        return #"{"stage":"analyzed","file":"/music/\#(n)","name":"\#(n)","bpm":\#(b),"keys":[]}"#
    }
    func args(_ f: FakeLauncher, _ i: Int) -> [String] { Array(f.launches[i].drop(while: { $0 != "analyze" })) }
    var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Orion")
    }

    // MARK: Engine queue

    func testFilesArrivingWhileADownloadRunsAreQueuedThenAnalysedWhenItEnds() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), jobs: f)
        e.download("https://a"); waitLaunch(f, 1)
        e.submit([u("a.wav"), u("b.wav")])
        XCTAssertEqual(e.queued, 2)
        spin(); XCTAssertEqual(f.launches.count, 1, "never launched while busy")
        f.onLine?(#"{"stage":"done","file":"/d.mp3","name":"d.mp3","bpm":"90.0","keys":[["Am",50]]}"#)
        f.onExit?(0)
        waitLaunch(f, 2)
        XCTAssertEqual(args(f, 1), ["analyze", "/music/a.wav", "/music/b.wav"])
        XCTAssertEqual(e.queued, 0)
        f.onLine?(line("a.wav")); f.onLine?(line("b.wav")); f.onExit?(0); spin()
        guard case .analyzed(let rs) = e.state else { return XCTFail("\(e.state)") }
        XCTAssertEqual(rs.map(\.name), ["a.wav", "b.wav"])
    }

    func testIdleSubmitStartsAtOnce() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), jobs: f)
        e.submit([u("a.wav")]); waitLaunch(f, 1)
        XCTAssertEqual(args(f, 0), ["analyze", "/music/a.wav"])
        XCTAssertEqual(e.queued, 0)
    }

    func testQueueIsFIFOAndAllResultsPageTogether() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), jobs: f)
        e.submit([u("1.wav")]); waitLaunch(f, 1)
        e.submit([u("2.wav")]); e.submit([u("3.wav"), u("4.wav")])
        XCTAssertEqual(e.queued, 3)
        f.onLine?(line("1.wav")); f.onExit?(0)
        waitLaunch(f, 2)
        XCTAssertEqual(args(f, 1), ["analyze", "/music/2.wav", "/music/3.wav", "/music/4.wav"])
        XCTAssertEqual(e.state, .working(stage: "analyzing"), "no idle flash between queued jobs")
        f.onLine?(line("2.wav")); f.onLine?(line("3.wav")); f.onLine?(line("4.wav")); f.onExit?(0); spin()
        guard case .analyzed(let rs) = e.state else { return XCTFail("\(e.state)") }
        XCTAssertEqual(rs.map(\.name), ["1.wav", "2.wav", "3.wav", "4.wav"], "one pager: N OF M")
        XCTAssertNil(e.note)
    }

    func testDuplicatePathsAreDroppedFromQueueAndFromTheRunningJob() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), jobs: f)
        e.submit([u("a.wav"), u("a.wav")]); waitLaunch(f, 1)
        XCTAssertEqual(args(f, 0), ["analyze", "/music/a.wav"], "twice in one drop = once")
        e.submit([u("a.wav"), u("b.wav")])          // a is already running
        e.submit([u("b.wav"), u("c.wav"), u("c.wav")])
        XCTAssertEqual(e.queued, 2)
        f.onLine?(line("a.wav")); f.onExit?(0); waitLaunch(f, 2)
        XCTAssertEqual(args(f, 1), ["analyze", "/music/b.wav", "/music/c.wav"])
    }

    func testAFailedFileInTheQueueSurfacesAsAFailedResult() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), jobs: f)
        e.submit([u("1.wav")]); waitLaunch(f, 1)
        e.submit([u("2.wav")])
        f.onLine?(line("1.wav")); f.onExit?(0); waitLaunch(f, 2)
        f.onExit?(1); spin()                          // helper died on the queued file, no result
        guard case .analyzed(let rs) = e.state else { return XCTFail("\(e.state)") }
        XCTAssertEqual(rs.map(\.name), ["1.wav", "2.wav"], "the good reading is kept")
        XCTAssertNil(rs[1].bpm)
        XCTAssertNotNil(Engine.failureNote(e.state), "the existing failed-result path names it")
    }

    func testFailureOfTheMiddleJobDoesNotStopTheRestOfTheQueue() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), jobs: f)
        e.submit([u("1.wav")]); waitLaunch(f, 1)
        e.submit([u("2.wav")])
        f.onExit?(1)                                   // job 1 dies without a result
        waitLaunch(f, 2)
        XCTAssertEqual(args(f, 1), ["analyze", "/music/2.wav"])
        f.onLine?(line("2.wav")); f.onExit?(0); spin()
        guard case .analyzed(let rs) = e.state else { return XCTFail("\(e.state)") }
        XCTAssertEqual(rs.map(\.name), ["1.wav", "2.wav"])
        XCTAssertNil(rs[0].bpm); XCTAssertNotNil(rs[1].bpm)
    }

    func testQueueEventsAreLoggedWithCountsNotNames() {
        var lines: [String] = []
        AppLog.sink = { lines.append($0) }
        defer { AppLog.sink = nil }
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), jobs: f)
        e.download("https://a"); waitLaunch(f, 1)
        e.submit([u("secret-name.wav"), u("secret-name.wav"), u("b.wav")])
        f.onLine?(#"{"stage":"done","file":"/d.mp3","name":"d.mp3","bpm":"90.0","keys":[]}"#); f.onExit?(0)
        waitLaunch(f, 2)
        let q = lines.filter { $0.contains("queue") }
        XCTAssertTrue(q.contains { $0.contains("added 2") && $0.contains("size 2") && $0.contains("1 duplicate") }, "\(q)")
        XCTAssertTrue(q.contains { $0.contains("start") && $0.contains("2 file") }, "\(q)")
        XCTAssertFalse(q.contains { $0.contains("secret-name") })
    }

    // MARK: folders

    func testFoldersExpandOneLevelWithTheAudioFilter() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("orion-drop-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("deeper")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for n in ["b.wav", "a.mp3", "notes.pdf", ".hidden.wav", "deeper/c.wav"] {
            fm.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data([0]))
        }
        let single = fm.temporaryDirectory.appendingPathComponent("orion-single-\(UUID().uuidString).wav")
        fm.createFile(atPath: single.path, contents: Data([0]))
        defer { try? fm.removeItem(at: single) }
        let got = Faceplate.audioFiles(Faceplate.expandFolders([dir, single])).map(\.lastPathComponent)
        XCTAssertEqual(Array(got.prefix(2)), ["a.mp3", "b.wav"], "one level, sorted, hidden and non-audio left out")
        XCTAssertEqual(got.count, 3)
        XCTAssertEqual(got.last, single.lastPathComponent, "order of the drop is kept")
        XCTAssertFalse(got.contains("c.wav"))
    }

    // MARK: the one entry point

    func testEveryDropOpenAndDockPathIsIntakeReceive() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("orion-entry-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir); Intake.handler = nil; AppLog.sink = nil }
        for n in ["a.wav", "b.pdf"] { fm.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data([0])) }
        var got: [[String]] = []
        Intake.handler = { files in got.append(files.map { $0.lastPathComponent }); return true }
        var lines: [String] = []
        AppLog.sink = { lines.append($0) }

        // a drop of providers (window / pocket / Mini) ...
        let providers = ["a.wav", "b.pdf"].map { NSItemProvider(object: dir.appendingPathComponent($0) as NSURL) }
        XCTAssertTrue(Intake.drop(providers, via: "window"))
        let deadline = Date().addingTimeInterval(5)
        while got.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(got.first, ["a.wav"])
        // ... and the Dock icon / Open With arrive at the same function
        XCTAssertTrue(Intake.receive([dir.appendingPathComponent("a.wav")], via: "dock"))
        XCTAssertEqual(got.count, 2)
        XCTAssertTrue(lines.contains { $0.contains("intake via window: 2 item(s), 1 audio, 1 skipped") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("intake via dock") })
        XCTAssertFalse(lines.contains { $0.contains("a.wav") }, "counts only, never names")
        // nothing audio: refused loudly, not silently
        XCTAssertFalse(Intake.receive([dir.appendingPathComponent("b.pdf")], via: "pocket"))
        XCTAssertTrue(lines.contains { $0.contains("intake via pocket: 1 item(s), 0 audio, 1 skipped") })
    }

    func testFilesThatArriveBeforeTheWindowAllWait() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("orion-wait-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir); Intake.handler = nil }
        for n in ["a.wav", "b.wav"] { fm.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data([0])) }
        Intake.handler = nil
        _ = Intake.receive([dir.appendingPathComponent("a.wav")], via: "open with")
        _ = Intake.receive([dir.appendingPathComponent("b.wav")], via: "open with")
        var got: [String] = []
        Intake.handler = { files in got = files.map { $0.lastPathComponent }; return true }
        XCTAssertEqual(got, ["a.wav", "b.wav"], "the second open must not replace the first")
    }

    /// The only `onDrop(of:` in the app is Intake's one modifier; every surface calls that.
    func testOnlyIntakeDeclaresADropTarget() throws {
        let en = try XCTUnwrap(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        var owners: Set<String> = [], users: Set<String> = []
        for case let url as URL in en where url.pathExtension == "swift" {
            let s = try String(contentsOf: url)
            if s.contains("onDrop(of:") { owners.insert(url.lastPathComponent) }
            if s.contains(".acceptsFileDrops(via:") { users.insert(url.lastPathComponent) }
        }
        XCTAssertEqual(owners, ["Intake.swift"])
        XCTAssertTrue(users.isSuperset(of: ["FaceplateView.swift", "MenuBar.swift", "Mini.swift"]), "\(users)")
    }

    func testDockIconAcceptsAudioAndFolders() throws {
        let plist = sourcesRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let d = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let docs = try XCTUnwrap(d["CFBundleDocumentTypes"] as? [[String: Any]])
        let types = Set(docs.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        XCTAssertTrue(types.isSuperset(of: ["public.audio", "public.movie", "public.midi-audio", "public.folder"]))
        XCTAssertTrue(docs.allSatisfy { ($0["LSHandlerRank"] as? String) == "Alternate" }, "never steals the default app")
    }
}
