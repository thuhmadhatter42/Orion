import AppKit
import SwiftUI

// The look's primitives, one copy for the app's faceplate and the plug-in's face: the display colour
// (Accent), the one white of every white button (CapWhite) and the faceplate greys (PlateGrey). The app's
// Theme / Palette / AccentSettings build on these; the plug-in's FaceLook does the same.

/// An sRGB colour from 0...255 components (Theme.rgb in the app is the same maths).
@inline(__always) func lookRGB(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

/// The faceplate grey, the one token: the window's plate, the pocket's plate, the Mini and the
/// plug-in's face follow it (J 2026-11-19: "the face plate grey is too light grey": about 20% darker
/// than 0x232326 / 0x191a1c / 0x131315).
public enum PlateGrey {
    public static let top = lookRGB(0x1b, 0x1b, 0x1e)
    public static let mid = lookRGB(0x14, 0x14, 0x15)
    public static let bottom = lookRGB(0x0f, 0x0f, 0x11)
    /// The plate's body: top, middle at 40%, bottom.
    public static var body: LinearGradient {
        LinearGradient(gradient: Gradient(stops: [.init(color: top, location: 0), .init(color: mid, location: 0.4),
                                                  .init(color: bottom, location: 1)]),
                       startPoint: .top, endPoint: .bottom)
    }
}

/// The display colour (J 2026-11-09: "a Color button ... pops up a color wheel that lets you change
/// the amber color to whatever you want"). sRGB 0...255. Amber is the default; every step of
/// Theme.A, the glow, the lit-fill ink and the Mini derive from the one in use.
public struct Accent: Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = min(255, max(0, r)); self.g = min(255, max(0, g)); self.b = min(255, max(0, b))
    }

    public static let amber = Accent(255, 176, 32)
    /// The LCD glass behind the text (#0c0a06).
    public static let lcd = Accent(12, 10, 6)
    /// The reading (A1) keeps at least this contrast on the LCD: amber has 10.8:1. A pick under it
    /// is lifted (brighter first, then paler) until it reaches it.
    public static let minContrast = 7.0
    /// Ink on a lit amber fill: the design's #1a1206.
    public static let amberInk = Accent(26, 18, 6)
    /// Ink on a dark lit fill (only a pick that was not clamped can be that dark).
    public static let lightInk = Accent(246, 244, 238)

    public var rgb: (Double, Double, Double) { (r, g, b) }
    public var color: Color { lookRGB(r, g, b) }
    public var nsColor: NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }

    /// WCAG relative luminance, 0...1.
    public var luminance: Double {
        func lin(_ c: Double) -> Double {
            let s = c / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrast(with o: Accent) -> Double {
        let (a, b) = (luminance, o.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Ink for text on a fill of this colour: the darker or the lighter one, whichever reads better.
    /// Dark ink is the colour taken down to a tenth (amber keeps the design's exact #1a1206).
    public var ink: Accent {
        let dark = self == .amber ? Accent.amberInk : Accent(r * 0.1, g * 0.1, b * 0.1)
        return contrast(with: dark) >= contrast(with: Accent.lightInk) ? dark : Accent.lightInk
    }

    /// A lit key cap (LISTEN, DOWNLOAD...): its gradient top / middle / bottom and its legend.
    /// Amber keeps the design's hexes (#ffe4a6 / #f7b32b / #c07f12, legend #3a2a06); another colour
    /// gets the same shape: lighter on top, the colour, three quarters at the bottom.
    public var litCap: (top: Accent, mid: Accent, bottom: Accent, legend: Accent) {
        if self == .amber {
            return (Accent(255, 228, 166), Accent(247, 179, 43), Accent(192, 127, 18), Accent(58, 42, 6))
        }
        let top = Accent(r + (255 - r) * 0.6, g + (255 - g) * 0.6, b + (255 - b) * 0.6)
        let legend = ink == Accent.lightInk ? Accent.lightInk : Accent(r * 0.23, g * 0.23, b * 0.23)
        return (top, self, Accent(r * 0.75, g * 0.75, b * 0.75), legend)
    }

    /// The colour as the LCD shows it: unchanged when it reads on the glass, else lifted to
    /// `minContrast` (HSB brightness up first, keeping its hue and strength; then less saturated).
    /// `clamped` says whether it had to be lifted.
    public func readable() -> (accent: Accent, clamped: Bool) {
        if contrast(with: .lcd) >= Accent.minContrast { return (self, false) }
        var (h, s, v) = hsb
        func at(_ s: Double, _ v: Double) -> Accent { Accent.fromHSB(h, s, v) }
        func ok(_ a: Accent) -> Bool { a.contrast(with: .lcd) >= Accent.minContrast }
        if ok(at(s, 1)) {
            var lo = v, hi = 1.0
            for _ in 0..<24 { let m = (lo + hi) / 2; if ok(at(s, m)) { hi = m } else { lo = m } }
            v = hi
        } else {
            v = 1
            var lo = 0.0, hi = s
            for _ in 0..<24 { let m = (lo + hi) / 2; if ok(at(m, 1)) { lo = m } else { hi = m } }
            s = lo
        }
        if h.isNaN { h = 0 }
        return (at(s, v), true)
    }

    /// Hue 0...1, saturation 0...1, brightness 0...1.
    public var hsb: (Double, Double, Double) {
        let (R, G, B) = (r / 255, g / 255, b / 255)
        let mx = max(R, G, B), mn = min(R, G, B), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == R { h = ((G - B) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == G { h = (B - R) / d + 2 }
            else { h = (R - G) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    public static func fromHSB(_ h: Double, _ s: Double, _ v: Double) -> Accent {
        let i = floor(h * 6), f = h * 6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (R, G, B): (Double, Double, Double)
        switch Int(i) % 6 {
        case 0: (R, G, B) = (v, t, p)
        case 1: (R, G, B) = (q, v, p)
        case 2: (R, G, B) = (p, v, t)
        case 3: (R, G, B) = (p, q, v)
        case 4: (R, G, B) = (t, p, v)
        default: (R, G, B) = (v, p, q)
        }
        return Accent(R * 255, G * 255, B * 255)
    }

    /// From any NSColor (the panel may hand back a catalogue or generic colour); nil = no sRGB form.
    public init?(_ ns: NSColor) {
        guard let c = ns.usingColorSpace(.sRGB) else { return nil }
        self.init(Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
    }

    public var described: String { "rgb(\(Int(r.rounded())),\(Int(g.rounded())),\(Int(b.rounded())))" }
}

/// The one owner of "white" (J 2026-11-19: the caps read as yellow teeth; "tinted towards the user
/// selected colour, that's it"). Pure white mixed toward the display colour by ONE constant, `tint`;
/// every white button (SSLCapStyle: key caps, send caps, popover caps; the plug-in's caps) and the
/// Manual Key Selection's white (`Palette.manualWhite`, which the menu-bar key uses too) take their
/// colours from here, and no off-white is written anywhere else. High Contrast: pure white, no tint.
public enum CapWhite {
    /// How far toward the display colour the white leans (0...1). The one number to change.
    public static let tint = 0.04
    private static let white = 255.0

    /// Pure white mixed toward `accent` by `tint` (sRGB 0...255). High Contrast: pure white.
    /// `tint` is a parameter only so tests can pin the maths; clamped to 0...1.
    public static func rgb(accent: Accent, highContrast: Bool, tint t: Double = CapWhite.tint) -> (Double, Double, Double) {
        if highContrast { return (white, white, white) }
        let t = min(1, max(0, t))
        return (white + (accent.r - white) * t, white + (accent.g - white) * t, white + (accent.b - white) * t)
    }

    /// The cap's shading, as fractions of the white: top, middle, bottom. A pressable cap and an
    /// unavailable one (a touch darker); the legend is a dark tinted the same way.
    public static let readyShade: [Double] = [0.97, 0.88, 0.75]
    public static let unavailableShade: [Double] = [0.88, 0.80, 0.69]
    public static let legendBase: (Double, Double, Double) = (56, 56, 59)

    public struct Face {
        public var ready: [Color]
        public var unavailable: [Color]
        public var legend: Color
        public var legendDim: Color
    }

    public static func face(accent: Accent, highContrast: Bool) -> Face {
        let w = rgb(accent: accent, highContrast: highContrast)
        func shaded(_ k: [Double]) -> [Color] { k.map { lookRGB(w.0 * $0, w.1 * $0, w.2 * $0) } }
        // the legend leans the same way, by the same tint (High Contrast: neutral dark)
        let t = highContrast ? 0 : min(1, max(0, tint))
        let l = legendBase
        let lg = (l.0 + (accent.r - l.0) * t, l.1 + (accent.g - l.1) * t, l.2 + (accent.b - l.2) * t)
        return Face(ready: shaded(readyShade), unavailable: shaded(unavailableShade),
                    legend: lookRGB(lg.0, lg.1, lg.2), legendDim: lookRGB(lg.0, lg.1, lg.2, 0.45))
    }
}
