import XCTest
@testable import Orion

/// House kit, help-menu: Help > Manual, Help > What's New and App menu > Licenses.
/// The pages are real files (app/pages, app/tools/licenses.sh) and a missing one is logged and alerted.
@MainActor
final class HelpPagesTests: XCTestCase {
    private var realOpener: ((URL) -> Bool)!
    private var realAlert: ((String, String) -> Void)!
    private var dir: URL!
    private var lines: [String] = []

    private let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()          // app/

    override func setUp() async throws {
        realOpener = HouseHelp.opener
        realAlert = HouseHelp.notFoundAlert
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HelpPagesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lines = []
        AppLog.sink = { [weak self] l in self?.lines.append(l) }
    }

    override func tearDown() async throws {
        HouseHelp.opener = realOpener
        HouseHelp.notFoundAlert = realAlert
        AppLog.sink = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func bundle(_ files: [String]) throws -> Bundle {
        let d = dir.appendingPathComponent("\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for f in files { try "x".write(to: d.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        return try XCTUnwrap(Bundle(url: d))
    }

    private func page(_ name: String) throws -> String {
        try String(contentsOf: app.appendingPathComponent("pages/\(name)"), encoding: .utf8)
    }

    // MARK: menu items open the bundled pages

    func testThePagesOpenFromTheBundle() throws {
        let b = try bundle(["Manual.html", "WhatsNew.html", "Licenses.txt"])
        var opened: [String] = []
        HouseHelp.opener = { opened.append($0.lastPathComponent); return true }
        HouseHelp.notFoundAlert = { _, _ in XCTFail("nothing is missing") }
        for p in HouseHelp.pages { XCTAssertTrue(HouseHelp.open(p, in: b)) }
        XCTAssertEqual(opened, ["Manual.html", "WhatsNew.html", "Licenses.txt"])
        XCTAssertTrue(lines.contains { $0.hasPrefix("[help]") && $0.contains("opened Licenses.txt") }, "\(lines)")
    }

    /// A missing page is never silent: an ERROR line in beatkey.log and a short "not found" alert.
    func testAMissingPageIsLoggedAndAlerted() throws {
        let b = try bundle(["Manual.html"])
        var alerts: [(String, String)] = []
        var opened = 0
        HouseHelp.opener = { _ in opened += 1; return true }
        HouseHelp.notFoundAlert = { alerts.append(($0, $1)) }
        XCTAssertFalse(HouseHelp.open(HouseHelp.whatsNew, in: b))
        XCTAssertFalse(HouseHelp.open(HouseHelp.licenses, in: b))
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(alerts.map(\.0), ["What's New", "Licenses"])
        XCTAssertTrue(alerts[0].1.contains("missing"), alerts[0].1)
        XCTAssertEqual(lines.filter { $0.hasPrefix("[help]") && $0.contains("ERROR") }.count, 2, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("What's New: none of") }, "\(lines)")
    }

    func testAPageThatWillNotOpenIsLoggedAndAlerted() throws {
        let b = try bundle(["Manual.html"])
        var alerts = 0
        HouseHelp.opener = { _ in false }
        HouseHelp.notFoundAlert = { _, _ in alerts += 1 }
        XCTAssertFalse(HouseHelp.open(HouseHelp.manual, in: b))
        XCTAssertEqual(alerts, 1)
        XCTAssertTrue(lines.contains { $0.contains("ERROR") && $0.contains("would not open") }, "\(lines)")
    }

    // MARK: the shipped pages

    /// What build.sh bundles (the names the gate looks for) exists in the repo and is not empty.
    func testTheManualAndWhatsNewSourcesExist() throws {
        for name in ["Manual.html", "WhatsNew.html"] { XCTAssertGreaterThan(try page(name).count, 500, name) }
        XCTAssertTrue(HouseHelp.manual.names.contains("Manual.html"))
        XCTAssertTrue(HouseHelp.whatsNew.names.contains("WhatsNew.html"))
        XCTAssertTrue(HouseHelp.licenses.names.contains("Licenses.txt"))
    }

    /// Every shortcut the Manual prints is the one Quick Keys holds (no second copy to go stale).
    func testManualShortcutsAreTheQuickKeysRows() throws {
        let manual = try page("Manual.html")
        func html(_ s: String) -> String {
            s.unicodeScalars.map { $0.value > 127 ? "&#\($0.value);" : String($0) }.joined()
        }
        for id in ["quickKeys", "listen", "analyzeFile", "newSong", "hold", "sendDAW", "sendAllDAWs",
                   "sendAutoTune", "exportMidi", "advancedMode"] {
            let id = id == "quickKeys" ? QuickKeys.quickKeysID : id
            let chord = QuickKeys.tipDisplay(id)
            XCTAssertFalse(chord.isEmpty, id)
            XCTAssertTrue(manual.contains(html(chord)) || manual.contains(chord), "Manual does not show \(id) = \(chord)")
        }
    }

    /// Board Talk (docs/BOARD-TALK.md): none of the banned phrases in the Manual or What's New.
    func testPagesFollowBoardTalk() throws {
        let banned = ["please", "you can", "allows you to", "lets you", "simply", "easily", "in order to", "this will"]
        for name in ["Manual.html", "WhatsNew.html"] {
            let text = try page(name).lowercased()
            for b in banned { XCTAssertFalse(text.contains(b), "\(name) has \"\(b)\"") }
        }
    }

    /// The newest What's New section is the repo's VERSION (0.1.80, the next ship; VERSION is bumped by the release, not here).
    /// When a later version ships, add its section on top and change this line.
    func testWhatsNewHasTheCurrentVersion() throws {
        let text = try page("WhatsNew.html")
        let version = try String(contentsOf: app.deletingLastPathComponent().appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let first = try XCTUnwrap(text.range(of: "<h2>")).upperBound
        XCTAssertTrue(text[first...].hasPrefix("\(version)</h2>"), "the first What's New section is not \(version)")
    }

    /// Licenses.txt is generated from THIRD-PARTY-LICENSES.md + LICENSE: both are in it.
    func testLicensesAreGeneratedFromTheTwoSources() throws {
        let out = dir.appendingPathComponent("Licenses.txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [app.appendingPathComponent("tools/licenses.sh").path, out.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let text = try String(contentsOf: out, encoding: .utf8)
        let root = app.deletingLastPathComponent()
        let third = try String(contentsOf: root.appendingPathComponent("THIRD-PARTY-LICENSES.md"), encoding: .utf8)
        let own = try String(contentsOf: root.appendingPathComponent("LICENSE"), encoding: .utf8)
        XCTAssertTrue(text.contains(third), "THIRD-PARTY-LICENSES.md is not in Licenses.txt whole")
        XCTAssertTrue(text.contains(own), "LICENSE is not in Licenses.txt whole")
        XCTAssertTrue(text.contains("Source for Beat Key and its modifications"))
    }
}
