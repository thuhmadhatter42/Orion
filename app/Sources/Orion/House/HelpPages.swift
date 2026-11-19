import AppKit
import SwiftUI

// HOUSE KIT, help-menu module (HouseHelp half): the Manual, What's New and Licenses pages. Pasted from
// ~/dev/house-kit/modules/help-menu/swift/HelpMenu.swift (the `HouseHelp` enum); the kit's HelpCommands,
// Doctor and DoctorSheet are NOT pasted: Beat Key already has its own Run Doctor (Doctor.swift,
// App menu) and its own Help menu (Beat Key Help, Help Mode), so the menu items are wired in OrionApp.swift.
//
// The pages are files in Contents/Resources (app/build.sh puts them there):
//   Manual.html     <- app/pages/Manual.html
//   WhatsNew.html   <- app/pages/WhatsNew.html
//   Licenses.txt    <- app/tools/licenses.sh: THIRD-PARTY-LICENSES.md + LICENSE (one source, never a hand copy)
// A page that is not in the bundle is an ERROR in beatkey.log (users send it with Help > Send Report…)
// and a short "not found" alert. Never a menu item that does nothing.

enum HouseHelp {
    /// One bundled page: the first of `names` that exists in Contents/Resources wins.
    struct Page: Equatable {
        let title: String
        let names: [String]
    }

    static let manual = Page(title: "Manual", names: ["Manual.pdf", "Manual.html"])
    static let whatsNew = Page(title: "What's New", names: ["WhatsNew.html", "WhatsNew.txt"])
    static let licenses = Page(title: "Licenses", names: ["Licenses.html", "Licenses.txt"])
    static let pages = [manual, whatsNew, licenses]

    static func url(for page: Page, in bundle: Bundle = .main) -> URL? {
        for name in page.names {
            let ns = name as NSString
            if let u = bundle.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension) { return u }
        }
        return nil
    }

    /// THE SEAM: how a page is shown (a test swaps it; nothing opens).
    @MainActor static var opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// THE SEAM: the "not found" alert (a test swaps it; no window). Gets the page title and the message.
    @MainActor static var notFoundAlert: (String, String) -> Void = { title, message in
        let a = NSAlert()
        a.messageText = "\(title) not found"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// Open a bundled page in its default app (HTML in the browser, text in TextEdit): it works offline.
    /// A missing page or a refused open is logged as an error AND shown in a short alert.
    @MainActor @discardableResult
    static func open(_ page: Page, in bundle: Bundle = .main) -> Bool {
        guard let u = url(for: page, in: bundle) else {
            AppLog.shared.error("help", "\(page.title): none of \(page.names) is in the bundle")
            notFoundAlert(page.title, "\(page.title) is missing from this copy of \(House.appName). Reinstall it, or use Help > Send Report…")
            return false
        }
        let ok = opener(u)
        if ok { AppLog.shared.info("help", "opened \(u.lastPathComponent)") }
        else {
            AppLog.shared.error("help", "macOS would not open \(u.path)")
            notFoundAlert(page.title, "macOS would not open \(u.lastPathComponent). Use Help > Send Report…")
        }
        return ok
    }
}
