import AppKit
import SwiftUI
import XCTest
@testable import Orion

/// Beat Key's side of the house kit retrofit (2026-11-19): the glue between the pasted modules (Glow, Quick Keys,
/// Report, Uninstall) and Beat Key's own Accent / AppLog / Palette / menus. The kit's own tests (GlowTests,
/// QuickKeysTests, ReportTests, UninstallTests, ConfigTests) are pasted beside this file.
final class HouseRetrofitTests: XCTestCase {
    /// app/ (the package folder), found from this file.
    private var appDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func sources(_ sub: String = "Sources/Orion") -> [(String, String)] {
        let root = appDir.appendingPathComponent(sub)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "swift" }.compactMap { u in
            (try? String(contentsOf: u, encoding: .utf8)).map { (u.path.replacingOccurrences(of: root.path + "/", with: ""), $0) }
        }
    }

    // MARK: config

    func testTheConfigNamesBeatKey() {
        XCTAssertEqual(House.appName, Brand.name)
        XCTAssertEqual(House.bundleID, "com.jshriver.orion")
        XCTAssertEqual(House.reportTo, "contact@fourletterrecords.com", "Beat Key is a public app: 22 downloads, outside emails")
        XCTAssertEqual(AppLog.dir.lastPathComponent, House.logFolder)
        XCTAssertEqual(House.logDirEnv, "ORION_LOG_DIR")
    }

    func testBundleIDMatchesInfoPlist() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: appDir.appendingPathComponent("Info.plist")))
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, House.bundleID)
    }

    // MARK: logging (Beat Key's own AppLog kept; the kit's calls land in the same file and the same sink)

    func testTheKitsLogCallsLandInBeatKeysLog() {
        var lines: [String] = []
        AppLog.sink = { lines.append($0) }
        defer { AppLog.sink = nil }
        AppLog.shared.info("report", "composed to x")
        AppLog.shared.error("uninstall", "script ended rc=1")
        AppLog.shared.log(.warn, "quickkeys", "a row twice")
        AppLog.log("plain Beat Key line")
        XCTAssertEqual(lines.prefix(3), ["[report] composed to x", "[uninstall] ERROR: script ended rc=1", "[quickkeys] WARN: a row twice"])
        XCTAssertTrue(lines.last?.hasSuffix("plain Beat Key line") == true)
    }

    func testReportAttachesBeatKeysLogFiles() {
        // the files that exist, live first; the test run never writes the user's log, so nothing is attached here
        for u in AppLog.shared.logFiles() { XCTAssertTrue(FileManager.default.fileExists(atPath: u.path)) }
        XCTAssertEqual(AppLog.shared.logFiles().first.map { $0 == AppLog.url } ?? true, true, "the live log leads")
    }

    // MARK: glow: the module draws every halo; High Contrast draws none

    /// One bright dot on black, with and without the house glow, rendered at 4x: High Contrast must match "no glow
    /// at all" byte for byte, and the glow must really draw something (so the check can fail).
    @available(macOS 13.0, *)
    @MainActor
    func render(_ glow: Bool, highContrast: Bool = false, active: Bool = true) throws -> [UInt8] {
        let palette = Palette(accent: .amber, highContrast: highContrast)
        let dot = Circle().fill(palette.amber).frame(width: 10, height: 10)
        let content = ZStack {
            Color.black
            if glow { dot.paletteGlow(HouseGlow.Full.litButton, palette, active: active) } else { dot }
        }.frame(width: 40, height: 40)
        let r = ImageRenderer(content: content)
        r.scale = 4
        let cg = try XCTUnwrap(r.cgImage)
        let rep = NSBitmapImageRep(cgImage: cg)
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    @MainActor
    func testHighContrastDrawsNoHalo() throws {
        guard #available(macOS 13.0, *) else { throw XCTSkip("ImageRenderer is macOS 13+") }
        let none = try render(false)
        XCTAssertEqual(try render(true, highContrast: true), none, "High Contrast: no halo")
        XCTAssertEqual(try render(true, active: false), none, "not active: no halo")
        XCTAssertNotEqual(try render(true), none, "the glow draws something when lit")
    }

    func testNoFullStrengthShadowIsLeftInTheFaceplate() throws {
        // the glow strength is HouseGlow's two constants; a view that draws its own amber `.shadow` would bypass them
        for (path, text) in sources() where !path.hasPrefix("House/") {
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                guard l.contains(".shadow(color:"), !l.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                XCTAssertFalse(l.contains("amber") || l.contains("palette.accent") || l.contains("lamp.color"),
                               "\(path):\(i + 1) draws its own glow: use paletteGlow / accentGlow (the glow module)")
            }
        }
    }

    // MARK: quick keys: one table, no literal chords

    func testEveryShortcutIsARow() throws {
        // chords typed in a menu item or a key handler are a second copy: only the locked macOS ones may stay
        let allowed: Set<String> = [
            "OrionApp.swift: Button(Brand.hide) { NSApp.hide(nil) }.keyboardShortcut(\"h\")",
            "OrionApp.swift: Button(\"Hide Others\") { NSApp.hideOtherApplications(nil) }.keyboardShortcut(\"h\", modifiers: [.command, .option])",
            "OrionApp.swift: Button(Brand.quit) { NSApp.terminate(nil) }.keyboardShortcut(\"q\")",
            "OrionApp.swift: .keyboardShortcut(\"?\", modifiers: .command)",
        ]
        var found: Set<String> = []
        for (path, text) in sources() where !path.hasPrefix("House/") {
            for line in text.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard l.contains(".keyboardShortcut("), !l.hasPrefix("//"), !l.hasPrefix("///") else { continue }
                if l.contains(".defaultAction") || l.contains(".cancelAction") { continue }
                found.insert("\((path as NSString).lastPathComponent): \(l)")
            }
        }
        XCTAssertEqual(found.subtracting(allowed), [], "a literal shortcut: make it a row in QuickKeyTable.swift and use .quickKey(id)")
    }

    func testTheTableHasEveryShortcutBeatKeyHad() {
        let ids = Set(QuickKeys.appRows.map(\.id))
        for id in ["listen", "analyzeFile", "newSong", "hold", "analyzeSelection",      // Hotkeys.swift
                   "sendAutoTune", "sendDAW", "sendAllDAWs", "exportMidi", "advancedMode",    // the menus
                   "playSendAutoTune", "help"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        // the defaults Beat Key shipped, unchanged
        let d = Dictionary(uniqueKeysWithValues: QuickKeys.appRows.map { ($0.id, $0.chord.display) })
        XCTAssertEqual(d["listen"], "⌃⌥⌘K"); XCTAssertEqual(d["analyzeFile"], "⌃⌥⌘F")
        XCTAssertEqual(d["newSong"], "⌃⌥⌘R"); XCTAssertEqual(d["hold"], "⌃⌥⌘H")
        XCTAssertEqual(d["sendAutoTune"], "⌃⌥⌘A"); XCTAssertEqual(d["sendDAW"], "⌃⌥⌘S")
        XCTAssertEqual(d["sendAllDAWs"], "⌃⌥⌘D"); XCTAssertEqual(d["exportMidi"], "⌃⌥⌘E")
        XCTAssertEqual(d["advancedMode"], "⌥⌘A"); XCTAssertEqual(d["playSendAutoTune"], "⇧⌘A")
        XCTAssertEqual(d["analyzeSelection"], QuickKeys.unassigned)
    }

    func testQuickKeysOpensWithShiftControlK() {
        let row = QuickKeys.standardRows.first { $0.id == QuickKeys.quickKeysID }
        XCTAssertEqual(row?.chord.display, "⌃⇧K")
        XCTAssertEqual(row?.chord.mods, [.control, .shift])
    }

    func testTipsReadTheirChordFromTheRow() {
        XCTAssertEqual(AutoTuneSend.shortcutDisplay, "⌃⌥⌘A")
        XCTAssertTrue(HelpText.keysAdvanced.body.contains("⌥⌘A"), HelpText.keysAdvanced.body)
        XCTAssertEqual(QuickKeys.tipDisplay("nope"), "no shortcut")
    }

    // MARK: report

    func testTheReportDoorsExist() throws {
        let app = try String(contentsOf: appDir.appendingPathComponent("Sources/Orion/OrionApp.swift"), encoding: .utf8)
        for need in [".quickKeysSheet()", ".reportSheet(", ".uninstallSheet(", "QuickKeysCommands()", "UninstallCommands()", "ReportCommands()"] {
            XCTAssertTrue(app.contains(need), need)
        }
        let face = try String(contentsOf: appDir.appendingPathComponent("Sources/Orion/Face/FaceplateFace.swift"), encoding: .utf8)
        XCTAssertTrue(face.contains("FooterChip(title: \"REPORT\""), "the window has a Report button")
        XCTAssertTrue(HelpText.all.contains(HelpText.report))
    }

    // MARK: uninstall: the manifest names everything Beat Key puts on a Mac

    private var manifest: [(kind: String, value: String)] {
        let text = (try? String(contentsOf: appDir.appendingPathComponent("uninstall/uninstall.manifest"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { l in
                let kind = String(l.prefix { !$0.isWhitespace })
                return (kind, l.dropFirst(kind.count).trimmingCharacters(in: .whitespaces))
            }
    }

    func testTheManifestCoversWhatBeatKeyWrites() {
        let m = manifest
        func has(_ kind: String, _ value: String) -> Bool { m.contains { $0.kind == kind && $0.value == value } }
        XCTAssertTrue(has("name", House.appName))
        XCTAssertTrue(has("app", "/Applications/\(House.appName).app"))
        XCTAssertTrue(has("receipt", "\(House.bundleID).pkg"), "build.sh: pkgbuild --identifier \"$BUNDLE_ID.pkg\"")
        // the login item (LoginItem.swift writes it on macOS 12)
        XCTAssertTrue(has("user", "Library/LaunchAgents/\(LaunchAgentLoginItem.label).plist"))
        // Application Support: the runtime's seeded yt-dlp copy always goes, the rest (sign-in, DAW hand-offs) is settings
        let support = Runtime.appDefault().support.lastPathComponent
        XCTAssertTrue(has("user", "Library/Application Support/\(support)/bin"), "Runtime.supportBin")
        XCTAssertTrue(has("user", "Library/Application Support/\(support)/\(Runtime.appDefault().stamp.lastPathComponent)"))
        XCTAssertTrue(has("data", "Library/Application Support/\(support)"))
        XCTAssertTrue(has("data", "Library/Application Support/Beat Key"), "DAWFiles.support")
        XCTAssertTrue(has("data", "Library/Preferences/\(House.bundleID).plist"))
        // logs and the usual caches
        XCTAssertTrue(has("user", "Library/Logs/\(AppLog.dir.lastPathComponent)"))
        for c in ["Caches", "HTTPStorages", "WebKit"] { XCTAssertTrue(has("user", "Library/\(c)/\(House.bundleID)"), c) }
        XCTAssertTrue(has("user", "Library/Saved Application State/\(House.bundleID).savedState"))
        XCTAssertFalse(m.contains { $0.value.contains("APP_NAME") || $0.value.contains("BUNDLE_ID") })
    }

    func testTheManifestParsesAndTheBundledScriptRuns() throws {
        // a fixture home and root: the script reads this manifest, moves nothing on a dry run
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bk-uninstall-\(UUID().uuidString)")
        let (home, root) = (tmp.appendingPathComponent("home"), tmp.appendingPathComponent("root"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = appDir.appendingPathComponent("uninstall/uninstall.sh")
        let args = ["--manifest", appDir.appendingPathComponent("uninstall/uninstall.manifest").path,
                    "--home", home.path, "--root", root.path]
        let (rc, out) = HouseUninstall.runPlain(script: script, args: args + ["--dry-run"])
        XCTAssertEqual(rc, 0, out)
        XCTAssertTrue(out.hasSuffix("DONE\n"), out)
        // the .pkg's receipt makes a real run ask for the password (the app asks the script first)
        XCTAssertEqual(HouseUninstall.needsAdmin(script: script, args: args).0, false, "fixture root: no receipt is run")
    }

    func testBuildShBundlesTheUninstaller() throws {
        let b = try String(contentsOf: appDir.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(b.contains("uninstall.sh uninstall.manifest"))
        XCTAssertTrue(b.contains("Contents/Resources/$f"))
        for f in ["uninstall.sh", "uninstall.manifest"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: appDir.appendingPathComponent("uninstall/\(f)").path), f)
        }
    }
}
