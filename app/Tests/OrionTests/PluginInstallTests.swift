import XCTest
@testable import Orion

/// Plan step 16: the plug-ins are choices inside the one installer, the uninstaller knows their paths, and an update
/// (Sparkle runs the same pkg) re-ticks exactly the plug-ins already installed. Nothing here touches the real
/// /Library: every path is a fixture tree in a temp folder.
@MainActor
final class PluginInstallTests: XCTestCase {
    /// One plug-in format as the installer lays it down (system-wide; app/uninstall/uninstall.manifest lists the same paths).
    struct Format: Equatable {
        let name: String
        let path: String
    }

    static let formats = [
        Format(name: "Audio Unit", path: "/Library/Audio/Plug-Ins/Components/Beat Key.component"),
        Format(name: "VST3", path: "/Library/Audio/Plug-Ins/VST3/Beat Key.vst3"),
        Format(name: "AAX", path: "/Library/Application Support/Avid/Audio/Plug-Ins/Beat Key.aaxplugin"),
        Format(name: "Audio Unit MIDI", path: "/Library/Audio/Plug-Ins/Components/Beat Key MIDI.component"),
        Format(name: "VST3 MIDI", path: "/Library/Audio/Plug-Ins/VST3/Beat Key MIDI.vst3"),
        Format(name: "AAX MIDI", path: "/Library/Application Support/Avid/Audio/Plug-Ins/Beat Key MIDI.aaxplugin"),
    ]

    private var root: URL!
    private let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()          // app/

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginInstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func installBundle(_ f: Format, version: String?, under r: URL? = nil) throws {
        let base = (r ?? root).path + f.path
        try FileManager.default.createDirectory(atPath: base + "/Contents", withIntermediateDirectories: true)
        let dict: NSDictionary = version.map { ["CFBundleShortVersionString": $0] } ?? [:]
        XCTAssertTrue(dict.write(toFile: base + "/Contents/Info.plist", atomically: true))
    }

    // MARK: the uninstall manifest knows the plug-ins

    private var manifestURL: URL { app.appendingPathComponent("uninstall/uninstall.manifest") }
    private var scriptURL: URL { app.appendingPathComponent("uninstall/uninstall.sh") }

    func testManifestListsEveryPlugInPathAndReceipt() throws {
        let m = try String(contentsOf: manifestURL, encoding: .utf8)
        for f in Self.formats { XCTAssertTrue(m.contains("system  \(f.path)"), "manifest lacks \(f.path)") }
        for id in ["au", "vst3", "aax"] { XCTAssertTrue(m.contains("receipt  com.jshriver.orion.plugin.\(id).pkg"), id) }
        XCTAssertTrue(m.contains("receipt  com.jshriver.orion.pkg"))
        XCTAssertTrue(m.contains("user    Library/Audio/Plug-Ins/Components/Beat Key.component"))
    }

    private func sh(_ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The REAL manifest and script on a fixture disk: the installed plug-ins go to the Trash, a neighbour stays.
    func testRealManifestMovesThePlugInsToTheTrashAndNothingElse() throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("Users/u")
        try fm.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        for f in Self.formats { try installBundle(f, version: "0.1.78") }
        let neighbour = root.appendingPathComponent("Library/Audio/Plug-Ins/Components/Other.component")
        try fm.createDirectory(at: neighbour, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Applications/Beat Key.app"), withIntermediateDirectories: true)

        let (rc, out) = try sh([scriptURL.path, "--manifest", manifestURL.path, "--home", home.path, "--user", NSUserName(),
                                "--root", root.path])
        XCTAssertEqual(rc, 0, out)
        XCTAssertTrue(out.contains("DONE"), out)
        for f in Self.formats {
            XCTAssertFalse(fm.fileExists(atPath: root.path + f.path), "\(f.name) is still installed")
            XCTAssertTrue(out.contains("move \(root.path)\(f.path)"), "\(f.name) was not moved: \(out)")
        }
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".Trash/Beat Key.component").path), "moved to the Trash, not deleted")
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".Trash/Beat Key.vst3").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".Trash/Beat Key.aaxplugin").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".Trash/Beat Key MIDI.vst3").path), "Beat Key MIDI goes too")
        XCTAssertTrue(fm.fileExists(atPath: neighbour.path), "another vendor's plug-in is never touched")
    }

    /// With plug-ins installed in a folder the user cannot write to, the uninstaller says it needs the password.
    func testPlugInsInASystemFolderAskForTheAdminPassword() throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("Users/u")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        for f in Self.formats { try installBundle(f, version: "0.1.78") }
        let folder = root.appendingPathComponent("Library/Audio/Plug-Ins/VST3")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let (rc, out) = try sh([scriptURL.path, "--needs-admin", "--manifest", manifestURL.path, "--home", home.path,
                                "--user", NSUserName(), "--root", root.path])
        XCTAssertEqual(rc, 0, out)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "yes", out)
    }

    // MARK: the installer description

    private func xml(_ name: String) throws -> XMLDocument {
        try XMLDocument(contentsOf: app.appendingPathComponent("pkg/\(name)"), options: [])
    }

    func testTheInstallerOffersAUVST3AndAAXAsChoicesInOneDownload() throws {
        let d = try xml("distribution.xml")
        let opts = try d.nodes(forXPath: "//options").first as? XMLElement
        XCTAssertEqual(opts?.attribute(forName: "customize")?.stringValue, "allow", "the Customize button shows the choices")
        func choice(_ id: String) throws -> XMLElement {
            try XCTUnwrap(d.nodes(forXPath: "//choice[@id='\(id)']").first as? XMLElement, id)
        }
        XCTAssertEqual(try choice("com.jshriver.orion.pkg").attribute(forName: "visible")?.stringValue, "false", "the app is not a choice")
        for fmt in ["au", "vst3", "aax"] {
            let c = try choice("com.jshriver.orion.plugin.\(fmt)")
            // an update ticks only what is already installed (distribution.xml JS; app/pkg/test.sh evaluates it)
            let start = try XCTUnwrap(c.attribute(forName: "start_selected")?.stringValue, fmt)
            XCTAssertTrue(start.hasPrefix("plugInStartsTicked('/Library/"), "\(fmt): \(start)")
            XCTAssertNotNil(c.attribute(forName: "title")?.stringValue)
            let ref = try XCTUnwrap(c.elements(forName: "pkg-ref").first?.attribute(forName: "id")?.stringValue)
            XCTAssertEqual(ref, "com.jshriver.orion.plugin.\(fmt).pkg")
            let file = try XCTUnwrap((d.nodes(forXPath: "//pkg-ref[@id='\(ref)'][@version]").first as? XMLElement)?.stringValue)
            XCTAssertEqual(file, "Beat-Key-\(fmt.uppercased()).pkg")
            XCTAssertEqual(try d.nodes(forXPath: "//line[@choice='com.jshriver.orion.plugin.\(fmt)']").count, 1, "in the outline")
        }
        // Beat Key MIDI (plan step 15): its three formats are choices too, each with its own component package
        for (fmt, file) in [("midi.au", "Beat-Key-AU-MIDI.pkg"), ("midi.vst3", "Beat-Key-VST3-MIDI.pkg"), ("midi.aax", "Beat-Key-AAX-MIDI.pkg")] {
            let c = try choice("com.jshriver.orion.plugin.\(fmt)")
            let ref = try XCTUnwrap(c.elements(forName: "pkg-ref").first?.attribute(forName: "id")?.stringValue)
            XCTAssertEqual(ref, "com.jshriver.orion.plugin.\(fmt).pkg")
            XCTAssertEqual((try d.nodes(forXPath: "//pkg-ref[@id='\(ref)'][@version]").first as? XMLElement)?.stringValue, file)
            XCTAssertEqual(try d.nodes(forXPath: "//line[@choice='com.jshriver.orion.plugin.\(fmt)']").count, 1, "in the outline")
        }
        XCTAssertEqual(try d.nodes(forXPath: "//pkg-ref[@id='com.jshriver.orion.pkg'][@version]").count, 1)
    }

    /// The AAX blocks are fenced by BEGIN / END comments so a build without AAX can drop them: balanced.
    func testTheAAXBlocksAreFencedAndBalanced() throws {
        for name in ["distribution.xml"] {
            let text = try String(contentsOf: app.appendingPathComponent("pkg/\(name)"), encoding: .utf8)
            let begins = text.components(separatedBy: "<!-- BEGIN AAX -->").count - 1
            let ends = text.components(separatedBy: "<!-- END AAX -->").count - 1
            XCTAssertEqual(begins, ends, name)
            XCTAssertGreaterThanOrEqual(begins, 3, name)
        }
    }

    // MARK: the build wires it

    func testBuildScriptPacksTheChoicesIntoTheOneInstaller() throws {
        let b = try String(contentsOf: app.appendingPathComponent("build.sh"), encoding: .utf8)
        for needle in ["plugin-pkgs.sh\" build", "plugin-pkgs.sh\" distribution", "plugin-pkgs.sh\" verify", "components/\"*.pkg"] {
            XCTAssertTrue(b.contains(needle), "build.sh does not call/ship: \(needle)")
        }
        // one installer: no second plug-ins-only package inside the app, no DMG
        XCTAssertFalse(b.contains("Beat-Key-Plug-ins.pkg"), "no second installer inside the app")
        XCTAssertFalse(b.contains("hdiutil"), "no DMG")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("pkg/plugins-distribution.xml").path))
    }

    /// Sparkle's enclosure is the bare signed pkg (the same file people download), typed as a package update.
    func testAppcastEnclosureIsTheBarePkg() throws {
        let b = try String(contentsOf: app.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(b.contains("<enclosure url=\"${DL_PREFIX}Beat-Key-$VER.pkg\" sparkle:installationType=\"package\""))
        XCTAssertTrue(b.contains("sign_update\" --ed-key-file \"$ED_FILE\" \"$PKG\""), "the EdDSA signature is of the pkg")
    }

    /// Sparkle relaunches Beat Key after its install; the postinstall opens it only for a hand-run download.
    func testPostinstallLeavesTheLaunchToSparkleDuringAnUpdate() throws {
        let t = try String(contentsOf: app.appendingPathComponent("pkg/postinstall"), encoding: .utf8)
        XCTAssertTrue(t.contains("Autoupdate com\\.jshriver\\.orion "), "detects Sparkle's helper by its arguments")
        let guardAt = try XCTUnwrap(t.range(of: "Autoupdate com"))
        let openAt = try XCTUnwrap(t.range(of: "/usr/bin/open \"$APP\""))
        XCTAssertLessThan(guardAt.lowerBound, openAt.lowerBound, "the Sparkle check comes before the launch")
    }

    func testPostinstallsLogToTheUsersInstallLogAndNeverToTmp() throws {
        for name in ["postinstall", "plugin-postinstall"] {
            let t = try String(contentsOf: app.appendingPathComponent("pkg/\(name)"), encoding: .utf8)
            XCTAssertTrue(t.contains("Library/Logs/Beat Key"), name)
            XCTAssertTrue(t.contains("install.log"), name)
            let code = t.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
            XCTAssertFalse(code.contains("/tmp"), "\(name) must not use /tmp")
            XCTAssertTrue(t.contains("sudo -u \"$CU\""), "\(name) writes the log as the user, never as root")
            XCTAssertTrue(t.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exit 0"), "\(name) never fails the install")
        }
    }
}
