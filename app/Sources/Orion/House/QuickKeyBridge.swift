import SwiftUI

// BEAT KEY'S GLUE FOR THE QUICK KEYS MODULE (not part of the kit's paste).
//
// The kit's `QuickKeyButton("id", "Title") { … }` makes a button whose shortcut is its row. Beat Key's menu
// items are Toggles, Buttons with `.disabled`, items inside `Menu`s and views that already exist, so this is the
// same thing as a modifier: `.quickKey("exportMidi")` instead of a literal `.keyboardShortcut(…)`.
// Rebinding the row in ⇧⌃K rebinds the item; a cleared row leaves the item bare.

private struct QuickKeyShortcut: ViewModifier {
    @ObservedObject private var keys = QuickKeys.shared
    let id: String

    func body(content: Content) -> some View {
        // Two branches, not `.keyboardShortcut(optional)`: that overload needs macOS 12.3 and Beat Key runs on 12.0.
        if let shortcut = keys.shortcut(for: id) {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}

extension View {
    /// The shortcut of this Quick Keys row (QuickKeyTable.swift), live.
    func quickKey(_ id: String) -> some View { modifier(QuickKeyShortcut(id: id)) }
}

extension QuickKeys {
    /// A row's chord as a tip or label prints it ("⌃⌥⌘A"; "no shortcut" when cleared). The live table when
    /// called on the main thread (the launch, the views), else the row's default. Never typed twice.
    nonisolated static func tipDisplay(_ id: String) -> String {
        let chord: QuickChord
        if Thread.isMainThread {
            chord = MainActor.assumeIsolated { QuickKeys.shared.chord(for: id) }
        } else {
            chord = QuickKeys.appRows.first { $0.id == id }?.chord ?? .none
        }
        return chord.isAssigned ? chord.display : "no shortcut"
    }
}

extension QuickKeys {
    /// Settings › Open Quick Keys…: the sheet belongs to the main window, so bring that forward first.
    @MainActor static func openFromElsewhere() {
        StatusItemController.bringWindowForward()
        QuickKeys.shared.open()
    }
}
