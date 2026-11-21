import AppKit
import SwiftUI
import XCTest
@testable import Orion

/// Settings window, rendered offscreen in a real window so the pop-ups draw
/// (ORION_SNAPSHOT_DIR=<dir> swift test --filter SettingsRenderTests).
final class SettingsRenderTests: XCTestCase {
    private func fresh() -> UserDefaults {
        let n = TestPrefs.name("settings-render-")
        let d = UserDefaults(suiteName: n)!
        d.removePersistentDomain(forName: n)
        return d
    }

    @MainActor
    private func shot(_ name: String, source: LiveSource?, advanced: Bool = true) throws {
        guard let dir = ProcessInfo.processInfo.environment["ORION_SNAPSHOT_DIR"] else {
            throw XCTSkip("set ORION_SNAPSHOT_DIR to write the Settings PNGs")
        }
        let d = fresh()
        let live = LiveSettings(defaults: d)
        if let s = source { live.source = s }
        let display = DisplaySettings(defaults: d)
        display.advanced = advanced
        let view = SettingsView(loginItem: LoginItemSettings(), live: live, display: display, rename: RenameSettings(defaults: d))
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let size = host.fittingSize
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        win.setFrameOrigin(NSPoint(x: 100, y: 100))
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        defer { win.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        var png: Data?
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
           cg.width > 0 {
            png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        if png == nil {   // no window server: fall back to the view's own drawing
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            png = rep.representation(using: .png, properties: [:])
        }
        let png2 = try XCTUnwrap(png)
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try png2.write(to: out.appendingPathComponent("\(name).png"))
        print("SETTINGS-RENDER \(name) \(size)")
    }

    /// Board Talk: Settings carries no help paragraphs (Help mode owns them); only the login item's
    /// own status line may be small grey text.
    func testSettingsHasNoHelpParagraphs() throws {
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/OrionTests/SettingsRenderTests.swift", with: "Sources/Orion/Settings.swift"))
        let view = String(src[..<src.range(of: "/// How the window looks")!.lowerBound])
        XCTAssertEqual(view.components(separatedBy: ".font(.caption)").count - 1, 1, "only loginItem.message")
    }

    @MainActor func testRenderDefault() throws { try shot("default", source: nil) }
    @MainActor func testRenderMissingDevice() throws {
        try shot("missing-device", source: .input(uid: "gone-device-uid", channel: 0))
    }
}
