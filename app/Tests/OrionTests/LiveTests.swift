import AVFoundation
import ScreenCaptureKit
import CBeatKey
import XCTest
@testable import Orion

final class LiveTests: XCTestCase {
    func reading(_ key: String = "Ebm", _ pct: Int = 85, bpm: String? = "128.0") -> Result {
        Result(file: LiveSession.songFile(1), name: "LIVE", bpm: bpm,
               keys: [(key, pct), ("F#", 8), ("Bbm", 4)], bpmExact: bpm == nil ? nil : 128.02)
    }
    func defaults() -> UserDefaults {
        let name = "orion-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: 3.3 the analyzer's lines

    func testParsesStreamLines() {
        let s1 = LiveSession.songFile(1)
        XCTAssertEqual(LiveEvent.parse(line: #"{"event":"ready"}"#, song: s1), .ready)
        XCTAssertEqual(LiveEvent.parse(line: #"{"event":"reset"}"#, song: s1), .reset)
        XCTAssertEqual(LiveEvent.parse(line: #"{"event": "silence", "db": -61.3}"#, song: s1), .silence(db: -61.3))
        XCTAssertEqual(LiveEvent.parse(line: #"{"event": "sound", "db": -14.2, "after": 4.5}"#, song: s1),
                       .sound(db: -14.2, after: 4.5))
        XCTAssertNil(LiveEvent.parse(line: #"{"event": "silence"}"#, song: s1))             // no level: not the analyzer's
        XCTAssertNil(LiveEvent.parse(line: #"{"event": "sound", "db": -14.2}"#, song: s1))
        XCTAssertEqual(LiveEvent.parse(line: #"{"event":"error","message":"x"}"#, song: s1), .error("x"))
        let line = #"{"event":"reading","bpm":"128.0","bpm_exact":128.02,"keys":[["Ebm",85],["F#",8],["Bbm",4]],"secs":14.0}"#
        XCTAssertEqual(LiveEvent.parse(line: line, song: LiveSession.songFile(1)), .reading(reading()))
        let early = #"{"event":"reading","bpm":null,"bpm_exact":null,"keys":[["Ebm",85],["F#",8],["Bbm",4]],"secs":4.0}"#
        guard case .reading(let r)? = LiveEvent.parse(line: early, song: LiveSession.songFile(1)) else { return XCTFail() }
        XCTAssertNil(r.bpm)
        XCTAssertNil(LiveEvent.parse(line: "garbage", song: LiveSession.songFile(1)))
        XCTAssertNil(LiveEvent.parse(line: #"{"event":"reading","keys":[["Ebm"]]}"#, song: LiveSession.songFile(1)))
        XCTAssertNil(LiveEvent.parse(line: #"{"stage":"done"}"#, song: LiveSession.songFile(1)))
    }

    // MARK: 3.3 auto-lock and start over

    func testAutoLocksAfterSixSecondsOfTheSameConfidentKey() {
        var s = LiveSession()
        s.begin(why: "test")
        XCTAssertEqual(s.state, .listening)
        s.feed(.reading(reading()), now: t0)
        XCTAssertEqual(s.state, .reading(reading()))
        s.feed(.reading(reading()), now: t0 + 4)
        XCTAssertEqual(s.state.lamp, .locked)               // green, not yet held
        guard case .reading = s.state else { return XCTFail() }
        s.feed(.reading(reading()), now: t0 + 6)
        XCTAssertEqual(s.state, .locked(reading()))
        // never held: a new key replaces it at once (J, 2026-11-01)
        s.feed(.reading(reading("Am", 90)), now: t0 + 8)
        XCTAssertEqual(s.state, .reading(reading("Am", 90)))
    }

    func testUnsureOrChangedKeyRestartsTheClock() {
        var s = LiveSession()
        s.begin(why: "test")
        s.feed(.reading(reading()), now: t0)
        s.feed(.reading(reading("Ebm", 50)), now: t0 + 2)  // amber
        XCTAssertEqual(s.state.lamp, .unsure)
        s.feed(.reading(reading()), now: t0 + 4)
        s.feed(.reading(reading()), now: t0 + 8)
        guard case .reading = s.state else { return XCTFail("locked too early") }
        s.feed(.reading(reading("F#", 80)), now: t0 + 10)  // another key
        s.feed(.reading(reading("F#", 80)), now: t0 + 14)
        guard case .reading = s.state else { return XCTFail("locked on a fresh key too early") }
        s.feed(.reading(reading("F#", 80)), now: t0 + 16)
        XCTAssertEqual(s.state, .locked(reading("F#", 80)))
    }

    func testNoLockWithoutABpm() {
        var s = LiveSession()
        s.begin(why: "test")
        s.feed(.reading(reading(bpm: nil)), now: t0)
        s.feed(.reading(reading(bpm: nil)), now: t0 + 10)
        guard case .reading = s.state else { return XCTFail() }
    }

    func testGapStartsOver() {
        var s = LiveSession()
        s.begin(why: "test")
        s.feed(.reading(reading()), now: t0)
        s.feed(.reading(reading()), now: t0 + 6)
        XCTAssertEqual(s.state, .locked(reading()))
        s.feed(.reset, now: t0 + 10)
        XCTAssertEqual(s.state, .listening)
        s.feed(.reading(reading("Am", 90)), now: t0 + 12)
        XCTAssertEqual(s.state, .reading(reading("Am", 90)))   // the clock started over too
    }

    func testErrorsAndOffIgnoreReadings() {
        var s = LiveSession()
        s.feed(.reading(reading()), now: t0)
        XCTAssertEqual(s.state, .off)
        s.begin(why: "test")
        s.feed(.error("boom"), now: t0)
        XCTAssertEqual(s.state, .failed("boom"))
        s.feed(.reading(reading()), now: t0)
        XCTAssertEqual(s.state, .failed("boom"))
    }

    func testLampsAndCaptions() {
        XCTAssertEqual(LiveState.listening.lamp, .listening)
        XCTAssertEqual(LiveState.listening.status(source: "System Audio"), "LISTENING · SYSTEM AUDIO")
        XCTAssertEqual(LiveState.reading(reading("Cm", 41)).lamp, .unsure)
        XCTAssertEqual(LiveState.reading(reading()).status(source: "x"), "LOCKED 85%")
        XCTAssertEqual(LiveState.locked(reading()).status(source: "x"), "LOCKED 85%")
        XCTAssertNil(LiveState.off.lamp)
        XCTAssertFalse(LiveState.failed("x").isActive)
    }

    func testLcdReadoutWhileListening() {
        XCTAssertNil(Faceplate.liveReadout(.off, source: "x", factor: .one))
        guard case .listening(let status)? = Faceplate.liveReadout(.listening, source: "Mic", factor: .one)
        else { return XCTFail() }
        XCTAssertEqual(status, "LISTENING · MIC")
        guard case .result(let r, nil, false, nil, let o)? = Faceplate.liveReadout(.locked(reading()), source: "Mic", factor: .double)
        else { return XCTFail() }
        XCTAssertEqual(r, reading())
        XCTAssertEqual(o.factor, .double)
        XCTAssertEqual(o.live?.lamp, .locked)
        XCTAssertEqual(o.live?.status, "LOCKED 85%")
        XCTAssertEqual(o.live?.source, "Mic")
        guard case .error(let m, false, let hint)? = Faceplate.liveReadout(.failed("NO"), source: "Mic", factor: .one)
        else { return XCTFail() }
        XCTAssertEqual(m, "NO")
        XCTAssertEqual(hint, Faceplate.liveRetryHint)
    }

    func testMenuBarWhileListening() {
        XCTAssertNil(MenuBarReadout.of(live: .off, source: "x", factor: .one))
        XCTAssertEqual(MenuBarReadout.of(live: .listening, source: "Mic", factor: .one)?.lamp, .listening)
        let m = MenuBarReadout.of(live: .locked(reading()), source: "Mic", factor: .one)
        XCTAssertEqual(m?.text, "Ebm 128.0")
        XCTAssertEqual(m?.lamp, .locked)
        XCTAssertEqual(MenuBarReadout.of(live: .reading(reading("Cm", 41)), source: "Mic", factor: .one)?.lamp, .unsure)
    }

    // MARK: 3.1 / 3.2 sources

    func testSourceStorageRoundTrips() {
        for s in [LiveSource.system, .input(uid: nil, channel: 0), .input(uid: "AppleUSB:1:2", channel: 3)] {
            XCTAssertEqual(LiveSource.from(stored: s.stored), s)
        }
        XCTAssertNil(LiveSource.from(stored: "input:x:y"))
        XCTAssertNil(LiveSource.from(stored: nil))
    }

    func testSettingsDefaultsAndMacOS12() {
        let d = defaults()
        XCTAssertEqual(LiveSettings(defaults: d, systemAvailable: true).source, .system)
        XCTAssertEqual(LiveSettings(defaults: d, systemAvailable: false).source, .input(uid: nil, channel: 0))
        let s = LiveSettings(defaults: d, systemAvailable: true)
        s.source = .system
        XCTAssertEqual(LiveSettings(defaults: d, systemAvailable: false).source, .input(uid: nil, channel: 0))
        s.source = .input(uid: "u1", channel: 2)
        s.gap = 5
        let again = LiveSettings(defaults: d, systemAvailable: true)
        XCTAssertEqual(again.source, .input(uid: "u1", channel: 2))
        XCTAssertEqual(again.gap, 5)
        XCTAssertEqual(LiveSettings(defaults: defaults()).gap, 3)
    }

    func testSourceNames() {
        let s = LiveSettings(defaults: defaults(), systemAvailable: true)
        let devs = [InputDevice(id: 7, uid: "u1", name: "Scarlett 4i4", channels: 4)]
        s.source = .system
        XCTAssertEqual(s.sourceName(devices: devs), "System Audio")
        s.source = .input(uid: "u1", channel: 3)
        XCTAssertEqual(s.sourceName(devices: devs), "Scarlett 4i4 · Ch 3")
        s.source = .input(uid: nil, channel: 0)
        XCTAssertEqual(s.sourceName(devices: devs), "Default Input")
        s.source = .input(uid: "gone", channel: 0)
        XCTAssertEqual(s.sourceName(devices: devs), "Missing Input")
    }

    func testMonoMixAndChannelPick() {
        let a: [Float] = [1, 1, 1], b: [Float] = [0, 0.5, 1]
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                XCTAssertEqual(PCM.mono([pa, pb], channel: 0), [0.5, 0.75, 1])
                XCTAssertEqual(PCM.mono([pa, pb], channel: 2), [0, 0.5, 1])
                XCTAssertEqual(PCM.mono([pa, pb], channel: 9), [0.5, 0.75, 1])   // missing channel: the mix
            }
        }
    }

    func testMonoFromAnAVAudioBuffer() {
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 4)!
        buf.frameLength = 4
        for i in 0..<4 { buf.floatChannelData![0][i] = 1; buf.floatChannelData![1][i] = 0 }
        XCTAssertEqual(PCM.mono(buf, channel: 0), [0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(PCM.mono(buf, channel: 1), [1, 1, 1, 1])
    }

    func testResamplerTo44k() {
        XCTAssertEqual(Resampler(from: 44100)!.process([1, 2, 3]), [1, 2, 3])   // pass-through
        let r = Resampler(from: 48000)!
        var total = 0
        for _ in 0..<10 { total += r.process([Float](repeating: 0.1, count: 4800)).count }
        XCTAssertEqual(Double(total), 44100, accuracy: 600)                      // 1 s in, ~1 s out
    }

    @available(macOS 13.0, *)
    func testSystemAudioBuffersToMono() {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var l: [Float] = [1, 1, 1, 1], r: [Float] = [0, 0, 1, 1]
        l.withUnsafeMutableBytes { lp in
            r.withUnsafeMutableBytes { rp in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: lp.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: rp.baseAddress)
                XCTAssertEqual(SystemAudioCapture.mono(list), [0.5, 0.5, 1, 1])
            }
        }
        let one = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(one.unsafeMutablePointer) }
        var inter: [Float] = [1, 0, 1, 0, 1, 1]          // L R interleaved, 3 frames
        inter.withUnsafeMutableBytes { p in
            one[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 24, mData: p.baseAddress)
            XCTAssertEqual(SystemAudioCapture.mono(one), [0.5, 0.5, 1])
        }
    }

    @available(macOS 13.0, *)
    func testSystemAudioPermissionErrorSaysWhereToAllow() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue)
        XCTAssertEqual(SystemAudioCapture.text(declined), SystemAudioCapture.permissionText)
        XCTAssertTrue(SystemAudioCapture.permissionText.hasPrefix("ALLOW BEAT KEY IN SYSTEM SETTINGS"))
        XCTAssertTrue(LiveController.realCapture(.system) is SystemAudioCapture)
        XCTAssertTrue(LiveController.realCapture(.input(uid: nil, channel: 0)) is InputCapture)
    }

    func testUsageStringsAndEntitlementForListening() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()      // app/
        let plist = try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")))
        XCTAssertTrue((plist["NSMicrophoneUsageDescription"] as? String)?.contains("Nothing is recorded") == true)
        XCTAssertNotNil(plist["NSAudioCaptureUsageDescription"] as? String)
        let ents = try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("entitlements-app.plist")))
        XCTAssertEqual(ents["com.apple.security.device.audio-input"] as? Bool, true)
    }

    func testSilenceFiller() {
        var f = SilenceFiller(rate: 44100, tick: 0.5, now: t0)
        XCTAssertEqual(f.zeros(at: t0 + 0.4), 0)
        XCTAssertEqual(f.zeros(at: t0 + 0.6), 22050)
        XCTAssertEqual(f.zeros(at: t0 + 0.9), 0)          // a tick since the last fill
        f.heard(at: t0 + 1.0)
        XCTAssertEqual(f.zeros(at: t0 + 1.3), 0)
        XCTAssertEqual(f.zeros(at: t0 + 1.6), 22050)
    }

    // MARK: the controller, with a fake capture and analyzer

    final class FakePipe: LivePipe {
        var written = 0
        var closed = false
        func write(_ samples: [Float]) { written += samples.count }
        func close() { closed = true }
    }

    final class FakeCapture: AudioCapture {
        var onSamples: (([Float]) -> Void)?
        var onError: ((String) -> Void)?
        var onDrop: ((CaptureDrop) -> Void)?
        var stopped = false
        func start(onSamples: @escaping ([Float]) -> Void, onError: @escaping (String) -> Void) {
            self.onSamples = onSamples; self.onError = onError
        }
        func stop() { stopped = true }
    }

    func testControllerRunsAndStops() {
        let pipe = FakePipe(), cap = FakeCapture()
        var lineOut: ((String) -> Void)?
        var gapAsked: Double?
        let c = LiveController(settings: LiveSettings(defaults: defaults(), systemAvailable: false),
                               launch: { gap, onLine, _ in gapAsked = gap; lineOut = onLine; return pipe },
                               makeCapture: { _ in cap })
        c.start()
        XCTAssertEqual(c.state, .listening)
        XCTAssertEqual(gapAsked, 3)
        cap.onSamples?([0, 0, 0])
        XCTAssertEqual(pipe.written, 3)
        lineOut?(#"{"event":"reading","bpm":"128.0","bpm_exact":128.02,"keys":[["Ebm",85],["F#",8],["Bbm",4]]}"#)
        let exp = expectation(description: "main hop")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(c.state, .reading(reading()))
        c.stop()
        XCTAssertEqual(c.state, .off)
        XCTAssertTrue(pipe.closed)
        XCTAssertTrue(cap.stopped)
    }

    /// 0.1.50: the 20 Hz input level ticks its own object (LiveLevel), never the controller, so a
    /// tick redraws the meter and not the whole face (the jerky animations J saw in 0.1.49).
    func testLevelTicksNeverRepublishTheController() {
        let pipe = FakePipe(), cap = FakeCapture()
        let c = LiveController(settings: LiveSettings(defaults: defaults(), systemAvailable: false),
                               launch: { _, _, _ in pipe }, makeCapture: { _ in cap })
        c.start()
        var controllerChanges = 0, meterChanges = 0
        let a = c.objectWillChange.sink { controllerChanges += 1 }
        let b = c.meter.objectWillChange.sink { meterChanges += 1 }
        let end = Date().addingTimeInterval(0.4)
        while Date() < end {
            cap.onSamples?([0.5, -0.4, 0.2])
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(c.level, 0)
        XCTAssertEqual(c.level, c.meter.value)
        XCTAssertGreaterThan(meterChanges, 0)
        XCTAssertEqual(controllerChanges, 0, "a level tick republished LiveController")
        c.stop()
        XCTAssertEqual(c.level, 0)
        a.cancel(); b.cancel()
    }

    /// New Song: a locked reading is dropped at once, a fresh analyzer and capture start, the lamp
    /// goes back to red LISTENING. With Listen off it does nothing.
    func testNewSongResetsALock() {
        var pipes: [FakePipe] = [], caps: [FakeCapture] = []
        let c = LiveController(settings: LiveSettings(defaults: defaults(), systemAvailable: false),
                               launch: { _, _, _ in let p = FakePipe(); pipes.append(p); return p },
                               makeCapture: { _ in let k = FakeCapture(); caps.append(k); return k })
        c.reset()
        XCTAssertEqual(c.state, .off)
        XCTAssertTrue(pipes.isEmpty)
        c.start()
        c.handle(.reading(reading()), gen: nil)
        c.handle(.reading(reading()), gen: nil)
        XCTAssertEqual(c.state, .reading(reading()))
        c.reset()
        XCTAssertEqual(c.state, .listening)
        XCTAssertEqual(c.state.lamp, .listening)
        XCTAssertEqual(pipes.count, 2)
        XCTAssertTrue(pipes[0].closed)
        XCTAssertTrue(caps[0].stopped)
        XCTAssertFalse(pipes[1].closed)
        c.stop()
    }

    func testControllerFailures() {
        let c = LiveController(settings: LiveSettings(defaults: defaults(), systemAvailable: false),
                               launch: { _, _, _ in nil }, makeCapture: { _ in FakeCapture() })
        c.start()
        XCTAssertEqual(c.state, .failed("THE ANALYZER WOULDN'T START"))
        let none = LiveController(settings: LiveSettings(defaults: defaults(), systemAvailable: false),
                                  launch: { _, _, _ in FakePipe() }, makeCapture: { _ in nil })
        none.start()
        guard case .failed = none.state else { return XCTFail() }
        // a capture error stops everything
        let pipe = FakePipe(), cap = FakeCapture()
        let d = LiveController(settings: LiveSettings(defaults: defaults(), systemAvailable: false),
                               launch: { _, _, _ in pipe }, makeCapture: { _ in cap })
        d.start()
        cap.onError?(InputCapture.deniedText)
        let exp = expectation(description: "main hop")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(d.state, .failed(InputCapture.deniedText))
        XCTAssertTrue(pipe.closed)
        XCTAssertTrue(cap.stopped)
    }

    func testSilenceIsFilledWhenTheCaptureGoesQuiet() {
        let pipe = FakePipe()
        var clock = t0
        let c = LiveController(settings: LiveSettings(defaults: defaults(), systemAvailable: false),
                               launch: { _, _, _ in pipe }, makeCapture: { _ in FakeCapture() }, now: { clock })
        c.start()
        clock = t0 + 0.6
        c.fillSilence()
        XCTAssertEqual(pipe.written, 22050)
        c.stop()
    }

    // MARK: 3.3 end to end: Swift's pipe into the real core (CoreLive, the plug-ins' live path)

    func testRealAnalyzerReadsWhatThePipeWrites() throws {
        let weights = CoreTestSupport.weights
        guard FileManager.default.fileExists(atPath: weights.path) else { throw XCTSkip("no core weights at \(weights.path)") }
        var lines: [String] = []
        let lock = NSLock()
        let p = CoreLive(gap: 3, onLine: { l in lock.lock(); lines.append(l); lock.unlock() }, weights: weights)
        // 14 s of a 120 BPM click over an A-minor drone, in 0.1 s pieces like a capture's, a little
        // faster than real time (the ring holds about 11 s; a capture is never faster than real time)
        let sr = 44100.0
        for piece in 0..<140 {
            let samples = (0..<4410).map { i -> Float in
                let t = Double(piece * 4410 + i) / sr
                let click = t.truncatingRemainder(dividingBy: 0.5) < 0.01 ? 0.9 * sin(2 * .pi * 1000 * t) : 0
                let drone = 0.08 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 261.63 * t) + sin(2 * .pi * 329.63 * t))
                return Float(click + drone)
            }
            p.write(samples)
            Thread.sleep(forTimeInterval: 0.03)
        }
        func events() -> [LiveEvent] {
            lock.lock(); let got = lines; lock.unlock()
            return got.compactMap { LiveEvent.parse(line: $0, song: LiveSession.songFile(1)) }
        }
        func readings() -> [Result] {
            events().compactMap { e -> Result? in if case .reading(let r) = e { return r } else { return nil } }
        }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, readings().last?.bpm == nil { Thread.sleep(forTimeInterval: 0.1) }
        p.close()
        XCTAssertEqual(events().first, .ready)
        lock.lock(); let got = lines; lock.unlock()
        let last = try XCTUnwrap(readings().last, got.joined(separator: "\n"))
        XCTAssertEqual(last.bpm.flatMap(Double.init).map { Int($0.rounded()) }, 120)
        XCTAssertTrue(last.keys.map(\.0).contains("Am"))
    }

    func testNoWeightsIsTheIncompleteSentenceNeverSilence() {
        var lines: [String] = []
        let lock = NSLock()
        let p = CoreLive(gap: 3, onLine: { l in lock.lock(); lines.append(l); lock.unlock() },
                         weights: URL(fileURLWithPath: "/nonexistent/\(Core.weightsName)"))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            lock.lock(); let n = lines.count; lock.unlock()
            if n > 0 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        p.close()
        lock.lock(); let got = lines; lock.unlock()
        // weights already loaded in this process by another test = ready; otherwise the one sentence
        let first = got.first.flatMap { LiveEvent.parse(line: $0, song: LiveSession.songFile(1)) }
        XCTAssertTrue(first == .ready || first == .error(Core.incomplete), "\(got)")
    }

    // MARK: snapshot -> stream lines (SnapshotLines)

    func snap(seq: UInt64, song: UInt64 = 0, why: Int32 = 0, readings: UInt64 = 0, readingSong: UInt64 = 0,
              silent: Int32 = 0, error: Int32 = 0) -> bk_snapshot {
        var s = bk_snapshot()
        s.seq = seq; s.song = song; s.song_why = why; s.readings = readings; s.reading_song = readingSong
        s.has_reading = readings > 0 ? 1 : 0; s.silent = silent; s.error = error
        s.silence_db = -61.3; s.sound_after = 4.5; s.level_db = -14.24
        s.reading.has_bpm = 1; s.reading.bpm = 128; s.reading.secs = 6
        withUnsafeMutableBytes(of: &s.reading.keys.0.name) { $0.copyBytes(from: Array("Ebm".utf8) + [0]) }
        s.reading.keys.0.percent = 82
        return s
    }

    func kinds(_ lines: [String]) -> [String] {
        lines.map { l in
            let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any] ?? [:]
            return [(o["event"] as? String) ?? "?", (o["reason"] as? String) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: ":")
        }
    }

    func testSnapshotLinesFollowTheStreamOrder() {
        var l = SnapshotLines()
        XCTAssertEqual(kinds(l.next(snap(seq: 1, readings: 1))), ["reading"])
        XCTAssertEqual(l.next(snap(seq: 1, readings: 1)), [], "same seq: nothing new")
        // silence: its notice, the song's last reading, then the reset (bpm.py's order)
        XCTAssertEqual(kinds(l.next(snap(seq: 2, song: 1, why: Int32(BK_SONG_SILENCE), readings: 2, readingSong: 0, silent: 1))),
                       ["silence", "reading", "reset"])
        XCTAssertEqual(kinds(l.next(snap(seq: 3, song: 1, why: Int32(BK_SONG_SILENCE), readings: 2, silent: 0))), ["sound"])
        XCTAssertEqual(kinds(l.next(snap(seq: 4, song: 2, why: Int32(BK_SONG_AUDIO), readings: 3, readingSong: 2))),
                       ["boundary:audio", "reading"], "a reading of the new song comes after its boundary")
        XCTAssertEqual(kinds(l.next(snap(seq: 5, song: 3, why: Int32(BK_SONG_ANNOUNCED), readings: 3, readingSong: 2))),
                       ["boundary:title"])
        XCTAssertEqual(kinds(l.next(snap(seq: 6, song: 3, why: Int32(BK_SONG_ANNOUNCED), readings: 3, readingSong: 2, error: 1))),
                       ["error"])
    }

    func testSnapshotLinesParseAsTheStreamDid() {
        var l = SnapshotLines()
        let lines = l.next(snap(seq: 1, readings: 1)) + l.next(snap(seq: 2, readings: 1, silent: 1))
            + l.next(snap(seq: 3, readings: 1, silent: 0))
        let song = LiveSession.songFile(4)
        let events = lines.compactMap { LiveEvent.parse(line: $0, song: song) }
        XCTAssertEqual(events.count, 3, "\(lines)")
        guard case .reading(let r) = events[0] else { return XCTFail("\(events)") }
        XCTAssertEqual(r.bpm, "128.0")
        XCTAssertEqual(r.keys.first?.0, "Ebm")
        XCTAssertEqual(r.keys.first?.1, 82)
        XCTAssertNil(r.bpmExact)
        XCTAssertNil(r.tuningCents)
        XCTAssertEqual(r.file, song)
        XCTAssertEqual(events[1], .silence(db: -61.3))
        XCTAssertEqual(events[2], .sound(db: -14.2, after: 4.5))
    }
}

/// Where the tests find the core's weights (the repo's models/), passed in explicitly.
enum CoreTestSupport {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let weights = repo.appendingPathComponent("models/\(Core.weightsName)")
}
