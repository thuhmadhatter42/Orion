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

private struct AccentKey: EnvironmentKey {
    static let defaultValue: Accent = .amber
}

private struct HighContrastKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The accent in use (`AccentSettings.shared.effective`), set by `accentRoot()` at every sheet root.
    var accent: Accent {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }

    /// High Contrast is on: no glow, brighter text.
    var highContrast: Bool {
        get { self[HighContrastKey.self] }
        set { self[HighContrastKey.self] = newValue }
    }
}

extension Accent {
    /// The accent at an opacity (the house modules' translucent fills and borders).
    func color(_ opacity: Double) -> Color { Theme.rgb(r, g, b, opacity) }
}

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

    /// The house glow, drawn in the palette's colour: High Contrast leaves it out. Full-strength Artemis
    /// numbers in, the glow module's two constants (`HouseGlow.opacityScale` / `radiusScale`) scale them.
    /// For Beat Key's own views, which read `\.palette`; the glow module reads `\.accent`.
    func paletteGlow(_ full: [HouseGlow.Layer] = HouseGlow.Full.litChip, _ palette: Palette, active: Bool = true,
                     color: Color? = nil) -> some View {
        accentGlow(full, active: active && !palette.highContrast, color: color ?? palette.amber)
    }

    /// The same from one raw full-strength layer (`radius` in SwiftUI points, a CSS blur / 2).
    func paletteGlow(radius: CGFloat, opacity: Double, _ palette: Palette, active: Bool = true,
                     color: Color? = nil) -> some View {
        paletteGlow([HouseGlow.Layer(radius: radius, opacity: opacity)], palette, active: active, color: color)
    }
}
