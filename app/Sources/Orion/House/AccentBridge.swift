import AppKit
import SwiftUI

// HOUSE KIT, ACCENT MODULE: KEPT BEAT KEY'S OWN (Faceplate/Accent.swift), NOT RE-PASTED.
// The kit's accent module was lifted from this file (amber 255,176,32, High Contrast, the colour wheel,
// UserDefaults `accentColor`), and Beat Key's is the better fit: its minimum contrast is measured on the LCD
// glass, its ink and lit-cap colours are the design's own hexes, and the whole faceplate reads it through
// `\.palette`. Pasting the kit's copy would define a second `Accent` / `AccentSettings`.
//
// The pasted house modules (Glow, Quick Keys, Report, Uninstall) were written against three things from the
// kit's accent module. This file is those three, on top of Beat Key's Accent:
//   `@Environment(\.accent)`, `@Environment(\.highContrast)`, `.accentRoot()`, and `Accent.color(_ opacity:)`.
// They are filled from the same two owners as `\.palette`: AccentSettings.shared (the colour) and the
// `highContrast` default that DisplaySettings writes (Settings, View menu).

/// A surface's root (every house sheet): the accent and High Contrast in the environment, system controls
/// tinted in the accent. Beat Key is dark only already (the window sets `.darkAqua`).
struct AccentRoot: ViewModifier {
    @ObservedObject private var accent = AccentSettings.shared
    // DisplaySettings.highContrast writes this key; @AppStorage redraws when it changes.
    @AppStorage(DisplaySettings.key) private var highContrast = false

    func body(content: Content) -> some View {
        content
            .environment(\.accent, accent.effective)
            .environment(\.highContrast, highContrast)
            .environment(\.palette, Palette(accent: accent.effective, highContrast: highContrast))
            .tint(accent.effective.color)
            .preferredColorScheme(.dark)
    }
}

extension View {
    /// Put this on the root view of every house sheet.
    func accentRoot() -> some View { modifier(AccentRoot()) }

}
