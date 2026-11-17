import AppKit
import SwiftUI

// Help › Beat Key Help (⌘?): a native in-app window listing every control and what it does,
// grouped by area. It draws HelpText.sections, the same table the hover cards read: one source of
// truth, no second copy of any sentence (J 2026-11-17). Opens in this process; there is no help
// book. Lines go to the app log (tag [HelpWindow]).

/// The window's lines as plain values (so the window can be tested without drawing it).
enum HelpWindowContent {
    struct Row: Equatable {
        let section: String
        let title: String
        let body: String
    }

    /// Every tip of every section, in order.
    static func rows(_ sections: [HelpSection] = HelpText.sections) -> [Row] {
        sections.flatMap { s in s.tips.map { Row(section: s.title, title: $0.title, body: $0.body) } }
    }
}

final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()
    static let size = NSSize(width: 560, height: 640)

    private var window: NSWindow?

    /// Unit tests never open a window.
    private static let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    /// Brings the window forward, building it the first time. `why` says who asked (for the log).
    func open(why: String) {
        guard !HelpWindow.testing else { return }
        let problems = HelpText.problems()
        if !problems.isEmpty { AppLog.log("help table has \(problems.count) problem(s): \(problems.joined(separator: "; "))") }
        if window == nil { window = build() }
        guard let w = window else {
            AppLog.log("FAILED to build the help window (asked by \(why))")
            NSSound.beep()
            return
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if w.isVisible {
            AppLog.log("opened (\(why)), \(HelpText.all.count) entries in \(HelpText.sections.count) sections")
        } else {
            AppLog.log("FAILED to show the help window (asked by \(why)): window not visible after ordering front")
            NSSound.beep()
        }
    }

    private func build() -> NSWindow? {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: HelpWindow.size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = Brand.help
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(srgbRed: 8 / 255, green: 8 / 255, blue: 10 / 255, alpha: 1)
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 420, height: 360)
        w.delegate = self
        w.contentView = NSHostingView(rootView: HelpWindowView())
        w.center()
        return w
    }

    func windowWillClose(_ notification: Notification) {
        AppLog.log("closed")
    }
}

struct HelpWindowView: View {
    var sections: [HelpSection] = HelpText.sections
    private var palette: Palette { Palette(accent: AccentSettings.shared.effective) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.S.l) {
                Text(Brand.help).font(Theme.T.title).foregroundColor(palette.a1)
                Text("Every control and what it does. To see a card on the control itself, turn on Help › Help Mode (or press the HELP chip) and hover it.")
                    .font(Theme.T.note).foregroundColor(Theme.textLo)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(sections, id: \.title) { s in
                    VStack(alignment: .leading, spacing: Theme.S.s) {
                        Text(s.title.uppercased()).labelStyle().foregroundColor(palette.a2)
                        Rectangle().fill(palette.a4).frame(height: 1)
                        ForEach(s.tips, id: \.id) { t in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(Theme.T.value).foregroundColor(Theme.textHi)
                                Text(t.body).font(Theme.T.note).foregroundColor(Theme.textLo)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(Theme.S.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.palette, palette)
    }
}
