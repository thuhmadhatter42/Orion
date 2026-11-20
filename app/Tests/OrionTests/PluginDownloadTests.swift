import XCTest
@testable import Orion

/// DOWNLOAD from the plug-in, the app's half (overnight plan §4-§6): PluginDownloadListener with a
/// fake transport, a fake downloader (FileJobs), a fake importer and a fake Finder reveal, and the
/// CId_Import request by its encoded bytes. No network, no Pro Tools, no yt-dlp.
final class PluginDownloadTests: XCTestCase {
    // MARK: fakes

    final class Wire {
        var posts: [(Notification.Name, [String: Any])] = []
        var handler: (([AnyHashable: Any]?) -> Void)?
        var transport: PluginDownloadListener.Transport {
            PluginSendListener.Transport(post: { self.posts.append(($0, $1)) }, observe: { _, h in self.handler = h })
        }
        var replies: [PluginDownload.Reply] {
            posts.filter { $0.0 == PluginDownload.replyName }.compactMap { PluginDownload.Reply.decode($0.1) }
        }
        var finals: [PluginDownload.Reply] { replies.filter { $0.final } }
        var progress: [PluginDownload.Reply] { replies.filter { !$0.final } }
    }

    /// The downloader: each `download` call plays the next script (the last repeats), on a background queue.
    final class FakeJobs: FileJobs {
        var scripts: [[Event]]
        var delay: TimeInterval
        var calls: [(url: String, cookies: URL?)] = []
        private let q = DispatchQueue(label: "fake.jobs")
        init(_ scripts: [[Event]], delay: TimeInterval = 0) { self.scripts = scripts; self.delay = delay }

        func download(_ url: String, cookiesFile: URL?, onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void) {
            let script = scripts[min(calls.count, scripts.count - 1)]
            calls.append((url, cookiesFile))
            let d = delay
            q.async {
                for e in script {
                    if d > 0 { Thread.sleep(forTimeInterval: d) }
                    onEvent(e)
                }
                onExit(0)
            }
        }
        func analyze(_ files: [URL], onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void) { XCTFail("no analysis here") }
        func rename(_ item: RenameItem, onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void) { XCTFail("no rename here") }
    }

    static let file = URL(fileURLWithPath: "/tmp/beat (140.00 BPM Cm Eb Gm).mp3")
    static let reading = Result(file: file, name: file.lastPathComponent, bpm: "140.0", keys: [("Cm", 80), ("Eb", 9)], bpmExact: 140.003)
    static let good: [Event] = [.stage("downloading"), .stage("analyzing"), .stage("renaming"), .done(reading)]

    private var logDir: URL!
    /// The listeners of this test (they hold themselves weakly in their callbacks, as the app's singleton lives for ever).
    private var keep: [PluginDownloadListener] = []
    private var appLines: [String] = []

    override func setUp() {
        super.setUp()
        logDir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-plugin-dl-\(UUID().uuidString)")
        setenv("BEATKEY_LOG_DIR", logDir.path, 1)
        appLines = []
        AppLog.sink = { [weak self] l in self?.appLines.append(l) }
    }

    override func tearDown() {
        AppLog.sink = nil
        unsetenv("BEATKEY_LOG_DIR")
        try? FileManager.default.removeItem(at: logDir)   // this test's own scratch folder
        super.tearDown()
    }

    private func logLines() -> [String] {
        ((try? String(contentsOf: PluginErrorLog.file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func wait(_ secs: Double = 3, until: () -> Bool) {
        let end = Date().addingTimeInterval(secs)
        while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func request(_ id: String, url: String = "https://youtu.be/abc", placement: DownloadPlacement? = nil,
                         bundle: String = "com.avid.ProTools", name: String = "Pro Tools") -> [AnyHashable: Any] {
        PluginDownload.Request(requestID: id, url: url, placement: placement, hostBundleID: bundle, hostName: name, hostPid: 7).userInfo
    }

    /// A listener on fakes. `importer` / `reveal` record into the returned box.
    private final class Box { var imports: [(URL, DownloadPlacement)] = []; var revealed: [URL] = [] }

    private func make(_ jobs: FileJobs, wire: Wire, box: Box, saved: @escaping () -> URL? = { nil }, dropped: @escaping () -> Void = {},
                      probe: (() -> Bool)? = nil, progressEvery: TimeInterval = 20,
                      importer: @escaping (URL, DownloadPlacement) -> PTSLImport.Outcome = { _, _ in .imported }) -> PluginDownloadListener {
        let l = PluginDownloadListener(transport: wire.transport, jobs: { jobs }, prepare: {}, savedLogin: saved, dropLogin: dropped,
                                       downloadsProbe: probe,
                                       importer: { f, p in box.imports.append((f, p)); return importer(f, p) },
                                       reveal: { box.revealed.append($0) }, progressEvery: progressEvery)
        keep.append(l)
        return l
    }

    // MARK: the happy paths

    func testNoPlacementSavesRevealsAndAnswersWithBpmAndKey() {
        let w = Wire(), box = Box(), jobs = FakeJobs([Self.good])
        let l = make(jobs, wire: w, box: box)
        l.install()
        w.handler?(request("r1", bundle: "com.ableton.live", name: "Live"))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(w.finals, [PluginDownload.Reply(requestID: "r1", final: true, ok: true, message: "Saved beat (140.00 BPM Cm Eb Gm).mp3.",
                                                       path: Self.file.path, imported: false, bpm: "140.00", key: "Cm")])
        XCTAssertEqual(box.revealed, [Self.file])
        XCTAssertTrue(box.imports.isEmpty)
        XCTAssertEqual(jobs.calls.map(\.url), ["https://youtu.be/abc"])
        XCTAssertNil(jobs.calls.first?.cookies)
        XCTAssertEqual(logLines(), [], "a good run writes nothing to the error log")
        // progress: the start, then one line per stage
        XCTAssertEqual(w.progress.map(\.message), ["Starting the download.", "Downloading.", "Downloading.", "Reading the key and tempo.", "Naming the file."])
        XCTAssertTrue(w.progress.allSatisfy { $0.requestID == "r1" && $0.ok && !$0.final })
    }

    func testProToolsWithPlacementImportsAndDoesNotReveal() {
        let w = Wire(), box = Box()
        let place = DownloadPlacement(destination: .newTrack, location: .spot)
        let l = make(FakeJobs([Self.good]), wire: w, box: box)
        l.handle(request("r2", placement: place))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(box.imports.count, 1)
        XCTAssertEqual(box.imports.first?.0, Self.file)
        XCTAssertEqual(box.imports.first?.1, place)
        XCTAssertTrue(box.revealed.isEmpty)
        let f = w.finals.first
        XCTAssertEqual(f?.ok, true)
        XCTAssertEqual(f?.imported, true)
        XCTAssertEqual(f?.path, Self.file.path)
        XCTAssertEqual(f?.bpm, "140.00")
        XCTAssertEqual(f?.key, "Cm")
        XCTAssertEqual(f?.message, "Imported beat (140.00 BPM Cm Eb Gm).mp3 into Pro Tools (New Track, Spot at Cursor).")
        XCTAssertTrue(w.progress.contains { $0.message == "Importing into Pro Tools." })
        XCTAssertEqual(logLines(), [])
    }

    func testProToolsWithoutPlacementOnlySaves() {
        let w = Wire(), box = Box()
        make(FakeJobs([Self.good]), wire: w, box: box).handle(request("r3"))
        wait { !w.finals.isEmpty }
        XCTAssertTrue(box.imports.isEmpty)
        XCTAssertEqual(box.revealed, [Self.file])
        XCTAssertEqual(w.finals.first?.imported, false)
        XCTAssertEqual(w.finals.first?.ok, true)
    }

    func testPlacementInAnotherHostOnlySaves() {
        let w = Wire(), box = Box()
        make(FakeJobs([Self.good]), wire: w, box: box)
            .handle(request("r4", placement: DownloadPlacement(destination: .clipList, location: nil), bundle: "com.ableton.live", name: "Live"))
        wait { !w.finals.isEmpty }
        XCTAssertTrue(box.imports.isEmpty, "only Pro Tools is imported into")
        XCTAssertEqual(box.revealed, [Self.file])
        XCTAssertEqual(w.finals.first?.ok, true)
    }

    func testFileWithNoReadingStillImportsWithEmptyBpmAndKey() {
        let w = Wire(), box = Box()
        let r = Result(file: Self.file, name: Self.file.lastPathComponent, bpm: nil, keys: [])
        make(FakeJobs([[.stage("downloading"), .done(r)]]), wire: w, box: box)
            .handle(request("r5", placement: DownloadPlacement(destination: .newTrack, location: .selection)))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(w.finals.first?.ok, true)
        XCTAssertEqual(w.finals.first?.bpm, "")
        XCTAssertEqual(w.finals.first?.key, "")
        XCTAssertEqual(box.imports.count, 1)
    }

    func testProgressEveryIntervalWhileSilent() {
        let w = Wire(), box = Box()
        // 4 events 0.15 s apart = 0.6 s of work, a progress line every 0.05 s
        let l = make(FakeJobs([Self.good], delay: 0.15), wire: w, box: box, progressEvery: 0.05)
        l.handle(request("slow"))
        wait { !w.finals.isEmpty }
        XCTAssertGreaterThanOrEqual(w.progress.count, 8, "the timer keeps the plug-in's 45 s clock restarting")
        XCTAssertEqual(w.finals.count, 1)
        // the timer is stopped with the final reply
        let n = w.replies.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(w.replies.count, n)
    }

    // MARK: one at a time

    func testSecondRequestWhileRunningIsRefusedAndLoggedThenTheNextOneRuns() {
        let w = Wire(), box = Box()
        let l = make(FakeJobs([Self.good], delay: 0.1), wire: w, box: box)
        l.handle(request("a"))
        l.handle(request("b"))
        XCTAssertEqual(w.finals, [PluginDownload.Reply(requestID: "b", final: true, ok: false, message: PluginDownloadListener.busyLine)])
        wait { w.finals.count == 2 }
        XCTAssertEqual(w.finals.first { $0.requestID == "a" }?.ok, true)
        let lines = logLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("[plugin host=Pro Tools] app-listener: download request refused: already downloading"), lines[0])
        l.handle(request("c"))
        wait { w.finals.count == 3 }
        XCTAssertEqual(w.finals.last?.requestID, "c")
        XCTAssertEqual(w.finals.last?.ok, true)
    }

    // MARK: failures, each one line in beatkey.log with source=plugin and the host

    private func assertOneLine(_ source: String, contains text: String, host: String = "Pro Tools", file: StaticString = #filePath, line: UInt = #line) {
        let lines = logLines()
        XCTAssertEqual(lines.count, 1, "exactly one line: \(lines)", file: file, line: line)
        guard let l = lines.first else { return }
        XCTAssertTrue(l.contains("[plugin host=\(host)] \(source): "), l, file: file, line: line)
        XCTAssertTrue(l.contains(text), l, file: file, line: line)
        XCTAssertFalse(l.dropLast().contains("\n"))
    }

    func testDownloadFailedIsAnsweredAndLogged() {
        let w = Wire(), box = Box()
        make(FakeJobs([[.stage("downloading"), .error("That video is private and cannot be downloaded.")]]), wire: w, box: box).handle(request("f1"))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(w.finals, [PluginDownload.Reply(requestID: "f1", final: true, ok: false, message: "That video is private and cannot be downloaded.")])
        assertOneLine("download", contains: "download failed: That video is private")
        XCTAssertTrue(box.revealed.isEmpty && box.imports.isEmpty)
    }

    func testAnalyzeFailedAfterTheDownloadIsAnsweredAndLogged() {
        let w = Wire(), box = Box()
        make(FakeJobs([[.stage("downloading"), .stage("analyzing"), .error("Beat Key's files are damaged. Reinstall it.")]]), wire: w, box: box)
            .handle(request("f2", placement: DownloadPlacement(destination: .clipList, location: nil)))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(w.finals.first?.ok, false)
        XCTAssertEqual(w.finals.first?.message, "Beat Key's files are damaged. Reinstall it.")
        assertOneLine("download", contains: "analyze failed after the download (stage analyzing): Beat Key's files are damaged")
        XCTAssertTrue(box.imports.isEmpty, "no import of a file that could not be read")
    }

    func testHelperStoppedWithNoAnswerIsLogged() {
        let w = Wire(), box = Box()
        make(FakeJobs([[.stage("downloading")]]), wire: w, box: box).handle(request("f3"))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(w.finals.first?.ok, false)
        XCTAssertEqual(w.finals.first?.message, "The downloader stopped unexpectedly (exit 0).")
        assertOneLine("download", contains: "download helper stopped with no answer")
    }

    func testDownloadsFolderNotWritableIsLogged() {
        let w = Wire(), box = Box()
        let jobs = FakeJobs([Self.good])
        make(jobs, wire: w, box: box, probe: { false }).handle(request("f4"))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(w.finals.first?.ok, false)
        XCTAssertTrue(w.finals.first?.message.contains("Downloads folder") ?? false)
        XCTAssertTrue(jobs.calls.isEmpty)
        assertOneLine("download", contains: "Downloads folder not writable")
    }

    func testPTSLConnectFailureKeepsTheFileAndIsLogged() {
        let w = Wire(), box = Box()
        let msg = PTSLImport.notAnswering("beat (140.00 BPM Cm Eb Gm).mp3")
        make(FakeJobs([Self.good]), wire: w, box: box, importer: { _, _ in .failed(stage: "ptsl-connect", message: msg) })
            .handle(request("f5", placement: DownloadPlacement(destination: .newTrack, location: .selection)))
        wait { !w.finals.isEmpty }
        let f = w.finals.first
        XCTAssertEqual(f?.ok, false)
        XCTAssertEqual(f?.imported, false)
        XCTAssertEqual(f?.message, msg)
        XCTAssertEqual(f?.path, Self.file.path, "the file is on disk and the plug-in is told where")
        XCTAssertEqual(f?.bpm, "140.00")
        assertOneLine("ptsl-connect", contains: "ptsl-connect: \(msg)")
    }

    func testPTSLImportFailureIsLogged() {
        let w = Wire(), box = Box()
        make(FakeJobs([Self.good]), wire: w, box: box,
             importer: { _, _ in .failed(stage: "ptsl-import", message: "Pro Tools has no session open. File saved: x.mp3.") })
            .handle(request("f6", placement: DownloadPlacement(destination: .clipList, location: nil)))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(w.finals.first?.ok, false)
        XCTAssertEqual(w.finals.first?.message, "Pro Tools has no session open. File saved: x.mp3.")
        assertOneLine("ptsl-import", contains: "Pro Tools has no session open")
    }

    func testBadRequestWithIDIsAnsweredAndLoggedWithItsHost() {
        let w = Wire(), box = Box()
        let l = make(FakeJobs([Self.good]), wire: w, box: box)
        l.handle(["requestID": "bad1", "proto": 1, "url": "ftp://nope", "hostName": "Logic Pro"])
        XCTAssertEqual(w.finals, [PluginDownload.Reply(requestID: "bad1", final: true, ok: false, message: "Beat Key app refused it: that is not an http(s) link.")])
        assertOneLine("app-listener", contains: "download request refused: that is not an http(s) link", host: "Logic Pro")
        XCTAssertTrue(appLines.contains { $0.contains("ERROR plug-in download refused: that is not an http(s) link") })
    }

    func testBadRequestWithoutIDIsOnlyLogged() {
        let w = Wire(), box = Box()
        make(FakeJobs([Self.good]), wire: w, box: box).handle(["url": "https://youtu.be/abc", "hostName": "Live"])
        XCTAssertTrue(w.posts.isEmpty, "nobody to answer")
        assertOneLine("app-listener", contains: "download request refused: no requestID", host: "Live")
        // no payload at all: no host to name
        logDirReset()
        make(FakeJobs([Self.good]), wire: w, box: box).handle(nil)
        assertOneLine("app-listener", contains: "no payload", host: "unknown host")
    }

    func testUnknownPlacementAndProtocolAreRefused() {
        let w = Wire(), box = Box()
        let l = make(FakeJobs([Self.good]), wire: w, box: box)
        var info = request("p1")
        info["placement"] = "newTrack.sideways"
        l.handle(info)
        XCTAssertTrue(w.finals.first?.message.contains("placement \"newTrack.sideways\" is unknown") ?? false)
        l.handle(["requestID": "p2", "proto": 9, "url": "https://youtu.be/abc"])
        XCTAssertTrue(w.finals.last?.message.contains("update the plug-in and the app together") ?? false)
        XCTAssertEqual(logLines().count, 2, "one line per refusal")
    }

    private func logDirReset() { try? FileManager.default.removeItem(at: PluginErrorLog.file) }

    // MARK: the YouTube login

    func testNeedsLoginRetriesOnceWithTheSavedLogin() {
        let w = Wire(), box = Box()
        let cookies = URL(fileURLWithPath: "/tmp/cookies.txt")
        let jobs = FakeJobs([[.stage("downloading"), .needsLogin(reason: "age", message: "age-restricted", stale: false)], Self.good])
        make(jobs, wire: w, box: box, saved: { cookies }).handle(request("l1"))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(jobs.calls.map { $0.cookies }, [nil, cookies])
        XCTAssertEqual(w.finals.count, 1)
        XCTAssertEqual(w.finals.first?.ok, true)
        XCTAssertEqual(logLines(), [])
    }

    func testNeedsLoginWithNoSavedLoginSaysWhatToDoAndLogs() {
        let w = Wire(), box = Box()
        let jobs = FakeJobs([[.stage("downloading"), .needsLogin(reason: "bot", message: "YouTube wants a login before it will serve this video.", stale: false)]])
        make(jobs, wire: w, box: box).handle(request("l2"))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(jobs.calls.count, 1)
        XCTAssertEqual(w.finals.first?.ok, false)
        XCTAssertEqual(w.finals.first?.message, "YouTube wants a login before it will serve this video. Sign in to YouTube in the Beat Key app, then press DOWNLOAD again.")
        assertOneLine("download", contains: "download needs a YouTube login (bot)")
    }

    func testStaleLoginIsDroppedAndNotRetried() {
        let w = Wire(), box = Box()
        var dropped = 0
        let jobs = FakeJobs([[.needsLogin(reason: "age", message: "age-restricted", stale: true)]])
        make(jobs, wire: w, box: box, saved: { URL(fileURLWithPath: "/tmp/c.txt") }, dropped: { dropped += 1 }).handle(request("l3"))
        wait { !w.finals.isEmpty }
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(jobs.calls.count, 1)
        XCTAssertEqual(w.finals.first?.ok, false)
        assertOneLine("download", contains: "the saved login is stale")
    }

    // MARK: PTSL CId_Import, by its encoded bytes

    private let song = URL(fileURLWithPath: "/Users/j/Downloads/beat (140.00 BPM Cm Eb Gm).wav")
    private let folder = "/Users/j/Sessions/Song/Audio Files"
    private let head = #"{"audio_data":{"audio_destination":"MDestination_NewTrack","#
    private let tail = #""audio_operations":"AOperations_ConvertAudio","destination_path":"/Users/j/Sessions/Song/Audio Files","file_list":["/Users/j/Downloads/beat (140.00 BPM Cm Eb Gm).wav"]"#

    private func json(_ p: DownloadPlacement, spot: Int64? = nil) throws -> String {
        try PTSLClient.json(PTSLImport.body(file: song, placement: p, audioFilesFolder: folder, spotSamples: spot))
    }

    func testImportBodyNewTrackAtCursor() throws {
        XCTAssertEqual(try json(DownloadPlacement(destination: .newTrack, location: .selection)),
                       head + #""audio_location":"MLocation_Selection","# + tail + #"},"import_type":"IType_Audio"}"#)
    }

    func testImportBodyNewTrackAtSessionStart() throws {
        XCTAssertEqual(try json(DownloadPlacement(destination: .newTrack, location: .sessionStart)),
                       head + #""audio_location":"MLocation_SessionStart","# + tail + #"},"import_type":"IType_Audio"}"#)
    }

    func testImportBodyNewTrackAtSongStart() throws {
        XCTAssertEqual(try json(DownloadPlacement(destination: .newTrack, location: .songStart)),
                       head + #""audio_location":"MLocation_SongStart","# + tail + #"},"import_type":"IType_Audio"}"#)
    }

    func testImportBodyNewTrackSpotCarriesTheCursorInSamples() throws {
        XCTAssertEqual(try json(DownloadPlacement(destination: .newTrack, location: .spot), spot: 12_345_678),
                       head + #""audio_location":"MLocation_Spot","# + tail
                       + #","location_data":{"location":{"location":"12345678","time_type":"TLType_Samples"},"location_type":"SLType_Start"}"#
                       + #"},"import_type":"IType_Audio"}"#)
        // without a cursor there is no location_data (run() never gets here: it fails first)
        XCTAssertFalse(try json(DownloadPlacement(destination: .newTrack, location: .spot)).contains("location_data"))
    }

    func testImportBodyClipListHasNoPlaceOnTheTimeline() throws {
        let j = try PTSLClient.json(PTSLImport.body(file: song, placement: DownloadPlacement(destination: .clipList, location: nil),
                                                    audioFilesFolder: folder, spotSamples: 99))
        XCTAssertEqual(j, #"{"audio_data":{"audio_destination":"MDestination_ClipList","audio_location":"MLocation_None","# + tail + #"},"import_type":"IType_Audio"}"#)
        XCTAssertFalse(j.contains("location_data"), "a stray cursor never goes with the Clip List")
    }

    func testImportBodyWithoutASessionFolderLeavesDestinationPathOut() throws {
        let j = try PTSLClient.json(PTSLImport.body(file: song, placement: DownloadPlacement(destination: .clipList, location: nil),
                                                    audioFilesFolder: nil, spotSamples: nil))
        XCTAssertFalse(j.contains("destination_path"))
    }

    func testEveryMenuPlacementEncodesToValidJSONWithItsOwnEnums() throws {
        for p in DownloadPlacement.all {
            let o = try JSONSerialization.jsonObject(with: Data(try json(p, spot: 1).utf8)) as? [String: Any]
            let a = o?["audio_data"] as? [String: Any]
            XCTAssertEqual(o?["import_type"] as? String, "IType_Audio")
            XCTAssertEqual(a?["audio_destination"] as? String, p.ptslDestination)
            XCTAssertEqual(a?["audio_location"] as? String, p.ptslLocation)
            XCTAssertEqual(a?["audio_operations"] as? String, "AOperations_ConvertAudio")
            XCTAssertEqual(a?["file_list"] as? [String], [song.path])
        }
    }

    func testImportRequestBytesCarryTheJSONAndCommandIdTwo() throws {
        let body = try json(DownloadPlacement(destination: .newTrack, location: .selection))
        let bytes = PTSLProto.request(command: PTSLClient.Command.importData.rawValue, sessionID: "S-1", bodyJSON: body)
        XCTAssertEqual(PTSLClient.Command.importData.rawValue, 2, "CId_Import = 2 in PTSL.proto")
        let top = try XCTUnwrap(PTSLProto.fields(bytes))
        XCTAssertEqual(top.map { $0.0 }, [1, 2])
        guard case .bytes(let header) = top[0].1, case .bytes(let sent) = top[1].1 else { return XCTFail("shape") }
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), body)
        let h = try XCTUnwrap(PTSLProto.fields(header))
        XCTAssertEqual(h.first { $0.0 == 2 }?.1, .varint(2), "RequestHeader.command = CId_Import")
        XCTAssertEqual(h.first { $0.0 == 3 }?.1, .varint(2026))
        XCTAssertEqual(h.first { $0.0 == 4 }?.1, .bytes(Data("S-1".utf8)))
        XCTAssertEqual(h.first { $0.0 == 5 }?.1, .varint(4))
        // and as one gRPC-framed message
        XCTAssertEqual(H2.unwrapGRPC(H2.grpcMessage(bytes)), bytes)
    }

    func testAudioFilesFolderIsBesideTheSessionFile() {
        XCTAssertEqual(PTSLImport.audioFilesFolder(sessionPath: "/Users/j/Sessions/Song/Song.ptx"), "/Users/j/Sessions/Song/Audio Files")
    }

    func testPTSLNotRunningMeansFailedConnectAndTheFileIsSaved() {
        let o = PTSLImport.run(file: song, placement: DownloadPlacement(destination: .newTrack, location: .selection), port: 47_498)
        guard case .failed(let stage, let message) = o else { return XCTFail("\(o)") }
        XCTAssertEqual(stage, "ptsl-connect")
        XCTAssertTrue(message.contains("isn't open, or PTSL isn't enabled"), message)
        XCTAssertTrue(message.contains("File saved: \(song.lastPathComponent)."), message)
        XCTAssertFalse(message.contains("\n"))
    }

    // run() against a fake PTSL server: the whole conversation, by command id and body

    /// A fake PTSL server on a free port: answers each command with `reply(command, bodyJSON)`
    /// = (status 3 ok | 4 failed, body JSON, error JSON) until the client closes.
    private final class FakePTSL {
        let port: UInt16
        private let lfd: Int32
        var seen: [(command: Int, session: String, body: String)] = []
        init(reply: @escaping (Int, String) -> (Int, String, String)) {
            let lfd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            self.lfd = lfd
            var a = UDP.loopback(0)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            listen(lfd, 1)
            var got = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(lfd, $0, &len) } }
            port = UInt16(bigEndian: got.sin_port)
            Thread.detachNewThread { [self] in
                let fd = accept(lfd, nil, nil)
                defer { close(fd); close(lfd) }
                var buf = Data()
                func fill() -> Bool {
                    var c = [UInt8](repeating: 0, count: 65_536)
                    let n = recv(fd, &c, c.count, 0)
                    if n <= 0 { return false }
                    buf += c[0..<n]; return true
                }
                func put(_ d: Data) { _ = d.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) } }
                while buf.count < 24 { guard fill() else { return } }
                buf.removeFirst(24)
                put(H2.frame(4, Data()))
                var body = Data()
                while true {
                    guard let (f, used) = H2.parse(buf) else { guard fill() else { return }; continue }
                    buf.removeFirst(used)
                    guard f.type == 0 else { continue }
                    body += f.payload
                    guard f.flags & H2.endStream != 0 else { continue }
                    let msg = H2.unwrapGRPC(body)!; body = Data()
                    var command = 0, session = "", json = ""
                    for (n, v) in PTSLProto.fields(msg)! {
                        if n == 2, case .bytes(let j) = v { json = String(decoding: j, as: UTF8.self) }
                        if n == 1, case .bytes(let h) = v {
                            for (hn, hv) in PTSLProto.fields(h)! {
                                if hn == 2, case .varint(let c) = hv { command = Int(c) }
                                if hn == 4, case .bytes(let s) = hv { session = String(decoding: s, as: UTF8.self) }
                            }
                        }
                    }
                    seen.append((command, session, json))
                    let (status, out, err) = reply(command, json)
                    var resp = PTSLProto.bytesField(1, PTSLProto.varintField(3, UInt64(status)))
                    if !out.isEmpty { resp += PTSLProto.bytesField(2, Data(out.utf8)) }
                    if !err.isEmpty { resp += PTSLProto.bytesField(3, Data(err.utf8)) }
                    put(H2.frame(1, flags: H2.endHeaders, stream: f.stream, Data(H2.literal(":status", "200"))))
                    put(H2.frame(0, stream: f.stream, H2.grpcMessage(resp)))
                    put(H2.frame(1, flags: H2.endHeaders | H2.endStream, stream: f.stream, Data(H2.literal("grpc-status", "0"))))
                }
            }
        }
    }

    func testRunImportsOverPTSLWithTheSessionFolderAndTheCursor() {
        let server = FakePTSL { cmd, _ in
            switch cmd {
            case 70: return (3, #"{"session_id":"S-9"}"#, "")
            case 43: return (3, #"{"session_path":{"path":"/Users/j/Sessions/Song/Song.ptx"}}"#, "")
            case 131: return (3, #"{"in_time":"480000","out_time":"480000"}"#, "")
            default: return (3, "", "")
            }
        }
        let o = PTSLImport.run(file: song, placement: DownloadPlacement(destination: .newTrack, location: .spot), port: server.port)
        XCTAssertEqual(o, .imported)
        XCTAssertEqual(server.seen.map(\.command), [70, 43, 131, 2])
        XCTAssertEqual(server.seen.map(\.session), ["", "S-9", "S-9", "S-9"])
        XCTAssertEqual(server.seen[2].body, #"{"location_type":"TLType_Samples"}"#)
        XCTAssertEqual(server.seen[3].body,
                       head + #""audio_location":"MLocation_Spot","# + tail
                       + #","location_data":{"location":{"location":"480000","time_type":"TLType_Samples"},"location_type":"SLType_Start"}"#
                       + #"},"import_type":"IType_Audio"}"#)
    }

    func testRunWithNoSessionOpenFailsAtImportAndKeepsTheFile() {
        let server = FakePTSL { cmd, _ in
            switch cmd {
            case 70: return (3, #"{"session_id":"S-9"}"#, "")
            default: return (4, "", #"{"errors":[{"command_error_type":"PT_NoSession","command_error_message":"No session"}]}"#)
            }
        }
        let o = PTSLImport.run(file: song, placement: DownloadPlacement(destination: .clipList, location: nil), port: server.port)
        XCTAssertEqual(o, .failed(stage: "ptsl-import", message: "Pro Tools has no session open. File saved: \(song.lastPathComponent)."))
    }

    func testRunWhenProToolsRefusesTheImportSaysWhy() {
        let server = FakePTSL { cmd, _ in
            switch cmd {
            case 70: return (3, #"{"session_id":"S-9"}"#, "")
            case 43: return (3, #"{"session_path":{"path":"/S/S.ptx"}}"#, "")
            default: return (4, "", #"{"errors":[{"command_error_type":"PT_Bad","command_error_message":"Unsupported file"}]}"#)
            }
        }
        let o = PTSLImport.run(file: song, placement: DownloadPlacement(destination: .clipList, location: nil), port: server.port)
        XCTAssertEqual(o, .failed(stage: "ptsl-import", message: "Pro Tools refused the import: Unsupported file. File saved: \(song.lastPathComponent)."))
    }
}
