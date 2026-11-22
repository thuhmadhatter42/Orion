import AppKit
import SwiftUI

// Advanced mode (the window and the plug-in; the menu-bar pocket has none since option C,
// J 2026-11-22): the ADVANCED box at the right of the footer (DisplaySettings.advanced).

/// ADVANCED at the right end of the footer: a small square box (ticked when on) and its label, the
/// footer's caption type and height, in the display colour so it follows COLOR.
struct AdvancedBox: View {
    @Environment(\.palette) private var palette
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    static let boxSide: CGFloat = 10
    static let label = "ADVANCED"
    /// The box and the word 4 after it.
    static var width: CGFloat { boxSide + Theme.S.xs + FooterChip.textWidth(label) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.S.xs) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(on ? palette.amber : Color.clear)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(on ? Color.clear : hover ? palette.a1 : palette.a2, lineWidth: 1)
                    if on {
                        CheckMark().stroke(palette.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                            .padding(2)
                    }
                }
                .frame(width: AdvancedBox.boxSide, height: AdvancedBox.boxSide)
                Text(AdvancedBox.label).captionStyle()
                    .foregroundColor(on || hover ? palette.a1 : palette.a2)
                    .lineLimit(1).fixedSize()
            }
            .frame(minHeight: Theme.H.xs, maxHeight: Theme.H.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hover = $0 }
        .pointingHand()
        .nativeHelp("Advanced mode: the key wheel, chords and MATCH TO")
        .helpTip(HelpText.advanced)
        .accessibility(label: Text("Advanced mode"))
        .accessibility(value: Text(on ? "on" : "off"))
        .accessibility(hint: Text(on ? "Hides the key wheel, chords and Match To" : "Shows the key wheel, chords and Match To"))
        .accessibility(addTraits: on ? .isSelected : [])
    }
}

private struct CheckMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY - r.height * 0.1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.1))
        return p
    }
}
