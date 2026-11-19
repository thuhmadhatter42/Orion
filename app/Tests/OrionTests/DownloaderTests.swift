import Foundation
import XCTest
@testable import Orion

/// The download, ported from app_run.py + downloader.py's app mode (tests/test_app_run.py's cases),
/// against the same yt-dlp stub (tests/stub/yt-dlp, STUB_MODE picks its behaviour).
final class DownloaderTests: XCTestCase {
    var tmp: URL!, dl: URL!, state: URL!, logs: URL!, wav: URL!
    let url = "https://www.youtube.com/watch?v=xxxxxxxxxxx"
    static let stub = CoreTestSupport.repo.appendingPathComponent("tests/stub/yt-dlp")

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("beatkey-dl-\(UUID().uuidString)")
        dl = tmp.appendingPathComponent("dl"); state = tmp.appendingPathComponent("state"); logs = tmp.appendingPathComponent("logs")
        for d in [dl!, state!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        wav = tmp.appendingPathComponent("audio.wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data("RIFF-not-really".utf8))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    var argvLog: URL { tmp.appendingPathComponent("argv.log") }
    func calls() -> [String] {
        ((try? String(contentsOf: argvLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func downloader(_ mode: String, ytdlp: URL = DownloaderTests.stub, deno: URL? = nil, timeout: TimeInterval = 120,
                    audio: URL? = nil) -> Downloader {
        Downloader(ytdlp: ytdlp, deno: deno, downloads: dl,
                   environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "STUB_MODE": mode,
                                 "STUB_AUDIO": (audio ?? wav).path, "STUB_STATE": state.path, "STUB_ARGV_LOG": argvLog.path],
                   timeout: timeout, logDir: logs)
    }

    func cookieFile(mode: mode_t = 0o600) -> URL {
        let f = tmp.appendingPathComponent("youtube-cookies.txt")
        FileManager.default.createFile(atPath: f.path, contents: Data("# Netscape HTTP Cookie File\n".utf8))
        chmod(f.path, mode)
        return f
    }

    // MARK: the pure pieces

    func testAppStrategiesNeverReadABrowser() {
        let s = Downloader.strategies(cookiesFile: nil)
        XCTAssertEqual(s, [["--extractor-args", "youtube:player_client=android"],
                           ["--extractor-args", "youtube:player_client=web"], []])
        XCTAssertFalse(s.joined().contains("--cookies-from-browser"))
        XCTAssertEqual(Downloader.strategies(cookiesFile: URL(fileURLWithPath: "/x/youtube-cookies.txt")),
                       [["--cookies", "/x/youtube-cookies.txt"]])
    }

    func testReasonClassifier() {
        XCTAssertEqual(Downloader.loginReason(["Sign in to confirm your age"]), "age")
        XCTAssertEqual(Downloader.loginReason(["This video is age-restricted"]), "age")
        XCTAssertEqual(Downloader.loginReason(["Sign in to confirm you\u{2019}re not a bot"]), "bot")
        XCTAssertEqual(Downloader.loginReason(["members-only content"]), "members")
        XCTAssertNil(Downloader.loginReason(["Private video. Sign in if you've been granted access"]))
        XCTAssertNil(Downloader.loginReason(["Video unavailable"]))
    }

    func testStaleClassifier() {
        XCTAssertTrue(Downloader.cookiesStale(["WARNING: [youtube] The provided YouTube account cookies are no longer valid. They have likely been rotated"]))
        XCTAssertFalse(Downloader.cookiesStale(["ERROR: Sign in to confirm your age"]))
    }

    func testErrorMappingUsesYtDlpWording() {
        let e = { (l: String) in Downloader.explain([l]) }
        let blocked = "YouTube blocked this download. Try Beat Key › Run Doctor."
        XCTAssertEqual(e("ERROR: [youtube] x: Requested format is not available. Use --list-formats for a list of available formats"), blocked)
        XCTAssertEqual(e("WARNING: Only images are available for download. use --list-formats to see them"), blocked)
        XCTAssertEqual(e("WARNING: [youtube] x: n challenge solving failed: Some formats may be missing."), blocked)
        XCTAssertEqual(e("ERROR: [youtube] x: Video unavailable. This video has been removed by the uploader"),
                       "That video is unavailable or has been removed.")
        XCTAssertEqual(e("ERROR: [youtube] x: The uploader has not made this video available in your country"),
                       "That video is not available in your country.")
        XCTAssertEqual(e("ERROR: [youtube] x: Private video. Sign in if you've been granted access"),
                       "That video is private and cannot be downloaded.")
        XCTAssertTrue(e("ERROR: [youtube] x: Sign in to confirm your age. This video may be inappropriate for some users.").hasPrefix("That video is age-restricted"))
        XCTAssertTrue(e("ERROR: [youtube] x: Video unavailable. This video is no longer available due to a copyright claim by someone").hasPrefix("This video is blocked due to a copyright"))
        XCTAssertTrue(e("ERROR: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided, or not known>").hasPrefix("Network error"))
        XCTAssertTrue(e("ERROR: Unsupported URL: https://example.com/").hasPrefix("That doesn't look like"))
        // "images", "page", "message" contain "age"; none of them is an age restriction
        XCTAssertFalse(e("WARNING: Only images are available").hasPrefix("That video is age"))
        XCTAssertEqual(Downloader.explain([]), "Download failed for an unknown reason.")
        XCTAssertEqual(Downloader.explain(["ERROR: something odd", "see https://github.com/yt-dlp"]), "Download failed: ERROR: something odd")
    }

    func testSafeName() {
        XCTAssertEqual(Downloader.safeName(#"a/b: "c" 🔥"#), #"a_b_ _c_ 🔥"#)
        XCTAssertEqual(Downloader.safeName(" .. "), "audio")
        XCTAssertEqual(Downloader.safeName("[x]"), "_x_")
    }

    func testRedactsSecrets() {
        let out = Downloader.redact("WARNING: x Cookie: SAPISID=abc123; token=zzz sig=AOq0 visitor_data=Cgt")
        for secret in ["abc123", "zzz", "AOq0", "Cgt"] { XCTAssertFalse(out.contains(secret), out) }
    }

    // MARK: downloads through the stub

    func testDownloadOk() {
        let o = downloader("ok").download("https://example.com/v", cookiesFile: nil)
        XCTAssertEqual(o, .downloaded(dl.appendingPathComponent("Test Beat.mp3")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dl.appendingPathComponent("Test Beat.mp3").path))
        XCTAssertEqual(calls().count, 2, "one metadata call, one download call")
    }

    func testWeirdTitle() {
        guard case .downloaded(let f) = downloader("ok-weird-title").download("https://example.com/v", cookiesFile: nil)
        else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        XCTAssertFalse(f.lastPathComponent.contains("/"))
        XCTAssertEqual(f.deletingLastPathComponent().standardizedFileURL, dl.standardizedFileURL)
    }

    func testNetworkError() {
        guard case .failed(let m) = downloader("fail-network").download("https://example.com/v", cookiesFile: nil)
        else { return XCTFail() }
        XCTAssertTrue(m.hasPrefix("Network error"), m)
    }

    func testOneRetryLayerOnly() {
        // metadata works, the download never does: each of the 3 strategies gets exactly one
        // metadata call and one download call, and yt-dlp is never upgraded-and-repeated
        XCTAssertEqual(downloader("fail-download").download("https://example.com/v", cookiesFile: nil),
                       .failed(Downloader.blockedMessage))
        XCTAssertEqual(calls().filter { $0.contains("--dump-json") }.count, 3, "\(calls())")
        XCTAssertEqual(calls().filter { $0.contains("--extract-audio") }.count, 3)
        XCTAssertFalse(calls().joined(separator: " ").split(separator: " ").contains("-U"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("upgraded").path))
    }

    func testUnavailableStopsBeforeCookiesAndUpgrade() {
        guard case .failed(let m) = downloader("fail-unavailable").download(url, cookiesFile: nil) else { return XCTFail() }
        XCTAssertTrue(m.hasPrefix("That video is unavailable"), m)
        XCTAssertFalse(calls().joined().contains("--cookies-from-browser"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("upgraded").path))
    }

    func testTimeoutIsAnError() {
        let t0 = Date()
        XCTAssertEqual(downloader("hang", timeout: 1).download("https://example.com/v", cookiesFile: nil),
                       .failed("Download timed out."))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15, "the hung yt-dlp is killed, not waited for")
    }

    func testDownloadsRunThroughTheGivenYtDlp() throws {
        let wrap = tmp.appendingPathComponent("my-ytdlp")
        try "#!/bin/bash\necho used >> \"\(tmp.appendingPathComponent("used.log").path)\"\nexec \"\(DownloaderTests.stub.path)\" \"$@\"\n"
            .write(to: wrap, atomically: true, encoding: .utf8)
        chmod(wrap.path, 0o755)
        guard case .downloaded = downloader("ok", ytdlp: wrap).download("https://example.com/v", cookiesFile: nil) else { return XCTFail() }
        let used = try String(contentsOf: tmp.appendingPathComponent("used.log"), encoding: .utf8)
        XCTAssertGreaterThanOrEqual(used.components(separatedBy: "used").count - 1, 2)
    }

    func testPlaylistUrlStaysOneVideo() {
        _ = downloader("ok").download("https://example.com/watch?v=x&list=PL123", cookiesFile: nil)
        XCTAssertFalse(calls().isEmpty)
        XCTAssertTrue(calls().allSatisfy { $0.contains("--no-playlist") }, "\(calls())")
    }

    // MARK: the login

    func testTheAppNeverReadsBrowserCookies() {
        for mode in ["fail-age", "fail-bot", "fail-network", "fail-unavailable", "ok", "fail-download"] {
            try? FileManager.default.removeItem(at: argvLog)
            _ = downloader(mode).download(url, cookiesFile: nil)
            XCTAssertFalse(calls().joined().contains("--cookies"), mode)
        }
    }

    func testAgeBotAndMembersNeedLogin() {
        for (mode, reason) in [("fail-age", "age"), ("fail-bot", "bot"), ("fail-members", "members")] {
            XCTAssertEqual(downloader(mode).download(url, cookiesFile: nil), .needsLogin(reason: reason, stale: false), mode)
            XCTAssertNotNil(Downloader.loginMessages[reason])
        }
    }

    func testDeadLinkIsAnErrorNotALogin() {
        guard case .failed = downloader("fail-unavailable").download(url, cookiesFile: nil) else { return XCTFail() }
    }

    func testCookiesFileRunsExactlyOneCookieAttempt() {
        let f = cookieFile()
        guard case .downloaded = downloader("cookie-ok").download(url, cookiesFile: f) else { return XCTFail("\(calls())") }
        XCTAssertFalse(calls().isEmpty)
        XCTAssertTrue(calls().allSatisfy { $0.contains("--cookies \(f.path)") }, "\(calls())")
        XCTAssertFalse(calls().joined().contains("--cookies-from-browser"))
        XCTAssertEqual(calls().filter { $0.contains("--dump-json") }.count, 1)
    }

    func testCookiesFileStaysOwnerOnly() throws {
        let f = cookieFile(mode: 0o644)   // yt-dlp rewrote it under a loose umask
        _ = downloader("cookie-ok").download(url, cookiesFile: f)
        let mode = try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testStaleLoginAsksAgain() throws {
        let f = cookieFile()
        XCTAssertEqual(downloader("cookie-stale").download(url, cookiesFile: f), .needsLogin(reason: "age", stale: true))
        XCTAssertEqual(calls().count, 1)
        let last = try String(contentsOf: logs.appendingPathComponent("last-run.log"), encoding: .utf8)
        XCTAssertTrue(last.contains("outcome: needs_login: saved login no longer works"), last)
        XCTAssertTrue(last.contains("login: saved YouTube login"), last)
    }

    func testLoginStillRefusedWithCookiesAsksAgain() {
        XCTAssertEqual(downloader("fail-age").download(url, cookiesFile: cookieFile()), .needsLogin(reason: "age", stale: true))
    }

    func testMissingCookiesFileAsksAgainWithoutRunning() {
        XCTAssertEqual(downloader("ok").download(url, cookiesFile: tmp.appendingPathComponent("gone.txt")),
                       .needsLogin(reason: "age", stale: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: argvLog.path), "yt-dlp never ran")
    }

    func testDeadLinkWithCookiesIsAnError() {
        guard case .failed = downloader("fail-unavailable").download(url, cookiesFile: cookieFile()) else { return XCTFail() }
    }

    func testUnsolvedJsChallengeIsBlockedNotRegion() {
        XCTAssertEqual(downloader("fail-format").download(url, cookiesFile: nil), .failed(Downloader.blockedMessage))
        XCTAssertEqual(downloader("fail-format").download(url, cookiesFile: cookieFile()), .failed(Downloader.blockedMessage))
    }

    // MARK: the JavaScript runtime and the logs

    func deno() throws -> URL {
        let d = tmp.appendingPathComponent("rt/deno")
        try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\necho deno 0\n".write(to: d, atomically: true, encoding: .utf8)
        chmod(d.path, 0o755)
        return d
    }

    func testEveryYtDlpCallGetsTheBundledDeno() throws {
        let d = try deno()
        guard case .downloaded = downloader("ok", deno: d).download(url, cookiesFile: nil) else { return XCTFail() }
        XCTAssertTrue(calls().allSatisfy { $0.contains("--js-runtimes deno:\(d.path)") }, "\(calls())")
        try FileManager.default.removeItem(at: argvLog)
        let cf = cookieFile()
        _ = downloader("cookie-ok", deno: d).download(url, cookiesFile: cf)
        XCTAssertTrue(calls().allSatisfy { $0.contains("--js-runtimes deno:\(d.path)") && $0.contains("--cookies \(cf.path)") })
    }

    func testNoDenoPassesNoFlag() {
        _ = downloader("ok").download(url, cookiesFile: nil)
        XCTAssertFalse(calls().joined().contains("--js-runtimes"))
        // the app's own choice: only an executable deno on macOS 12+ is passed
        let rt = Runtime(root: tmp.appendingPathComponent("none"), arch: "arm64", support: tmp.appendingPathComponent("S"), osMajor: 14)
        XCTAssertNil(Downloader.appDefault(rt, env: [:]).deno)
    }

    func testLastRunLogHasYtDlpStderrAndIsOverwritten() throws {
        _ = downloader("fail-format").download(url, cookiesFile: nil)
        let f = logs.appendingPathComponent("last-run.log")
        var text = try String(contentsOf: f, encoding: .utf8)
        XCTAssertTrue(text.contains("Requested format is not available"), text)
        XCTAssertTrue(text.contains("n challenge solving failed"))
        XCTAssertTrue(text.contains("outcome: error: YouTube blocked this download"))
        _ = downloader("ok").download(url, cookiesFile: nil)
        text = try String(contentsOf: f, encoding: .utf8)
        XCTAssertFalse(text.contains("Requested format"))
        XCTAssertTrue(text.contains("outcome: downloaded"))
    }

    func testALogThatCannotBeWrittenNeverCostsTheDownload() {
        let blocker = tmp.appendingPathComponent("file-not-dir")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        var d = downloader("ok")
        d.logDir = blocker.appendingPathComponent("logs")
        guard case .downloaded = d.download(url, cookiesFile: nil) else { return XCTFail() }
    }

    func testAFailureGoesToBeatKeyLogWithTheStderrTail() {
        var lines: [String] = []
        let lock = NSLock()
        AppLog.sink = { l in lock.lock(); lines.append(l); lock.unlock() }
        defer { AppLog.sink = nil }
        _ = downloader("fail-network").download("https://example.com/v", cookiesFile: nil)
        lock.lock(); let got = lines; lock.unlock()
        let line = got.first { $0.contains("download FAILED") }
        XCTAssertNotNil(line, "\(got)")
        XCTAssertTrue(line?.contains("Network error") ?? false, line ?? "")
        XCTAssertTrue(line?.contains("urlopen error") ?? false, line ?? "")
        XCTAssertTrue(line?.contains("last-run.log") ?? false)
    }

    // MARK: the whole job: download -> read with the core -> tag -> links log

    func testTheDownloadJobReadsTagsAndLogs() throws {
        guard FileManager.default.fileExists(atPath: CoreTestSupport.weights.path) else { throw XCTSkip("no core weights") }
        guard let bin = CoreFileTests.ffmpegDir else { throw XCTSkip("no ffmpeg (bin/)") }
        // a real 15 s click track for the stub to "download"
        let audio = tmp.appendingPathComponent("click.wav")
        _ = try FileReader.run(bin.appendingPathComponent("ffmpeg"), ["-v", "error", "-y", "-f", "lavfi", "-i",
            "aevalsrc=if(lt(mod(t\\,0.5)\\,0.01)\\,0.9*sin(2*PI*1000*t)\\,0)+0.08*(sin(2*PI*220*t)+sin(2*PI*261.63*t)+sin(2*PI*329.63*t)):s=44100:d=15",
            "-c:a", "pcm_s16le", audio.path])
        setenv("ORION_DOWNLOADS", dl.path, 1)
        defer { unsetenv("ORION_DOWNLOADS") }
        let jobs = CoreFileJobs(reader: { FileReader(binDir: bin, weights: CoreTestSupport.weights) },
                                downloader: { self.downloader("ok", audio: audio) })
        var events: [Event] = []
        let done = expectation(description: "job ends")
        jobs.download("https://example.com/v", cookiesFile: nil, onEvent: { events.append($0) }, onExit: { _ in done.fulfill() })
        wait(for: [done], timeout: 120)
        XCTAssertEqual(Array(events.prefix(3)), [.stage("downloading"), .stage("analyzing"), .stage("renaming")], "\(events)")
        guard case .done(let r)? = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(FileTag.isTagged(r.name), r.name)
        XCTAssertTrue(r.name.hasPrefix("Test Beat (120.0 BPM "), r.name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.file.path))
        XCTAssertEqual(try String(contentsOf: LinksLog.url(), encoding: .utf8), LinksLog.line(url: "https://example.com/v", name: r.name))
    }

    func testTheDownloadJobSaysLoginAndErrors() {
        let jobs = CoreFileJobs(reader: { FileReader(binDir: self.tmp) }, downloader: { self.downloader("fail-bot") })
        var events: [Event] = []
        let done = expectation(description: "job ends")
        jobs.download(url, cookiesFile: nil, onEvent: { events.append($0) }, onExit: { _ in done.fulfill() })
        wait(for: [done], timeout: 60)
        XCTAssertEqual(events, [.stage("downloading"),
                                .needsLogin(reason: "bot", message: Downloader.loginMessages["bot"]!, stale: false)])
    }
}
