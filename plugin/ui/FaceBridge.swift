import AppKit
import Combine
import SwiftUI

// The face's entry and its reading of the instance. The shims call bkp_view_create(token) (C); this
// file answers it with the SwiftUI face in an NSHostingView. Everything the face knows about the
// instance comes through bkp_view_read(token) and goes back through the bkp_view_* actions: by token,
// never by pointer (bkp_view.h).

/// The C entry the shims call (bkp_view.h). Main thread. An autoreleased NSView, or nil (logged).
@_cdecl("bkp_view_create")
public func bkp_view_create(_ token: UInt64) -> UnsafeMutableRawPointer? {
    FaceLog.install()
    guard token != 0 else {
        FaceLog.line(0, "view: no token (the instance never registered a face); no face")
        PluginErrorLog.write(.faceLoad, "no face: the instance never registered one (no token)")
        return nil
    }
    guard Thread.isMainThread else {
        FaceLog.line(token, "REFUSED: the host asked for the face off the main thread; no face")
        PluginErrorLog.write(.faceLoad, "no face: the host asked for it off the main thread")
        return nil
    }
    Textures.ownBundle = FaceHouse.bundle   // the faceplate's grain, from the plug-in's own Resources
    let view = FaceHostView(token: token)
    return Unmanaged.passRetained(view).autorelease().toOpaque()
}

/// The face's size now (ADVANCED widens it), for the shims' getSize (bkp_view.h). Main thread.
@_cdecl("bkp_face_size")
public func bkp_face_size(_ w: UnsafeMutablePointer<Int32>?, _ h: UnsafeMutablePointer<Int32>?) {
    let s = FaceplateFace.pluginSize(advanced: FaceSettings.shared.advanced)
    w?.pointee = Int32(s.width.rounded())
    h?.pointee = Int32(s.height.rounded())
}

/// The face's root NSView: the app window's face at FaceplateFace.pluginSize, dark. ADVANCED changes
/// its width; the shims follow the frame (VST3 resizeView, AAX SetViewSize; AU hosts watch the frame).
final class FaceHostView: NSHostingView<FaceRoot> {
    let model: FaceModel
    private var sizeWatch: AnyCancellable?

    init(token: UInt64) {
        model = FaceModel(token: token)
        super.init(rootView: FaceRoot(model: model))
        frame = NSRect(origin: .zero, size: FaceHostView.size)
        appearance = NSAppearance(named: .darkAqua)
        postsFrameChangedNotifications = true
        sizeWatch = FaceSettings.shared.$advanced.dropFirst().receive(on: RunLoop.main).sink { [weak self] adv in
            let s = FaceplateFace.pluginSize(advanced: adv)
            self?.setFrameSize(s)
            self?.invalidateIntrinsicContentSize()
            FaceLog.line(token, "face: advanced \(adv ? "on" : "off"); size \(Int(s.width)) x \(Int(s.height))")
        }
    }

    static var size: CGSize { FaceplateFace.pluginSize(advanced: FaceSettings.shared.advanced) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    required init(rootView: FaceRoot) {
        model = rootView.model
        super.init(rootView: rootView)
    }

    override var intrinsicContentSize: NSSize { FaceHostView.size }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // poll only while on screen; a hidden editor costs nothing
        if window != nil { model.start() } else { model.stop() }
    }
}

/// The plug-in's log, from Swift: plugin.log through the core's one writer (bk_log), under the
/// instance's area when there is one. Also the sink of the shared code (SharedLog), set once.
enum FaceLog {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        SharedLog.sink = { tag, line in FaceLog.line(0, "[\(tag)] \(line)") }
    }

    static func line(_ token: UInt64, _ text: String) {
        text.withCString { bkp_view_log(token, $0) }
    }

    static func send(_ token: UInt64, what: String, value: String, ok: Bool, outcome: String) {
        what.withCString { w in value.withCString { v in outcome.withCString { o in
            bkp_view_log_send(token, w, v, ok ? 1 : 0, o)
        } } }
    }

    /// plugin.log (+ plugin.log.1 when it rolled) and beatkey.log (the plug-in's failures, PluginErrorLog,
    /// beside the app's own lines): what Report attaches.
    static var files: [URL] {
        var buf = [CChar](repeating: 0, count: 1024)
        let path = String(cString: bk_log_path(&buf, buf.count))
        var out: [URL] = []
        if !path.isEmpty { out += [URL(fileURLWithPath: path), URL(fileURLWithPath: path + ".1")] }
        out.append(PluginErrorLog.file)
        return out.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// A fixed-size C char array (a tuple in Swift) as a String.
func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.bindMemory(to: CChar.self)
        guard let base = bytes.baseAddress else { return "" }
        return String(cString: base)   // the C side always NUL-terminates
    }
}

/// What the face shows, read from the instance in one go (bkp_view_read).
struct FaceState: Equatable {
    var alive = false
    var key: String?
    var pin: String?
    var bpm: Double?
    var bpmExact = false
    var mult = 0
    var hostTempo: Double?
    var bypass = false
    var format = ""
    var status = ""
    /// The detector's top 3, best first, whole percent.
    var top: [Choice] = []
    var tuningCents: Double?
    /// The notes heard, C..B, 0..1 (Advanced mode's NOTES HEARD); nil = no reading.
    var chroma: [Double]?
    /// The last half-second's level, 0...1 on the face's meter scale.
    var level: Float = 0
    /// The song number (a new one at every silence gap / new song): the reading's identity.
    var song: UInt64 = 0
    var readings: UInt64 = 0
    var hasReading = false
    var stale = false
    var silent = false
    var error = false
    /// An AudioSuite instance: readings come from Analyze on a selection, not from playback.
    var clips = false
    /// That instance is reading a selection right now.
    var analyzing = false
    /// The MIDI variant (plan step 15): whether this is it, the route (0 no audio yet, 1 the host takes
    /// MIDI, 2 it does not) and the key whose chord is held now.
    var midi = false
    var midiRoute = 0
    var midiSounding: String?

    struct Choice: Equatable { var name: String; var percent: Int }

    static func read(_ token: UInt64) -> FaceState {
        var s = bkp_view_state()
        guard bkp_view_read(token, &s) == 0, s.alive != 0 else { return FaceState() }
        var f = FaceState()
        f.alive = true
        f.key = s.has_key != 0 ? cString(s.key) : nil
        let pin = cString(s.pin)
        f.pin = pin.isEmpty ? nil : pin
        f.bpm = s.has_bpm != 0 && s.bpm.isFinite && s.bpm > 0 ? s.bpm : nil
        f.bpmExact = s.bpm_exact != 0
        f.mult = Int(s.tempo_mult)
        f.hostTempo = s.host_tempo > 0 && s.host_tempo.isFinite ? s.host_tempo : nil
        f.bypass = s.bypass != 0
        f.format = cString(s.format)
        f.status = cString(s.status)
        f.clips = s.clip_state != 0
        f.analyzing = s.clip_state == 2
        f.hasReading = s.snap.has_reading != 0
        f.readings = s.snap.readings
        f.song = s.snap.song
        let db = s.snap.level_db
        f.level = db.isFinite ? LevelMeter.scale(Float(pow(10, db / 20))) : 0
        f.stale = s.snap.has_reading != 0 && s.snap.reading_song < s.snap.song
        f.silent = s.snap.silent != 0
        f.error = s.snap.error != 0
        f.midi = s.midi != 0
        f.midiRoute = Int(s.midi_route)
        f.midiSounding = s.midi_sounding >= 0 ? bk_key_name(s.midi_sounding).map { String(cString: $0) } : nil
        if f.hasReading {
            let r = s.snap.reading
            f.top = [r.keys.0, r.keys.1, r.keys.2].compactMap { k in
                let n = cString(k.name)
                return n.isEmpty ? nil : Choice(name: n, percent: Int(k.percent.rounded()))
            }
            f.tuningCents = r.has_tuning != 0 && r.tuning_cents.isFinite ? r.tuning_cents : nil
            let c = [r.chroma.0, r.chroma.1, r.chroma.2, r.chroma.3, r.chroma.4, r.chroma.5,
                     r.chroma.6, r.chroma.7, r.chroma.8, r.chroma.9, r.chroma.10, r.chroma.11]
            f.chroma = c.allSatisfy { $0.isFinite } && c.contains { $0 > 0 } ? c : nil
        }
        return f
    }

    /// The face's factor, from the instance's -1 / 0 / +1.
    var factor: TempoFactor { mult < 0 ? .half : mult > 0 ? .double : .one }

    /// The BPM as the face prints it: the shared tempo text (two decimals when refined).
    var bpmText: String? {
        guard let bpm else { return nil }
        // bpm already carries the x2 / /2: the factor is applied by the instance, not again here
        return Tempo.text(bpm: bpmExact ? nil : String(format: "%.1f", bpm), exact: bpmExact ? bpm : nil)
    }
}

extension TempoFactor {
    /// The instance's -1 / 0 / +1.
    var mult: Int32 {
        switch self {
        case .one: return 0
        case .double: return 1
        case .half: return -1
        }
    }
}
