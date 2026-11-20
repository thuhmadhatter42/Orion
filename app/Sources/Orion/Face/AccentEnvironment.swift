import SwiftUI

// The accent and High Contrast as environment values (the house glow module reads them; the face's
// views read `\.palette`). The app fills them at every root (House/AccentBridge.swift: AccentRoot);
// the plug-in from its instance's own colour (plugin/ui/FaceBridge.swift).

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

extension View {
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
