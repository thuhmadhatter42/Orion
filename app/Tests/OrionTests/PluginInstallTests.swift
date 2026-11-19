import XCTest
@testable import Orion

/// Plan step 16: the plug-ins are choices inside the one installer, the uninstaller knows their paths, and the
/// app offers "Update Plug-ins…" when what is installed is older than the app. Nothing here touches the real
/// /Library: every path is a fixture tree in a temp folder.
@MainActor
final class PluginInstallTests: XCTestCase {
    private var root: URL!
    private var lines: [String] = []
    private let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()          // app/
    private var realOpener: ((URL) -> Bool)!
    private var realAsker: ((String) -> Bool)!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginInstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lines = []
        AppLog.sink = { [weak self] l in self?.lines.append(l) }
        realOpener = PluginUpdate.opener
        realAsker = PluginUpdate.asker
    }

    override func tearDown() {
        PluginUpdate.opener = realOpener
        PluginUpdate.asker = realAsker
        AppLog.sink = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func installBundle(_ f: PluginUpdate.Format, version: String?, under r: URL? = nil) throws {
        let base = (r ?? root).path + f.path
        try FileManager.default.createDirectory(atPath: base + "/Contents", withIntermediateDirectories: true)
        let dict: NSDictionary = version.map { ["CFBundleShortVersionString": $0] } ?? [:]
        XCTAssertTrue(dict.write(toFile: base + "/Contents/Info.plist", atomically: true))
    }

    private func fakeApp(withPackage: Bool) throws -> Bundle {
        let d = root.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.example.fake", "CFBundleShortVersionString": "0.1.78"]
        XCTAssertTrue(info.write(toFile: d.path + "/Contents/Info.plist", atomically: true))
        if withPackage { try "pkg".write(to: d.appendingPathComponent("Contents/Resources/\(PluginUpdate.packageName)"), atomically: true, encoding: .utf8) }
        return try XCTUnwrap(Bundle(url: d))
    }

    // MARK: versions

    func testVersionsCompareAsNumbersNotText() {
        XCTAssertTrue(PluginUpdate.isOlder("0.1.9", than: "0.1.10"))
        XCTAssertTrue(PluginUpdate.isOlder("0.1.77", than: "0.1.78"))
        XCTAssertTrue(PluginUpdate.isOlder("0.9.99", than: "1.0.0"))
        XCTAssertTrue(PluginUpdate.isOlder("0.1", than: "0.1.1"))
        XCTAssertFalse(PluginUpdate.isOlder("0.1.78", than: "0.1.78"))
        XCTAssertFalse(PluginUpdate.isOlder("0.2.0", than: "0.1.99"))
    }

    func testNothingInstalledIsNotAnUpdate() {
        XCTAssertEqual(PluginUpdate.status(appVersion: "0.1.78", root: root.path), .notInstalled)
    }

    func testStatusNamesWhatIsOlder() throws {
        let au = PluginUpdate.formats[0], v3 = PluginUpdate.formats[1], aax = PluginUpdate.formats[2]
        try installBundle(au, version: "0.1.77")
        try installBundle(v3, version: "0.1.78")
        guard case .older(let old) = PluginUpdate.status(appVersion: "0.1.78", root: root.path) else { return XCTFail("want older") }
        XCTAssertEqual(old.map(\.format.name), ["Audio Unit"])
        try installBundle(au, version: "0.1.78")
        guard case .current(let all) = PluginUpdate.status(appVersion: "0.1.78", root: root.path) else { return XCTFail("want current") }
        XCTAssertEqual(all.map(\.format.name), ["Audio Unit", "VST3"])
        // a bundle whose Info.plist has no version is damaged: it counts as old
        try installBundle(aax, version: nil)
        guard case .older(let old2) = PluginUpdate.status(appVersion: "0.1.78", root: root.path) else { return XCTFail("want older") }
        XCTAssertEqual(old2.map(\.format.name), ["AAX"])
        XCTAssertEqual(PluginUpdate.summary(old2), "AAX unreadable")
    }

    // MARK: the offer

    private func model(_ b: Bundle, defaults: UserDefaults, version: String = "0.1.78") -> PluginUpdateModel {
        PluginUpdateModel(appVersion: { version }, root: root.path, bundle: b, defaults: defaults)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "PluginInstallTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testOlderPlugInsAreAskedOncePerAppVersionAndYesOpensInstaller() throws {
        try installBundle(PluginUpdate.formats[0], version: "0.1.77")
        let b = try fakeApp(withPackage: true), d = freshDefaults()
        var asked: [String] = [], opened: [URL] = []
        PluginUpdate.asker = { asked.append($0); return true }
        PluginUpdate.opener = { opened.append($0); return true }
        let m = model(b, defaults: d)
        m.checkAtLaunch()
        XCTAssertTrue(m.needsUpdate)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].contains("Audio Unit 0.1.77"), asked[0])
        XCTAssertEqual(opened.map(\.lastPathComponent), [PluginUpdate.packageName])
        XCTAssertTrue(lines.contains { $0.contains("[plugins]") && $0.contains("older than Beat Key 0.1.78") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("asked to update: yes") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("opened \(PluginUpdate.packageName) in Installer") }, "\(lines)")
        // the second launch of the same version does not ask again; the menu item stays
        m.checkAtLaunch()
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(m.needsUpdate)
        // a newer app asks again
        let m2 = model(b, defaults: d, version: "0.1.79")
        m2.checkAtLaunch()
        XCTAssertEqual(asked.count, 2)
    }

    func testLaterLeavesTheMenuItemAndOpensNothing() throws {
        try installBundle(PluginUpdate.formats[1], version: "0.1.70")
        var opened = 0
        PluginUpdate.asker = { _ in false }
        PluginUpdate.opener = { _ in opened += 1; return true }
        let m = model(try fakeApp(withPackage: true), defaults: freshDefaults())
        m.checkAtLaunch()
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(m.needsUpdate, "the menu item is still there")
        XCTAssertTrue(lines.contains { $0.contains("asked to update: later") }, "\(lines)")
    }

    func testNoPlugInsOrCurrentOnesNeverAsk() throws {
        PluginUpdate.asker = { _ in XCTFail("nothing to ask"); return false }
        let b = try fakeApp(withPackage: true)
        let m = model(b, defaults: freshDefaults())
        m.checkAtLaunch()
        XCTAssertFalse(m.needsUpdate)
        XCTAssertTrue(lines.contains { $0.contains("no Beat Key plug-in installed") }, "\(lines)")
        try installBundle(PluginUpdate.formats[0], version: "0.1.78")
        m.checkAtLaunch()
        XCTAssertFalse(m.needsUpdate)
        XCTAssertTrue(lines.contains { $0.contains("up to date") }, "\(lines)")
    }

    func testAnAppWithoutThePackageNeverAsksAndSaysSoWhenOpened() throws {
        try installBundle(PluginUpdate.formats[0], version: "0.1.77")
        PluginUpdate.asker = { _ in XCTFail("no package, no question"); return false }
        let m = model(try fakeApp(withPackage: false), defaults: freshDefaults())
        m.checkAtLaunch()
        XCTAssertFalse(m.openInstaller())
        XCTAssertTrue(lines.contains { $0.contains("ERROR") && $0.contains("is not in this copy of Beat Key") }, "\(lines)")
    }

    func testInstallerThatWillNotOpenIsLogged() throws {
        try installBundle(PluginUpdate.formats[0], version: "0.1.77")
        PluginUpdate.opener = { _ in false }
        let m = model(try fakeApp(withPackage: true), defaults: freshDefaults())
        XCTAssertFalse(m.openInstaller())
        XCTAssertTrue(lines.contains { $0.contains("ERROR") && $0.contains("Installer would not open") }, "\(lines)")
    }

    // MARK: the uninstall manifest knows the plug-ins

    private var manifestURL: URL { app.appendingPathComponent("uninstall/uninstall.manifest") }
    private var scriptURL: URL { app.appendingPathComponent("uninstall/uninstall.sh") }

    func testManifestListsEveryPlugInPathAndReceipt() throws {
        let m = try String(contentsOf: manifestURL, encoding: .utf8)
        for f in PluginUpdate.formats { XCTAssertTrue(m.contains("system  \(f.path)"), "manifest lacks \(f.path)") }
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
        for f in PluginUpdate.formats { try installBundle(f, version: "0.1.78") }
        let neighbour = root.appendingPathComponent("Library/Audio/Plug-Ins/Components/Other.component")
        try fm.createDirectory(at: neighbour, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Applications/Beat Key.app"), withIntermediateDirectories: true)

        let (rc, out) = try sh([scriptURL.path, "--manifest", manifestURL.path, "--home", home.path, "--user", NSUserName(),
                                "--root", root.path])
        XCTAssertEqual(rc, 0, out)
        XCTAssertTrue(out.contains("DONE"), out)
        for f in PluginUpdate.formats {
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
        for f in PluginUpdate.formats { try installBundle(f, version: "0.1.78") }
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
            XCTAssertEqual(c.attribute(forName: "start_selected")?.stringValue, "true", fmt)
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

    /// The AAX blocks are fenced by BEGIN / END comments so a build without AAX can drop them: balanced, in both files.
    func testTheAAXBlocksAreFencedAndBalanced() throws {
        for name in ["distribution.xml", "plugins-distribution.xml"] {
            let text = try String(contentsOf: app.appendingPathComponent("pkg/\(name)"), encoding: .utf8)
            let begins = text.components(separatedBy: "<!-- BEGIN AAX -->").count - 1
            let ends = text.components(separatedBy: "<!-- END AAX -->").count - 1
            XCTAssertEqual(begins, ends, name)
            XCTAssertGreaterThanOrEqual(begins, 3, name)
        }
    }

    // MARK: the build wires it

    func testBuildScriptPacksTheChoicesAndTheUpdatePackage() throws {
        let b = try String(contentsOf: app.appendingPathComponent("build.sh"), encoding: .utf8)
        for needle in ["plugin-pkgs.sh\" build", "plugin-pkgs.sh\" distribution", "plugin-pkgs.sh\" verify",
                       "Beat-Key-Plug-ins.pkg", "components/\"*.pkg"] {
            XCTAssertTrue(b.contains(needle), "build.sh does not call/ship: \(needle)")
        }
        // the plug-in packages are built BEFORE the app is assembled (the app's seal covers the package it carries)
        let packed = try XCTUnwrap(b.range(of: "plugin-pkgs.sh\" build"))
        let assembled = try XCTUnwrap(b.range(of: "echo \"== assemble"))
        XCTAssertLessThan(packed.lowerBound, assembled.lowerBound)
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
