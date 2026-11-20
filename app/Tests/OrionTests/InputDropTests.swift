import XCTest
@testable import Orion

/// A mid-listen input drop or format change is not an error (J, 2026-11-15: "no music playing, and
/// yet the UI visually communicates a catastrophic error"): Listen stays on, the capture restarts
/// on the device, Mac audio takes over when it can't, and only "nothing can capture" is red.
final class InputDropTests: XCTestCase {
    typealias FakePipe = LiveTests.FakePipe
    typealias FakeCapture = LiveTests.FakeCapture

    private func defaults() -> UserDefaults {
        let name = "orion-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func mainHop() {
        let exp = expectation(description: "main hop")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    // MARK: the pure decisions

    func testRecoveryRestartsRetriesOnceThenGivesUp() {
        XCTAssertEqual(InputRecovery.next(attempt: 1, ok: true), .restarted)
        XCTAssertEqual(InputRecovery.next(attempt: 1, ok: false), .retry(after: 1))
        XCTAssertEqual(InputRecovery.next(attempt: 2, ok: true), .restarted)
        XCTAssertEqual(InputRecovery.next(attempt: 2, ok: false), .giveUp, "bounded: never an open-ended loop")
        XCTAssertEqual(InputRecovery.next(attempt: 9, ok: false), .giveUp)
    }

    func testRecoveryRestartsOnlyWhenStoppedOrTheFormatChanged() {
        XCTAssertTrue(InputRecovery.needsRestart(engineRunning: false, tapRate: 44100, tapChannels: 2, nowRate: 44100, nowChannels: 2))
        XCTAssertTrue(InputRecovery.needsRestart(engineRunning: true, tapRate: 44100, tapChannels: 2, nowRate: 48000, nowChannels: 2))
        XCTAssertTrue(InputRecovery.needsRestart(engineRunning: true, tapRate: 44100, tapChannels: 2, nowRate: 44100, nowChannels: 8))
        XCTAssertFalse(InputRecovery.needsRestart(engineRunning: true, tapRate: 44100, tapChannels: 2, nowRate: 44100, nowChannels: 2),
                       "our own restart must not set off another")
    }

    func testAfterLossFallsBackToMacAudioOrNothing() {
        XCTAssertEqual(LiveSourcePlan.afterLoss(of: .input(uid: "interface", channel: 2), systemAvailable: true),
                       .fallback(.system, missingUID: "interface", channel: 2))
        XCTAssertEqual(LiveSourcePlan.afterLoss(of: .input(uid: nil, channel: 0), systemAvailable: true),
                       .fallback(.system, missingUID: "default input", channel: 0))
        let saved = LiveSource.input(uid: "interface", channel: 0)
        XCTAssertEqual(LiveSourcePlan.afterLoss(of: saved, systemAvailable: false), .use(saved),
                       "macOS 12: nothing to fall back to")
        XCTAssertEqual(LiveSourcePlan.afterLoss(of: .system, systemAvailable: true), .use(.system))
    }

    // MARK: the controller

    private struct Rig {
        let c: LiveController
        let settings: LiveSettings
        var pipe: FakePipe
        let asked: Box
        final class Box { var sources: [LiveSource] = []; var caps: [FakeCapture] = [] }
    }

    private func rig(saved: LiveSource, systemAvailable: Bool = true, systemCapture: Bool = true) -> Rig {
        let s = LiveSettings(defaults: defaults(), systemAvailable: systemAvailable)
        s.source = saved
        let pipe = FakePipe(), box = Rig.Box()
        let c = LiveController(settings: s, launch: { _, _, _ in pipe },
                               makeCapture: { src in
                                   box.sources.append(src)
                                   if src == .system && !systemCapture { return nil }
                                   let k = FakeCapture(); box.caps.append(k); return k
                               },
                               devices: { [InputDevice(id: 7, uid: "interface", name: "Interface", channels: 2)] })
        return Rig(c: c, settings: s, pipe: pipe, asked: box)
    }

    func testDropWaitingIsCalmNotAnError() {
        let r = rig(saved: .input(uid: "interface", channel: 0))
        r.c.start()
        let song = r.c.songChange.to
        r.asked.caps[0].onDrop?(.waiting)
        mainHop()
        XCTAssertEqual(r.c.state, .listening, "still listening: not FAILED")
        XCTAssertEqual(r.c.notice, "WAITING FOR MUSIC...")
        guard case .listening(let status)? = Faceplate.liveReadout(r.c.state, source: r.c.sourceName, factor: .one,
                                                                    notice: r.c.notice) else { return XCTFail("not the neutral listening readout") }
        XCTAssertEqual(status, "WAITING FOR MUSIC...")
        XCTAssertEqual(r.c.state.lamp, .listening)
        XCTAssertEqual(r.c.songChange.to, song)
        r.c.stop()
    }

    func testWaitingEndsWithTheFirstMusic() {
        let r = rig(saved: .input(uid: "interface", channel: 0))
        r.c.start()
        r.asked.caps[0].onDrop?(.waiting)
        mainHop()
        r.asked.caps[0].onSamples?([0, 0, 0])
        r.c.tickLevel()
        XCTAssertEqual(r.c.notice, "WAITING FOR MUSIC...", "silence is not music")
        r.asked.caps[0].onSamples?([0.4, -0.3, 0.2])
        r.c.tickLevel()
        XCTAssertNil(r.c.notice)
        XCTAssertEqual(r.c.state, .listening)
        r.c.stop()
    }

    func testGoneFallsBackToMacAudioKeepingTheSongAndTheSavedChoice() {
        let saved = LiveSource.input(uid: "interface", channel: 0)
        let r = rig(saved: saved)
        r.c.start()
        XCTAssertEqual(r.c.sourceName, "Interface")
        let song = r.c.songChange.to
        let old = r.asked.caps[0]
        old.onDrop?(.gone(why: "NO AUDIO INPUT FOUND"))
        mainHop()
        XCTAssertEqual(r.asked.sources, [saved, .system])
        XCTAssertTrue(old.stopped)
        XCTAssertEqual(r.c.state, .listening, "not FAILED")
        XCTAssertEqual(r.c.sourceName, "System Audio", "the SOURCE box says what is heard, not Missing Input")
        XCTAssertEqual(r.c.notice, LiveSourcePlan.fallbackNotice)
        XCTAssertEqual(r.settings.source, saved, "the saved device choice is never overwritten")
        XCTAssertEqual(r.c.songChange.to, song, "same song: the analyzer and the session were not restarted")
        XCTAssertFalse(r.pipe.closed)
        r.asked.caps[1].onSamples?([0.1, 0.2])
        XCTAssertEqual(r.pipe.written, 2, "the new capture feeds the same analyzer")
        r.c.stop()
        XCTAssertTrue(r.asked.caps[1].stopped)
    }

    func testGoneWithoutMacAudioIsTheOnlyRedCase() {
        let r = rig(saved: .input(uid: "interface", channel: 0), systemAvailable: false)
        r.c.start()
        r.asked.caps[0].onDrop?(.gone(why: "NO AUDIO INPUT FOUND"))
        mainHop()
        XCTAssertEqual(r.c.state, .failed(InputCapture.lostText))
        XCTAssertTrue(r.pipe.closed)
    }

    func testGoneWhenMacAudioCannotOpenFails() {
        let r = rig(saved: .input(uid: "interface", channel: 0), systemCapture: false)
        r.c.start()
        r.asked.caps[0].onDrop?(.gone(why: "x"))
        mainHop()
        XCTAssertEqual(r.c.state, .failed(InputCapture.lostText))
    }

    func testFallbackThatIsDeniedFailsThroughTheNormalErrorPath() {
        let r = rig(saved: .input(uid: "interface", channel: 0))
        r.c.start()
        r.asked.caps[0].onDrop?(.gone(why: "x"))
        mainHop()
        let denied = "ALLOW BEAT KEY IN SYSTEM SETTINGS › PRIVACY & SECURITY › SCREEN RECORDING"
        r.asked.caps[1].onError?(denied)
        mainHop()
        XCTAssertEqual(r.c.state, .failed(denied))
    }

    func testADropFromAnOldListenIsIgnored() {
        let r = rig(saved: .input(uid: "interface", channel: 0))
        r.c.start()
        let first = r.asked.caps[0]
        r.c.start(why: "new song")
        first.onDrop?(.gone(why: "late"))
        first.onDrop?(.waiting)
        mainHop()
        XCTAssertEqual(r.c.state, .listening)
        XCTAssertNil(r.c.notice)
        XCTAssertEqual(r.asked.sources.count, 2, "no fallback capture for a stale drop")
        r.c.stop()
    }

    func testDropWhenOffIsIgnored() {
        let r = rig(saved: .input(uid: "interface", channel: 0))
        r.c.start()
        let cap = r.asked.caps[0]
        r.c.stop()
        cap.onDrop?(.gone(why: "late"))
        mainHop()
        XCTAssertEqual(r.c.state, .off)
    }
}
