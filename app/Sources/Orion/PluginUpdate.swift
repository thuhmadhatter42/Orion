import AppKit
import SwiftUI

// UPDATE PLUG-INS (plan step 16). Plug-ins reach a Mac through the Beat Key installer (a choice inside the one
// download) and are updated the same way the app is: Sparkle brings the new Beat Key, and the new Beat Key
// carries the new plug-ins as Contents/Resources/Beat-Key-Plug-ins.pkg (built by app/pkg/plugin-pkgs.sh before
// the app is sealed). At launch Beat Key reads the version of each installed plug-in bundle. If any is older
// than the app it says so once per app version and adds Beat Key menu > Update Plug-ins…, which opens that
// package in Installer (one administrator password, the installer's own receipts and install.log).
// A Mac with no Beat Key plug-in installed never sees any of this. Every step is a line in beatkey.log ([plugins]).

enum PluginUpdate {
    /// One plug-in format as the installer lays it down (system-wide; app/uninstall/uninstall.manifest lists the same paths).
    struct Format: Equatable {
        let name: String
        let path: String
    }

    static let formats = [
        Format(name: "Audio Unit", path: "/Library/Audio/Plug-Ins/Components/Beat Key.component"),
        Format(name: "VST3", path: "/Library/Audio/Plug-Ins/VST3/Beat Key.vst3"),
        Format(name: "AAX", path: "/Library/Application Support/Avid/Audio/Plug-Ins/Beat Key.aaxplugin"),
        // Beat Key MIDI (plan step 15): the same installer and version, its own bundles
        Format(name: "Audio Unit MIDI", path: "/Library/Audio/Plug-Ins/Components/Beat Key MIDI.component"),
        Format(name: "VST3 MIDI", path: "/Library/Audio/Plug-Ins/VST3/Beat Key MIDI.vst3"),
        Format(name: "AAX MIDI", path: "/Library/Application Support/Avid/Audio/Plug-Ins/Beat Key MIDI.aaxplugin"),
    ]

    /// The package the app carries (Contents/Resources); nil in `swift run` and tests.
    static let packageName = "Beat-Key-Plug-ins.pkg"

    struct Installed: Equatable {
        let format: Format
        /// CFBundleShortVersionString of the installed bundle; nil = unreadable (a damaged bundle counts as old).
        let version: String?
    }

    enum Status: Equatable {
        case notInstalled
        case current([Installed])
        /// The installed plug-ins older than the app, by format name.
        case older([Installed])
    }

    /// The plug-ins on this Mac. `root` is "" for the real disk; a test points it at a fixture tree.
    static func installed(root: String = "", formats: [Format] = PluginUpdate.formats) -> [Installed] {
        formats.compactMap { f in
            let path = root + f.path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
            return Installed(format: f, version: plist?["CFBundleShortVersionString"] as? String)
        }
    }

    /// Dotted-number compare ("0.1.9" < "0.1.10"); a part that is not a number counts as 0.
    static func isOlder(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q }
        }
        return false
    }

    static func status(appVersion: String, root: String = "", formats: [Format] = PluginUpdate.formats) -> Status {
        let all = installed(root: root, formats: formats)
        if all.isEmpty { return .notInstalled }
        let old = all.filter { $0.version.map { isOlder($0, than: appVersion) } ?? true }
        return old.isEmpty ? .current(all) : .older(old)
    }

    static func packageURL(in bundle: Bundle = .main) -> URL? {
        let u = bundle.bundleURL.appendingPathComponent("Contents/Resources/\(packageName)")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func summary(_ list: [Installed]) -> String {
        list.map { "\($0.format.name) \($0.version ?? "unreadable")" }.joined(separator: ", ")
    }

    /// THE SEAM: open the package in Installer (a test swaps it; nothing opens).
    @MainActor static var opener: (URL) -> Bool = { pkg in
        guard let installer = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.installer") else { return false }
        NSWorkspace.shared.open([pkg], withApplicationAt: installer, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
    /// THE SEAM: the once-per-version question. Returns true for "Update Plug-ins…".
    @MainActor static var asker: (String) -> Bool = { text in
        let a = NSAlert()
        a.messageText = "Plug-ins are out of date"
        a.informativeText = text
        a.addButton(withTitle: "Update Plug-ins…")
        a.addButton(withTitle: "Later")
        return a.runModal() == .alertFirstButtonReturn
    }
}

/// What the Beat Key menu and the launch check read. One per app.
@MainActor
final class PluginUpdateModel: ObservableObject {
    static let shared = PluginUpdateModel()
    /// Plug-ins older than this app; empty = nothing to offer (none installed, or all current).
    @Published private(set) var older: [PluginUpdate.Installed] = []
    var needsUpdate: Bool { !older.isEmpty }
    static let askedKey = "pluginUpdateAskedFor"

    private let appVersion: () -> String
    private let root: String
    private let bundle: Bundle
    private let defaults: UserDefaults

    init(appVersion: @escaping () -> String = { House.version }, root: String = "", bundle: Bundle = .main,
         defaults: UserDefaults = .standard) {
        self.appVersion = appVersion; self.root = root; self.bundle = bundle; self.defaults = defaults
    }

    /// Read the disk. Logs what it found, every time it runs.
    func refresh() {
        let v = appVersion()
        switch PluginUpdate.status(appVersion: v, root: root) {
        case .notInstalled:
            older = []
            AppLog.shared.info("plugins", "no Beat Key plug-in installed in the system folders")
        case .current(let all):
            older = []
            AppLog.shared.info("plugins", "installed: \(PluginUpdate.summary(all)); Beat Key \(v): up to date")
        case .older(let old):
            older = old
            AppLog.shared.info("plugins", "installed plug-ins older than Beat Key \(v): \(PluginUpdate.summary(old))")
        }
    }

    /// Beat Key menu > Update Plug-ins…, and the "Update" answer of the launch question.
    @discardableResult
    func openInstaller() -> Bool {
        guard let pkg = PluginUpdate.packageURL(in: bundle) else {
            AppLog.shared.error("plugins", "\(PluginUpdate.packageName) is not in this copy of Beat Key")
            return false
        }
        let ok = PluginUpdate.opener(pkg)
        if ok { AppLog.shared.info("plugins", "opened \(pkg.lastPathComponent) in Installer") }
        else { AppLog.shared.error("plugins", "Installer would not open \(pkg.path)") }
        return ok
    }

    /// Launch: read the disk; when plug-ins are older, ask ONCE per app version. "Later" leaves the menu item.
    func checkAtLaunch() {
        refresh()
        guard needsUpdate, PluginUpdate.packageURL(in: bundle) != nil else { return }
        let v = appVersion()
        guard defaults.string(forKey: Self.askedKey) != v else { return }
        defaults.set(v, forKey: Self.askedKey)
        let text = "Beat Key \(v) came with new plug-ins. Installed: \(PluginUpdate.summary(older)). One password."
        let yes = PluginUpdate.asker(text)
        AppLog.shared.info("plugins", "asked to update: \(yes ? "yes" : "later")")
        if yes { openInstaller() }
    }
}

/// The menu item: there only while some installed plug-in is older than the app.
struct UpdatePluginsButton: View {
    @ObservedObject var model: PluginUpdateModel
    var body: some View {
        if model.needsUpdate {
            Button(Brand.updatePlugins) { model.openInstaller() }
        }
    }
}
