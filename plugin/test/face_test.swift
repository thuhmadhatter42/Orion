import AppKit
import SwiftUI

// plugin/test/face_test.swift: the face without a host (plan steps 9-11), run by plugin/test.sh on both
// slices. Compiled with the face's own sources under module BeatKeyFaceTest. Opens no window on screen:
// the face is drawn offscreen into PNGs (argv[2]) for a person or an agent to read.
//   1. shared code: the 24 key names are the core's (bk_key_index), Board Talk tips <= 60 characters,
//      the send contract round-trips and refuses bad payloads
//   2. a real instance fed 16 s of a C-major chord at 120 BPM: the face reads key + BPM through the token
//   3. SEND AUTO-TUNE writes the hand-off to a temp path (never ~/Music), and refuses with no key
//   4. SEND BPM against a fake app: not installed, answers ok + read-back, answers no, never answers,
//      launched and never listening; each ends in one line and one log line
//   5. renders: empty, reading, pinned, MORE popover content, a failed send line
//   6. the MIDI variant (plan step 15): the C side's chord table is the app's Harmony for all 24 keys; a
//      MIDI instance's notes through bkp_view_midi_enable; the face's route lines; the drag-out .mid is
//      MidiExport's bytes; a render with the .MID chip

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL \(what) (line \(line))") }
}

func spin(_ secs: Double, until: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(secs)
    while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

func render(_ view: NSView, _ path: String) {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { check(false, "no bitmap for \(path)"); return }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { check(false, "no PNG for \(path)"); return }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { check(false, "write \(path): \(error)") }
    print("rendered \(path) (\(Int(view.bounds.width))x\(Int(view.bounds.height)) pt)")
}

/// A host-sized offscreen window (never ordered front) so SwiftUI lays the view out as in a host.
func offscreen(_ v: NSView) -> NSWindow {
    let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = v
    w.appearance = NSAppearance(named: .darkAqua)
    return w
}

func logText(_ dir: String) -> String {
    (try? String(contentsOfFile: dir + "/plugin.log", encoding: .utf8)) ?? ""
}

@main
struct FaceTest {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: face_test <weights.bkw> <png dir>"); exit(2) }
        let weights = args[1], shots = args[2]
        let logDir = ProcessInfo.processInfo.environment["BEATKEY_LOG_DIR"] ?? ""
        NSApplication.shared.setActivationPolicy(.prohibited)
        FaceLog.install()

        // ---- 1. shared code
        for (i, k) in KeyNames.all.enumerated() {
            let idx = k.withCString { bk_key_index($0) }
            // core index = 2 * pitch class + minor; KeyNames.all = 12 majors then 12 minors
            let want = i < 12 ? 2 * i : 2 * (i - 12) + 1
            check(Int(idx) == want, "key \(k): core index \(idx), want \(want)")
        }
        check(KeyNames.all.count == 24 && Set(KeyNames.all).count == 24, "24 distinct key names")
        for t in FaceTips.all { check(t.count <= FaceTips.maxBody, "tip over \(FaceTips.maxBody): \(t)") }
        let req = PluginSend.Request(requestID: "abc", bpm: 141.98, hostBundleID: "com.ableton.live", hostName: "Live", hostPid: 42)
        let back = PluginSend.Request.decode(req.userInfo)
        check(back.request == req && back.refusal == nil, "send request round trip")
        check(PluginSend.Request.decode(["requestID": "x", "proto": 1, "bpm": Double.nan]).refusal != nil, "NaN BPM refused")
        check(PluginSend.Request.decode(["requestID": "x", "proto": 2, "bpm": 120.0]).refusal != nil, "proto 2 refused")
        check(PluginSend.Request.decode(["bpm": 120.0]).requestID == nil, "no requestID refused")
        check(PluginSend.Reply.decode(PluginSend.Reply(requestID: "r", ok: true, message: "m").userInfo)?.ok == true, "reply round trip")

        // ---- 2. a real instance
        var cfg = bkp_config()
        let p: OpaquePointer? = "VST3".withCString { f in weights.withCString { w in "test.face".withCString { h in
            cfg.format = f; cfg.weights_path = w; cfg.host = h; cfg.bundle_id = nil
            return bkp_create(&cfg)
        } } }
        guard let p else { print("FAIL no instance"); exit(1) }
        check(bkp_prepare(p, 44100) == 0, "prepare 44.1 kHz")
        let token = bkp_view_register(p)
        check(token != 0, "token")

        // empty face first
        let emptyView = FaceHostView(token: token)
        let w1 = offscreen(emptyView)
        emptyView.model.refresh()
        spin(0.3)
        check(emptyView.model.state.alive && emptyView.model.state.key == nil, "empty face: alive, no key")
        render(emptyView, shots + "/face-empty.png")

        // 16 s of C major (C E G) with a click at 120 BPM, fed ~10x real time
        let rate = 44100.0
        var x = [Float](repeating: 0, count: Int(rate * 16))
        for i in 0..<x.count {
            let t = Double(i) / rate
            var v = 0.0
            for f in [261.63, 329.63, 392.0] { v += 0.12 * sin(2 * .pi * f * t) + 0.04 * sin(2 * .pi * 2 * f * t) }
            let since = t.truncatingRemainder(dividingBy: 0.5)
            v += 0.5 * exp(-since * 60) * sin(2 * .pi * 1800 * since)
            x[i] = Float(v)
        }
        var at = 0
        while at < x.count {
            let n = min(512, x.count - at)
            x.withUnsafeMutableBufferPointer { buf in
                let base = UnsafeMutableRawPointer(buf.baseAddress! + at)
                var ins: [UnsafeRawPointer?] = [UnsafeRawPointer(base), UnsafeRawPointer(base)]
                var outs: [UnsafeMutableRawPointer?] = [base, base]
                ins.withUnsafeMutableBufferPointer { i in outs.withUnsafeMutableBufferPointer { o in
                    bkp_process(p, i.baseAddress, 2, o.baseAddress, 2, UInt32(n), 0)
                } }
            }
            at += n
            if at % 22050 < 512 { usleep(40_000) }
        }
        bkp_set_host_tempo(p, 120)
        spin(30) { FaceState.read(token).bpm != nil }
        let face = FaceHostView(token: token)
        let w2 = offscreen(face)
        face.model.start()
        spin(0.5)
        let s = face.model.state
        check(s.key == "C", "key read through the token: \(s.key ?? "nil")")
        check(s.bpm.map { abs($0 - 120) < 1.5 } ?? false, "BPM ~120 through the token: \(s.bpm.map { "\($0)" } ?? "nil")")
        check(s.hostTempo == 120, "host tempo through the token")
        check(!s.top.isEmpty, "top keys present")
        render(face, shots + "/face-reading.png")

        // ×2 and pin, through the token
        face.model.setFactor(.double)
        check(face.model.state.factor == .double && face.model.state.bpm.map { abs($0 - 2 * (s.bpm ?? 0)) < 0.01 } ?? false, "×2 applied")
        face.model.togglePin("Am")
        check(face.model.state.pin == "Am" && face.model.state.key == "Am", "pin Am")
        spin(0.3)
        render(face, shots + "/face-pinned-x2.png")
        face.model.togglePin("Am")
        face.model.setFactor(.one)
        check(face.model.state.pin == nil, "unpin")

        // MORE popover content, drawn on its own
        let more = NSHostingView(rootView: FaceMore(model: face.model).environment(\.accent, Accent.amber))
        more.frame = NSRect(x: 0, y: 0, width: 320, height: more.fittingSize.height)
        let w3 = offscreen(more)
        spin(0.3)
        render(more, shots + "/face-more.png")

        // ---- 3. SEND AUTO-TUNE to a temp path
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bk-face-\(UUID().uuidString)")
        let handoff = tmp.appendingPathComponent("Temp/Auto-Key.handoff")
        face.model.autoTuneURL = handoff
        face.model.sendAutoTune()
        let text = (try? String(contentsOf: handoff, encoding: .utf8)) ?? ""
        check(text == AutoTuneSend.contents(pitchClass: 0, minor: false, referencePitch: AutoTuneButton.referencePitch()),
              "hand-off holds C major, byte for byte")
        check(face.model.line?.kind == .ok && (face.model.line?.text.contains("Auto-Tune ← C") ?? false), "Auto-Tune line: \(face.model.line?.text ?? "nil")")
        check(logText(logDir).contains("SEND AUTO-TUNE C: wrote"), "Auto-Tune send logged")
        let none = AutoTuneButton.send(token: token, key: nil, to: handoff)
        check(!none.ok && none.line == "No key yet.", "no key refused")
        try? FileManager.default.removeItem(at: tmp)

        // ---- 4. SEND BPM against a fake app
        final class FakeApp {
            var installed = true, running = true, answersPing = true
            var answer: ((PluginSend.Request) -> PluginSend.Reply?)?
            var onSend: ((PluginSend.Request) -> Void)?
            var handlers: [Notification.Name: [([AnyHashable: Any]?) -> Void]] = [:]
            var launched = false
            var env: BPMSend.Env {
                var e = BPMSend.Env.live
                e.appURL = { self.installed ? URL(fileURLWithPath: "/Applications/Beat Key.app") : nil }
                e.appRunning = { self.running }
                e.launch = { _, done in self.launched = true; self.running = true; DispatchQueue.main.async { done(nil) } }
                e.post = { name, info in
                    DispatchQueue.main.async {
                        if name.rawValue == "com.jshriver.orion.request", self.running, self.answersPing {
                            self.handlers[Notification.Name("com.jshriver.orion.reading")]?.forEach { $0(["source": "none", "songID": ""]) }
                        }
                        if name == PluginSend.sendName, let r = PluginSend.Request.decode(info).request {
                            self.onSend?(r)
                            if let reply = self.answer?(r) { self.handlers[PluginSend.sentName]?.forEach { $0(reply.userInfo) } }
                        }
                    }
                }
                e.observe = { name, h in self.handlers[name, default: []].append(h); return NSObject() }
                e.unobserve = { _ in }
                e.sandboxed = { false }
                e.host = { ("com.ableton.live", "Live", 4242) }
                e.pluginTimeout = 0.6
                e.launchWait = 0.8
                e.pingWait = 0.4
                e.readBackWait = 0.5
                return e
            }
        }
        func runSend(_ app: FakeApp) -> FaceLine? {
            face.model.bpmEnv = app.env
            face.model.sendBPM()
            spin(4) { !face.model.sendingBPM }
            return face.model.line
        }
        // a. not installed
        let a = FakeApp(); a.installed = false
        var l = runSend(a)
        check(l?.kind == .error && l?.text == "SEND BPM needs the Beat Key app." && l?.link == PluginSend.downloadURL, "not installed: \(l?.text ?? "nil")")
        // b. answers ok, host tempo moves: the read-back line
        let b = FakeApp()
        var sentBPM = 0.0, sentHost = ""
        b.onSend = { r in sentBPM = r.bpm; sentHost = r.hostBundleID; bkp_set_host_tempo(p, r.bpm) }
        b.answer = { r in PluginSend.Reply(requestID: r.requestID, ok: true, message: "Ableton Live: tempo set to \(PluginSend.bpmText(r.bpm))") }
        l = runSend(b)
        check(abs(sentBPM - (s.bpm ?? -1)) < 1e-9 && sentHost == "com.ableton.live", "the BPM in use went out with the host's id")
        check(l?.kind == .ok && l?.text == "Session tempo \(PluginSend.bpmText(sentBPM))", "read-back line: \(l?.text ?? "nil")")
        check(logText(logDir).contains("SEND BPM \(PluginSend.bpmText(sentBPM)): the app:"), "BPM send logged ok")
        // c. answers ok but the host tempo does not move
        bkp_set_host_tempo(p, 100)
        let c = FakeApp()
        c.answer = { r in PluginSend.Reply(requestID: r.requestID, ok: true, message: "sent") }
        l = runSend(c)
        check(l?.kind == .error && l?.text == "Session still 100.00", "still line: \(l?.text ?? "nil")")
        // d. the app says no
        let d = FakeApp()
        d.answer = { r in PluginSend.Reply(requestID: r.requestID, ok: false, message: "Allow Accessibility for Beat Key.") }
        l = runSend(d)
        check(l?.kind == .error && l?.text == "Allow Accessibility for Beat Key.", "app refusal shown: \(l?.text ?? "nil")")
        // e. the app never answers the send
        let e = FakeApp()
        l = runSend(e)
        check(l?.kind == .error && (l?.text.hasPrefix("Beat Key app didn't answer") ?? false), "timeout line: \(l?.text ?? "nil")")
        check(logText(logDir).contains("no answer from the Beat Key app"), "timeout logged")
        // f. not running: launched, never listens
        let f = FakeApp(); f.running = false; f.answersPing = false
        l = runSend(f)
        check(f.launched && l?.text == "Beat Key didn't start listening.", "launch, no listener: \(l?.text ?? "nil")")
        // g. not running: launched, listens, answers
        let g = FakeApp(); g.running = false
        g.onSend = { r in bkp_set_host_tempo(p, r.bpm) }
        g.answer = { r in PluginSend.Reply(requestID: r.requestID, ok: true, message: "ok") }
        l = runSend(g)
        check(g.launched && l?.kind == .ok, "launched then sent: \(l?.text ?? "nil")")
        // a failed line, drawn
        _ = runSend(e)
        spin(0.2)
        render(face, shots + "/face-send-failed.png")

        // ---- 6. the MIDI variant
        // the table the C side gets is the app's chord strip: degree I, triad, root position, for every core key
        let table = MidiOut.table()
        check(table.count == 24, "24 chords")
        for (k, name) in MidiOut.coreKeys.enumerated() {
            let strip = Harmony.diatonic(name, quality: .triad).first?.notes(.root) ?? []
            check(strip.count == 3 && table[k] == strip, "chord for \(name): \(table[k]) vs the strip's \(strip)")
            check(Int(name.withCString { bk_key_index($0) }) == k, "core key \(k) is \(name)")
        }
        check(table[0] == [48, 52, 55] && table[Int("Am".withCString { bk_key_index($0) })] == [57, 60, 64] &&
              table[Int("F#m".withCString { bk_key_index($0) })] == [54, 57, 61] && table[Int("B".withCString { bk_key_index($0) })] == [59, 63, 66],
              "C, Am, F#m, B chords")
        check(KeyNotes.velocity == 96 && KeyNotes.velocity == MidiExport.defaultVelocity, "velocity is the chord clips' 96")
        var mcfg = bkp_config()
        let pm: OpaquePointer? = "VST3-MIDI".withCString { f in weights.withCString { w in "test.face".withCString { h in
            mcfg.format = f; mcfg.weights_path = w; mcfg.host = h; mcfg.bundle_id = nil
            return bkp_create(&mcfg)
        } } }
        guard let pm else { print("FAIL no MIDI instance"); exit(1) }
        check(bkp_view_midi_enable(pm) == 0 && bkp_midi(pm) == 1, "bkp_view_midi_enable through the face's table")
        check(logText(logDir).contains("MIDI variant: the key in use goes out as notes on channel 1 (3 a chord, velocity 96; C = 48 52 55, Cm = 48 51 55)"),
              "enable logged with the real table")
        check(bkp_prepare(pm, 44100) == 0, "MIDI instance prepare")
        let mtoken = bkp_view_register(pm)
        var ev = [bkp_midi_event](repeating: bkp_midi_event(), count: Int(BKP_MIDI_EVENTS))
        func midiBlock(_ takes: Int32) -> [bkp_midi_event] {
            let n = Int(bkp_midi_process(pm, takes, &ev))
            return Array(ev.prefix(n))
        }
        let mface = FaceHostView(token: mtoken)
        let w4 = offscreen(mface)
        mface.model.refresh()
        check(mface.model.state.midi && mface.model.state.midiRoute == 0 && MidiOut.line(mface.model.state) == nil, "MIDI face before audio")
        check(MidiOut.write(token: mtoken, state: mface.model.state, in: tmp) == nil && logText(logDir).contains("MIDI DRAG REFUSED: no key or BPM yet"),
              "drag refused with nothing to write")
        _ = midiBlock(0)
        mface.model.refresh()
        check(mface.model.state.midiRoute == 2 && MidiOut.line(mface.model.state)?.text == "No MIDI out in this host. Drag .MID.", "no-MIDI host line")
        check(logText(logDir).contains("MIDI out: the host gives Beat Key no MIDI output"), "no-MIDI route logged")
        mface.model.togglePin("Am")
        let on = midiBlock(1)
        check(on.count == 3 && on.map { Int($0.note) } == KeyNotes.triad("Am") && on.allSatisfy { $0.status == 0x90 && $0.velocity == 96 },
              "Am chord on: \(on.map { $0.note })")
        mface.model.refresh()
        check(mface.model.state.midiSounding == "Am" && MidiOut.line(mface.model.state)?.text == "MIDI out: Am chord", "MIDI line: \(MidiOut.line(mface.model.state)?.text ?? "nil")")
        check(MidiOut.noteNames("Am") == "A C E" && MidiOut.noteNames("Ebm") == "E♭ G♭ B♭", "note names")
        bkp_set_host_tempo(pm, 120)
        spin(0.3)
        render(mface, shots + "/face-midi.png")
        // the drag-out file: MidiExport's bytes for the key in use (no BPM read yet: key only)
        if let url = MidiOut.write(token: mtoken, state: mface.model.state, in: tmp) {
            let bytes = (try? Data(contentsOf: url)) ?? Data()
            check(url.lastPathComponent == "Beat Key (Am).mid", "drag file name \(url.lastPathComponent)")
            check(bytes == MidiExport.data(bpm: nil, key: "Am", trackName: "Beat Key"), "drag file is MidiExport's bytes")
            check(logText(logDir).contains("MIDI DRAG: wrote \(url.path)"), "drag logged")
        } else { check(false, "drag file not written") }
        // with a BPM: the reading's tempo and key (the C-major instance above, its BPM in use)
        var withBPM = FaceState.read(token)
        withBPM.midi = true
        if let url = MidiOut.write(token: token, state: withBPM, in: tmp), let bpm = withBPM.bpm {
            let bytes = (try? Data(contentsOf: url)) ?? Data()
            check(bytes == MidiExport.data(bpm: bpm, key: withBPM.key, trackName: "Beat Key"), "tempo + key file is MidiExport's bytes")
            check(bytes.range(of: Data([0xFF, 0x51, 0x03])) != nil && bytes.range(of: Data([0xFF, 0x59, 0x02])) != nil, "tempo and key-signature events present")
            check(url.lastPathComponent == MidiExport.suggestedName(track: "Beat Key", bpm: withBPM.bpmText, key: withBPM.key), "name with BPM")
        } else { check(false, "tempo + key drag file not written") }
        try? FileManager.default.removeItem(at: tmp)
        check(FaceState.read(token).midi == false, "the plain instance is not MIDI")
        bkp_view_unregister(mtoken)
        mface.model.stop()
        bkp_destroy(pm)
        check(logText(logDir).contains("MIDI: 1 chord changes sent"), "MIDI close line")
        _ = w4

        // ---- closed instance: the face says so and never touches it
        bkp_view_unregister(token)
        face.model.refresh()
        check(!face.model.state.alive && face.model.statusText.0 == "This instance is closed.", "closed after unregister")
        face.model.stop()
        bkp_destroy(p)
        _ = (w1, w2, w3)
        print("face_test: \(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
