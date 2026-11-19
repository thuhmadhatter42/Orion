import Foundation

// The YouTube download, in the app (plan step 19: it was app_run.py `download` + downloader.py's
// app mode, run on the bundled Python). The ONE owner of: the yt-dlp calls and their arguments,
// the strategy list, the one retry layer, the saved-login (cookies file) attempt, reading yt-dlp's
// errors (login needed / stale login / a sentence for the LCD), the timeout, and last-run.log.
// downloader.py stays only for the command-line tool (run.sh), which has its own browser-cookie
// order and no app behaviour.

/// How one download ended.
enum DownloadOutcome: Equatable {
    case downloaded(URL)
    /// A YouTube login would fix it ("age" | "bot" | "members"); stale = the saved login was used
    /// and YouTube no longer takes it (the app deletes it and asks again).
    case needsLogin(reason: String, stale: Bool)
    /// The LCD sentence.
    case failed(String)
}

/// One yt-dlp run: argv, exit code (nil = timed out), stdout, stderr.
struct ToolRun: Equatable {
    let argv: [String]
    let code: Int32?
    let out: String
    let err: String
}

/// Runs a tool in its own process group (yt-dlp's one-file build forks a child; a timeout kills
/// the whole group). Injected so tests can count and fake calls.
protocol ToolRunner {
    func run(_ exe: URL, _ args: [String], environment: [String: String], timeout: TimeInterval?) -> ToolRun
}

struct SpawnRunner: ToolRunner {
    func run(_ exe: URL, _ args: [String], environment: [String: String], timeout: TimeInterval?) -> ToolRun {
        let argv = [exe.path] + args
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            return ToolRun(argv: argv, code: -1, out: "", err: "pipe failed: \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for fd in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] { posix_spawn_file_actions_addclose(&actions, fd) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe.path, &actions, &attr, cArgs, cEnv)
        cArgs.forEach { free($0) }
        cEnv.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return ToolRun(argv: argv, code: -1, out: "", err: "\(exe.lastPathComponent) could not start: \(String(cString: strerror(rc)))")
        }
        var out = Data(), err = Data()
        let g = DispatchGroup()
        for (fd, isOut) in [(outPipe[0], true), (errPipe[0], false)] {
            g.enter()
            DispatchQueue.global(qos: .utility).async {
                let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                let d = h.readDataToEndOfFile()
                if isOut { out = d } else { err = d }
                g.leave()
            }
        }
        var status: Int32 = 0
        var timedOut = false
        if let t = timeout {
            let deadline = Date().addingTimeInterval(t)
            while true {
                let r = waitpid(pid, &status, WNOHANG)
                if r == pid || r == -1 { break }
                if Date() >= deadline {
                    timedOut = true
                    killpg(pid, SIGKILL)
                    kill(pid, SIGKILL)
                    waitpid(pid, &status, 0)
                    break
                }
                usleep(20_000)
            }
        } else {
            waitpid(pid, &status, 0)
        }
        // a timed-out tool's grandchildren may still hold the pipes: do not wait forever for them
        _ = g.wait(timeout: .now() + (timedOut ? 5 : 3600))
        let code: Int32? = timedOut ? nil : ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
        return ToolRun(argv: argv, code: code, out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self))
    }
}

/// The app's YouTube download: one call = one try of every strategy, as app_run.py did.
struct Downloader {
    let ytdlp: URL
    /// The JavaScript runtime yt-dlp solves YouTube's challenges with; nil = none passed.
    let deno: URL?
    /// The folder the file lands in (Doctor.downloadsFolder: ORION_DOWNLOADS or ~/Downloads).
    let downloads: URL
    /// The environment yt-dlp runs in: PATH finds the bundled ffmpeg for --extract-audio.
    let environment: [String: String]
    /// Seconds per yt-dlp call.
    var timeout: TimeInterval = Downloader.defaultTimeout
    var runner: ToolRunner = SpawnRunner()
    /// Where last-run.log goes (AppLog.lastRunURL's folder).
    var logDir: URL = AppLog.lastRunURL.deletingLastPathComponent()

    static let defaultTimeout: TimeInterval = 600

    static func appDefault(_ rt: Runtime, env: [String: String] = ProcessInfo.processInfo.environment) -> Downloader {
        let fm = FileManager.default
        let yt = fm.isExecutableFile(atPath: rt.ytdlp.path) ? rt.ytdlp : rt.bundledYtDlp
        let deno = rt.hasJSRuntime && fm.isExecutableFile(atPath: rt.deno.path) ? rt.deno : nil
        let timeout = env["ORION_YTDLP_TIMEOUT"].flatMap(Double.init) ?? defaultTimeout
        return Downloader(ytdlp: yt, deno: deno, downloads: Doctor.downloadsFolder(env: env),
                          environment: rt.environment(passing: env), timeout: timeout)
    }

    // MARK: the pieces (pure)

    /// The strategies, in order: the non-cookie ones (never a browser's cookies), or exactly one
    /// `--cookies <file>` attempt with the login Beat Key saved from its own login window.
    static func strategies(cookiesFile: URL?) -> [[String]] {
        if let c = cookiesFile { return [["--cookies", c.path]] }
        return [["--extractor-args", "youtube:player_client=android"],
                ["--extractor-args", "youtube:player_client=web"],
                []]
    }

    var jsRuntimeArgs: [String] { deno.map { ["--js-runtimes", "deno:\($0.path)"] } ?? [] }

    static func lowered(_ lines: [String]) -> String {
        lines.joined(separator: " ").lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// "age" | "bot" | "members" when yt-dlp's error says a YouTube login would fix it.
    static func loginReason(_ lines: [String]) -> String? {
        let t = lowered(lines)
        if t.contains("private video") { return nil }
        if t.contains("sign in to confirm your age") || t.contains("age-restricted") || t.contains("inappropriate for some users") { return "age" }
        if t.contains("not a bot") { return "bot" }
        if t.contains("members-only") || t.contains("members only") || t.contains("join this channel") { return "members" }
        return nil
    }

    /// yt-dlp says the --cookies login no longer works (YouTube rotated or signed it out).
    static func cookiesStale(_ lines: [String]) -> Bool {
        lines.joined(separator: " ").lowercased().contains("cookies are no longer valid")
    }

    /// The LCD's words for each login reason (the Engine's login prompt carries them).
    static let loginMessages = [
        "age": "This video is age-restricted. A YouTube login is needed.",
        "bot": "YouTube wants a login before it will serve this video.",
        "members": "This video is for channel members. A YouTube login is needed.",
    ]

    static let privateMessage = "That video is private and cannot be downloaded."
    static let unavailableMessage = "That video is unavailable or has been removed."
    static let regionMessage = "That video is not available in your country."
    static let invalidURLMessage = "That doesn't look like a valid URL — paste a full https:// link."
    static let blockedMessage = "YouTube blocked this download. Try Beat Key › Run Doctor."
    static let loginHintMessage = "YouTube is blocking the download. Open YouTube in Firefox, sign in, then retry."
    static let timeoutMessage = "Download timed out."
    static let unknownMessage = "Download failed for an unknown reason."

    /// The LCD sentence for yt-dlp's error lines. Every phrase matched is one yt-dlp itself prints.
    static func explain(_ lines: [String], url: String = "") -> String {
        let t = lowered(lines)
        func has(_ s: String...) -> Bool { s.contains { t.contains($0) } }
        if has("private video") { return privateMessage }
        if has("sign in to confirm your age", "age-restricted", "inappropriate for some users") {
            return "That video is age-restricted. Open YouTube in Firefox and sign in, then retry."
        }
        if has("not a bot") { return loginHintMessage }
        if has("copyright") { return "This video is blocked due to a copyright claim." }
        if has("not made this video available in your country", "not available from your location") { return regionMessage }
        if t.contains("try again later") && t.contains("rate-limited") {
            return "YouTube is limiting downloads from this Mac. Wait an hour, then try again."
        }
        // YouTube served no audio: its JS challenge went unsolved, or it held the formats back
        if has("requested format is not available", "only images are available", "challenge solving failed",
               "signature solving failed", "no video formats found") { return blockedMessage }
        if has("video unavailable", "this video is unavailable", "this video is not available",
               "this video has been removed", "this video is no longer available") { return unavailableMessage }
        if has("urlopen error", "unable to download webpage", "network is unreachable", "connection") {
            return "Network error — check your connection and try again."
        }
        if has("unsupported url", "is not a valid url") || (!url.isEmpty && !url.hasPrefix("http")) { return invalidURLMessage }
        if has("sign in", "login") { return loginHintMessage }
        for line in lines.reversed() {
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !l.isEmpty && !l.contains("github.com") && !l.contains("yt-dlp -U") { return "Download failed: \(l)" }
        }
        return unknownMessage
    }

    /// A file name from a title: path and shell-hostile characters become "_".
    static func safeName(_ text: String) -> String {
        var s = text
        for ch in #"\/:*?"<>|[]"# { s = s.replacingOccurrences(of: String(ch), with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return s.isEmpty ? "audio" : s
    }

    private static func lines(_ r: ToolRun) -> [String] {
        (r.out + r.err).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: one download

    /// Blocking; call off the main thread. Every yt-dlp call is kept for last-run.log.
    func download(_ url: String, cookiesFile: URL?) -> DownloadOutcome {
        var runs: [ToolRun] = []
        var outcome: DownloadOutcome = .failed(Downloader.unknownMessage)
        var errs: [String] = []
        defer {
            if let c = cookiesFile { chmod(c.path, 0o600) }   // yt-dlp writes the jar back; keep it owner-only
            writeLastRun(url: url, cookies: cookiesFile != nil, outcome: outcome, runs: runs)
            if case .failed(let m) = outcome { logFailure(m, runs: runs) }
        }
        if let c = cookiesFile, !FileManager.default.fileExists(atPath: c.path) {
            // the saved login is gone: ask for one again rather than run without it
            outcome = .needsLogin(reason: "age", stale: true)
            return outcome
        }
        let result = attempt(url, cookiesFile: cookiesFile, runs: &runs, errs: &errs)
        switch result {
        case .some(.success(let path)):
            outcome = .downloaded(path)
        case .some(.failure(let message)):
            if message != Downloader.timeoutMessage {
                let reason = Downloader.loginReason(errs)
                if cookiesFile != nil && (reason != nil || Downloader.cookiesStale(errs)) {
                    outcome = .needsLogin(reason: reason ?? "age", stale: true)
                    return outcome
                }
                if let r = reason { outcome = .needsLogin(reason: r, stale: false); return outcome }
            }
            outcome = .failed(message)
        case .none:
            outcome = .failed(Downloader.unknownMessage)   // yt-dlp said yes but left no file
        }
        return outcome
    }

    private enum Attempt { case success(URL), failure(String) }

    /// The one retry layer: each strategy fetches the metadata and downloads with the same
    /// arguments; the first that gets the file wins. Nothing retries the same failure again (no
    /// second pass, no upgrade-and-repeat: yt-dlp is upgraded at launch and in Run Doctor).
    private func attempt(_ url: String, cookiesFile: URL?, runs: inout [ToolRun], errs: inout [String]) -> Attempt? {
        var metaErr: [String] = [], downloadErr: [String] = []
        var reachedDownload = false
        for s in Downloader.strategies(cookiesFile: cookiesFile) {
            let extra = jsRuntimeArgs + s
            let meta = runner.run(ytdlp, ["--dump-json", "--no-playlist"] + extra + [url], environment: environment, timeout: timeout)
            runs.append(meta)
            guard let code = meta.code else { return .failure(Downloader.timeoutMessage) }
            let lastOut = meta.out.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            guard code == 0, !lastOut.trimmingCharacters(in: .whitespaces).isEmpty,
                  let info = (try? JSONSerialization.jsonObject(with: Data(lastOut.utf8))) as? [String: Any] else {
                metaErr = Downloader.lines(meta)
                continue
            }
            let title = Downloader.safeName((info["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "audio")
            let template = downloads.appendingPathComponent("\(title).%(ext)s").path
            reachedDownload = true
            let dl = runner.run(ytdlp, ["-f", "bestaudio/best", "-o", template, "--no-playlist", "--quiet", "--no-progress",
                                        "--extract-audio", "--audio-format", "mp3", "--audio-quality", "0",
                                        "--print", "after_move:filepath", "--print", "%(format_id)s", "--print", "%(abr)s"]
                                + extra + [url], environment: environment, timeout: timeout)
            runs.append(dl)
            guard let dcode = dl.code else { return .failure(Downloader.timeoutMessage) }
            guard dcode == 0 else { downloadErr = Downloader.lines(dl); continue }
            // exit 0 = success; the path from --print, else the newest "<title>.*" in the folder
            let printed = dl.out.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !printed.isEmpty, FileManager.default.fileExists(atPath: printed) { return .success(URL(fileURLWithPath: printed)) }
            let fm = FileManager.default
            let matches = ((try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(title + ".") }
                .sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a > b
                }
            if let m = matches.first { return .success(m) }
            return nil
        }
        // a strategy that got as far as the download has the more useful error
        errs = reachedDownload ? downloadErr : metaErr
        return .failure(Downloader.explain(errs, url: url))
    }

    // MARK: the logs

    /// Secrets yt-dlp may print (cookies, tokens, signatures), blanked in every log.
    static func redact(_ line: String) -> String {
        let re = try! NSRegularExpression(pattern: #"(?i)\b(cookie|cookies|authorization|sapisid\w*|po_?token|visitor_?data|token|key|sig|signature)(\s*[=:]\s*)([^\s&,;'"]+)"#)
        return re.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1$2<redacted>")
    }

    static func outcomeText(_ o: DownloadOutcome) -> String {
        switch o {
        case .downloaded: return "downloaded"
        case .needsLogin(_, true): return "needs_login: saved login no longer works"
        case .needsLogin(let r, false): return "needs_login: \(r)"
        case .failed(let m): return "error: \(m)"
        }
    }

    /// last-run.log: the last download's yt-dlp calls and their stderr, overwritten every run,
    /// for whoever debugs the next failure. Never costs the download.
    func writeLastRun(url: String, cookies: Bool, outcome: DownloadOutcome, runs: [ToolRun]) {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = "yyyy-MM-dd"
        var lines = ["Beat Key last run  \(d.string(from: Date()))", "url: \(url)",
                     "login: \(cookies ? "saved YouTube login" : "-")", "outcome: \(Downloader.outcomeText(outcome))", ""]
        for r in runs {
            lines.append("$ " + r.argv.joined(separator: " "))
            lines.append("exit: \(r.code.map(String.init) ?? "timeout")")
            let err = r.code == nil ? "(timed out)" : r.err
            lines += err.split(whereSeparator: \.isNewline).map { Downloader.redact(String($0)) }
            lines.append("")
        }
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: logDir.appendingPathComponent("last-run.log"), atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("download: could not write last-run.log: \(error)")
        }
    }

    /// A failed download in beatkey.log: the sentence and the tail of yt-dlp's stderr.
    func logFailure(_ message: String, runs: [ToolRun]) {
        let tail = runs.flatMap { r -> [String] in
            (r.code == nil ? "(timed out)" : r.err).split(whereSeparator: \.isNewline).map { Downloader.redact(String($0)) }
        }.suffix(8)
        AppLog.log("download FAILED: \(message); yt-dlp stderr tail: "
                   + (tail.isEmpty ? "(none)" : tail.joined(separator: " | ")) + " (every call: last-run.log)")
    }
}
