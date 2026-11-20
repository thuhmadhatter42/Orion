import SwiftUI

// Two pieces of the shared face only a plug-in draws (overnight plan 2026-11-20 §3-§5):
//   the status line: one plain line for what just happened (a download's progress, a send's result,
//     a failure in words a customer can act on), in the row the app uses for Open Audio + FIND;
//   the DOWNLOAD menu: where the beat goes in Pro Tools. The recent picks are listed as history,
//     nothing is pre-selected, and nothing happens without a click (J: "keep the history, but not active").

/// The face's one-line status (nil = none to show).
struct FaceStatus: Equatable {
    enum Kind: Equatable { case info, ok, error }
    var text: String
    var kind: Kind = .info
    /// The longer form (the tooltip; the log has the full line).
    var detail: String? = nil
}

/// The DOWNLOAD menu's contents: the recent picks (history, never pre-selected), every placement,
/// and Save Only when the host is not Pro Tools or the user wants the file alone.
struct DownloadMenu: Equatable {
    var history: [DownloadPlacement] = []
    var placements: [DownloadPlacement] = DownloadPlacement.all
    /// The host can import (Pro Tools): the placements are offered; else only Save Only.
    var canImport = true

    static let title = "PUT IT IN PRO TOOLS"
    static let saveOnly = "SAVE ONLY · SHOW IN FINDER"
    static let width: CGFloat = 248
    static let rowHeight: CGFloat = 22
}

/// The status line: an LCD strip, the display colour (red for a failure).
struct StatusStrip: View {
    @Environment(\.palette) private var palette
    let status: FaceStatus?
    var placeholder = ""

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.R.well, style: .continuous)
        let text = status?.text ?? placeholder
        HStack(spacing: Theme.S.s) {
            Text(text.uppercased())
                .captionStyle()
                .foregroundColor(status?.kind == .error ? Theme.redText : status?.kind == .ok ? palette.a1 : palette.a2)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.S.m)
        .frame(height: Theme.H.lg)
        .lcdGlass(radius: Theme.R.well)
        .background(shape.fill(Color.white.opacity(0.05)).offset(y: 1).padding(-1))
        .nativeHelp(status?.detail ?? text)
        .accessibilityElement(children: .ignore)
        .accessibility(label: Text(text))
    }
}

/// The DOWNLOAD menu, drawn by the face (so it looks like the faceplate and renders offscreen).
struct DownloadMenuPanel: View {
    @Environment(\.palette) private var palette
    let menu: DownloadMenu
    let pick: (DownloadPlacement?) -> Void
    let dismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.R.well, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(menu.canImport ? DownloadMenu.title : "DOWNLOAD").captionStyle().foregroundColor(palette.a2)
                Spacer(minLength: 0)
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(palette.a2) }
                    .buttonStyle(PlainButtonStyle())
                    .accessibility(label: Text("Close the download menu"))
            }
            .frame(height: DownloadMenu.rowHeight)
            if menu.canImport {
                if !menu.history.isEmpty {
                    section("RECENT")
                    ForEach(menu.history, id: \.wire) { p in row(p.label.uppercased(), dim: true) { pick(p) } }
                    rule
                }
                ForEach(menu.placements, id: \.wire) { p in row(p.label.uppercased()) { pick(p) } }
                rule
            }
            row(DownloadMenu.saveOnly) { pick(nil) }
        }
        .padding(.horizontal, Theme.S.m)
        .padding(.vertical, Theme.S.xs)
        .frame(width: DownloadMenu.width)
        .lcdGlass(radius: Theme.R.well)
        .background(shape.fill(Color.black).shadow(color: Color.black.opacity(0.6), radius: 8, y: 4))
        .accessibilityElement(children: .contain)
        .accessibility(label: Text("Where the download goes"))
    }

    private func section(_ t: String) -> some View {
        Text(t).captionStyle().foregroundColor(palette.a3).frame(height: 16)
    }

    private var rule: some View {
        Rectangle().fill(palette.a4).frame(height: 1).padding(.vertical, 3)
    }

    private func row(_ title: String, dim: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(Theme.T.body).foregroundColor(dim ? palette.a2 : palette.a1).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: DownloadMenu.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .pointingHand()
    }
}
