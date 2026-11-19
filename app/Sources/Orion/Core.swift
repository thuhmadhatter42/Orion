import CBeatKey
import Foundation

// The analysis core (core/, beatkey.h) inside the app (plug-in plan step 19). The app and the
// plug-ins read audio with ONE engine: files go through bk_analyze_buffer / bk_analyze_midi here,
// Listen through bk_analyzer_* (CoreLive.swift). The Python analyzer (bpm.py, essentia, numpy) is
// gone from the app, and with the download in Swift (Downloader.swift) the app ships no Python.

/// Bring-up: the core's log lines into beatkey.log, the tempo weights loaded once per process.
enum Core {
    /// The one refusal for a damaged install (no or bad weights), word for word what the app showed
    /// before (bpm.py's ANALYZER_INCOMPLETE): files show it as the error, Listen as its error line.
    static let incomplete = "The analyzer is incomplete. Run Doctor."
    static let weightsName = "deeptemp-k16-3.bkw"

    /// The weights file: Contents/Resources in the app; ORION_CORE_WEIGHTS for a debug run
    /// (`swift run`) and tests, which have no bundle.
    static func weightsURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let o = env["ORION_CORE_WEIGHTS"], !o.isEmpty { return URL(fileURLWithPath: o) }
        return (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/")).appendingPathComponent(weightsName)
    }

    private static let lock = NSLock()
    private static var loaded = false
    private static var sinkSet = false

    /// The core logs through AppLog ("[Core] core <area>: <message>" in beatkey.log), never its own
    /// plugin.log, from the first call on.
    static func routeLog() {
        lock.lock(); defer { lock.unlock() }
        guard !sinkSet else { return }
        sinkSet = true
        bk_log_set_sink({ area, message, _ in
            let a = area.map { String(cString: $0) } ?? "-"
            let m = message.map { String(cString: $0) } ?? ""
            AppLog.log("core \(a): \(m)")
        }, nil)
    }

    /// nil = ready. Otherwise the core's own sentence (also in the log). A failed load is tried
    /// again on the next call (the user may have reinstalled), a good one never repeats.
    @discardableResult
    static func load(_ url: URL = Core.weightsURL()) -> String? {
        routeLog()
        lock.lock(); defer { lock.unlock() }
        if loaded { return nil }
        var err = [CChar](repeating: 0, count: 512)
        let rc = bk_load_weights(url.path, &err, err.count)
        if rc == BK_OK {
            loaded = true
            AppLog.log("core: ready, Beat Key core \(String(cString: bk_version())), weights \(url.lastPathComponent)")
            return nil
        }
        let why = String(cString: err)
        AppLog.log("core: weights refused (\(rc)) from \(url.path): \(why)")
        return why.isEmpty ? "the weights did not load" : why
    }
}

// MARK: one file

/// What reading one file came to.
enum FileReading {
    /// A reading (bpm nil = no tempo could be measured: the row shows the file unread).
    case reading(Result)
    /// The install is damaged (no weights): one error for the whole job, never a row per file.
    case incomplete(String)
}

/// Reads one file with the core: bpm.py analyze_full + app_run.py analyze_file, in-process.
///   audio  decoded by the bundled ffmpeg exactly as bpm.py's decode_ffmpeg did (mp3: the
///          fixed-point decoder, s16 / 32768; others: float), mixed to mono as essentia's
///          MonoMixer does, then bk_analyze_buffer at the file's own rate. The mono samples are
///          bit-identical to the ones the goldens were frozen from (CoreParityTests).
///   MIDI   bk_analyze_midi (midi_analyze.py).
struct FileReader {
    let binDir: URL
    var weights: URL = Core.weightsURL()

    static let midiExtensions: Set<String> = ["mid", "midi"]

    func read(_ file: URL) -> FileReading {
        if let why = Core.load(weights) {
            AppLog.log("analysis refused for \(file.lastPathComponent): \(why)")
            return .incomplete(Core.incomplete)
        }
        let name = file.lastPathComponent
        var r: bk_reading
        do {
            r = try FileReader.midiExtensions.contains(file.pathExtension.lowercased())
                ? readMidi(file) : readAudio(file)
        } catch {
            AppLog.log("analysis: no reading for \(name): \(error)")
            return .reading(FileReader.unread(file))
        }
        // TempoCNN gives 0 for a clip under ~12 s: no reading, never "(0.0 BPM ...)" (bpm.py exit 1)
        guard r.has_bpm != 0, r.bpm > 0 else {
            AppLog.log("analysis: could not measure a tempo for \(name) (the clip may be too short)")
            return .reading(FileReader.unread(file))
        }
        return .reading(FileReader.result(r, file: file, midi: FileReader.midiExtensions.contains(file.pathExtension.lowercased())))
    }

    /// A row with no reading; "permission" when macOS refuses to let Beat Key read the file.
    static func unread(_ file: URL) -> Result {
        Result(file: file.resolvingSymlinksInPath(), name: file.lastPathComponent, bpm: nil, keys: [],
               readError: permissionRefused(file) ? "permission" : nil, tagged: FileTag.isTagged(file.lastPathComponent))
    }

    static func permissionRefused(_ file: URL) -> Bool {
        let fd = open(file.path, O_RDONLY)
        if fd >= 0 { close(fd); return false }
        if errno == EPERM || errno == EACCES {
            AppLog.log("macOS refused to let Beat Key read \(file.lastPathComponent) (permission)")
            return true
        }
        return false
    }

    /// The row app_run.py made from bpm.py's lines: BPM as bpm.py printed it ("128.0"), keys as
    /// whole percentages (Python's round: half to even), the extras only with a BPM.
    static func result(_ r: bk_reading, file: URL, midi: Bool) -> Result {
        var keys: [(String, Int)] = []
        withUnsafeBytes(of: r.keys) { raw in
            for k in raw.bindMemory(to: bk_key.self) {
                let name = withUnsafeBytes(of: k.name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
                keys.append((name, Int(k.percent.rounded(.toNearestOrEven))))
            }
        }
        let chroma: [Double]? = midi ? nil : withUnsafeBytes(of: r.chroma) { Array($0.bindMemory(to: Double.self)) }
        return Result(file: file.resolvingSymlinksInPath(), name: file.lastPathComponent, bpm: "\(r.bpm)", keys: keys,
                      bpmExact: r.has_bpm_exact != 0 ? r.bpm_exact : nil,
                      tuningCents: r.has_tuning != 0 ? r.tuning_cents : nil,
                      chroma: chroma, tagged: FileTag.isTagged(file.lastPathComponent))
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func readMidi(_ file: URL) throws -> bk_reading {
        let data = try Data(contentsOf: file)
        var r = bk_reading()
        var err = [CChar](repeating: 0, count: 512)
        let rc = data.withUnsafeBytes { buf in
            bk_analyze_midi(buf.bindMemory(to: UInt8.self).baseAddress, buf.count, &r, &err, err.count)
        }
        guard rc == BK_OK else { throw Failure(description: String(cString: err)) }
        return r
    }

    func readAudio(_ file: URL) throws -> bk_reading {
        let (mono, rate) = try decode(file)
        var r = bk_reading()
        var err = [CChar](repeating: 0, count: 512)
        let rc = mono.withUnsafeBufferPointer { bk_analyze_buffer($0.baseAddress, $0.count, rate, &r, &err, err.count) }
        guard rc == BK_OK else { throw Failure(description: "core \(rc): \(String(cString: err))") }
        return r
    }

    // MARK: decoding (bpm.py decode_ffmpeg + essentia MonoMixer)

    /// (mono float32 at the file's own rate, that rate).
    func decode(_ file: URL) throws -> ([Float], Double) {
        let ffprobe = binDir.appendingPathComponent("ffprobe"), ffmpeg = binDir.appendingPathComponent("ffmpeg")
        let probe = try FileReader.run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries",
                                                 "stream=codec_name,sample_rate,channels", "-of", "json", file.path])
        guard let obj = try? JSONSerialization.jsonObject(with: probe) as? [String: Any],
              let stream = (obj["streams"] as? [[String: Any]])?.first,
              let sr = Int("\(stream["sample_rate"] ?? "")"), let ch = (stream["channels"] as? NSNumber)?.intValue, ch > 0
        else { throw Failure(description: "ffprobe found no audio stream") }
        let nch = min(ch, 2)
        let mp3 = (stream["codec_name"] as? String) == "mp3"
        var args = ["-nostdin", "-v", "error"]
        if mp3 { args += ["-c:a", "mp3"] }
        args += ["-i", file.path, "-map", "0:a:0", "-ac", String(nch), "-f", mp3 ? "s16le" : "f32le",
                 "-c:a", mp3 ? "pcm_s16le" : "pcm_f32le", "-"]
        let raw = try FileReader.run(ffmpeg, args)
        return (try FileReader.mono(raw, channels: nch, s16: mp3), Double(sr))
    }

    /// Interleaved PCM -> mono: s16 / 32768 in float32 (numpy's astype + divide), then MonoMixer:
    /// one channel as it is, two = 0.5 * (L + R).
    static func mono(_ raw: Data, channels nch: Int, s16: Bool) throws -> [Float] {
        let width = s16 ? 2 : 4
        guard raw.count % width == 0 else { throw Failure(description: "ffmpeg gave a partial sample") }
        let n = raw.count / width
        guard n % nch == 0 else { throw Failure(description: "ffmpeg gave a partial frame") }
        let frames = n / nch
        var x = [Float](repeating: 0, count: n)
        raw.withUnsafeBytes { buf in
            if s16 {
                for i in 0..<n {
                    let v = Int16(littleEndian: buf.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                    x[i] = Float(v) / Float(32768)
                }
            } else {
                for i in 0..<n {
                    x[i] = Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
                }
            }
        }
        if nch == 1 { return x }
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames { mono[i] = 0.5 * (x[2 * i] + x[2 * i + 1]) }
        return mono
    }

    /// Runs a tool, returns its stdout; a non-zero exit throws with the tail of its stderr.
    static func run(_ exe: URL, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure(description: "\(exe.lastPathComponent) could not start: \(error)") }
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global(qos: .utility).async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            let tail = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
            throw Failure(description: "\(exe.lastPathComponent) exit \(p.terminationStatus): \(tail)")
        }
        return data
    }
}
