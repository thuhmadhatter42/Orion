import AppKit
import SwiftUI

// The face's look, built on the shared primitives (BeatKeyShared/Look.swift: Accent, CapWhite,
// PlateGrey) and the app's glow module (app/Sources/Orion/House/Glow.swift, compiled into the face
// as is). Same tokens as the app's faceplate: Helvetica Neue, the LCD glass, the white SSL cap.

// The two environment values the glow module reads (the app fills them in AccentBridge.swift).
private struct AccentKey: EnvironmentKey { static let defaultValue: Accent = .amber }
private struct HighContrastKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var accent: Accent {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
    var highContrast: Bool {
        get { self[HighContrastKey.self] }
        set { self[HighContrastKey.self] = newValue }
    }
}

enum FaceType {
    static func face(_ size: CGFloat, bold: Bool = true) -> Font {
        Font.custom(bold ? "HelveticaNeue-Bold" : "HelveticaNeue", size: size)
    }
    /// 11 Bold, +0.08em: cap legends and labels (the app's T.label).
    static let label = face(11)
    static let labelTracking: CGFloat = 11 * 0.08
    /// 10 Medium, +0.10em (the app's T.caption).
    static let caption = Font.custom("HelveticaNeue-Medium", size: 10)
    static let captionTracking: CGFloat = 1.0
}

extension Accent {
    func color(_ a: Double) -> Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a) }
}

extension View {
    /// The app's LCD glass (LCD.swift `lcdGlass`): the near-black face, the sheen, the recess.
    func faceGlass(radius r: CGFloat = 6) -> some View {
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        return self
            .overlay(LinearGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0)],
                                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)).allowsHitTesting(false))
            .background(LinearGradient(colors: [Color(.sRGB, red: 10 / 255, green: 12 / 255, blue: 9 / 255, opacity: 1),
                                                Color(.sRGB, red: 5 / 255, green: 6 / 255, blue: 4 / 255, opacity: 1)],
                                       startPoint: .top, endPoint: .bottom))
            .clipShape(shape)
            .overlay(shape.stroke(Color.black.opacity(0.9), lineWidth: 1))
            .shadow(color: Color.white.opacity(0.04), radius: 0, y: 1)
    }
}

/// The white SSL cap (the app's SSLCapStyle): CapWhite's one tint, dark legend, a top shine.
/// Unavailable = the same cap a touch darker, legend dimmed (never see-through).
struct FaceCapStyle: ButtonStyle {
    var height: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        FaceCap(label: configuration.label, pressed: configuration.isPressed, height: height)
    }
}

private struct FaceCap<Label: View>: View {
    @Environment(\.accent) private var accent
    @Environment(\.isEnabled) private var enabled
    let label: Label
    let pressed: Bool
    let height: CGFloat
    @State private var hover = false

    var body: some View {
        let cap = CapWhite.face(accent: accent, highContrast: false)
        let c = enabled ? cap.ready : cap.unavailable
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return label
            .font(FaceType.label)
            .foregroundColor(enabled ? cap.legend : cap.legendDim)
            .shadow(color: Color.white.opacity(enabled ? 0.5 : 0.2), radius: 0, y: 1)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: height - 2)
            .background(
                ZStack(alignment: .top) {
                    LinearGradient(gradient: Gradient(stops: [.init(color: c[0], location: 0), .init(color: c[1], location: 0.45),
                                                              .init(color: c[2], location: 1)]),
                                   startPoint: .top, endPoint: .bottom)
                    if enabled {
                        GeometryReader { g in
                            LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0)], startPoint: .top, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .frame(width: g.size.width * 0.84, height: g.size.height * 0.36)
                                .offset(x: g.size.width * 0.08, y: 2)
                        }
                    }
                }
                .clipShape(shape))
            .overlay(shape.stroke(Color(.sRGB, red: 10 / 255, green: 10 / 255, blue: 11 / 255, opacity: 1), lineWidth: 1))
            .background(shape.fill(Color.black.opacity(0.6)).offset(y: 2).blur(radius: 1.5))
            .brightness(pressed ? -0.08 : (hover && enabled ? 0.04 : 0))
            .offset(y: pressed ? 1 : 0)
            .contentShape(shape)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// A small chip (the app's footer chip): a 1 px accent border, accent caption, lit = filled faintly + glow.
struct FaceChipStyle: ButtonStyle {
    var lit = false
    func makeBody(configuration: Configuration) -> some View { Chip(label: configuration.label, pressed: configuration.isPressed, lit: lit) }

    private struct Chip<L: View>: View {
        @Environment(\.accent) private var accent
        @Environment(\.isEnabled) private var enabled
        let label: L
        let pressed: Bool
        let lit: Bool
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
            return label
                .font(FaceType.caption)
                .foregroundColor(lit ? accent.ink.color : accent.color(enabled ? 0.85 : 0.35))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(shape.fill(lit ? accent.color : accent.color(pressed ? 0.2 : 0.06)))
                .overlay(shape.stroke(accent.color(lit ? 0 : 0.45), lineWidth: 1))
                .contentShape(shape)
                .accentGlow(HouseGlow.Full.litChip, active: lit)
        }
    }
}
