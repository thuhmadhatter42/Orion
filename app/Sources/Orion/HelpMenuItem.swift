import AppKit

// The Help menu's "Beat Key Help" item, the way AppKit's own is.
//
// Read live with a probe app on 2026-11-17 (macOS 27.2.1): the standard item is `<App> Help`,
// action `showHelp:` (NSApplication, NSHelpManager.h), key equivalent "?", modifier mask ⌘ only
// (the shift of Shift-/ is implied by the "?"). SwiftUI's `.keyboardShortcut("?", .command)` gives
// the same key and mask but its own `menuAction:`, so the item was not the system's Help item.
// This points the item at `showHelp:` (target: here, so it opens the in-app window, not the missing
// help book) and sets the key and mask explicitly. The system, not the item, owns what ⌘? does:
// it opens the Help menu's Search field in every app. Failures go to the app log, tag [HelpMenuItem]
// (~/Library/Logs/Beat Key/beatkey.log).

final class HelpMenuItem: NSObject {
    static let shared = HelpMenuItem()
    private var observers: [NSObjectProtocol] = []
    private var reportedMissing = false

    /// The standard Help item's key: "?" with ⌘.
    static let key = "?"
    static let modifiers: NSEvent.ModifierFlags = .command

    @objc(showHelp:) func showHelp(_ sender: Any?) { HelpWindow.shared.open(why: "menu") }

    /// The item titled `Brand.help` anywhere under `menu` (the Help menu is a submenu of the bar).
    static func find(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.title == Brand.help { return item }
            if let hit = find(in: item.submenu) { return hit }
        }
        return nil
    }

    /// Gives the item the standard action, key and mask. Only writes what differs (SwiftUI rebuilds
    /// menus, and the change notifications this causes must settle). False = there is no such item.
    @discardableResult
    func apply(to menu: NSMenu?) -> Bool {
        guard let item = HelpMenuItem.find(in: menu) else { return false }
        let action = #selector(HelpMenuItem.showHelp(_:))
        if item.action != action { item.action = action }
        if item.target !== self { item.target = self }
        if item.keyEquivalent != HelpMenuItem.key { item.keyEquivalent = HelpMenuItem.key }
        if item.keyEquivalentModifierMask != HelpMenuItem.modifiers {
            item.keyEquivalentModifierMask = HelpMenuItem.modifiers
        }
        return true
    }

    /// At launch: the menu bar is built a moment later and rebuilt when its state changes, so the
    /// item is set after a short wait, and again on every menu change.
    func install() {
        let nc = NotificationCenter.default
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.apply(to: NSApp.mainMenu)
            })
        }
        for delay in [0.3, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
        }
    }

    private func check() {
        if apply(to: NSApp.mainMenu) { return }
        guard !reportedMissing else { return }
        reportedMissing = true
        AppLog.log("FAILED to attach the Help shortcut: no \"\(Brand.help)\" item in the menu bar. "
                   + "The item still opens the Help window from the menu; the system owns Cmd-?.")
    }
}
