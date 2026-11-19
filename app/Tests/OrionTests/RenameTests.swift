import XCTest
@testable import Orion

/// Add key + BPM to the file's name (J 2026-11-18, idea 2): the policy chair (ask / remember /
/// Pro Tools guard), the helper's `rename` events, and the path refresh after a rename.
final class RenameTests: XCTestCase {
    // MARK: fixtures

    var lines: [String] = []
    override func setUp() {
        super.setUp()
        lines = []
        AppLog.sink = { [unowned self] l in self.lines.append(l) }
    }
    override func tearDown() { AppLog.sink = nil; super.tearDown() }

    func defaults() -> UserDefaults {
        let name = "rename-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func reading(_ path: String = "/Music/Beats/Beat A.wav", bpm: String? = "141.0",
                 keys: [(String, Int)] = [("Ebm", 80), ("F#", 12), ("Bbm", 8)], tagged: Bool = false,
                 error: String? = nil) -> Result {
        let u = URL(fileURLWithPath: path)
        return Result(file: u, name: u.lastPathComponent, bpm: bpm, keys: keys, readError: error,
                      bpmExact: 140.82, tagged: tagged)
    }

    /// A folder tree under the temp dir: returns the file URL inside `Audio Files`.
    func session(audioFolder: String = "Audio Files", ptx: String? = "Song.ptx", file: String = "a.wav") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        let audio = root.appendingPathComponent("Song").appendingPathComponent(audioFolder)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        if let ptx { FileManager.default.createFile(atPath: root.appendingPathComponent("Song/\(ptx)").path, contents: Data()) }
        let f = audio.appendingPathComponent(file)
        FileManager.default.createFile(atPath: f.path, contents: Data())
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return f
    }

    // MARK: Pro Tools guard

    func testFileInAudioFilesBesideAPtxIsInASession() throws {
        XCTAssertTrue(ProToolsGuard.inSession(try session()))
    }

    func testAudioFilesWithoutAPtxIsNotASession() throws {
        XCTAssertFalse(ProToolsGuard.inSession(try session(ptx: nil)))
        XCTAssertFalse(ProToolsGuard.inSession(try session(ptx: "Song.txt")))
    }

    func testOtherFolderNamesAreNotSessions() throws {
        XCTAssertFalse(ProToolsGuard.inSession(try session(audioFolder: "Bounced Files")))
        XCTAssertFalse(ProToolsGuard.inSession(try session(audioFolder: "My Audio Files")))
    }

    func testFolderNameAndExtensionIgnoreCase() throws {
        XCTAssertTrue(ProToolsGuard.inSession(try session(audioFolder: "audio files", ptx: "SONG.PTX")))
    }

    func testAFileInTheSessionFolderItselfIsNotGuarded() throws {
        let f = try session()
        let loose = f.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bounce.wav")
        FileManager.default.createFile(atPath: loose.path, contents: Data())
        XCTAssertFalse(ProToolsGuard.inSession(loose))
    }

    func testAFolderThatDoesNotExistIsNotGuarded() {
        XCTAssertFalse(ProToolsGuard.inSession(URL(fileURLWithPath: "/nope/Audio Files/a.wav")))
    }

    // MARK: the remembered choice

    func testDefaultIsAsk() {
        XCTAssertEqual(RenameSettings(defaults: defaults()).choice, .ask)
    }

    func testChoiceIsRememberedBetweenLaunches() {
        let d = defaults()
        RenameSettings(defaults: d).set(.always, from: "settings")
        XCTAssertEqual(RenameSettings(defaults: d).choice, .always)
        RenameSettings(defaults: d).set(.never, from: "settings")
        XCTAssertEqual(RenameSettings(defaults: d).choice, .never)
        RenameSettings(defaults: d).set(.ask, from: "settings")
        XCTAssertEqual(RenameSettings(defaults: d).choice, .ask)
    }

    func testAGarbageSavedValueIsAsk() {
        let d = defaults()
        d.set("sometimes", forKey: RenameSettings.key)
        XCTAssertEqual(RenameSettings(defaults: d).choice, .ask)
    }

    func testChangingTheChoiceIsLoggedWithWhereItCameFrom() {
        let s = RenameSettings(defaults: defaults())
        s.set(.always, from: "Settings")
        XCTAssertTrue(lines.contains { $0.contains("rename: remembered choice ask -> always (Settings)") }, "\(lines)")
        lines = []
        s.set(.always, from: "Settings")
        XCTAssertTrue(lines.isEmpty, "no change, no line")
    }

    // MARK: what goes in the name

    func testTheKeyInUseComesFirstThenTheDetectorsOthers() {
        let r = reading()
        let pin = KeyChoice(file: r.file, name: r.name, pitchClass: 6, minor: false, slot: 1)   // F#
        let item = RenameItem.make(r, choice: pin)
        XCTAssertEqual(item?.keys, ["F#", "Ebm", "Bbm"])
        XCTAssertEqual(item?.bpm, "141.0")
        XCTAssertEqual(item?.file, r.file)
    }

    func testNoPinMeansTheDetectorsOrder() {
        XCTAssertEqual(RenameItem.make(reading(), choice: nil)?.keys, ["Ebm", "F#", "Bbm"])
    }

    func testAPinTheDetectorDidNotListGoesFirst() {
        let r = reading()
        let pin = KeyChoice(file: r.file, name: r.name, pitchClass: 9, minor: true)   // Am
        XCTAssertEqual(RenameItem.make(r, choice: pin)?.keys, ["Am", "Ebm", "F#", "Bbm"])
    }

    func testAPinOnAnotherReadingIsIgnored() {
        let other = reading("/Music/Beats/Other.wav")
        let pin = KeyChoice(file: other.file, name: other.name, pitchClass: 6, minor: false)
        XCTAssertEqual(RenameItem.make(reading(), choice: pin)?.keys.first, "Ebm")
    }

    func testTheBpmShownIsTheOneInTheName() {
        XCTAssertEqual(RenameItem.make(reading(), choice: nil, factor: .double)?.bpm, "282.0")
        XCTAssertEqual(RenameItem.make(reading(), choice: nil, factor: .half)?.bpm, "70.5")
    }

    func testNothingToTagWithoutABpmOrAKeyOrWhenAlreadyTagged() {
        XCTAssertNil(RenameItem.make(reading(bpm: nil), choice: nil))
        XCTAssertNil(RenameItem.make(reading(keys: []), choice: nil))
        XCTAssertNil(RenameItem.make(reading(tagged: true), choice: nil))
        XCTAssertNil(RenameItem.make(reading(error: "permission"), choice: nil))
    }

    // MARK: the policy chair

    final class FakeAsker: RenameAsker {
        var askCounts: [Int] = []
        var answers: [(Bool, Bool) -> Void] = []
        var dismissed = 0
        var confirms: [Int] = []
        var confirmAnswer = true
        func ask(count: Int, answer: @escaping (Bool, Bool) -> Void) { askCounts.append(count); answers.append(answer) }
        func dismissAsk() { dismissed += 1 }
        func confirmProToolsLoss(count: Int) -> Bool { confirms.append(count); return confirmAnswer }
    }

    struct Rig {
        let settings: RenameSettings
        let asker: FakeAsker
        let coordinator: RenameCoordinator
        let performed: Box
    }
    final class Box { var batches: [[RenameItem]] = [] }

    func rig(choice: RenameChoice = .ask, protools: @escaping (URL) -> Bool = { _ in false }) -> Rig {
        let s = RenameSettings(defaults: defaults())
        if choice != .ask { s.set(choice, from: "test") }
        lines = []
        let a = FakeAsker(), b = Box()
        let c = RenameCoordinator(settings: s, asker: a, item: { RenameItem.make($0, choice: nil) },
                                  isProToolsFile: protools, perform: { b.batches.append($0) })
        return Rig(settings: s, asker: a, coordinator: c, performed: b)
    }

    func testAskModeAsksAndWaits() {
        let r = rig()
        r.coordinator.offer([reading()])
        XCTAssertEqual(r.asker.askCounts, [1])
        XCTAssertTrue(r.performed.batches.isEmpty, "nothing is renamed before the answer")
        XCTAssertTrue(lines.contains { $0.contains("rename: asked (1 file)") }, "\(lines)")
    }

    func testYesWithoutRememberRenamesAndStillAsksNextTime() {
        let r = rig()
        r.coordinator.offer([reading()])
        r.asker.answers[0](true, false)
        XCTAssertEqual(r.performed.batches.count, 1)
        XCTAssertEqual(r.performed.batches[0].first?.keys, ["Ebm", "F#", "Bbm"])
        XCTAssertEqual(r.settings.choice, .ask)
        XCTAssertTrue(lines.contains { $0.contains("rename: answer yes (not remembered)") }, "\(lines)")
    }

    func testNoWithoutRememberRenamesNothing() {
        let r = rig()
        r.coordinator.offer([reading()])
        r.asker.answers[0](false, false)
        XCTAssertTrue(r.performed.batches.isEmpty)
        XCTAssertEqual(r.settings.choice, .ask)
        XCTAssertTrue(lines.contains { $0.contains("rename: answer no (not remembered)") }, "\(lines)")
    }

    func testYesRememberedMeansAlwaysAndNeverAsksAgain() {
        let r = rig()
        r.coordinator.offer([reading()])
        r.asker.answers[0](true, true)
        XCTAssertEqual(r.settings.choice, .always)
        XCTAssertEqual(r.performed.batches.count, 1)
        r.coordinator.offer([reading("/Music/Beats/Beat B.wav")])
        XCTAssertEqual(r.asker.askCounts.count, 1, "no second ask")
        XCTAssertEqual(r.performed.batches.count, 2, "renamed straight away")
        XCTAssertTrue(lines.contains { $0.contains("rename: remembered choice ask -> always (prompt)") }, "\(lines)")
    }

    func testNoRememberedMeansNeverAndNeverAsksAgain() {
        let r = rig()
        r.coordinator.offer([reading()])
        r.asker.answers[0](false, true)
        XCTAssertEqual(r.settings.choice, .never)
        r.coordinator.offer([reading("/Music/Beats/Beat B.wav")])
        XCTAssertEqual(r.asker.askCounts.count, 1)
        XCTAssertTrue(r.performed.batches.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("rename: remembered no, not asking") }, "\(lines)")
    }

    func testAlreadyTaggedFilesAreSkippedAndLogged() {
        let r = rig()
        r.coordinator.offer([reading(tagged: true)])
        XCTAssertTrue(r.asker.askCounts.isEmpty)
        XCTAssertTrue(r.performed.batches.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("rename: skipped 1 file already tagged by Beat Key") }, "\(lines)")
    }

    func testFilesWithNoReadingAreNotOffered() {
        let r = rig()
        r.coordinator.offer([reading(bpm: nil, keys: [])])
        XCTAssertTrue(r.asker.askCounts.isEmpty)
        XCTAssertTrue(r.performed.batches.isEmpty)
    }

    func testSeveralFilesAreOneQuestion() {
        let r = rig()
        r.coordinator.offer([reading("/a/1.wav"), reading("/a/2.wav"), reading("/a/3.wav", tagged: true)])
        XCTAssertEqual(r.asker.askCounts, [2])
        r.asker.answers[0](true, false)
        XCTAssertEqual(r.performed.batches[0].map { $0.file.lastPathComponent }, ["1.wav", "2.wav"])
    }

    func testTheKeyIsReadWhenYouAnswerSoAPinMadeWhileTheAskIsUpCounts() {
        let s = RenameSettings(defaults: defaults())
        let a = FakeAsker(), b = Box()
        var pin: KeyChoice?
        let c = RenameCoordinator(settings: s, asker: a, item: { RenameItem.make($0, choice: pin) },
                                  isProToolsFile: { _ in false }, perform: { b.batches.append($0) })
        let r = reading()
        c.offer([r])
        pin = KeyChoice(file: r.file, name: r.name, pitchClass: 6, minor: false)
        a.answers[0](true, false)
        XCTAssertEqual(b.batches[0].first?.keys.first, "F#")
    }

    func testANewOfferDismissesTheOldAskAndTheOldAnswerDoesNothing() {
        let r = rig()
        r.coordinator.offer([reading()])
        r.coordinator.offer([reading("/Music/Beats/Beat B.wav")])
        XCTAssertEqual(r.asker.dismissed, 1)
        r.asker.answers[0](true, true)
        XCTAssertTrue(r.performed.batches.isEmpty)
        XCTAssertEqual(r.settings.choice, .ask, "a stale answer remembers nothing")
        XCTAssertTrue(lines.contains { $0.contains("rename: ask dismissed") }, "\(lines)")
    }

    // MARK: the Pro Tools guard in the policy

    func testProToolsFileAlwaysGetsTheBlockingConfirmWhateverWasRemembered() {
        for choice in [RenameChoice.ask, .always, .never] {
            let r = rig(choice: choice, protools: { _ in true })
            r.coordinator.offer([reading("/S/Audio Files/a.wav")])
            XCTAssertEqual(r.asker.confirms, [1], "\(choice)")
            XCTAssertTrue(lines.contains { $0.contains("rename: Pro Tools guard") }, "\(choice) \(lines)")
        }
    }

    func testProToolsYesRenamesAndNoDoesNot() {
        let r = rig(protools: { _ in true })
        r.coordinator.offer([reading("/S/Audio Files/a.wav")])
        XCTAssertEqual(r.performed.batches.count, 1)
        XCTAssertTrue(r.asker.askCounts.isEmpty, "the guard replaces the soft ask for that file")
        let n = rig(protools: { _ in true })
        n.asker.confirmAnswer = false
        n.coordinator.offer([reading("/S/Audio Files/a.wav")])
        XCTAssertTrue(n.performed.batches.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("rename: Pro Tools guard answer no") }, "\(lines)")
    }

    func testAMixedDropGuardsOnlyTheSessionFiles() {
        let r = rig(choice: .always, protools: { $0.path.contains("Audio Files") })
        r.asker.confirmAnswer = false
        r.coordinator.offer([reading("/S/Audio Files/a.wav"), reading("/M/b.wav")])
        XCTAssertEqual(r.asker.confirms, [1])
        XCTAssertEqual(r.performed.batches.flatMap { $0 }.map { $0.file.lastPathComponent }, ["b.wav"])
    }

    func testLogsNeverNameAFile() {
        let r = rig(protools: { $0.path.contains("Audio Files") })
        r.coordinator.offer([reading("/S/Audio Files/Secret Song.wav"), reading("/M/Other Secret.wav"),
                             reading("/M/Tagged Secret.wav", tagged: true)])
        r.asker.answers.first?(true, true)
        XCTAssertFalse(lines.contains { $0.contains("Secret") }, "\(lines)")
    }

    // MARK: helper events

    func testRenameEventsParse() {
        XCTAssertEqual(Event.parse(line: #"{"stage":"renamed","file":"/a/B.wav","to":"/a/B (1 BPM Cm).wav","name":"B (1 BPM Cm).wav"}"#),
                       .renamed(from: "/a/B.wav", to: "/a/B (1 BPM Cm).wav"))
        XCTAssertEqual(Event.parse(line: #"{"stage":"rename_skipped","file":"/a/B.wav","reason":"tagged"}"#),
                       .renameSkipped(file: "/a/B.wav"))
        XCTAssertEqual(Event.parse(line: #"{"stage":"rename_failed","file":"/a/B.wav","errno":13,"message":"Permission denied"}"#),
                       .renameFailed(file: "/a/B.wav", errno: 13, message: "Permission denied"))
    }

    func testTaggedFlagParses() {
        let line = #"{"stage":"analyzed","file":"/a.wav","name":"a.wav","tagged":true,"bpm":"90.0","keys":[["Am",50]]}"#
        guard case .analyzed(let r)? = Event.parse(line: line) else { return XCTFail() }
        XCTAssertTrue(r.tagged)
        let old = #"{"stage":"analyzed","file":"/a.wav","name":"a.wav","bpm":"90.0","keys":[["Am",50]]}"#
        guard case .analyzed(let o)? = Event.parse(line: old) else { return XCTFail() }
        XCTAssertFalse(o.tagged)
    }

    func testRespelledKeepsTheTag() {
        XCTAssertTrue(reading(tagged: true).respelled(choice: nil).tagged)
    }

    // MARK: the engine: run the helper, refresh the paths

    func rt() -> Runtime {
        Runtime(root: URL(fileURLWithPath: "/R/runtime"), arch: "arm64",
                support: URL(fileURLWithPath: "/S/Orion"), osMajor: 14)
    }
    func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

    func testEngineRunsTheHelperRenameWithTheKeysInOrder() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), launcher: f, jobs: f)
        let r = reading()
        e.rename([RenameItem.make(r, choice: nil)!])
        spin()
        XCTAssertEqual(f.launches.count, 1)
        XCTAssertEqual(Array(f.launches[0].dropFirst()), ["rename", r.file.path, "141.0", "Ebm", "F#", "Bbm"])
    }

    func testRenamedMovesTheReadingOnShowTheRecentsAndThePin() {
        let f = FakeLauncher()
        let recents = RecentStore(defaults: defaults())
        let spelling = SpellingSettings()
        let e = Engine(runtime: rt(), launcher: f, jobs: f, recents: recents)
        e.spelling = spelling
        let r = reading()
        e.state = .analyzed([r])
        recents.record(r)
        spelling.manualKey = KeyChoice(file: r.file, name: r.name, pitchClass: 6, minor: false, slot: 1)
        e.rename([RenameItem.make(r, choice: nil)!]); spin()
        f.onLine?(#"{"stage":"renamed","file":"/Music/Beats/Beat A.wav","to":"/Music/Beats/Beat A (141.0 BPM Ebm F# Bbm).wav","name":"Beat A (141.0 BPM Ebm F# Bbm).wav"}"#)
        f.onExit?(0); spin()
        guard case .analyzed(let rs) = e.state else { return XCTFail("\(e.state)") }
        XCTAssertEqual(rs[0].file.path, "/Music/Beats/Beat A (141.0 BPM Ebm F# Bbm).wav")
        XCTAssertEqual(rs[0].name, "Beat A (141.0 BPM Ebm F# Bbm).wav")
        XCTAssertTrue(rs[0].tagged)
        XCTAssertEqual(rs[0].bpm, "141.0")
        XCTAssertEqual(recents.readings.map { $0.path }, ["/Music/Beats/Beat A (141.0 BPM Ebm F# Bbm).wav"])
        XCTAssertEqual(recents.readings.first?.name, "Beat A (141.0 BPM Ebm F# Bbm).wav")
        XCTAssertEqual(spelling.manualKey?.file.path, "/Music/Beats/Beat A (141.0 BPM Ebm F# Bbm).wav")
        XCTAssertEqual(spelling.manualKey?.pitchClass, 6)
        XCTAssertEqual(spelling.manualKey?.slot, 1)
        XCTAssertTrue(lines.contains { $0.contains("rename: done") }, "\(lines)")
        XCTAssertFalse(lines.filter { $0.contains("rename:") }.contains { $0.contains("Beat A") }, "\(lines)")
    }

    func testRenamedAlsoMovesAPageOfSeveralFiles() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), launcher: f, jobs: f)
        let a = reading("/m/A.wav"), b = reading("/m/B.wav")
        e.state = .analyzed([a, b])
        e.rename([RenameItem.make(b, choice: nil)!]); spin()
        f.onLine?(#"{"stage":"renamed","file":"/m/B.wav","to":"/m/B (141.0 BPM Ebm F# Bbm).wav","name":"B (141.0 BPM Ebm F# Bbm).wav"}"#)
        f.onExit?(0); spin()
        guard case .analyzed(let rs) = e.state else { return XCTFail() }
        XCTAssertEqual(rs.map { $0.file.lastPathComponent }, ["A.wav", "B (141.0 BPM Ebm F# Bbm).wav"])
    }

    func testAFailedRenameKeepsTheReadingAndSaysSoOnTheReadout() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), launcher: f, jobs: f)
        let r = reading()
        e.state = .analyzed([r])
        e.rename([RenameItem.make(r, choice: nil)!]); spin()
        f.onLine?(#"{"stage":"rename_failed","file":"/Music/Beats/Beat A.wav","errno":1,"message":"Operation not permitted"}"#)
        f.onExit?(0); spin()
        XCTAssertEqual(e.state, .analyzed([r]), "the reading and its path stand")
        XCTAssertEqual(e.note, Faceplate.renameFailedNote("Operation not permitted"))
        XCTAssertTrue(e.note?.contains("RENAME") ?? false)
        XCTAssertTrue(lines.contains { $0.contains("rename: FAILED") && $0.contains("errno 1") }, "\(lines)")
        XCTAssertFalse(lines.filter { $0.contains("rename:") }.contains { $0.contains("Beat A") }, "\(lines)")
    }

    func testAHelperThatDiesWithoutAnEventIsAFailureToo() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), launcher: f, jobs: f)
        let r = reading()
        e.state = .analyzed([r])
        e.rename([RenameItem.make(r, choice: nil)!]); spin()
        f.onExit?(1); spin()
        XCTAssertNotNil(e.note)
        XCTAssertTrue(lines.contains { $0.contains("rename: FAILED") }, "\(lines)")
    }

    func testASkippedRenameIsLoggedAndChangesNothing() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), launcher: f, jobs: f)
        let r = reading()
        e.state = .analyzed([r])
        e.rename([RenameItem.make(r, choice: nil)!]); spin()
        f.onLine?(#"{"stage":"rename_skipped","file":"/Music/Beats/Beat A.wav","reason":"tagged"}"#)
        f.onExit?(0); spin()
        XCTAssertEqual(e.state, .analyzed([r]))
        XCTAssertNil(e.note)
        XCTAssertTrue(lines.contains { $0.contains("rename: skipped (already tagged)") }, "\(lines)")
    }

    func testSeveralItemsRunOneAfterAnother() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), launcher: f, jobs: f)
        let a = reading("/m/A.wav"), b = reading("/m/B.wav")
        e.rename([RenameItem.make(a, choice: nil)!, RenameItem.make(b, choice: nil)!]); spin()
        XCTAssertEqual(f.launches.count, 1, "the second waits for the first")
        f.onExit?(0); spin()
        XCTAssertEqual(f.launches.count, 2)
        XCTAssertEqual(f.launches[1][2], "/m/B.wav")
    }

    func testRenameDoesNotTouchABusyState() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), launcher: f, jobs: f)
        let r = reading()
        e.rename([RenameItem.make(r, choice: nil)!]); spin()
        XCTAssertEqual(e.state, .idle, "the rename is quiet: no WORKING readout")
    }

    func testAnalysisOffersTheResultsAfterTheyAreOnShow() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), launcher: f, jobs: f)
        var offered: [[Result]] = []
        e.afterAnalysis = { offered.append($0) }
        e.analyze([URL(fileURLWithPath: "/a.wav")])
        let deadline = Date().addingTimeInterval(5)
        while f.launches.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        f.onLine?(#"{"stage":"analyzed","file":"/a.wav","name":"a.wav","tagged":false,"bpm":"100.0","keys":[["Am",50]]}"#)
        f.onExit?(0); spin()
        XCTAssertEqual(offered.count, 1)
        XCTAssertEqual(offered[0].first?.file.path, "/a.wav")
        if case .analyzed = e.state {} else { XCTFail("\(e.state)") }
    }

    func testADownloadIsNeverOffered() {
        let f = FakeLauncher()
        let e = Engine(runtime: rt(), launcher: f, jobs: f)
        var offered = 0
        e.afterAnalysis = { _ in offered += 1 }
        e.download("u")
        let deadline = Date().addingTimeInterval(5)
        while f.launches.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        f.onLine?(#"{"stage":"done","file":"/a.mp3","name":"a.mp3","bpm":"90.0","keys":[["Am",50]]}"#)
        f.onExit?(0); spin()
        XCTAssertEqual(offered, 0, "the download is already renamed by the helper")
    }

    // MARK: the pin follows the file

    func testPinMovesWithTheFileAndOnlyThisFile() {
        let s = SpellingSettings()
        let r = reading()
        s.manualKey = KeyChoice(file: r.file, name: r.name, pitchClass: 6, minor: false, slot: 2)
        let other = reading("/Music/Beats/Other.wav")
        s.moved(from: other.file, to: URL(fileURLWithPath: "/Music/Beats/X.wav"))
        XCTAssertEqual(s.manualKey?.file, r.file, "another file's rename leaves the pin alone")
        s.moved(from: r.file, to: URL(fileURLWithPath: "/Music/Beats/New.wav"))
        XCTAssertEqual(s.manualKey?.file.path, "/Music/Beats/New.wav")
        XCTAssertEqual(s.manualKey?.name, "New.wav")
        XCTAssertEqual(s.manualKey?.slot, 2)
    }
}
