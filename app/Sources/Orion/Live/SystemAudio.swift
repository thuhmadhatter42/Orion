import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// What the Mac plays, through ScreenCaptureKit's audio (macOS 13+): the main display's
/// stream with audio on and the picture shrunk to 2 x 2 px at one frame a second (SCK has no
/// audio-only filter). By default every app is heard; with `appBundleID` (Input > Add App) the one
/// content filter below includes only that app. Beat Key's own sound is always left out
/// (`excludesCurrentProcessAudio`). Needs the Screen (& System Audio) Recording permission;
/// nothing is saved.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, AudioCapture, SCStreamOutput, SCStreamDelegate {
    /// nil = every app; else only this app's sound (its bundle id).
    let appBundleID: String?
    /// The chosen app is not open (any more): told once; the controller falls back to Mac audio
    /// (LiveSourcePlan.afterLoss), the same rule as an unplugged input.
    var onDrop: ((CaptureDrop) -> Void)?
    private var dropped = false
    private var terminateObserver: NSObjectProtocol?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.jshriver.orion.system-audio")
    private var onSamples: (([Float]) -> Void)?
    private var onError: ((String) -> Void)?
    private var stopped = false
    /// SCK only delivers 8/16/24/48 kHz (asking for 44.1 kHz silently gets 48 kHz), so each
    /// buffer's real rate is read and resampled to the analyzer's 44.1 kHz. Unresampled 48 kHz
    /// audio read as 44.1 kHz puts every key ~1.5 semitones flat and every tempo 8 % slow.
    private var resampler: Resampler?
    private var resamplerRate: Double = 0
    /// SCK drops the stream when the display goes away (display sleep, lock, lid, monitor
    /// unplugged: error -3815 "Failed to find any displays or windows to capture"). That is not
    /// the user's problem, so Beat Key quietly reopens it: right away on screen wake, else after
    /// 2, 5, 10, then every 30 s. Only a permission refusal reaches the screen.
    private var retries = 0
    private var retryWork: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    init(appBundleID: String? = nil) {
        self.appBundleID = appBundleID
        super.init()
    }

    /// What the content filter does: every app, only the chosen app, or the chosen app is not open.
    enum FilterChoice: Equatable {
        case everyApp
        case only(String)
        case appGone(String)
    }

    /// Pure: `app` = the chosen app's bundle id (nil = every app), `shareable` = the bundle ids
    /// ScreenCaptureKit can filter on right now.
    static func filterChoice(app: String?, shareable: [String]) -> FilterChoice {
        guard let id = app else { return .everyApp }
        return shareable.contains(id) ? .only(id) : .appGone(id)
    }

    private var scopeLabel: String { appBundleID.map { "app \($0)" } ?? "all apps" }

    /// Once, on the capture's queue: the chosen app is gone.
    private func reportGone(_ why: String) {
        queue.async { [weak self] in
            guard let self = self, !self.stopped, !self.dropped else { return }
            self.dropped = true
            AppLog.log("system audio: \(self.scopeLabel) is gone (\(why)); telling Listen")
            self.onDrop?(.gone(why: why))
        }
    }

    /// macOS 15 renamed the privacy pane.
    static var permissionText: String {
        let pane: String
        if #available(macOS 15.0, *) { pane = "SCREEN & SYSTEM AUDIO RECORDING" } else { pane = "SCREEN RECORDING" }
        return "ALLOW \(Brand.wordmark) IN SYSTEM SETTINGS › PRIVACY & SECURITY › \(pane)"
    }

    func start(onSamples: @escaping ([Float]) -> Void, onError: @escaping (String) -> Void) {
        self.onSamples = onSamples
        self.onError = onError
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.reopen(now: true, why: "screen woke") }
        }
        if let id = appBundleID {
            terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == id { self?.reportGone("app quit") }
            }
        }
        begin()
    }

    private func begin() {
        guard !stopped, let onError = onError else { return }
        // Not allowed yet: the permission guide walks the user through it (it also asks macOS, which
        // lists Beat Key in the pane); Listen stops with the one line until they start again.
        guard SystemPermissions.isGranted(.screen) else {
            AppLog.log("system audio: screen & system audio recording not allowed; opening the permission guide")
            PermissionGuide.shared.need(.screen, why: "Listen on Mac audio")
            onError(SystemAudioCapture.permissionText); return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self, !self.stopped else { return }
            guard let display = content?.displays.first else {
                AppLog.log("system audio: no display yet for \(self.scopeLabel) (\(error.map { "\($0)" } ?? "none")), retrying")
                self.queue.async { self.reopen(now: false, why: "no display") }
                return
            }
            // Every app unless Add App chose one (J, 2026-11-10; Add App 2026-11-18). Mic isolation
            // is the Input choice in Settings.
            let apps = content?.applications ?? []
            let filter: SCContentFilter
            switch SystemAudioCapture.filterChoice(app: self.appBundleID, shareable: apps.compactMap(\.bundleIdentifier)) {
            case .everyApp:
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            case .only(let id):
                guard let app = apps.first(where: { $0.bundleIdentifier == id }) else { self.reportGone("not shareable"); return }
                AppLog.log("system audio: capturing only app \(id)")
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            case .appGone(let id):
                AppLog.log("system audio: app \(id) is not among the \(apps.count) apps ScreenCaptureKit can filter")
                self.reportGone("not open")
                return
            }
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = SystemAudioCapture.captureRate
            cfg.channelCount = 2
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.showsCursor = false
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            do {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                // a screen output too, or SCK logs a dropped frame every second
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                AppLog.log("system audio: could not add the stream output for \(self.scopeLabel): \(error)")
                onError(SystemAudioCapture.text(error)); return
            }
            s.startCapture { [weak self] err in
                guard let err = err else { return }
                if SystemAudioCapture.isPermission(err) {
                    AppLog.log("system audio: start refused for \(self?.scopeLabel ?? "?"): \(err)")
                    PermissionGuide.shared.need(.screen, why: "Listen on Mac audio (start refused)")
                    onError(SystemAudioCapture.text(err)); return
                }
                AppLog.log("system audio: start failed for \(self?.scopeLabel ?? "?") (\(err)), retrying")
                self?.queue.async { self?.reopen(now: false, why: "start failed") }
            }
            self.stream = s
        }
    }

    func stop() {
        stopped = true
        retryWork?.cancel()
        if let w = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(w); wakeObserver = nil }
        if let t = terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(t); terminateObserver = nil }
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let emit = onSamples else { return }
        if retries > 0 { AppLog.log("system audio: back after \(retries) retr\(retries == 1 ? "y" : "ies")"); retries = 0 }
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let rate = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee.mSampleRate, rate > 0
        else { return }
        if rate != resamplerRate { resampler = Resampler(from: rate); resamplerRate = rate }
        guard let r = resampler else { return }
        let mono: [Float]? = try? sb.withAudioBufferList { list, _ in SystemAudioCapture.mono(list) }
        if let m = mono, !m.isEmpty { emit(r.process(m)) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopped else { return }
        AppLog.log("system audio stopped: \(error)")
        if SystemAudioCapture.isPermission(error) {
            PermissionGuide.shared.need(.screen, why: "Listen on Mac audio (stream stopped)")
            onError?(SystemAudioCapture.text(error)); return
        }
        queue.async { self.reopen(now: false, why: "stream stopped") }
    }

    /// Runs on `queue`. Drops the dead stream and opens a new one, now or after a backoff.
    private func reopen(now: Bool, why: String) {
        guard !stopped else { return }
        retryWork?.cancel()
        stream?.stopCapture { _ in }
        stream = nil
        let delays: [Double] = [2, 5, 10]
        let wait = now ? 0.5 : (retries < delays.count ? delays[retries] : 30)
        retries += 1
        AppLog.log("system audio: reopening in \(wait) s (\(why), try \(retries))")
        let w = DispatchWorkItem { [weak self] in self?.begin() }
        retryWork = w
        queue.asyncAfter(deadline: .now() + wait, execute: w)
    }

    static func isPermission(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.userDeclined.rawValue
    }

    /// A rate SCK actually supports (8000, 16000, 24000, 48000).
    static let captureRate = 48000

    /// Float32 buffers (one per channel, or one interleaved) averaged to mono.
    static func mono(_ list: UnsafeMutableAudioBufferListPointer) -> [Float] {
        var chans: [UnsafeBufferPointer<Float>] = []
        for b in list {
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = max(Int(b.mNumberChannels), 1)
            let frames = Int(b.mDataByteSize) / MemoryLayout<Float>.size / ch
            if ch == 1 {
                chans.append(UnsafeBufferPointer(start: p, count: frames))
            } else {
                let all = UnsafeBufferPointer(start: p, count: frames * ch)
                return (0..<frames).map { f in (0..<ch).reduce(Float(0)) { $0 + all[f * ch + $1] } / Float(ch) }
            }
        }
        return PCM.mono(chans, channel: 0)
    }

    static func text(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == SCStreamErrorDomain && e.code == SCStreamError.userDeclined.rawValue { return permissionText }
        return "SYSTEM AUDIO STOPPED: \(e.localizedDescription.uppercased())"
    }
}
