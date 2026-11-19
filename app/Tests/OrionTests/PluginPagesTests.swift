import XCTest
@testable import Orion

/// Plan step 17: the Manual, What's New and Licenses pages say what the plug-in is and how it is installed,
/// in the plug-in's own words (the legends printed on its face) and with the paths the installer really uses.
final class PluginPagesTests: XCTestCase {
    private let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()          // app/
    private var repo: URL { app.deletingLastPathComponent() }

    private func page(_ name: String) throws -> String {
        try String(contentsOf: app.appendingPathComponent("pages/\(name)"), encoding: .utf8)
    }

    /// The plain text of an HTML page: tags and entities the pages use, flattened.
    private func plain(_ html: String) -> String {
        var t = html
        for (e, c) in [("&rsaquo;", "›"), ("&hellip;", "…"), ("&middot;", "·"), ("&divide;", "÷"), ("&times;", "×"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: e, with: c)
        }
        return t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    func testTheManualNamesTheTwoButtonsAsThePlugInPrintsThem() throws {
        let face = try String(contentsOf: repo.appendingPathComponent("plugin/ui/FaceView.swift"), encoding: .utf8)
        let manual = plain(try page("Manual.html"))
        for legend in ["SEND BPM", "SEND AUTO-TUNE", "MORE", "REPORT"] {
            XCTAssertTrue(face.contains("\"\(legend)\""), "the face no longer prints \(legend): change the Manual")
            XCTAssertTrue(manual.contains(legend), "the Manual does not name \(legend)")
        }
    }

    func testTheManualPlacesEachPieceInJsWords() throws {
        let manual = plain(try page("Manual.html"))
        XCTAssertTrue(manual.contains("Drop it in the Beat Key window"), "a file goes in the app window")
        XCTAssertTrue(manual.contains("Listen, from the menu bar"), "playing on YouTube: the menu bar")
        XCTAssertTrue(manual.contains("Put the plug-in on the track"), "a file in the session: the plug-in on its track")
        XCTAssertTrue(manual.contains("Needs the Beat Key app"), "SEND BPM needs the app")
        XCTAssertTrue(manual.contains("No app needed"), "SEND AUTO-TUNE does not")
    }

    func testTheManualPrintsTheFoldersTheInstallerUses() throws {
        let manual = plain(try page("Manual.html"))
        for f in PluginUpdate.formats {
            let folder = (f.path as NSString).deletingLastPathComponent
            XCTAssertTrue(manual.contains(folder), "the Manual does not print \(folder)")
        }
        XCTAssertTrue(manual.contains(Brand.updatePlugins), "the menu item's name is \(Brand.updatePlugins)")
        XCTAssertTrue(manual.contains("Customize"), "the installer's Customize button")
        XCTAssertTrue(manual.contains("install.log") && manual.contains("plugin.log"))
        XCTAssertTrue(manual.contains("sh \"/Applications/Beat Key.app/Contents/Resources/uninstall.sh\""), "the Terminal form of Uninstall")
    }

    func testWhatsNewSaysWhatShipsWithThePlugIn() throws {
        let text = plain(try page("WhatsNew.html"))
        for needle in ["SEND BPM", "SEND AUTO-TUNE", "One download", Brand.updatePlugins, "install.log", "the plug-ins too"] {
            XCTAssertTrue(text.contains(needle), "What's New lacks \"\(needle)\"")
        }
        // all of it is inside the 0.1.78 section, the one that ships next
        let section = try XCTUnwrap(text.components(separatedBy: "0.1.78").dropFirst().first)
        XCTAssertTrue(section.contains("SEND AUTO-TUNE"))
    }

    /// Board Talk's length rule for the words the plug-in adds: one short line per row, no banned phrase (the banned list
    /// itself is checked for every page by HelpPagesTests).
    func testManualPlugInRowsAreShort() throws {
        let html = try page("Manual.html")
        let start = try XCTUnwrap(html.range(of: "<h2>Plug-in</h2>"))
        let end = try XCTUnwrap(html.range(of: "</dl>", range: start.upperBound..<html.endIndex))
        for row in html[start.upperBound..<end.lowerBound].components(separatedBy: "<dd>").dropFirst() {
            let words = plain(row.components(separatedBy: "</dd>")[0]).split(separator: " ").count
            XCTAssertLessThanOrEqual(words, 24, "too long for a manual row: \(row.prefix(60))")
        }
    }

    // MARK: Licenses

    func testLicensesCarryEveryVendoredLicenceTextForThePlugIns() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("PluginPagesTests-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [app.appendingPathComponent("tools/licenses.sh").path, out.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(text.contains("PART 3: LICENCE TEXTS OF THE CODE BUILT INTO THE PLUG-INS"))
        let part3 = try XCTUnwrap(text.components(separatedBy: "PART 3: LICENCE TEXTS").last)
        // every licence file of the vendored code is in Part 3, whole
        let fm = FileManager.default
        var found = 0
        for sub in ["plugin/vendor", "core/vendor"] {
            let dir = repo.appendingPathComponent(sub)
            for d in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                for f in (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(d).path)) ?? []
                where f.hasPrefix("LICENSE") || f.hasPrefix("COPYING") {
                    let body = try String(contentsOf: dir.appendingPathComponent("\(d)/\(f)"), encoding: .utf8)
                    XCTAssertTrue(part3.contains(body), "\(sub)/\(d)/\(f) is not in Part 3 whole")
                    found += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(found, 3, "AudioUnitSDK, the VST3 interfaces and libsamplerate at least")
    }

    func testThirdPartyListNamesAllThreePlugInSdks() throws {
        let third = try String(contentsOf: repo.appendingPathComponent("THIRD-PARTY-LICENSES.md"), encoding: .utf8)
        for needle in ["VST3 plug-in interfaces", "AudioUnitSDK", "AAX SDK", "GPL-3.0 (the SDK's open-source option", "libsamplerate",
                       "never compiled in"] {
            XCTAssertTrue(third.contains(needle), "THIRD-PARTY-LICENSES.md lacks \"\(needle)\"")
        }
    }
}
