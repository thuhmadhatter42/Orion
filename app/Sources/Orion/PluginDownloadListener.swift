import AppKit
import Foundation

// DOWNLOAD from the plug-in, the app's half (overnight plan 2026-11-20 §4-§6). The plug-in posts
// `com.jshriver.orion.download` with a link, an optional Pro Tools placement and its host; this
// listener downloads with the app's own Swift downloader (CoreFileJobs: yt-dlp, then the core reads the
// BPM + key and the file is named with them, exactly as the app's DOWNLOAD does), then
//
//   placement picked AND the host is Pro Tools -> PTSLImport.run (CId_Import) off the main thread
//   anything else                              -> the file stays in Downloads and is shown in Finder
//
// and answers `com.jshriver.orion.downloaded`: progress lines (at least every `progressEvery` s, the
// plug-in's quiet clock is 45 s) and ONE final reply (ok, message, path, imported, bpm, key).
// Contract: BeatKeyShared/PluginDownload.swift.
//
//   a bad payload              -> final(no, the reason) when it has a requestID, else only logged
//   a second request while one runs -> REFUSED, never queued: "Beat Key is already downloading."
//                                 (one run at a time; the plug-in shows the line and J presses again.
//                                 A queue would hold a host-side face waiting through two downloads
//                                 with no way to cancel the second.)
//   a link that needs a YouTube login -> retried once with the app's saved login, else the reason
// Every failure writes ONE line to beatkey.log through PluginErrorLog (source=plugin, the request's
// host name); every request and every answer also logs an app line ([PluginDownloadListener]).

final class PluginDownloadListener {
    static let shared = PluginDownloadListener()

    typealias Transport = PluginSendListener.Transport

    static let busyLine = "Beat Key is already downloading. Try again when it's done."

    private let transport: Transport
    private let makeJobs: () -> FileJobs
    private var jobsInstance: FileJobs?
    /// Blocking, off the main thread: yt-dlp is seeded and no maintenance is running.
    private let prepare: () -> Void
    /// The app's saved YouTube login (cookies file), nil = none.
    private let savedLogin: () -> URL?
    private let dropLogin: () -> Void
    /// Touches ~/Downloads so macOS asks now (nil = no probe: tests, ORION_DOWNLOADS runs). Off main.
    private let downloadsProbe: (() -> Bool)?
    /// Blocking, called off the main thread.
    private let importer: (URL, DownloadPlacement) -> PTSLImport.Outcome
    /// Main thread.
    private let reveal: (URL) -> Void
    private let progressEvery: TimeInterval
    private var installed = false
    private var busy = false

    init(transport: Transport = .distributed,
         jobs: (() -> FileJobs)? = nil,
         prepare: @escaping () -> Void = { Runtime.maintenanceQueue.sync { Runtime.appDefault().ensureSeeded() } },
         savedLogin: @escaping () -> URL? = {
             let f = CookieFile.appDefault()
             return YouTubeLogin.inApp && f.exists ? f.url : nil
         },
         dropLogin: @escaping () -> Void = { CookieFile.appDefault().delete() },
         downloadsProbe: (() -> Bool)? = Engine.defaultProbe(),
         importer: @escaping (URL, DownloadPlacement) -> PTSLImport.Outcome = { PTSLImport.run(file: $0, placement: $1) },
         reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
         progressEvery: TimeInterval = 20) {
        self.transport = transport
        self.makeJobs = jobs ?? { CoreFileJobs(runtime: .appDefault()) }
        self.prepare = prepare
        self.savedLogin = savedLogin
        self.dropLogin = dropLogin
        self.downloadsProbe = downloadsProbe
        self.importer = importer
        self.reveal = reveal
        self.progressEvery = progressEvery
    }

    /// Once, from OrionApp.launch (beside PluginSendListener).
    func install() {
        guard !installed else { return }
        installed = true
        transport.observe(PluginDownload.requestName) { [weak self] info in self?.handle(info) }
        AppLog.log("plug-in download on: listening for \(PluginDownload.requestName.rawValue), answering \(PluginDownload.replyName.rawValue)")
    }

    // MARK: one request

    /// One run: what the timer and the failure paths need to know.
    private final class Run {
        let req: PluginDownload.Request
        let host: String
        var attempt = 0
        var stage = "starting"
        var usedLogin = false
        var progressText = "Starting the download."
        var timer: Timer?
        var finished = false
        init(_ req: PluginDownload.Request) {
            self.req = req
            host = req.hostName.isEmpty ? (req.hostBundleID.isEmpty ? "unknown host" : req.hostBundleID) : req.hostName
        }
    }

    /// One request (main thread).
    func handle(_ info: [AnyHashable: Any]?) {
        let d = PluginDownload.Request.decode(info)
        guard let req = d.request else {
            let reason = d.refusal ?? "unreadable"
            let host = (info?["hostName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown host"
            AppLog.log("ERROR plug-in download refused: \(reason)")
            PluginErrorLog.write(.appListener, "download request refused: \(reason)", host: host)
            if let rid = d.requestID { reply(.init(requestID: rid, final: true, ok: false, message: "Beat Key app refused it: \(reason).")) }
            return
        }
        let run = Run(req)
        AppLog.log("plug-in download: from \(run.host) (pid \(req.hostPid), request \(req.requestID.prefix(8))), placement \(req.placement?.wire ?? "none")")
        guard !busy else {
            AppLog.log("ERROR plug-in download refused: already downloading")
            PluginErrorLog.write(.appListener, "download request refused: already downloading", host: run.host)
            reply(.init(requestID: req.requestID, final: true, ok: false, message: PluginDownloadListener.busyLine))
            return
        }
        busy = true
        progress(run, "Starting the download.")
        let timer = Timer(timeInterval: progressEvery, repeats: true) { [weak self, weak run] _ in
            guard let self, let run, !run.finished else { return }
            self.reply(.progress(run.req.requestID, run.progressText))
        }
        RunLoop.main.add(timer, forMode: .common)
        run.timer = timer

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if let probe = self.downloadsProbe, !probe() {
                DispatchQueue.main.async {
                    self.fail(run, .download, log: "download: Downloads folder not writable",
                              tell: "Beat Key can't write to your Downloads folder. Allow it in System Settings, Privacy & Security, Files and Folders, then press DOWNLOAD again.")
                }
                return
            }
            self.prepare()
            DispatchQueue.main.async { self.download(run, useLogin: false) }
        }
    }

    private var jobs: FileJobs {
        if let j = jobsInstance { return j }
        let j = makeJobs()
        jobsInstance = j
        return j
    }

    private func download(_ run: Run, useLogin: Bool) {
        let cookies = useLogin ? savedLogin() : nil
        run.usedLogin = cookies != nil
        run.attempt += 1
        run.stage = "downloading"
        let attempt = run.attempt
        jobs.download(run.req.url, cookiesFile: cookies, onEvent: { [weak self] e in
            DispatchQueue.main.async { if run.attempt == attempt { self?.event(e, run) } }
        }, onExit: { [weak self] code in
            DispatchQueue.main.async { if run.attempt == attempt { self?.exited(code, run) } }
        })
    }

    private func event(_ e: Event, _ run: Run) {
        guard !run.finished else { return }
        switch e {
        case .stage(let s):
            run.stage = s
            progress(run, PluginDownloadListener.stageText(s))
        case .done(let r):
            run.attempt += 1   // its exit code, arriving next, is nothing more
            downloaded(r, run)
        case .error(let message):
            run.attempt += 1
            if run.stage == "downloading" {
                fail(run, .download, log: "download failed: \(message)", tell: message)
            } else {
                // yt-dlp finished; the core could not read the file, or it could not be named
                fail(run, .download, log: "analyze failed after the download (stage \(run.stage)): \(message)", tell: message)
            }
        case .needsLogin(let reason, let message, let stale):
            run.attempt += 1
            if stale { dropLogin() }
            if !stale, !run.usedLogin, savedLogin() != nil {
                AppLog.log("plug-in download: \(reason) needs a login; retrying with the saved one")
                progress(run, "Retrying with your YouTube login.")
                download(run, useLogin: true)
                return
            }
            let tell = (message.isEmpty ? "A YouTube login is needed." : message)
                + " Sign in to YouTube in the Beat Key app, then press DOWNLOAD again."
            fail(run, .download, log: "download needs a YouTube login (\(reason)\(stale ? ", the saved login is stale" : ""))", tell: tell)
        case .analyzed, .renamed, .renameSkipped, .renameFailed:
            break
        }
    }

    private func exited(_ code: Int32, _ run: Run) {
        guard !run.finished else { return }
        fail(run, .download, log: "download helper stopped with no answer (exit \(code))",
             tell: "The downloader stopped unexpectedly (exit \(code)).")
    }

    /// The file is on disk, named with its BPM and key.
    private func downloaded(_ r: Result, _ run: Run) {
        let file = r.file
        let bpm = r.bpmExact.map { String(format: "%.2f", $0) } ?? r.bpm ?? ""
        let key = r.keys.first?.0 ?? ""
        let req = run.req
        guard let placement = req.placement, PluginDownload.isProTools(bundleID: req.hostBundleID, name: req.hostName) else {
            reveal(file)
            finish(run, .init(requestID: req.requestID, final: true, ok: true, message: "Saved \(file.lastPathComponent).",
                              path: file.path, imported: false, bpm: bpm, key: key))
            return
        }
        run.stage = "importing"
        progress(run, "Importing into Pro Tools.")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.importer(file, placement)
            DispatchQueue.main.async {
                switch outcome {
                case .imported:
                    self.finish(run, .init(requestID: req.requestID, final: true, ok: true,
                                           message: "Imported \(file.lastPathComponent) into Pro Tools (\(placement.label)).",
                                           path: file.path, imported: true, bpm: bpm, key: key))
                case .failed(let stage, let message):
                    self.fail(run, stage == "ptsl-connect" ? .ptslConnect : .ptslImport, log: "\(stage): \(message)", tell: message,
                              path: file.path, bpm: bpm, key: key)
                }
            }
        }
    }

    // MARK: answering

    private func progress(_ run: Run, _ text: String) {
        run.progressText = text
        reply(.progress(run.req.requestID, text))
    }

    private func fail(_ run: Run, _ source: PluginErrorLog.Source, log: String, tell: String,
                      path: String = "", bpm: String = "", key: String = "") {
        guard !run.finished else { return }
        PluginErrorLog.write(source, log, host: run.host)
        finish(run, .init(requestID: run.req.requestID, final: true, ok: false, message: tell, path: path, imported: false, bpm: bpm, key: key))
    }

    /// The one final reply of a run.
    private func finish(_ run: Run, _ r: PluginDownload.Reply) {
        guard !run.finished else { return }
        run.finished = true
        run.timer?.invalidate()
        busy = false
        reply(r)
    }

    private func reply(_ r: PluginDownload.Reply) {
        if r.final {
            AppLog.log("plug-in download answered (request \(r.requestID.prefix(8))): \(r.ok ? "ok" : "FAILED"): \(r.message)")
        }
        transport.post(PluginDownload.replyName, r.userInfo)
    }

    static func stageText(_ stage: String) -> String {
        switch stage {
        case "downloading": return "Downloading."
        case "analyzing": return "Reading the key and tempo."
        case "renaming": return "Naming the file."
        case "updating": return "Updating the downloader."
        default: return stage.prefix(1).uppercased() + stage.dropFirst() + "."
        }
    }
}
