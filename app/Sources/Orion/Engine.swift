import Foundation

enum ViewState: Equatable {
    case idle
    case working(stage: String)
    case done(Result)
    case analyzed([Result])
    case failed(String)
    /// Not a failure: the next try needs a YouTube login. Not busy.
    case needsLogin(LoginPrompt)
    case doctor(DoctorReport)

    var stageName: String? { if case .working(let s) = self { return s } else { return nil } }
    var isBusy: Bool { if case .working = self { return true } else { return false } }
}

/// What the faceplate asks for after a login-fixable error.
struct LoginPrompt: Equatable {
    let url: String
    let reason: String      // "age" | "bot" | "members"
}

/// Launches a process and streams stdout lines. Injected so tests never spawn Python.
protocol ProcessLauncher {
    /// onLine and onExit may be called from any queue; the Engine hops to main.
    func launch(executable: URL, arguments: [String], environment: [String: String],
                onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void)
}

final class RealLauncher: ProcessLauncher {
    func launch(executable: URL, arguments: [String], environment: [String: String],
                onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = environment.merging(["HOME": NSHomeDirectory()]) { a, _ in a }
        let out = Pipe()
        p.standardOutput = out
        // app_run.py's stderr (its failure lines, bpm.py's warnings and tracebacks) → analyzer.log
        let what = arguments.dropFirst().first ?? "?"
        p.standardError = AppLog.analyzerHandle(header: "app_run.py \(what)") ?? FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch {
                AppLog.log("helper (app_run.py \(what)) failed to start: \(error)")
                onExit(-1); return
            }
            var buf = Data()
            let h = out.fileHandleForReading
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
                    buf.removeSubrange(buf.startIndex...nl)
                    onLine(line)
                }
            }
            if !buf.isEmpty { onLine(String(decoding: buf, as: UTF8.self)) }
            p.waitUntilExit()
            if p.terminationStatus != 0 || p.terminationReason != .exit {
                AppLog.log("helper (app_run.py \(what)) exited: status \(p.terminationStatus), "
                           + "reason \(p.terminationReason == .exit ? "exit" : "signal"); details in analyzer.log")
            }
            onExit(p.terminationStatus)
        }
    }
}

final class Engine: ObservableObject {
    @Published var state: ViewState = .idle {
        didSet {
            AppLog.log("engine: " + String(String(describing: state).prefix(400)))
            if let why = Engine.failureNote(state) { AppLog.log(why) }
            if oldValue.isBusy, !state.isBusy { queueAfterJob() }
        }
    }
    /// Caption under a partial analysis ("2 FILES COULDN'T BE READ · ..."); nil otherwise.
    @Published var note: String?
    private let runtime: Runtime
    private let launcher: ProcessLauncher
    private var results: [Result] = []
    private var expected = 0
    /// Files that arrived while a job was running (Intake.receive, every surface): FIFO, no
    /// duplicate paths. They start, as one analysis, when the running job ends.
    private var queue: [URL] = []
    /// How many files wait (the drop queue).
    @Published private(set) var queued = 0
    /// The files of the analysis that is running now (empty for a download or Run Doctor).
    private var activeFiles: [URL] = []
    /// Readings of the earlier jobs of one queued run: the last job's state pages through all of them.
    private var carried: [Result] = []
    private var sawTerminal = false
    private var pendingURL = ""
    private var generation = 0
    private let makeDoctor: (Runtime) -> Doctor
    private let doctorQueue: DispatchQueue
    /// After Run Doctor shows its report: the app asks Sparkle for a newer Beat Key.
    private let afterDoctor: () -> Void
    /// Touches the Downloads folder so macOS asks for access when DOWNLOAD is pressed, not after
    /// the download. nil = no probe (tests, and ORION_DOWNLOADS runs).
    private let downloadsProbe: (() -> Bool)?
    /// The saved YouTube login (cookies file) for yt-dlp, nil = none. Tests inject their own.
    private let savedLogin: () -> URL?
    /// YouTube no longer takes the saved login: delete it.
    private let dropLogin: () -> Void
    /// The running download uses the saved login.
    private var usedLogin = false
    /// Every reading that comes out is remembered here (Recent Readings). nil = not kept (tests).
    private let recents: RecentStore?
    /// Called with the results of every analysis once they are on the LCD (never for a download).
    /// The app wires the rename policy here (Rename.swift).
    var afterAnalysis: (([Result]) -> Void)?
    /// The pin that follows a renamed file. Tests inject their own.
    var spelling: SpellingSettings = .shared
    private var renameQueue: [RenameItem] = []
    private var renaming = false

    /// The app's probe: create and remove a hidden file in ~/Downloads. None when ORION_DOWNLOADS
    /// is set (a test/debug run that never touches the real folder).
    static func defaultProbe(env: [String: String] = ProcessInfo.processInfo.environment) -> (() -> Bool)? {
        if let d = env["ORION_DOWNLOADS"], !d.isEmpty { return nil }
        let dir = Doctor.downloadsFolder(env: env)
        return { Doctor.probeWritable(dir) }
    }

    init(runtime: Runtime = .appDefault(), launcher: ProcessLauncher = RealLauncher(),
         doctor: ((Runtime) -> Doctor)? = nil,
         doctorQueue: DispatchQueue = .global(qos: .userInitiated),
         downloadsProbe: (() -> Bool)? = nil,
         savedLogin: @escaping () -> URL? = { nil },
         dropLogin: @escaping () -> Void = {},
         afterDoctor: @escaping () -> Void = {},
         recents: RecentStore? = nil) {
        self.recents = recents
        self.afterDoctor = afterDoctor
        self.downloadsProbe = downloadsProbe
        self.savedLogin = savedLogin
        self.dropLogin = dropLogin
        self.runtime = runtime
        self.launcher = launcher
        self.makeDoctor = doctor ?? { Doctor(runtime: $0) }
        self.doctorQueue = doctorQueue
    }

    /// Beat Key › Run Doctor. Off main; the LCD shows each step. Ignored while busy, and while it
    /// runs the state is .working, so downloads and analyses are ignored.
    func runDoctor() {
        runOnMain {
            guard !self.state.isBusy else { return }
            self.generation += 1
            let gen = self.generation
            self.state = .working(stage: Doctor.stages[0])
            let doctor = self.makeDoctor(self.runtime)
            self.doctorQueue.async {
                // waits its turn behind the launch seed / upgrade
                let report = Runtime.maintenanceQueue.sync {
                    doctor.run { stage in
                        DispatchQueue.main.async { if gen == self.generation { self.state = .working(stage: stage) } }
                    }
                }
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.state = .doctor(report)
                    if report.outcome == .failed, report.line == Doctor.permissionHint.uppercased() {
                        AppLog.log("doctor: permission failure; opening the permission guide")
                        PermissionGuide.shared.need(nil, why: "Run Doctor permission hint")
                    }
                    // the tools are checked; now the app itself (Sparkle's own window)
                    self.afterDoctor()
                }
            }
        }
    }

    /// useLogin = run with the saved YouTube login (`--cookies-file`), the only way a download
    /// ever carries a login. No saved login = the login prompt again, nothing launched.
    func download(_ url: String, useLogin: Bool = false) {
        runOnMain {
            guard !self.state.isBusy else { return }
            self.pendingURL = url
            if useLogin && self.savedLogin() == nil {
                self.generation += 1
                self.state = .needsLogin(LoginPrompt(url: url, reason: "age"))
                return
            }
            self.begin(self.downloadArgs(url, useLogin: useLogin), stage: "downloading", probe: self.downloadsProbe)
        }
    }

    private func downloadArgs(_ url: String, useLogin: Bool) -> [String] {
        let login = useLogin ? savedLogin() : nil
        usedLogin = login != nil
        return ["download", url] + (login.map { ["--cookies-file", $0.path] } ?? [])
    }

    /// Drops the login prompt (the link changed). Anything else is left alone.
    func clearLogin() {
        runOnMain { if case .needsLogin = self.state { self.state = .idle } }
    }

    /// Recent Readings: put an earlier reading back on the LCD. Ignored while busy.
    func show(_ r: Result) {
        runOnMain {
            guard !self.state.isBusy else { return }
            self.generation += 1
            self.note = nil
            self.state = .analyzed([r])
        }
    }

    /// Starts an analysis now; ignored while busy. Files that arrive from outside (drop, open,
    /// Dock, pocket, Mini) never come here: they go through `submit`.
    func analyze(_ files: [URL]) {
        guard !files.isEmpty else { return }
        start(["analyze"] + files.map { $0.path }, stage: "analyzing", expected: files.count)
    }

    /// The one place files wait their turn. Idle: they start at once. Busy: they join the queue
    /// (duplicates of a queued or running path are left out) and start when the job ends.
    func submit(_ files: [URL]) {
        runOnMain {
            var seen = Set(self.queue.map(Engine.pathKey))
            if self.state.isBusy { seen.formUnion(self.activeFiles.map(Engine.pathKey)) }
            var added = 0, duplicates = 0
            for f in files {
                if seen.insert(Engine.pathKey(f)).inserted { self.queue.append(f); added += 1 } else { duplicates += 1 }
            }
            self.queued = self.queue.count
            AppLog.log("queue: added \(added), \(duplicates) duplicate skipped, size \(self.queue.count)"
                       + (self.state.isBusy ? ", waiting for the running job" : ""))
            self.startQueued(keepBatch: false)
        }
    }

    private static func pathKey(_ u: URL) -> String { u.standardizedFileURL.path }

    /// Idle and files waiting: all of them become one analysis. keepBatch = the readings so far stay
    /// on the pager (the next job of one queued run).
    private func startQueued(keepBatch: Bool) {
        guard !queue.isEmpty, keepBatch || !state.isBusy else { return }
        let files = queue
        queue = []; queued = 0
        AppLog.log("queue: start \(files.count) file(s)" + (keepBatch ? " (next job of the run)" : ""))
        begin(["analyze"] + files.map { $0.path }, stage: "analyzing", expected: files.count, keepBatch: keepBatch)
    }

    /// A job ended and files are waiting. A failure or login prompt stays on the LCD until the next job.
    private func queueAfterJob() {
        guard !queue.isEmpty else { return }
        switch state {
        case .failed, .needsLogin:
            AppLog.log("queue: \(queue.count) file(s) held behind a message that needs you; they start after the next job")
        default:
            DispatchQueue.main.async { self.startQueued(keepBatch: false) }
        }
    }

    private func start(_ args: [String], stage: String, expected: Int = 0, probe: (() -> Bool)? = nil) {
        runOnMain {
            guard !self.state.isBusy else { return }
            if args.first != "download" { self.usedLogin = false }
            self.begin(args, stage: stage, expected: expected, probe: probe)
        }
    }

    /// start without the busy check: also the automatic re-run with the saved login.
    private func begin(_ args: [String], stage: String, expected: Int = 0, probe: (() -> Bool)? = nil,
                       keepBatch: Bool = false) {
        runOnMain {
            if !keepBatch { self.carried = [] }
            self.activeFiles = args.first == "analyze" ? args.dropFirst().map { URL(fileURLWithPath: $0) } : []
            self.generation += 1
            let gen = self.generation
            self.state = .working(stage: probe == nil ? stage : "allow-downloads")
            self.results = []
            self.note = nil
            self.expected = expected
            self.sawTerminal = false
            guard let probe = probe else { self.launchHelper(args, gen: gen); return }
            // Touch ~/Downloads first so the macOS prompt shows now; the helper waits for the answer.
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = probe()
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    if ok {
                        self.state = .working(stage: stage)
                        self.launchHelper(args, gen: gen)
                    } else {
                        self.state = .failed("Operation not permitted: Downloads")
                    }
                }
            }
        }
    }

    /// Starts the helper once yt-dlp is seeded and no maintenance (launch upgrade, doctor) is running.
    private func launchHelper(_ args: [String], gen: Int) {
        let rt = runtime
        let stage = state.stageName
        var launched = false   // main thread only
        if args.first == "download" {
            // Waiting behind a seed / upgrade for more than a moment: say so.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !launched && gen == self.generation { self.state = .working(stage: "updating") }
            }
        }
        Runtime.maintenanceQueue.async {
            rt.ensureSeeded()
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                launched = true
                if let s = stage { self.state = .working(stage: s) }
                self.launcher.launch(
                    executable: rt.python,
                    arguments: [rt.script.path] + args,
                    environment: rt.environment(),
                    onLine: { line in
                        guard let e = Event.parse(line: line) else {
                            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                                AppLog.log("helper printed a non-event line: \(line.prefix(200))")
                            }
                            return
                        }
                        DispatchQueue.main.async { if gen == self.generation { self.handle(e) } }
                    },
                    onExit: { code in
                        DispatchQueue.main.async { if gen == self.generation { self.finish(code) } }
                    })
            }
        }
    }

    /// For a failure, or files with no reading: one line saying where its details are.
    static func failureNote(_ s: ViewState) -> String? {
        switch s {
        case .failed(let m):
            return "engine FAILED: \(m) (yt-dlp runs: last-run.log; helper stderr: analyzer.log)"
        case .analyzed(let rs):
            let bad = rs.filter { $0.bpm == nil }
            guard !bad.isEmpty else { return nil }
            return "engine: no reading for \(bad.count) of \(rs.count) file(s): "
                + bad.prefix(5).map { "\($0.name)\($0.readError.map { " [\($0)]" } ?? "")" }.joined(separator: ", ")
                + " (why: analyzer.log)"
        case .done(let r) where r.bpm == nil:
            return "engine: downloaded \(r.name) but no reading (why: analyzer.log)"
        default:
            return nil
        }
    }

    private func runOnMain(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
    }

    func handle(_ e: Event) {
        switch e {
        case .stage(let s): if !sawTerminal { state = .working(stage: s) }
        case .done(let r): sawTerminal = true; state = .done(r); recents?.record(r)
        case .analyzed(let r): results.append(r)
        case .error(let m):
            sawTerminal = true
            if !activeFiles.isEmpty, !queue.isEmpty || !carried.isEmpty {
                // a failed job inside a queued run: its files become failed rows, the run goes on
                AppLog.log("queue: a job failed (\(m.prefix(120))); its files are shown as unread")
                endAnalysis(results + unread(), code: -1)
            } else { state = .failed(m) }
        case .renamed, .renameSkipped, .renameFailed:
            handleRename(e)
        case .needsLogin(let reason, _, let stale):
            sawTerminal = true
            if stale || usedLogin {
                // YouTube no longer takes the saved login: throw it away, ask for a new one
                dropLogin()
            } else if YouTubeLogin.inApp, savedLogin() != nil {
                // a later blocked video: straight to the saved login, no window
                let url = pendingURL
                state = .working(stage: "downloading")
                begin(downloadArgs(url, useLogin: true), stage: "downloading")
                return
            }
            usedLogin = false
            state = .needsLogin(LoginPrompt(url: pendingURL, reason: reason))
        }
    }

    // MARK: rename (the helper's `rename`, one file at a time, quietly: the LCD is never busy)

    /// Tags each file's name through the helper's one renamer, then refreshes every place the old
    /// path lived (the reading on show, Recent Readings, the pinned key).
    func rename(_ items: [RenameItem]) {
        runOnMain {
            self.renameQueue += items
            self.renameNext()
        }
    }

    private func renameNext() {
        guard !renaming, !renameQueue.isEmpty else { return }
        renaming = true
        let item = renameQueue.removeFirst()
        var sawEvent = false   // main thread only
        launcher.launch(
            executable: runtime.python,
            arguments: [runtime.script.path, "rename", item.file.path, item.bpm] + item.keys,
            environment: runtime.environment(),
            onLine: { line in
                guard let e = Event.parse(line: line) else {
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        AppLog.log("rename: helper printed a non-event line: \(line.prefix(200))")
                    }
                    return
                }
                DispatchQueue.main.async { sawEvent = true; self.handleRename(e) }
            },
            onExit: { code in
                DispatchQueue.main.async {
                    if !sawEvent {
                        AppLog.log("rename: FAILED, the helper stopped without an answer (exit \(code); analyzer.log)")
                        self.note = Faceplate.renameFailedNote("The helper stopped unexpectedly.")
                    }
                    self.renaming = false
                    self.renameNext()
                }
            })
    }

    private func handleRename(_ e: Event) {
        switch e {
        case .renamed(let from, let to):
            applyRenamed(from: URL(fileURLWithPath: from), to: URL(fileURLWithPath: to))
        case .renameSkipped:
            AppLog.log("rename: skipped (already tagged) by the helper")
        case .renameFailed(_, let errno, let message):
            AppLog.log("rename: FAILED errno \(errno): \(message)")
            note = Faceplate.renameFailedNote(message)
        default:
            break
        }
    }

    /// The one place a renamed file's new path is taken over: the LCD's reading, Recent Readings,
    /// the pinned key. Nothing keeps the old path.
    private func applyRenamed(from old: URL, to new: URL) {
        switch state {
        case .analyzed(let rs) where rs.contains(where: { $0.file == old }):
            state = .analyzed(rs.map { $0.file == old ? $0.moved(to: new) : $0 })
        case .done(let r) where r.file == old:
            state = .done(r.moved(to: new))
        default: break
        }
        recents?.moved(from: old.path, to: new)
        spelling.moved(from: old, to: new)
        AppLog.log("rename: done")
    }

    private func finish(_ code: Int32) {
        guard !sawTerminal else { return }
        let inRun = !queue.isEmpty || !carried.isEmpty
        if !results.isEmpty {
            // Nothing readable and macOS refused it: say where to allow it, not a blank readout.
            if !inRun, results.allSatisfy({ $0.bpm == nil && $0.readError == "permission" }) {
                state = .failed("Operation not permitted: \(results[0].name)")
                return
            }
            // a job inside a queued run that lost files: they show as unread rows, the run goes on
            endAnalysis(code != 0 && !queue.isEmpty ? results + unread() : results, code: code)
        } else if state.isBusy {
            if inRun, !activeFiles.isEmpty {
                AppLog.log("queue: a job ended with no readings (exit \(code)); its files are shown as unread")
                endAnalysis(unread(), code: code)
            } else {
                state = .failed("The helper stopped unexpectedly (exit \(code)).")
            }
        }
    }

    /// The running analysis' files the helper gave no row for, as failed rows (the existing
    /// "no reading" path: failureNote names them in the log, the LCD shows them unread).
    private func unread() -> [Result] {
        let got = Set(results.map { Engine.pathKey($0.file) })
        return activeFiles.filter { !got.contains(Engine.pathKey($0)) }.map {
            Result(file: $0, name: $0.lastPathComponent, bpm: nil, keys: [], readError: "helper stopped")
        }
    }

    /// An analysis job ended with these rows. Files are waiting: keep the rows and start the next
    /// job (the LCD never goes idle in between). Otherwise every row of the run goes on the pager.
    private func endAnalysis(_ rows: [Result], code: Int32) {
        results.forEach { recents?.record($0) }
        // the rename offer sees each job's real readings once (never the unread placeholder rows)
        if !results.isEmpty { afterAnalysis?(results) }
        if !queue.isEmpty {
            carried += rows
            startQueued(keepBatch: true)
            return
        }
        if code != 0 { note = Faceplate.partialNote(max(expected - results.count, 1)) }
        state = .analyzed(carried + rows)
    }
}
