import CBeatKey
import Foundation

// Listen on the core (plan step 19): the capture's 44.1 kHz mono samples go into a bk_analyzer's
// ring (the same live path the plug-ins use: LiveAnalyzer, BoundaryDetector, one worker thread),
// and the analyzer's snapshots come back as the stream lines the controller reads, the ones
// `bpm.py --stream` printed: ready, reading, reset, boundary, silence, sound, error. Nothing is
// written to disk.

/// The newest snapshot against the one before it -> the stream's lines, in the order bpm.py
/// printed them for the same audio (silence / sound, a song's last reading, the new song, the new
/// song's reading). A reader that polls more slowly than the readings come sees only the newest
/// one, as `bpm.py --stream` printed only the newest of a backlog. Pure.
struct SnapshotLines {
    private(set) var last = bk_snapshot()

    init() { last.level_db = -120 }

    mutating func next(_ s: bk_snapshot) -> [String] {
        defer { last = s }
        guard s.seq != last.seq else { return [] }
        var out: [String] = []
        if s.silent != 0 && last.silent == 0 {
            out.append(SnapshotLines.json(["event": "silence", "db": s.silence_db]))
        } else if s.silent == 0 && last.silent != 0 {
            out.append(SnapshotLines.json(["event": "sound", "db": (s.level_db * 10).rounded() / 10, "after": s.sound_after]))
        }
        let newReading = s.readings > last.readings && s.has_reading != 0
        let newSong = s.song > last.song
        if newReading && newSong && s.reading_song < s.song { out.append(SnapshotLines.reading(s.reading)) }
        if newSong {
            switch s.song_why {
            case Int32(BK_SONG_SILENCE): out.append(SnapshotLines.json(["event": "reset"]))
            case Int32(BK_SONG_AUDIO): out.append(SnapshotLines.json(["event": "boundary", "reason": "audio"]))
            default: out.append(SnapshotLines.json(["event": "boundary", "reason": "title"]))
            }
        }
        if newReading && !(newSong && s.reading_song < s.song) { out.append(SnapshotLines.reading(s.reading)) }
        if s.error != 0 && last.error == 0 {
            out.append(SnapshotLines.json(["event": "error", "message": "The analyzer stopped."]))
        }
        return out
    }

    /// bpm.py's reading line: whole percentages, "bpm" as bpm.py printed it ("128.0"), null for
    /// what is not known yet.
    static func reading(_ r: bk_reading) -> String {
        var keys: [[Any]] = []
        withUnsafeBytes(of: r.keys) { raw in
            for k in raw.bindMemory(to: bk_key.self) {
                let name = withUnsafeBytes(of: k.name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
                keys.append([name, Int(k.percent.rounded(.toNearestOrEven))])
            }
        }
        let chroma = withUnsafeBytes(of: r.chroma) { Array($0.bindMemory(to: Double.self)) }
        return json(["event": "reading", "keys": keys, "secs": r.secs, "chroma": chroma,
                     "bpm": r.has_bpm != 0 ? "\(r.bpm)" : NSNull(),
                     "bpm_exact": r.has_bpm_exact != 0 ? r.bpm_exact : NSNull(),
                     "tuning_cents": r.has_tuning != 0 ? r.tuning_cents : NSNull()])
    }

    static func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// One Listen's analyzer: a bk_analyzer at 44.1 kHz. Samples are pushed from one serial queue (the
/// ring takes one writer); the snapshot is polled on the same queue, so nothing touches the analyzer
/// after it is destroyed.
final class CoreLive: LivePipe, SongSignal {
    /// What the capture delivers and the analyzer is made for.
    static let sampleRate = 44100
    static let pollEvery: DispatchTimeInterval = .milliseconds(50)

    private let queue = DispatchQueue(label: "com.jshriver.orion.live-core", qos: .userInitiated)
    private var analyzer: OpaquePointer?          // queue only
    private var timer: DispatchSourceTimer?       // queue only
    private var lines = SnapshotLines()           // queue only
    private var closed = false                    // queue only
    private var refusedPushes = 0                 // queue only
    private let onLine: (String) -> Void

    /// The app's launcher: the core needs no process, no runtime, no Python.
    static func launcher(weights: URL = Core.weightsURL()) -> LiveLauncher {
        return { gap, onLine, _ in CoreLive(gap: gap, onLine: onLine, weights: weights) }
    }

    /// `gap` = Listen's setting: seconds of silence that mean a new song (bpm.py --gap).
    init(gap: Double, onLine: @escaping (String) -> Void, weights: URL = Core.weightsURL()) {
        self.onLine = onLine
        queue.async { self.open(gap: gap, weights: weights) }
    }

    private func open(gap: Double, weights: URL) {
        if Core.load(weights) != nil {
            onLine(SnapshotLines.json(["event": "error", "message": Core.incomplete]))
            closed = true
            return
        }
        var cfg = bk_analyzer_config()
        cfg.sample_rate = Double(CoreLive.sampleRate)
        var err = [CChar](repeating: 0, count: 512)
        let a: OpaquePointer? = "Beat Key".withCString { host in
            "app".withCString { fmt in
                cfg.host = host
                cfg.format = fmt
                return bk_analyzer_create(&cfg, &err, err.count)
            }
        }
        guard let made = a else {
            let why = String(cString: err)
            AppLog.log("listen: the analyzer would not start: \(why)")
            onLine(SnapshotLines.json(["event": "error", "message": why.isEmpty ? Core.incomplete : why]))
            closed = true
            return
        }
        analyzer = made
        if bk_analyzer_set_silence_gap(made, gap) != BK_OK {
            AppLog.log("listen: the silence setting \(gap) s was refused by the analyzer; it keeps 3 s")
        }
        onLine(SnapshotLines.json(["event": "ready"]))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + CoreLive.pollEvery, repeating: CoreLive.pollEvery)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        guard let a = analyzer, !closed else { return }
        var s = bk_snapshot()
        bk_analyzer_snapshot(a, &s)
        for l in lines.next(s) { onLine(l) }
    }

    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard let a = analyzer, !closed else { return }
            let taken = samples.withUnsafeBufferPointer { bk_analyzer_push(a, $0.baseAddress, $0.count) }
            // the core counts and logs what its ring could not take; say it here once too
            if taken < samples.count, refusedPushes == 0 {
                refusedPushes += 1
                AppLog.log("listen: the analyzer's ring was full, \(samples.count - taken) samples dropped (the core's log has the count)")
            }
        }
    }

    /// The player's title changed: start over now (the core answers with a "title" boundary).
    func newSong() {
        queue.async { [self] in if let a = analyzer, !closed { bk_analyzer_new_song(a) } }
    }

    /// Stop Listening wants it gone, not its last reading.
    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            timer?.cancel()
            timer = nil
            if let a = analyzer { bk_analyzer_destroy(a) }
            analyzer = nil
        }
    }

    deinit {
        // close() already ran on every path the controller takes; this is the safety net
        if let a = analyzer, !closed { bk_analyzer_destroy(a) }
    }
}
