import XCTest
@testable import Orion

/// A picked key PINS (J 2026-11-18, docs/ideas/2026-11-18-J-dictation.md §6): the dial, wheel, chords,
/// Auto-Tune send and everything sent out use the pick; the detector keeps its own order and %,
/// the pinned slot stays where it was clicked, a second click on it unpins, and a pick never makes
/// Beat Key think that key is more likely.
final class PinnedKeyTests: XCTestCase {
    let file = URL(fileURLWithPath: "/x/Beats/Beat A.wav")
    var raw: Result { reading([("Ebm", 80), ("F#", 12), ("Bbm", 8)]) }
    private func reading(_ keys: [(String, Int)]) -> Result {
        Result(file: file, name: "Beat A.wav", bpm: "141.98", keys: keys, bpmExact: 141.98, tuningCents: 12)
    }
    private func settings() -> SpellingSettings { SpellingSettings() }
    private func names(_ r: Result) -> [String] { r.keys.map { $0.0 } }
    private func slots(_ r: Result) -> [String] {
        TopKeys.arranged(keys: r.keys, manual: r.pin).map { $0.pinned ? "\($0.name)*" : $0.name }
    }
    private var lines: [String] = []
    override func setUp() { super.setUp(); lines = []; AppLog.sink = { [weak self] l in self?.lines.append(l) } }
    override func tearDown() { AppLog.sink = nil; super.tearDown() }

    // MARK: pin slot 2, the order stays, the key in use is the pick

    func testPinningSlotTwoLeavesTheDetectorsOrderAndPercents() {
        let s = settings()
        XCTAssertTrue(s.setManualKey("F#", of: raw, from: .topKeys))
        let shown = raw.respelled(choice: s.manualKey)
        XCTAssertEqual(names(shown), ["Ebm", "F#", "Bbm"])
        XCTAssertEqual(shown.keys.map { $0.1 }, [80, 12, 8])                 // never more likely
        XCTAssertEqual(slots(shown), ["Ebm", "F#*", "Bbm"])
        XCTAssertEqual(shown.keyInUse?.name, "F#")
        XCTAssertEqual(shown.keyInUse?.percent, 12)                           // its real %, for the ring
        XCTAssertEqual(raw.respelled(choice: nil).keyInUse?.name, "Ebm")      // no pin: the detector's #1
    }

    func testEveryPathPinsInPlace() {
        for source in [ManualKeySource.wheel, .topKeys, .dropdown, .keyboard] {
            let s = settings()
            s.setManualKey("Bbm", of: raw, from: source)
            XCTAssertEqual(slots(raw.respelled(choice: s.manualKey)), ["Ebm", "F#", "Bbm*"], source.rawValue)
        }
    }

    func testANewReadingReordersTheOthersButThePinStays() {
        let s = settings()
        s.setManualKey("F#", of: raw, from: .topKeys)                         // slot 2
        let next = reading([("F#", 55), ("Ebm", 30), ("Bbm", 10)])            // the detector changed its mind
        let shown = next.respelled(choice: s.manualKey)
        XCTAssertEqual(names(shown), ["F#", "Ebm", "Bbm"])                    // the detector's own order
        XCTAssertEqual(slots(shown), ["Ebm", "F#*", "Bbm"])                   // pin in slot 2, others live
        XCTAssertEqual(shown.keyInUse?.name, "F#")
        let drifted = reading([("Am", 50), ("Ebm", 30), ("Cm", 20)])          // the pin left the detector's list
        let d = drifted.respelled(choice: s.manualKey)
        XCTAssertEqual(slots(d), ["Am", "F#*", "Ebm"])
        XCTAssertEqual(d.keyInUse?.name, "F#")
        XCTAssertEqual(d.keyInUse?.percent, 0)                                // no made-up %
    }

    func testClickingThePinnedSlotAgainUnpins() {
        let s = settings()
        s.setManualKey("F#", of: raw, from: .topKeys)
        var p = PocketState()
        p.readout = .result(raw.respelled(choice: s.manualKey), page: nil, download: true, options: ResultOptions())
        let t = KeyStrip.topKeys(p, settings: s)
        t.onChoose?("Bbm")                                                    // another slot: the pin moves there
        XCTAssertEqual(s.manualKey?.slot, 2)
        t.onClear?()                                                          // the pinned slot: unpins
        XCTAssertNil(s.manualKey)
        let shown = raw.respelled(choice: s.manualKey)
        XCTAssertEqual(slots(shown), ["Ebm", "F#", "Bbm"])
        XCTAssertEqual(shown.keyInUse?.name, "Ebm")
    }

    func testTheTopSlotIsPinnableToo() {
        let s = settings()
        s.setManualKey("Ebm", of: raw, from: .topKeys)
        XCTAssertEqual(slots(raw.respelled(choice: s.manualKey)), ["Ebm*", "F#", "Bbm"])
    }

    // MARK: a pick the detector does not list

    func testAPickOutsideTheTopThreeTakesNoSlot() {
        let s = settings()
        s.setManualKey("Am", of: raw, from: .wheel)
        let shown = raw.respelled(choice: s.manualKey)
        XCTAssertEqual(names(shown), ["Ebm", "F#", "Bbm"])                    // slots show the detector
        XCTAssertEqual(slots(shown), ["Ebm", "F#", "Bbm"])
        XCTAssertEqual(shown.keyInUse?.name, "Am")                            // the dial, wheel, sends use it
        XCTAssertEqual(shown.keyInUse?.percent, 0)
        XCTAssertNil(s.manualKey?.slot)
    }

    func testPinOfAnotherReadingIsIgnored() {
        let s = settings()
        let other = Result(file: URL(fileURLWithPath: "/x/other.wav"), name: "other.wav", bpm: "90", keys: [("C", 70)])
        s.setManualKey("Am", of: other, from: .wheel)
        let shown = raw.respelled(choice: s.manualKey)
        XCTAssertNil(shown.pin)
        XCTAssertEqual(shown.keyInUse?.name, "Ebm")
    }

    // MARK: everything that reads "the key" reads the pick

    func testTheViewsAndSendsReadTheKeyInUse() {
        let s = settings()
        s.setManualKey("F#", of: raw, from: .topKeys)
        let shown = raw.respelled(choice: s.manualKey)
        var p = PocketState()
        p.readout = .result(shown, page: nil, download: true, options: ResultOptions())
        XCTAssertNotNil(p.manualKey)
        XCTAssertEqual(p.confidence, 0.12)
        XCTAssertEqual(p.scale, Scale.of("F#"))
        XCTAssertTrue(p.canAutoTune)
        XCTAssertEqual(SendPayload(shown).key, "F#")
        XCTAssertEqual(MenuBarReadout.of(raw, choice: s.manualKey).text?.hasPrefix("F#"), true)
        XCTAssertEqual(HarmonyPanel.key(p), "F#")
        let w = HarmonyPanel.wheel(p, settings: s)
        XCTAssertEqual(w.rank(6, minor: false), 0)                            // F# = the key on show
        XCTAssertEqual(w.rank(3, minor: true), 1)                             // Ebm = a runner-up now
        XCTAssertEqual(w.rank(10, minor: true), 1)
    }

    // MARK: logging

    func testSetAndClearLogWhereThePinSits() {
        let s = settings()
        s.setManualKey("F#", of: raw, from: .topKeys)
        XCTAssertTrue(lines.contains { $0.contains("manual key selection set: F# from top-3") && $0.contains("slot 2") }, "\(lines)")
        s.setManualKey("Am", of: raw, from: .wheel)
        XCTAssertTrue(lines.contains { $0.contains("manual key selection set: Am") && $0.contains("not in the detector's top 3") }, "\(lines)")
        s.clearManualKey(of: raw, from: .topKeysReset)
        XCTAssertTrue(lines.contains { $0.contains("manual key selection cleared: Am from top-3 re-click") }, "\(lines)")
    }

    func testAPinSlotBeyondTheDetectorsListIsLoggedAsAnError() {
        let s = settings()
        s.setManualKey("Bbm", of: raw, from: .topKeys)                        // slot 3
        let short = reading([("Ebm", 80)])
        XCTAssertEqual(slots(short.respelled(choice: s.manualKey)), ["Ebm", "Bbm*"])
        XCTAssertTrue(lines.contains { $0.contains("ERROR manual key selection: pin slot 3") }, "\(lines)")
    }
}
