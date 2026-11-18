import AppKit
import Foundation

// Live listening (plan §3): the mic / an input device / system audio, read as it plays.
// Audio goes from the capture straight into one long-lived `bpm.py --stream` process as float32
// PCM on its stdin; nothing is ever written to disk. That process answers with a reading every 2 s.

/// One line from `bpm.py --stream`.
enum LiveEvent: Equatable {
    case ready
    case reading(Result)
    /// A silence longer than the gap: a new song starts over.
    case reset
    /// A new song with no pause (SongBoundary.swift): the analyzer has flushed, start over.
    case boundary(LiveBoundary)
    /// The analyzer's silence rule tripped (`gap` s under its line); db = the level it measured.
    /// The one judge of silence: the LCD's NO SOUND goes up on this and nothing else.
    case silence(db: Double)
    /// Sound again after a `silence`; after = s of silence it ended. NO SOUND clears.
    case sound(db: Double, after: Double)
    case error(String)

    /// `song` = the identity of the song being heard when this line arrives (LiveSession.songFile):
    /// a reading carries it as its file, so each song's readings are told apart from the next's.
    static func parse(line: String, song: URL) -> LiveEvent? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = obj["event"] as? String else { return nil }
        switch kind {
        case "ready": return .ready
        case "reset": return .reset
        case "boundary": return .boundary(LiveBoundary(json: obj))
        case "silence": return (obj["db"] as? Double).map { .silence(db: $0) }
        case "sound":
            guard let db = obj["db"] as? Double, let after = obj["after"] as? Double else { return nil }
            return .sound(db: db, after: after)
        case "error": return .error((obj["message"] as? String) ?? "The analyzer stopped.")
        case "reading":
            // keys, bpm, bpm_exact, tuning_cents (null under 50 %), chroma: the same parser as files.
            // "LIVE" is the label (the DAW track's and the MIDI file's name), not the identity.
            return Event.reading(obj, file: song, name: "LIVE").map { .reading($0) }
        default: return nil
        }
    }
}

enum LiveState: Equatable {
    case off
    /// Capture and analyzer starting, or running with nothing to say yet (or again, after a gap).
    case listening
    /// A reading that may still change: amber when unsure, green when the key is confident.
    case reading(Result)
    /// Green for `LiveSession.lockAfter` seconds with the same key and a BPM. Never frozen: the
    /// next reading still replaces it (J, 2026-11-01: songs change every two minutes, no hold).
    case locked(Result)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .listening, .reading, .locked: return true
        case .off, .failed: return false
        }
    }

    var result: Result? {
        switch self {
        case .reading(let r), .locked(let r): return r
        default: return nil
        }
    }

    /// The lamp: the display colour while listening, then display colour / green with the key's confidence.
    var lamp: Lamp? {
        switch self {
        case .listening: return .listening
        case .reading(let r): return Lamp.of(r.keys) ?? .listening
        case .locked: return .locked
        case .off, .failed: return nil
        }
    }

    /// The lamp's caption.
    func status(source: String, held: Bool = false) -> String? {
        let base: String?
        switch self {
        case .listening: base = "LISTENING · \(source.uppercased())"
        case .reading(let r): base = Faceplate.confidenceLine(r.keys) ?? "LISTENING · \(source.uppercased())"
        case .locked(let r): base = Faceplate.confidenceLine(r.keys) ?? "LOCKED"
        case .off, .failed: base = nil
        }
        guard held, let b = base, result != nil else { return base }
        return "HELD · " + b
    }
}

/// The readings as they come in: green-and-steady after `lockAfter` s of the same confident key
/// (with a BPM), always following the audio, and start over after a gap. Pure logic; the clock is passed in.
struct LiveSession {
    static let lockAfter: TimeInterval = 6

    /// The song being heard: a new number at every `begin` (Listen started, New Song, a gap, a
    /// boundary). Every reading heard in it carries `songFile` as its file, so whatever was set
    /// for one reading (a picked key: KeyChoice.matches; the keyboard's root: PlayState.show)
    /// belongs to that song and no other, and the tempo factor follows it (FaceplateModel.follow).
    private(set) var song = 0
    /// What began or ended the song, for the log: "listen started", "new song", "gap reset", ...
    private(set) var songWhy = ""

    /// Song `n`'s identity, "/live-song-n": its folder is "/" (what the MIDI panel opens, the file
    /// line's folder), as before songs had one.
    static func songFile(_ n: Int) -> URL { URL(fileURLWithPath: "/live-song-\(n)") }
    var songFile: URL { LiveSession.songFile(song) }
    /// The song on show while listening; nil = off or failed.
    var hearing: URL? { current.isActive ? songFile : nil }

    /// What the audio says right now (it keeps following while Hold is on).
    private(set) var current: LiveState = .off
    /// Hold (J, 2026-11-01): a button, never automatic. While on, `state` is the reading that was
    /// shown when it went on; listening carries on underneath.
    private var frozen: LiveState?
    private var greenKey: String?
    private var greenSince: Date?
    var lockAfter = LiveSession.lockAfter

    /// What is shown: the frozen reading while held, else the current one.
    var state: LiveState { frozen ?? current }
    var isHeld: Bool { frozen != nil }
    /// Hold can go on only with a reading to hold.
    var canHold: Bool { frozen != nil || current.result != nil }

    /// A new song: everything heard is dropped. `why` = what began it (the log's word).
    mutating func begin(why: String) {
        song += 1; songWhy = why
        current = .listening; frozen = nil; greenKey = nil; greenSince = nil
    }
    mutating func end(why: String) { songWhy = why; current = .off; frozen = nil; greenKey = nil; greenSince = nil }
    mutating func fail(_ message: String) {
        songWhy = "error: \(message)"
        current = .failed(message); frozen = nil; greenKey = nil; greenSince = nil
    }

    /// Hold on: freeze the reading on show. Hold off: jump to the current reading. False = nothing
    /// to hold (no reading yet, or not listening).
    @discardableResult
    mutating func setHold(_ on: Bool) -> Bool {
        if !on { frozen = nil; return true }
        guard current.isActive, current.result != nil else { return false }
        if frozen == nil { frozen = current }
        return true
    }

    @discardableResult
    mutating func toggleHold() -> Bool { setHold(!isHeld) }

    mutating func feed(_ e: LiveEvent, now: Date = Date()) {
        guard current.isActive else { return }
        switch e {
        case .ready, .silence, .sound:   // the notice is the controller's, the reading stands
            break
        case .reset:
            begin(why: "gap reset")
        case .boundary(let b):
            begin(why: b.reason == .title ? "player title changed" : "audio boundary")
        case .error(let m):
            fail(m)
        case .reading(let r):
            if Lamp.of(r.keys) == .locked, r.bpm != nil, let key = r.keys.first?.0 {
                if key != greenKey || greenSince == nil { greenKey = key; greenSince = now }
                if let since = greenSince, now.timeIntervalSince(since) >= lockAfter {
                    current = .locked(r)
                    return
                }
            } else {
                greenKey = nil
                greenSince = nil
            }
            current = .reading(r)
        }
    }
}

extension Faceplate {
    static let liveRetryHint = "READING › START LISTENING TO TRY AGAIN"

    /// What the LCD shows while Listen is on (or just failed); nil = Listen is off, the engine's
    /// readout stands. `reference` = the A the tuning line is measured against (Settings), as for files.
    static func liveReadout(_ s: LiveState, source: String, factor: TempoFactor,
                            onCycleTempo: (() -> Void)? = nil, held: Bool = false,
                            reference: Double = Tuning.defaultReference, notice: String? = nil) -> Readout? {
        switch s {
        case .off:
            return nil
        case .failed(let m):
            return .error(m, download: false, hint: liveRetryHint)
        case .listening:
            return .listening(status: notice ?? s.status(source: source) ?? "LISTENING")
        case .reading(let r), .locked(let r):
            let opts = ResultOptions(factor: factor, tuning: Tuning.meter(r.tuningCents, reference: reference),
                                     onCycleTempo: onCycleTempo,
                                     live: (s.lamp ?? .listening, notice ?? s.status(source: source, held: held) ?? "", source))
            return .result(r.respelled(), page: nil, download: false, options: opts)
        }
    }
}

// MARK: settings

/// Where live audio comes from.
enum LiveSource: Equatable {
    /// Everything the Mac plays (ScreenCaptureKit, macOS 13+).
    case system
    /// An input device (nil uid = the system's default input). channel 0 = all channels mixed,
    /// n = channel n only.
    case input(uid: String?, channel: Int)
    /// Only one open app's sound (Input > Add App), by bundle id: the same ScreenCaptureKit
    /// capture as `.system` with its filter narrowed to that app (macOS 13+).
    case app(bundleID: String)

    static var systemAvailable: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static var defaultSource: LiveSource { systemAvailable ? .system : .input(uid: nil, channel: 0) }

    var stored: String {
        switch self {
        case .system: return "system"
        case .input(let uid, let ch): return "input:\(ch):\(uid ?? "")"
        case .app(let id): return "app:\(id)"
        }
    }

    static func from(stored s: String?) -> LiveSource? {
        guard let s = s else { return nil }
        if s == "system" { return .system }
        if s.hasPrefix("app:") {
            let id = String(s.dropFirst(4))
            return id.isEmpty ? nil : .app(bundleID: id)
        }
        let parts = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "input", let ch = Int(parts[1]), ch >= 0 else { return nil }
        let uid = String(parts[2])
        return .input(uid: uid.isEmpty ? nil : uid, channel: ch)
    }
}

/// What Listen really opens for the saved source. A saved input device that isn't connected
/// (unplugged, renamed) falls back to Mac audio (System Audio) instead of failing; the saved
/// choice is left alone, so the device is used again once it is back (J, 2026-11-05 17:06).
enum LiveSourcePlan: Equatable {
    case use(LiveSource)
    /// The saved device (`missingUID`, channel) is gone: `source` (System Audio) instead.
    case fallback(LiveSource, missingUID: String, channel: Int)

    var source: LiveSource {
        switch self {
        case .use(let s), .fallback(let s, _, _): return s
        }
    }

    static let fallbackNotice = "SAVED INPUT MISSING · USING MAC AUDIO"
    /// The same fallback when the chosen app (Add App) is not open.
    static let appFallbackNotice = "SAVED APP NOT OPEN · USING MAC AUDIO"

    static func notice(for saved: LiveSource) -> String {
        if case .app = saved { return appFallbackNotice }
        return fallbackNotice
    }

    /// Pure: the input (or chosen app) being heard dropped out mid-listen and would not restart.
    /// Mac audio takes over (the same fallback as at the start; the saved choice stays);
    /// `.use(lost)` = nothing else can capture (no System Audio on macOS 12, or it was already Mac
    /// audio), so Listen fails.
    static func afterLoss(of lost: LiveSource, systemAvailable: Bool) -> LiveSourcePlan {
        guard systemAvailable else { return .use(lost) }
        switch lost {
        case .input(let uid, let ch): return .fallback(.system, missingUID: uid ?? "default input", channel: ch)
        case .app(let id): return .fallback(.system, missingUID: id, channel: 0)
        case .system: return .use(lost)
        }
    }
    /// How long the notice stands in for the lamp's caption.
    static let noticeSeconds: TimeInterval = 8

    /// Pure: `connectedUIDs` = the input devices Core Audio lists right now, `runningAppIDs` = the
    /// bundle ids of the open apps. Without System Audio (macOS 12) there is nothing to fall back
    /// to, and the input's own "not connected" error stands.
    static func plan(saved: LiveSource, connectedUIDs: Set<String>, systemAvailable: Bool,
                     runningAppIDs: Set<String> = []) -> LiveSourcePlan {
        guard systemAvailable else { return .use(saved) }
        switch saved {
        case .input(let uid?, let ch) where !connectedUIDs.contains(uid):
            return .fallback(.system, missingUID: uid, channel: ch)
        case .app(let id) where !runningAppIDs.contains(id):
            return .fallback(.system, missingUID: id, channel: 0)
        default:
            return .use(saved)
        }
    }
}

final class LiveSettings: ObservableObject {
    static let sourceKey = "liveSource"
    static let gapKey = "liveGapSeconds"
    static let gaps: [Double] = [2, 3, 5, 10]
    static let defaultGap = 3.0
    private let defaults: UserDefaults
    let systemAvailable: Bool

    @Published var source: LiveSource { didSet { defaults.set(source.stored, forKey: LiveSettings.sourceKey) } }
    /// Seconds of silence that mean a new song: everything heard is dropped and it starts over.
    @Published var gap: Double { didSet { defaults.set(gap, forKey: LiveSettings.gapKey) } }

    init(defaults: UserDefaults = .standard, systemAvailable: Bool = LiveSource.systemAvailable) {
        self.defaults = defaults
        self.systemAvailable = systemAvailable
        var s = LiveSource.from(stored: defaults.string(forKey: LiveSettings.sourceKey))
            ?? (systemAvailable ? .system : .input(uid: nil, channel: 0))
        if !systemAvailable {   // macOS 12: no ScreenCaptureKit audio, so no Mac audio and no app
            switch s {
            case .system, .app: s = .input(uid: nil, channel: 0)
            case .input: break
            }
        }
        source = s
        let g = defaults.object(forKey: LiveSettings.gapKey) as? Double
        gap = g.map { min(max($0, 1), 30) } ?? LiveSettings.defaultGap
    }

    /// "System Audio", "MacBook Pro Microphone", "Scarlett 4i4 · Ch 3".
    func sourceName(devices: [InputDevice]) -> String { LiveSettings.name(of: source, devices: devices) }

    static func name(of source: LiveSource, devices: [InputDevice]) -> String {
        switch source {
        case .system: return "System Audio"
        case .input(let uid, let ch):
            let dev = uid.flatMap { u in devices.first { $0.uid == u } }
            let name = dev?.name ?? (uid == nil ? "Default Input" : "Missing Input")
            return ch > 0 ? "\(name) · Ch \(ch)" : name
        case .app(let id): return "App: \(AudioApps.displayName(bundleID: id))"
        }
    }
}

// MARK: the analyzer process

/// Where the capture's samples go. write is called from audio threads.
protocol LivePipe: AnyObject {
    func write(_ samples: [Float])
    func close()
}

/// Starts the analyzer; nil = could not start. onLine / onExit may arrive on any queue.
typealias LiveLauncher = (_ gap: Double, _ onLine: @escaping (String) -> Void,
                          _ onExit: @escaping (Int32) -> Void) -> LivePipe?

/// `python bpm.py --stream` with the bundle's runtime, float32 PCM written to its stdin.
final class LiveProcess: LivePipe {
    static let sampleRate = 44100
    let process = Process()   // SongBoundary.swift signals it (newSong)
    private let stdin = Pipe()
    private let writes = DispatchQueue(label: "com.jshriver.orion.live-pipe")
    private var closed = false   // writes queue only

    static func launcher(runtime: Runtime) -> LiveLauncher {
        return { gap, onLine, onExit in
            LiveProcess(executable: runtime.python,
                        arguments: [runtime.analyzer.path, "--stream", "--rate", String(sampleRate),
                                    "--gap", String(gap)],
                        environment: runtime.environment(), onLine: onLine, onExit: onExit)
        }
    }

    init?(executable: URL, arguments: [String], environment: [String: String],
          onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        signal(SIGPIPE, SIG_IGN)   // a dead analyzer must fail a write, not kill the app
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment.merging(["HOME": NSHomeDirectory()]) { a, _ in a }
        let out = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = AppLog.analyzerHandle(header: "bpm.py --stream") ?? FileHandle.nullDevice
        AppLog.log("analyzer start: \(arguments.dropFirst().joined(separator: " "))")
        do { try process.run() } catch { AppLog.log("analyzer failed to start: \(error)"); return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = Data()
            let h = out.fileHandleForReading
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 0x0A) {
                    onLine(String(decoding: buf[buf.startIndex..<nl], as: UTF8.self))
                    buf.removeSubrange(buf.startIndex...nl)
                }
            }
            // exit only after every line is out
            self.process.waitUntilExit()
            AppLog.log("analyzer exited: status \(self.process.terminationStatus) reason \(self.process.terminationReason.rawValue)" + (self.process.terminationStatus == 0 ? "" : "; its stderr: analyzer.log"))
            onExit(self.process.terminationStatus)
        }
    }

    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian on every Mac
        writes.async { [self] in
            guard !closed else { return }
            do { try stdin.fileHandleForWriting.write(contentsOf: data) } catch {
                closed = true
                AppLog.log("analyzer pipe write failed (the analyzer is gone?): \(error)")
            }
        }
    }

    /// EOF on stdin ends the analyzer; it is stopped outright if it lingers past `grace` s
    /// (Stop Listening wants it gone, not its last reading).
    func close() { close(grace: 2) }

    func close(grace: TimeInterval) {
        writes.async { [self] in
            guard !closed else { return }
            closed = true
            try? stdin.fileHandleForWriting.close()
        }
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { if p.isRunning { p.terminate() } }
    }
}

/// A capture that has gone quiet (system audio sends nothing while nothing plays) still has to
/// read as silence, or the analyzer would never see the gap (nor say "silence" for NO SOUND).
/// Counts the zeros to send.
struct SilenceFiller {
    let rate: Int
    let tick: TimeInterval
    private(set) var lastSamples: Date

    init(rate: Int = LiveProcess.sampleRate, tick: TimeInterval = 0.5, now: Date = Date()) {
        self.rate = rate; self.tick = tick; lastSamples = now
    }

    mutating func heard(at now: Date) { lastSamples = now }

    /// Zeros to write at `now`: one tick's worth once nothing has come for longer than a tick.
    mutating func zeros(at now: Date) -> Int {
        guard now.timeIntervalSince(lastSamples) > tick else { return 0 }
        lastSamples = now
        return Int(Double(rate) * tick)
    }
}

// MARK: the controller

/// Captured audio, as 44.1 kHz mono float32 in pieces of any length.
protocol AudioCapture: AnyObject {
    /// Errors are LCD sentences ("ALLOW ..."). Either callback may arrive on any queue.
    func start(onSamples: @escaping ([Float]) -> Void, onError: @escaping (String) -> Void)
    func stop()
    /// Told when the source drops out mid-listen and the capture can't carry on (CaptureDrop).
    /// Only an input device can drop; the others keep this no-op.
    var onDrop: ((CaptureDrop) -> Void)? { get set }
}

extension AudioCapture {
    var onDrop: ((CaptureDrop) -> Void)? { get { nil } set {} }
}

/// Listen's input level, 0...1, on its own so its 20 Hz ticks redraw only the meter segments.
final class LiveLevel: ObservableObject {
    @Published var value: Float = 0
}

/// The song Listen hears changed: started, ended, or another song began (LiveSession.song).
struct LiveSongChange: Equatable {
    /// The song that ended (nil = Listen was off) and the one heard now (nil = Listen is off).
    let from: URL?
    let to: URL?
    /// What changed it: "listen started", "new song", "gap reset", "audio boundary", a stop reason.
    let why: String
}

final class LiveController: ObservableObject {
    /// What is shown: the frozen reading while Hold is on.
    @Published private(set) var state: LiveState = .off
    /// The latest song change; per-song state follows it (FaceplateModel.follow).
    @Published private(set) var songChange = LiveSongChange(from: nil, to: nil, why: "launch")
    /// Hold is on (a button, never automatic).
    @Published private(set) var isHeld = false
    @Published private(set) var sourceName = ""
    /// What this Listen hears ("all apps except Beat Key", "input Scarlett 4i4 · Ch 3"), for the log.
    private var hearingLabel = ""
    /// A short non-error line that stands in for the lamp's caption for a few seconds (the saved
    /// input is missing, Mac audio is used instead). nil = none.
    @Published private(set) var notice: String?
    /// The input's level while listening, 0...1 (peak, dB-scaled, falling back slowly), for the
    /// meters. 0 when Listen is off. Its own object, not a @Published here: it ticks 20 times a
    /// second, and every tick of the controller re-derived and redrew the whole face (12.6 ms of
    /// main thread per tick in the window), dropping frames from the readout's animations (0.1.50,
    /// J 2026-11-09: "very jerky clicky movements"). Only the meter segments observe it.
    let meter = LiveLevel()
    var level: Float { meter.value }
    let settings: LiveSettings
    /// New-song boundaries and one Recent Readings entry per song (SongBoundary.swift).
    let songs: SongTracker
    private var session = LiveSession()
    private let launch: LiveLauncher
    private let makeCapture: (LiveSource) -> AudioCapture?
    private let now: () -> Date
    private let devices: () -> [InputDevice]
    private let runningAppIDs: () -> Set<String>
    private var noticeWork: DispatchWorkItem?
    /// What this Listen really opened (the plan's source, or Mac audio after a drop).
    private var activeSource = LiveSource.system
    private var pipe: LivePipe?
    private var capture: AudioCapture?
    private var filler: SilenceFiller?
    private var fillTimer: Timer?
    private var levelTimer: Timer?
    private var peak: Float = 0
    /// This second's input, for the log's level line (fillLock guards it).
    private var window = LevelWindow()
    private var windowSince = Date.distantPast
    private var stateLine = ChangeLine(last: LiveController.summary(.off))   // off at launch: nothing to say
    private var quitObserver: NSObjectProtocol?
    private let fillLock = NSLock()
    private var generation = 0
    /// The last minute heard, for a "Wrong, it's X" teach record (fillLock guards it).
    private var clip = ClipRing(seconds: 60, sampleRate: LiveProcess.sampleRate)

    init(settings: LiveSettings, launch: @escaping LiveLauncher,
         makeCapture: @escaping (LiveSource) -> AudioCapture? = LiveController.realCapture,
         now: @escaping () -> Date = Date.init, songs: SongTracker? = nil,
         devices: @escaping () -> [InputDevice] = InputDevice.all,
         runningAppIDs: @escaping () -> Set<String> = AudioApps.runningBundleIDs) {
        self.runningAppIDs = runningAppIDs
        self.settings = settings
        self.songs = songs ?? SongTracker(now: now)
        self.launch = launch
        self.makeCapture = makeCapture
        self.now = now
        self.devices = devices
        // App quit: say Listen stopped because of it (the log's last word on the session).
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self, self.state.isActive else { return }
            self.stop(reason: "app quit")
            AppLog.flush()
        }
    }

    deinit { if let o = quitObserver { NotificationCenter.default.removeObserver(o) } }

    static func realCapture(_ s: LiveSource) -> AudioCapture? {
        switch s {
        case .system:
            if #available(macOS 13.0, *) { return SystemAudioCapture() }
            return nil
        case .input(let uid, let ch):
            return InputCapture(deviceUID: uid, channel: ch)
        case .app(let id):
            if #available(macOS 13.0, *) { return SystemAudioCapture(appBundleID: id) }
            return nil
        }
    }

    func toggle() { state.isActive ? stop(reason: "user stop") : start() }

    /// New Song: drop everything heard and any lock, now, and keep listening to the same source.
    /// The analyzer's stdin carries only samples (no control channel), so the stream is started
    /// over: a fresh analyzer and capture, the lamp back to LISTENING (display colour). Off = nothing to do.
    func reset() {
        guard state.isActive else { return }
        start(why: "new song")
    }

    /// `why` = why a running Listen is being started over (new song, source changed); it is
    /// logged as the old session's stop reason.
    func start(why: String = "restarted") {
        let songWhy = state.isActive ? why : "listen started"
        stop(reason: why)
        generation += 1
        let gen = generation
        let devs = devices()
        let plan = LiveSourcePlan.plan(saved: settings.source, connectedUIDs: Set(devs.map(\.uid)),
                                       systemAvailable: settings.systemAvailable,
                                       runningAppIDs: runningAppIDs())
        activeSource = plan.source
        sourceName = LiveSettings.name(of: plan.source, devices: devs)
        AppLog.log("listen: start · source \(sourceName) (\(plan.source.stored)) · gap \(settings.gap) s")
        hearingLabel = LiveController.hearing(plan.source, name: sourceName)
        AppLog.log("listen: hearing \(hearingLabel)")
        if case .fallback(_, let uid, let ch) = plan {
            if case .app(let id) = settings.source {
                AppLog.log("listen: saved app \(id) is not open, falling back to Mac audio (System Audio); saved choice kept")
            } else {
                AppLog.log("listen: saved input missing (uid \(uid), ch \(ch); connected: "
                           + (devs.isEmpty ? "none" : devs.map { "\($0.name) [\($0.uid)]" }.joined(separator: ", "))
                           + "), falling back to Mac audio (System Audio); saved choice kept")
            }
            showNotice(LiveSourcePlan.notice(for: settings.source), gen: gen)
        }
        guard let cap = makeCapture(plan.source) else {
            AppLog.log("listen: no capture for \(plan.source.stored)")
            fail("SYSTEM AUDIO NEEDS MACOS 13 OR NEWER", gen: gen); return
        }
        let onLine: (String) -> Void = { [weak self] line in
            DispatchQueue.main.async { self?.receive(line, gen: gen) }
        }
        let onExit: (Int32) -> Void = { [weak self] code in
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation, self.state.isActive else { return }
                self.fail("THE ANALYZER STOPPED (EXIT \(code))", gen: gen)
            }
        }
        guard let p = launch(settings.gap, onLine, onExit) else {
            fail("THE ANALYZER WOULDN'T START", gen: gen); return
        }
        pipe = p
        capture = cap
        session.begin(why: songWhy)
        publish()
        songs.begin(signal: p as? SongSignal)
        fillLock.lock(); filler = SilenceFiller(now: now()); clip.clear()
        window = LevelWindow(); windowSince = now(); fillLock.unlock()
        run(cap, into: p, gen: gen)
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.fillSilence() }
        RunLoop.main.add(t, forMode: .common)
        fillTimer = t
        let lt = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tickLevel() }
        RunLoop.main.add(lt, forMode: .common)
        levelTimer = lt
    }

    /// Starts `cap` feeding the analyzer. Also used when Mac audio takes over from a dropped input
    /// (the analyzer, the song and the timers carry on).
    private func run(_ cap: AudioCapture, into p: LivePipe, gen: Int) {
        cap.onDrop = { [weak self] drop in
            DispatchQueue.main.async { self?.inputDropped(drop, gen: gen) }
        }
        cap.start(onSamples: { [weak self, weak p] samples in
            guard let self = self else { return }
            let pk = samples.reduce(Float(0)) { max($0, abs($1)) }
            self.fillLock.lock(); self.filler?.heard(at: self.now()); self.peak = max(self.peak, pk)
            self.window.add(samples, peak: pk)
            self.clip.append(samples); self.fillLock.unlock()
            p?.write(samples)
        }, onError: { [weak self] message in
            DispatchQueue.main.async { self?.fail(message, gen: gen) }
        })
    }

    static let waitingNotice = "WAITING FOR MUSIC..."
    /// Peak (0...1) that counts as music again after the input dropped (about -60 dBFS).
    static let musicPeak: Float = 0.001

    /// The input dropped out mid-listen (device unplugged, format changed): not an error. Listening
    /// stays on with a calm notice, the capture restarts itself on the device (InputCapture), and
    /// when it can't, Mac audio takes over (LiveSourcePlan, as at the start); Listen fails only
    /// when nothing at all can capture. The analyzer and the song are untouched.
    func inputDropped(_ drop: CaptureDrop, gen: Int) {
        guard gen == generation, state.isActive else { return }
        switch drop {
        case .waiting:
            AppLog.log("listen: input \(sourceName) dropped out; still listening, LCD says \"\(LiveController.waitingNotice)\"")
            showNotice(LiveController.waitingNotice, gen: gen, seconds: nil)
        case .gone(let why):
            switch LiveSourcePlan.afterLoss(of: activeSource, systemAvailable: settings.systemAvailable) {
            case .use:
                AppLog.log("listen: input \(sourceName) is gone (\(why)) and Mac audio is not available; failing")
                fail(InputCapture.lostText, gen: gen)
            case .fallback(let src, let uid, let ch):
                guard let cap = makeCapture(src), let p = pipe else {
                    AppLog.log("listen: input \(sourceName) is gone (\(why)); no Mac audio capture to fall back to; failing")
                    fail(InputCapture.lostText, gen: gen); return
                }
                AppLog.log("listen: input \(sourceName) is gone (uid \(uid), ch \(ch); \(why)); falling back to Mac audio (System Audio); saved choice kept; same song")
                let lostSource = activeSource
                capture?.stop()
                capture = cap
                activeSource = src
                sourceName = LiveSettings.name(of: src, devices: devices())
                hearingLabel = LiveController.hearing(src, name: sourceName)
                showNotice(LiveSourcePlan.notice(for: lostSource), gen: gen)
                run(cap, into: p, gen: gen)
            }
        }
    }

    /// The meter (20 Hz): the loudest sample since the last tick, falling back at most 20 % per
    /// tick. Once a second it also logs the level; never per tick.
    func tickLevel() {
        let t = now()
        fillLock.lock()
        let pk = peak; peak = 0
        var second: LevelSecond?
        if t.timeIntervalSince(windowSince) >= 1 { second = window.take(); windowSince = t }
        fillLock.unlock()
        let next = max(LevelMeter.scale(pk), level * 0.8)
        if abs(next - level) > 0.004 { meter.value = next < 0.01 ? 0 : next }
        // "Waiting for music" ends with the first real sound after the drop.
        if pk > LiveController.musicPeak, notice == LiveController.waitingNotice, state.isActive {
            AppLog.log("listen: sound is back after the input dropped; \"\(LiveController.waitingNotice)\" cleared")
            noticeWork?.cancel(); noticeWork = nil; notice = nil
        }
        if let s = second, state.isActive { AppLog.log("listen: " + s.text) }
    }

    static let noSoundNotice = "NO SOUND · CHECK SOURCE"

    /// NO SOUND from the analyzer's own silence events, the one judge of silence: up when its
    /// rule trips (the same moment it resets the reading), cleared when it hears sound again.
    private func noSound(db: Double) {
        AppLog.log("listen: analyzer says silence (it measured \(String(format: "%.1f", db)) dB rms) from \(hearingLabel); LCD says \"\(LiveController.noSoundNotice)\"")
        showNotice(LiveController.noSoundNotice, gen: generation, seconds: nil)
    }

    private func soundBack(db: Double, after: Double) {
        AppLog.log("listen: analyzer says sound back (it measured \(String(format: "%.1f", db)) dB rms) after \(String(format: "%.1f", after)) s silent; NO SOUND cleared")
        if notice == LiveController.noSoundNotice { noticeWork?.cancel(); noticeWork = nil; notice = nil }
    }

    /// What a source hears, for the log: System Audio is every app but Beat Key itself.
    static func hearing(_ source: LiveSource, name: String) -> String {
        switch source {
        case .system: return "all apps except Beat Key"
        case .input: return "input \(name)"
        case .app(let id): return "only the app \(id)"
        }
    }

    /// Up to the last minute of audio heard since Listen (or New Song) started.
    func recentClip() -> [Float] {
        fillLock.lock(); defer { fillLock.unlock() }
        return clip.last
    }

    func fillSilence() {
        fillLock.lock()
        let n = filler?.zeros(at: now()) ?? 0
        fillLock.unlock()
        if n > 0 { pipe?.write([Float](repeating: 0, count: n)) }
    }

    /// `reason` lands in the log: user stop, new song, source changed, app quit, a download took
    /// the LCD... Nothing is logged when Listen was already off.
    func stop(reason: String = "user stop") {
        if state.isActive { AppLog.log("listen: stopped (\(reason))") }
        teardown()
        session.end(why: reason)
        publish()
    }

    /// Logs each change of what Listen shows (key, %, BPM, lamp), never a repeat.
    private func publish() {
        let d = LiveController.summary(session.state) + (session.isHeld ? " (held)" : "")
        if let line = stateLine.next(d) { AppLog.log("listen: \(line) · source \(sourceName)") }
        if session.hearing != songChange.to {
            songChange = LiveSongChange(from: songChange.to, to: session.hearing, why: session.songWhy)
        }
        state = session.state
        if isHeld != session.isHeld { isHeld = session.isHeld }
    }

    /// Hold / Release. False = nothing to hold yet.
    @discardableResult
    func setHold(_ on: Bool) -> Bool {
        let ok = session.setHold(on)
        publish()
        return ok
    }

    @discardableResult
    func toggleHold() -> Bool { setHold(!session.isHeld) }
    var canHold: Bool { session.canHold }

    /// The notice for `seconds`, then the lamp's own caption again; nil = until cleared.
    private func showNotice(_ text: String, gen: Int, seconds: TimeInterval? = LiveSourcePlan.noticeSeconds) {
        noticeWork?.cancel()
        noticeWork = nil
        notice = text
        guard let secs = seconds else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, gen == self.generation else { return }
            self.notice = nil
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: work)
    }

    private func teardown() {
        noticeWork?.cancel()
        noticeWork = nil
        if notice != nil { notice = nil }
        songs.end()
        fillTimer?.invalidate()
        fillTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        if level != 0 { meter.value = 0 }
        capture?.stop()
        capture = nil
        pipe?.close()
        pipe = nil
        fillLock.lock(); filler = nil; fillLock.unlock()
    }

    /// What took the LCD from Listen, for its stop reason ("download / analysis (downloading)").
    static func engineLabel(_ s: ViewState) -> String {
        switch s {
        case .idle: return "idle"
        case .working(let stage): return "a download or analysis (\(stage))"
        case .done: return "a download's result"
        case .analyzed: return "a file's result"
        case .failed: return "an error"
        case .needsLogin: return "a login prompt"
        case .doctor: return "Run Doctor"
        }
    }

    /// One log line's worth of Listen's state (the key list, not the whole Result), with the lamp.
    static func summary(_ s: LiveState) -> String {
        func keys(_ r: Result) -> String { r.keys.prefix(3).map { "\($0.0) \($0.1)%" }.joined(separator: ", ") }
        let lamp = s.lamp.map { " · lamp \($0.logName)" } ?? ""
        switch s {
        case .off: return "off"
        case .listening: return "listening" + lamp
        case .failed(let m): return "FAILED: \(m)"
        case .reading(let r): return "reading \(keys(r)) · bpm \(r.bpm ?? "-")" + lamp
        case .locked(let r): return "locked \(keys(r)) · bpm \(r.bpm ?? "-")" + lamp
        }
    }

    private func fail(_ message: String, gen: Int) {
        guard gen == generation else { return }
        AppLog.log("listen: stopped (error: \(message))")
        teardown()
        session.fail(message)
        publish()
    }

    /// One analyzer line, on the main queue in the order it was printed: a reading is given the
    /// song heard now, so a reset / boundary line before it has already begun the next song.
    func receive(_ line: String, gen: Int? = nil) {
        guard let e = LiveEvent.parse(line: line, song: session.songFile) else { return }
        handle(e, gen: gen)
    }

    func handle(_ e: LiveEvent, gen: Int? = nil) {
        if let g = gen, g != generation { return }
        if case .error(let m) = e { fail(m, gen: generation); return }
        if state.isActive {
            if case .silence(let db) = e { noSound(db: db) }
            if case .sound(let db, let after) = e { soundBack(db: db, after: after) }
        }
        songs.observe(e)
        session.feed(e, now: now())
        publish()
    }
}
