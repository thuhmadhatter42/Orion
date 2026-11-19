import Foundation
import XCTest
@testable import Orion

/// The file work that moved from app_run.py into the app with the core (plan step 19): the tag,
/// the renamer, the links log, reading a file, the step after a download, and the Engine's chain.
final class CoreFileTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("beatkey-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func make(_ name: String, _ data: Data = Data("x".utf8)) -> URL {
        let u = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: u.path, contents: data)
        return u
    }

    // MARK: the tag (was app_run.py renamed_name / is_tagged)

    func testTheNameIsTheOriginalAppsFormat() {
        XCTAssertEqual(FileTag.name(stem: "T", ext: "mp3", bpm: "142.0", keys: ["Cm", "Eb", "Gm"]), "T (142.0 BPM Cm Eb Gm).mp3")
        XCTAssertEqual(FileTag.name(stem: "T", ext: "", bpm: "90", keys: ["Cm"]), "T (90 BPM Cm)")
        XCTAssertEqual(FileTag.name(stem: "T", ext: "wav", bpm: "90", keys: ["Cm", "Eb", "Gm", "F"]), "T (90 BPM Cm Eb Gm).wav",
                       "the tag holds keyCount keys")
    }

    func testItsOwnTagIsRecognisedForEveryKeyCount() {
        for name in ["Beat (142.0 BPM Cm).wav", "Beat (142.0 BPM Cm Eb).wav", "Beat (142.0 BPM Cm Eb Gm).wav",
                     "Beat (90 BPM F#m Bb Db).mp3", "(128.5 BPM Ab).aif", "/a/b/Beat (142.0 BPM Cm Eb Gm).wav"] {
            XCTAssertTrue(FileTag.isTagged(name), name)
        }
    }

    func testAProducersOwnBpmOrKeyIsNotTheTag() {
        for name in ["Beat 140 BPM Cm.wav", "Beat (140 BPM).wav", "Beat (142.0 BPM Cm) final.wav", "Beat(142.0 BPM Cm).wav",
                     "Beat (142.0 BPM Cm Eb Gm F).wav", "Beat (142.0 bpm Cm).wav", "Beat.wav"] {
            XCTAssertFalse(FileTag.isTagged(name), name)
        }
    }

    // MARK: the renamer (was app_run.py rename_file)

    func testRenamesInPlaceKeepingContentsAndFolder() throws {
        let p = make("Beat.wav", Data("audio".utf8))
        let new = try FileTag.rename(p, bpm: "142.0", keys: ["Cm", "Eb", "Gm"], overwrite: false)
        XCTAssertEqual(new.path, dir.appendingPathComponent("Beat (142.0 BPM Cm Eb Gm).wav").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.path))
        XCTAssertEqual(try Data(contentsOf: new), Data("audio".utf8))
    }

    func testNeverOverwritesAnotherFile() {
        let p = make("Beat.wav", Data("mine".utf8))
        let other = make("Beat (142.0 BPM Cm).wav", Data("theirs".utf8))
        XCTAssertThrowsError(try FileTag.rename(p, bpm: "142.0", keys: ["Cm"], overwrite: false)) {
            XCTAssertEqual($0 as? FileTag.Failure, .os(EEXIST, "a file with that name already exists"))
        }
        XCTAssertEqual(try Data(contentsOf: other), Data("theirs".utf8))
        XCTAssertEqual(try Data(contentsOf: p), Data("mine".utf8))
    }

    func testNoUsableBpmOrNoKeyIsRefused() {
        let p = make("Beat.wav", Data("mine".utf8))
        for (bpm, keys) in [("0.0", ["Cm"]), ("0", ["Cm"]), ("", ["Cm"]), ("nan", ["Cm"]), ("x", ["Cm"]), ("142.0", [])] {
            for overwrite in [false, true] {
                XCTAssertThrowsError(try FileTag.rename(p, bpm: bpm, keys: keys, overwrite: overwrite)) {
                    guard case .refused = $0 as? FileTag.Failure else { return XCTFail("\(bpm) \(keys): \($0)") }
                }
            }
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [], ["Beat.wav"])
    }

    func testTheDownloadPathMayOverwrite() throws {
        let p = make("Beat.mp3", Data("new".utf8))
        _ = make("Beat (142.0 BPM Cm).mp3", Data("old".utf8))
        let new = try FileTag.rename(p, bpm: "142.0", keys: ["Cm"], overwrite: true)
        XCTAssertEqual(try Data(contentsOf: new), Data("new".utf8))
    }

    func testAMissingFileFailsWithErrno() {
        XCTAssertThrowsError(try FileTag.rename(dir.appendingPathComponent("gone.wav"), bpm: "90.0", keys: ["Cm"], overwrite: false)) {
            guard case .os(let e, _) = $0 as? FileTag.Failure else { return XCTFail("\($0)") }
            XCTAssertEqual(e, ENOENT)
        }
    }

    func testTheUnicodeNameSurvives() throws {
        let p = make("Bèat ✦ 夜.wav")
        let new = try FileTag.rename(p, bpm: "90.0", keys: ["Am"], overwrite: false)
        XCTAssertEqual(new.lastPathComponent, "Bèat ✦ 夜 (90.0 BPM Am).wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
    }

    // MARK: the rename job (Engine.rename's in-process half)

    func runJob(_ start: (@escaping (Event) -> Void, @escaping (Int32) -> Void) -> Void) -> ([Event], Int32?) {
        var events: [Event] = []
        var code: Int32?
        let done = expectation(description: "job ends")
        let lock = NSLock()
        start({ e in lock.lock(); events.append(e); lock.unlock() }, { c in lock.lock(); code = c; lock.unlock(); done.fulfill() })
        wait(for: [done], timeout: 120)
        lock.lock(); defer { lock.unlock() }
        return (events, code)
    }

    func testRenameJobSaysRenamedSkippedOrFailed() {
        let jobs = CoreFileJobs(reader: { FileReader(binDir: self.dir) })
        let p = make("Beat.wav")
        var (ev, code) = runJob { jobs.rename(RenameItem(file: p, bpm: "142.0", keys: ["Cm", "Eb", "Gm"]), onEvent: $0, onExit: $1) }
        XCTAssertEqual(ev, [.renamed(from: p.path, to: dir.appendingPathComponent("Beat (142.0 BPM Cm Eb Gm).wav").path)])
        XCTAssertEqual(code, 0)
        let tagged = make("Old (90.0 BPM Am).wav")
        (ev, _) = runJob { jobs.rename(RenameItem(file: tagged, bpm: "90.0", keys: ["Am"]), onEvent: $0, onExit: $1) }
        XCTAssertEqual(ev, [.renameSkipped(file: tagged.path)])
        let q = make("Q.wav")
        _ = make("Q (90.0 BPM Am).wav")
        (ev, _) = runJob { jobs.rename(RenameItem(file: q, bpm: "90.0", keys: ["Am"]), onEvent: $0, onExit: $1) }
        XCTAssertEqual(ev, [.renameFailed(file: q.path, errno: Int(EEXIST), message: "a file with that name already exists")])
        (ev, _) = runJob { jobs.rename(RenameItem(file: q, bpm: "0.0", keys: ["Am"]), onEvent: $0, onExit: $1) }
        guard case .renameFailed(_, 0, let m)? = ev.first else { return XCTFail("\(ev)") }
        XCTAssertTrue(m.contains("is not a BPM"), m)
    }

    // MARK: the links log (was app_run.py append_links_log)

    func testLinksLogNameAndLine() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 9
        let d = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(LinksLog.url(now: d, env: ["ORION_DOWNLOADS": "/D"]).path, "/D/(26-11-9) Youtube DL LINKS.txt")
        XCTAssertEqual(LinksLog.line(url: "u", name: "n"), "Input URL: u\nDownloaded: n\n\n")
        let f = dir.appendingPathComponent("sub/log.txt")
        LinksLog.append(url: "u1", name: "a.mp3", to: f)
        LinksLog.append(url: "u2", name: "b.mp3", to: f)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "Input URL: u1\nDownloaded: a.mp3\n\nInput URL: u2\nDownloaded: b.mp3\n\n")
    }

    // MARK: reading files with the core

    static var ffmpegDir: URL? {
        let repo = CoreTestSupport.repo
        var dirs = [repo.appendingPathComponent("bin")]
        if let r = repo.path.range(of: "/.claude/worktrees/") { dirs.append(URL(fileURLWithPath: String(repo.path[..<r.lowerBound]) + "/bin")) }
        if let e = ProcessInfo.processInfo.environment["BEATKEY_PARITY_BIN"] { dirs.insert(URL(fileURLWithPath: e), at: 0) }
        return dirs.first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("ffmpeg").path) }
    }

    func reader() throws -> FileReader {
        guard FileManager.default.fileExists(atPath: CoreTestSupport.weights.path) else { throw XCTSkip("no core weights") }
        guard let bin = CoreFileTests.ffmpegDir else { throw XCTSkip("no ffmpeg (bin/)") }
        return FileReader(binDir: bin, weights: CoreTestSupport.weights)
    }

    /// 16-bit stereo WAV: a 120 BPM click over an A-minor drone.
    func clickWav(_ name: String, secs: Double) -> URL {
        let sr = 44100, n = Int(Double(sr) * secs)
        var pcm = Data(capacity: n * 4)
        for i in 0..<n {
            let t = Double(i) / Double(sr)
            let click = t.truncatingRemainder(dividingBy: 0.5) < 0.01 ? 0.6 * sin(2 * .pi * 1000 * t) : 0
            let drone = 0.08 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 261.63 * t) + sin(2 * .pi * 329.63 * t))
            var v = Int16(max(-1, min(1, click + drone)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }
        }
        var h = Data()
        func u32(_ x: Int) { var v = UInt32(x).littleEndian; withUnsafeBytes(of: &v) { h.append(contentsOf: $0) } }
        func u16(_ x: Int) { var v = UInt16(x).littleEndian; withUnsafeBytes(of: &v) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count); h.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(sr); u32(sr * 4); u16(4); u16(16)
        h.append(contentsOf: Array("data".utf8)); u32(pcm.count)
        return make(name, h + pcm)
    }

    func testAWavIsReadByTheCore() throws {
        let r = try reader()
        guard case .reading(let res) = r.read(clickWav("Click.wav", secs: 20)) else { return XCTFail("refused") }
        XCTAssertEqual(res.bpm.flatMap(Double.init).map { Int($0.rounded()) }, 120, "\(res)")
        XCTAssertEqual(res.keys.first?.0, "Am")
        XCTAssertEqual(res.keys.count, 3)
        XCTAssertNotNil(res.bpmExact)
        XCTAssertEqual(res.chroma?.count, 12)
        XCTAssertFalse(res.tagged)
        XCTAssertEqual(res.name, "Click.wav")
    }

    func testAClipTooShortHasNoReading() throws {
        let r = try reader()
        guard case .reading(let res) = r.read(clickWav("Short.wav", secs: 3)) else { return XCTFail("refused") }
        XCTAssertNil(res.bpm)
        XCTAssertTrue(res.keys.isEmpty)
        XCTAssertNil(res.readError)
    }

    func testAFileThatIsNotAudioHasNoReading() throws {
        let r = try reader()
        guard case .reading(let res) = r.read(make("notes.txt", Data("hello".utf8))) else { return XCTFail("refused") }
        XCTAssertNil(res.bpm)
        XCTAssertNil(res.readError)
    }

    func testAnUnreadableFileSaysPermission() throws {
        let r = try reader()
        let p = clickWav("Locked.wav", secs: 1)
        chmod(p.path, 0)
        defer { chmod(p.path, 0o644) }
        guard case .reading(let res) = r.read(p) else { return XCTFail("refused") }
        XCTAssertNil(res.bpm)
        XCTAssertEqual(res.readError, "permission")
    }

    func testNoWeightsIsTheOneIncompleteSentence() throws {
        // weights already loaded by another test in this process: the core stays ready (by design)
        let r = FileReader(binDir: dir, weights: URL(fileURLWithPath: "/nonexistent/\(Core.weightsName)"))
        switch r.read(make("a.wav")) {
        case .incomplete(let why): XCTAssertEqual(why, Core.incomplete)
        case .reading: XCTAssertNil(Core.load(URL(fileURLWithPath: "/nonexistent")), "only a loaded core reads")
        }
    }

    /// tests/test_bpm_extras.py's MIDI file: 428,000 us per quarter = 140.19 BPM, C major tune.
    func testAMidiFileIsReadByTheCore() throws {
        guard FileManager.default.fileExists(atPath: CoreTestSupport.weights.path) else { throw XCTSkip("no core weights") }
        func vlq(_ n: Int) -> [UInt8] {
            var out = [UInt8(n & 0x7F)]; var n = n >> 7
            while n > 0 { out.append(UInt8((n & 0x7F) | 0x80)); n >>= 7 }
            return out.reversed()
        }
        var trk: [UInt8] = [0, 0xFF, 0x51, 0x03, 0x06, 0x87, 0xE0]
        let tune: [UInt8] = Array(repeating: [60, 64, 67, 72, 67, 64, 60, 60, 67, 67, 62, 65, 60] as [UInt8], count: 4).flatMap { $0 }
        for p in tune { trk += [0, 0x90, p, 90] + vlq(480) + [0x80, p, 0] }
        trk += [0, 0xFF, 0x2F, 0]
        var f: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, 0, 1, 0x01, 0xE0] + Array("MTrk".utf8)
        f += [UInt8(trk.count >> 24 & 0xFF), UInt8(trk.count >> 16 & 0xFF), UInt8(trk.count >> 8 & 0xFF), UInt8(trk.count & 0xFF)] + trk
        let r = FileReader(binDir: dir, weights: CoreTestSupport.weights)
        guard case .reading(let res) = r.read(make("t.mid", Data(f))) else { return XCTFail("refused") }
        XCTAssertEqual(res.bpm, "140.2")
        XCTAssertEqual(res.bpmExact, 140.19)
        XCTAssertEqual(res.keys.first?.0, "C")
        XCTAssertNil(res.chroma, "Notes Heard is hidden for MIDI")
        XCTAssertNil(res.tuningCents)
        guard case .reading(let bad) = r.read(make("bad.mid", Data("RIFF....".utf8))) else { return XCTFail("refused") }
        XCTAssertNil(bad.bpm)
    }

    // MARK: analyze job + the step after a download

    func testAnalyzeJobSendsOneRowPerFile() throws {
        let rd = try reader()
        let jobs = CoreFileJobs(reader: { rd })
        let a = clickWav("A.wav", secs: 15), b = make("B (90.0 BPM Am).txt", Data("no".utf8))
        let (ev, code) = runJob { jobs.analyze([a, b], onEvent: $0, onExit: $1) }
        XCTAssertEqual(code, 0)
        let rows = ev.compactMap { e -> Result? in if case .analyzed(let r) = e { return r } else { return nil } }
        XCTAssertEqual(ev.filter { $0 == .stage("analyzing") }.count, 2)
        XCTAssertEqual(rows.map(\.name), ["A.wav", "B (90.0 BPM Am).txt"])
        XCTAssertNotNil(rows[0].bpm)
        XCTAssertNil(rows[1].bpm)
        XCTAssertTrue(rows[1].tagged, "the tag is recognised on a row with no reading too")
    }

    func testFinishDownloadReadsTagsAndLogs() throws {
        let rd = try reader()
        let jobs = CoreFileJobs(reader: { rd })
        let downloads = dir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        setenv("ORION_DOWNLOADS", downloads.path, 1)
        defer { unsetenv("ORION_DOWNLOADS") }
        let file = clickWav("Downloads/Song.wav", secs: 15)
        _ = make("Downloads/Song (120.0 BPM Am C G).wav", Data("older copy".utf8))
        let (ev, code) = runJob { jobs.finishDownload(file, url: "https://y/1", onEvent: $0, onExit: $1) }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(Array(ev.prefix(2)), [.stage("analyzing"), .stage("renaming")])
        guard case .done(let r)? = ev.last else { return XCTFail("\(ev)") }
        XCTAssertTrue(FileTag.isTagged(r.name), r.name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotNil(r.bpmExact)
        let log = try String(contentsOf: LinksLog.url(), encoding: .utf8)
        XCTAssertEqual(log, LinksLog.line(url: "https://y/1", name: r.name))
    }

    func testFinishDownloadWithNoReadingKeepsTheName() throws {
        let rd = try reader()
        let jobs = CoreFileJobs(reader: { rd })
        let downloads = dir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        setenv("ORION_DOWNLOADS", downloads.path, 1)
        defer { unsetenv("ORION_DOWNLOADS") }
        let file = clickWav("Downloads/Tiny.wav", secs: 2)
        let (ev, _) = runJob { jobs.finishDownload(file, url: "u", onEvent: $0, onExit: $1) }
        XCTAssertEqual(ev.last, .done(Result(file: file, name: "Tiny.wav", bpm: nil, keys: [])))
        XCTAssertEqual(try String(contentsOf: LinksLog.url(), encoding: .utf8), LinksLog.line(url: "u", name: "Tiny.wav"))
    }

    // MARK: the Engine's chain: helper download -> in-process read, tag, log

    func testEngineChainsTheDownloadIntoTheFileJob() {
        let f = FakeLauncher()
        let e = Engine(runtime: Runtime(root: URL(fileURLWithPath: "/R/runtime"), arch: "arm64",
                                        support: URL(fileURLWithPath: "/S/Orion"), osMajor: 14), launcher: f, jobs: f)
        e.download("https://y/2")
        let deadline = Date().addingTimeInterval(5)
        while f.launches.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        f.onLine?(#"{"stage":"downloaded","file":"/D/Song.mp3","name":"Song.mp3"}"#)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(f.launches.count, 2)
        XCTAssertEqual(Array(f.launches[1].dropFirst()), ["finish-download", "/D/Song.mp3", "https://y/2"])
        f.exits[0](0)                      // the helper's own exit: not the end of the job
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(e.state.isBusy, "\(e.state)")
        f.onLine?(#"{"stage":"done","file":"/D/Song (90.0 BPM Am).mp3","name":"Song (90.0 BPM Am).mp3","bpm":"90.0","keys":[["Am",80]]}"#)
        f.onExit?(0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard case .done(let r) = e.state else { return XCTFail("\(e.state)") }
        XCTAssertEqual(r.name, "Song (90.0 BPM Am).mp3")
    }
}
