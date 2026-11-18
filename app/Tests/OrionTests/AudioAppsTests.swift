import XCTest
@testable import Orion

/// Listen's "Add App" submenu: the order of the open apps (playing first, then A-Z), which app is
/// playing, the capture filter an app choice makes, and the fallback when the app is gone.
final class AudioAppsTests: XCTestCase {
    private func app(_ name: String, _ id: String? = nil, pid: Int32 = 1) -> AudioApp {
        AudioApp(bundleID: id ?? "com.test.\(name.lowercased())", name: name, pid: pid)
    }

    // MARK: ordering

    func testPlayingAppsComeFirstThenTheRestAZ() {
        let apps = [app("Mail"), app("Spotify"), app("Finder"), app("Logic Pro"), app("Safari")]
        let out = AudioApps.ordered(apps, playing: ["com.test.spotify", "com.test.safari"])
        XCTAssertEqual(out.map(\.name), ["Safari", "Spotify", "Finder", "Logic Pro", "Mail"])
    }

    func testOrderIsCaseInsensitive() {
        let apps = [app("zoom"), app("Arc"), app("brave"), app("Calendar"), app("Apple Music")]
        XCTAssertEqual(AudioApps.ordered(apps, playing: []).map(\.name),
                       ["Apple Music", "Arc", "brave", "Calendar", "zoom"])
        // the playing group is sorted the same way
        let p = AudioApps.ordered(apps, playing: ["com.test.zoom", "com.test.brave", "com.test.arc"])
        XCTAssertEqual(p.map(\.name), ["Arc", "brave", "zoom", "Apple Music", "Calendar"])
    }

    func testSameNameFallsBackToBundleIDAndEmptyStaysEmpty() {
        let a = app("Helper", "com.b.helper"), b = app("helper", "com.a.helper")
        XCTAssertEqual(AudioApps.ordered([a, b], playing: []).map(\.bundleID), ["com.a.helper", "com.b.helper"])
        XCTAssertEqual(AudioApps.ordered([], playing: ["x"]), [])
    }

    func testPlayingIDsThatAreNotOpenAppsAreIgnored() {
        let out = AudioApps.ordered([app("B"), app("A")], playing: ["com.not.open"])
        XCTAssertEqual(out.map(\.name), ["A", "B"])
    }

    // MARK: which app is playing

    func testPlayingMatchesByPidByHelperBundleIDAndByAncestor() {
        let apps = [app("Spotify", "com.spotify.client", pid: 100),
                    app("Brave", "com.brave.Browser", pid: 200),
                    app("Safari", "com.apple.Safari", pid: 300),
                    app("Mail", "com.apple.mail", pid: 400)]
        let procs = [AudioProcess(pid: 100, bundleID: "com.spotify.client"),      // the app itself
                     AudioProcess(pid: 250, bundleID: "com.brave.Browser.helper"), // a helper by name
                     AudioProcess(pid: 350, bundleID: "com.apple.WebKit.GPU")]    // a helper by parent
        let parents: [Int32: Int32] = [350: 340, 340: 300]
        let out = AudioApps.playingIDs(outputProcesses: procs, apps: apps, parentOf: { parents[$0] })
        XCTAssertEqual(out, ["com.spotify.client", "com.brave.Browser", "com.apple.Safari"])
    }

    func testBundlePrefixNeedsADotBoundary() {
        let apps = [app("Music", "com.apple.Music", pid: 1)]
        let out = AudioApps.playingIDs(outputProcesses: [AudioProcess(pid: 9, bundleID: "com.apple.MusicBox")],
                                       apps: apps, parentOf: { _ in nil })
        XCTAssertEqual(out, [])
    }

    func testAncestorWalkIsBounded() {
        // a parent loop must not hang
        let out = AudioApps.playingIDs(outputProcesses: [AudioProcess(pid: 5, bundleID: nil)],
                                       apps: [app("A", pid: 1)], parentOf: { $0 == 5 ? 6 : 5 })
        XCTAssertEqual(out, [])
    }

    // MARK: the listing and its log

    func testListingOrdersAndLogsCounts() {
        var lines: [String] = []
        AppLog.sink = { lines.append($0) }
        defer { AppLog.sink = nil }
        let apps = [app("Mail", pid: 1), app("Spotify", pid: 2)]
        let l = AudioApps.listing(apps: apps, outputProcesses: [AudioProcess(pid: 2, bundleID: "com.test.spotify")],
                                  parentOf: { _ in nil })
        XCTAssertEqual(l.apps.map(\.name), ["Spotify", "Mail"])
        XCTAssertEqual(l.playingCount, 1)
        XCTAssertTrue(lines.contains { $0.contains("add app: list built, 2 apps, 1 playing") }, "\(lines)")
    }

    func testListingWithoutTheAPIIsPlainAZAndLogsTheGapOnce() {
        var lines: [String] = []
        AppLog.sink = { lines.append($0) }
        defer { AppLog.sink = nil }
        AudioApps.resetUnavailableLogForTests()
        let apps = [app("Mail"), app("Arc")]
        let a = AudioApps.listing(apps: apps, outputProcesses: nil, parentOf: { _ in nil })
        let b = AudioApps.listing(apps: apps, outputProcesses: nil, parentOf: { _ in nil })
        XCTAssertEqual(a.apps.map(\.name), ["Arc", "Mail"])
        XCTAssertEqual(b.playingCount, 0)
        XCTAssertEqual(lines.filter { $0.contains("playing-now is not available") }.count, 1, "\(lines)")
    }

    // MARK: the capture filter

    func testFilterChoice() {
        let open = ["com.spotify.client", "com.apple.Safari"]
        XCTAssertEqual(SystemAudioCapture.filterChoice(app: nil, shareable: open), .everyApp)
        XCTAssertEqual(SystemAudioCapture.filterChoice(app: "com.spotify.client", shareable: open),
                       .only("com.spotify.client"))
        XCTAssertEqual(SystemAudioCapture.filterChoice(app: "com.gone.app", shareable: open),
                       .appGone("com.gone.app"))
        XCTAssertEqual(SystemAudioCapture.filterChoice(app: "com.gone.app", shareable: []), .appGone("com.gone.app"))
        XCTAssertEqual(SystemAudioCapture.filterChoice(app: nil, shareable: []), .everyApp)
    }

    // MARK: the choice is part of the Input setting

    func testAppSourceIsStoredWithTheInputSetting() {
        let s = LiveSource.app(bundleID: "com.spotify.client")
        XCTAssertEqual(s.stored, "app:com.spotify.client")
        XCTAssertEqual(LiveSource.from(stored: s.stored), s)
        XCTAssertNil(LiveSource.from(stored: "app:"))
        // the existing options are untouched
        XCTAssertEqual(LiveSource.from(stored: "system"), .system)
        XCTAssertEqual(LiveSource.from(stored: "input:2:uid"), .input(uid: "uid", channel: 2))
    }

    func testMacOS12CannotKeepAnAppChoice() {
        let d = UserDefaults(suiteName: "orion-apps-\(UUID().uuidString)")!
        d.set("app:com.spotify.client", forKey: LiveSettings.sourceKey)
        XCTAssertEqual(LiveSettings(defaults: d, systemAvailable: false).source, .input(uid: nil, channel: 0))
        XCTAssertEqual(LiveSettings(defaults: d, systemAvailable: true).source, .app(bundleID: "com.spotify.client"))
    }

    func testHearingAndName() {
        let s = LiveSource.app(bundleID: "com.not.installed.anywhere")
        XCTAssertEqual(LiveController.hearing(s, name: "App: X"), "only the app com.not.installed.anywhere")
        XCTAssertEqual(LiveSettings.name(of: s, devices: []), "App: com.not.installed.anywhere")
    }

    // MARK: the app quits

    func testPlanAppNotOpenFallsBackToMacAudio() {
        let saved = LiveSource.app(bundleID: "com.spotify.client")
        XCTAssertEqual(LiveSourcePlan.plan(saved: saved, connectedUIDs: [], systemAvailable: true, runningAppIDs: []),
                       .fallback(.system, missingUID: "com.spotify.client", channel: 0))
        XCTAssertEqual(LiveSourcePlan.plan(saved: saved, connectedUIDs: [], systemAvailable: true,
                                           runningAppIDs: ["com.spotify.client"]), .use(saved))
    }

    func testAfterLossOfAnAppFallsBackToMacAudio() {
        let lost = LiveSource.app(bundleID: "com.spotify.client")
        XCTAssertEqual(LiveSourcePlan.afterLoss(of: lost, systemAvailable: true),
                       .fallback(.system, missingUID: "com.spotify.client", channel: 0))
    }

    private func controller(saved: LiveSource, open: Set<String>, asked: @escaping (LiveSource) -> Void,
                            cap: LiveTests.FakeCapture = LiveTests.FakeCapture()) -> (LiveController, LiveSettings) {
        let d = UserDefaults(suiteName: "orion-apps-\(UUID().uuidString)")!
        let s = LiveSettings(defaults: d, systemAvailable: true)
        s.source = saved
        return (LiveController(settings: s, launch: { _, _, _ in LiveTests.FakePipe() },
                               makeCapture: { src in asked(src); return cap },
                               devices: { [] }, runningAppIDs: { open }), s)
    }

    func testControllerChosenAppNotOpenOpensMacAudioWithNoticeAndKeepsTheChoice() {
        var lines: [String] = []
        AppLog.sink = { lines.append($0) }
        defer { AppLog.sink = nil }
        let saved = LiveSource.app(bundleID: "com.spotify.client")
        var asked: [LiveSource] = []
        let (c, s) = controller(saved: saved, open: ["com.apple.Safari"]) { asked.append($0) }
        c.start()
        XCTAssertEqual(asked, [.system])
        XCTAssertEqual(c.notice, LiveSourcePlan.appFallbackNotice)
        XCTAssertEqual(s.source, saved)
        XCTAssertTrue(lines.contains { $0.contains("saved app com.spotify.client is not open") && $0.contains("falling back") }, "\(lines)")
    }

    func testControllerChosenAppOpenCapturesOnlyThatApp() {
        let saved = LiveSource.app(bundleID: "com.spotify.client")
        var asked: [LiveSource] = []
        let (c, _) = controller(saved: saved, open: ["com.spotify.client"]) { asked.append($0) }
        c.start()
        XCTAssertEqual(asked, [saved])
        XCTAssertNil(c.notice)
        XCTAssertEqual(c.state, .listening)
    }

    func testAppQuitsMidListenFallsBackToMacAudioSameSong() {
        let saved = LiveSource.app(bundleID: "com.spotify.client")
        var asked: [LiveSource] = []
        let cap = LiveTests.FakeCapture()
        let (c, s) = controller(saved: saved, open: ["com.spotify.client"], asked: { asked.append($0) }, cap: cap)
        c.start()
        cap.onDrop?(.gone(why: "app quit"))
        let exp = expectation(description: "main queue")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(asked, [saved, .system])
        XCTAssertEqual(c.notice, LiveSourcePlan.appFallbackNotice)
        XCTAssertEqual(s.source, saved, "the chosen app stays saved; used again when it is back")
    }
}
