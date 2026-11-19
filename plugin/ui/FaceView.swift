import AppKit
import SwiftUI

// The face (plan §V): "put it on a track and it spits out the BPM and key, except you can say send BPM
// and send Auto-Tune". Main screen = key + BPM in the LCD glass, and the two white caps. Everything
// else (top 3 with %, tuning, x2 / ÷2, pin, new song, colour, Report, Manual, What's New, version) is
// one click away, in the MORE popover. Tips follow docs/BOARD-TALK.md (60 characters at most).

/// The root: the accent in the environment, the plate behind everything, fixed 360 x 120.
struct FaceRoot: View {
    @ObservedObject var model: FaceModel
    @ObservedObject var settings = FaceSettings.shared

    var body: some View {
        FaceMain(model: model)
            .frame(width: CGFloat(BKP_VIEW_W), height: CGFloat(BKP_VIEW_H))
            .background(PlateGrey.body)
            .environment(\.accent, settings.accent)
            .preferredColorScheme(.dark)
    }
}

/// Board Talk tips (title = the control's legend, body ≤ 60 characters). FaceTips.all is checked by
/// plugin/test/face_test.swift.
enum FaceTips {
    static let key = "Key in use. Pin one in MORE."
    static let bpm = "Tempo in use. ×2 / ÷2 in MORE."
    static let sendBPM = "Set the session tempo (via the Beat Key app)"
    static let sendAutoTune = "Set the key in Auto-Tune (Auto Key on)"
    static let more = "Top keys, pin, tuning, ×2 / ÷2, colour, help"
    static let newSong = "Start over: forget what was heard."
    static let topKey = "Click to pin, again to unpin."
    static let report = "Mail the log to Four Letter Records."
    static let all = [key, bpm, sendBPM, sendAutoTune, more, newSong, topKey, report]
    static let maxBody = 60
}

struct FaceMain: View {
    @ObservedObject var model: FaceModel
    @Environment(\.accent) private var accent
    @State private var more = false

    var body: some View {
        let s = model.state
        HStack(spacing: 8) {
            // the LCD: KEY | BPM, and the line under them
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    readout(label: s.pin != nil ? "KEY · PIN" : "KEY", value: s.key ?? "—", lit: s.key != nil, pinned: s.pin != nil)
                        .frame(width: 84, alignment: .leading)
                        .help(FaceTips.key)
                    bpmReadout(s)
                        .help(FaceTips.bpm)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 2)
                lineView
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .faceGlass()

            // the two caps + MORE
            VStack(spacing: 6) {
                Button(model.sendingBPM ? "SENDING…" : "SEND BPM") { model.sendBPM() }
                    .buttonStyle(FaceCapStyle())
                    .disabled(s.bpm == nil || model.sendingBPM)
                    .help(FaceTips.sendBPM)
                    .accessibility(label: Text("Send BPM"))
                Button("SEND AUTO-TUNE") { model.sendAutoTune() }
                    .buttonStyle(FaceCapStyle())
                    .disabled(s.key == nil)
                    .help(FaceTips.sendAutoTune)
                    .accessibility(label: Text("Send key to Auto-Tune"))
                HStack(spacing: 4) {
                    Text("BEAT KEY").font(FaceType.caption).tracking(FaceType.captionTracking)
                        .foregroundColor(Color.white.opacity(0.28))
                    Spacer(minLength: 0)
                    Button("MORE") { more.toggle() }
                        .buttonStyle(FaceChipStyle(lit: more))
                        .help(FaceTips.more)
                        .popover(isPresented: $more, arrowEdge: .bottom) {
                            FaceMore(model: model)
                                .environment(\.accent, accent)
                                .preferredColorScheme(.dark)
                        }
                }
            }
            .frame(width: 128)
        }
        .padding(10)
    }

    private func readout(label: String, value: String, lit: Bool, pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(FaceType.caption).tracking(FaceType.captionTracking)
                .foregroundColor(accent.color(0.62))
            Text(value)
                .font(FaceType.face(30))
                .foregroundColor(pinned ? lookWhite : accent.color(lit ? 1 : 0.28))
                .lineLimit(1).minimumScaleFactor(0.6)
                .accentGlow(HouseGlow.Full.litText, active: lit, color: pinned ? lookWhite : nil)
                .animation(.easeInOut(duration: 0.25), value: value)
        }
    }

    /// A pinned key is white (the cap white, tinted to the accent), as in the app.
    private var lookWhite: Color {
        let w = CapWhite.rgb(accent: accent, highContrast: false)
        return Color(.sRGB, red: w.0 / 255, green: w.1 / 255, blue: w.2 / 255, opacity: 1)
    }

    private func bpmReadout(_ s: FaceState) -> some View {
        let text = s.bpmText ?? "—"
        let parts = Tempo.split(text)
        let tag = s.factor.label
        return VStack(alignment: .leading, spacing: 1) {
            Text(tag.map { "BPM \($0)" } ?? "BPM").font(FaceType.caption).tracking(FaceType.captionTracking)
                .foregroundColor(accent.color(0.62))
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(parts.whole).font(FaceType.face(30).monospacedDigit())
                if let f = parts.fraction { Text(f).font(FaceType.face(16).monospacedDigit()) }
            }
            .foregroundColor(accent.color(s.bpm != nil ? 1 : 0.28))
            .lineLimit(1)
            .accentGlow(HouseGlow.Full.litText, active: s.bpm != nil)
        }
    }

    @ViewBuilder private var lineView: some View {
        let (text, kind, detail, link): (String, FaceLine.Kind, String?, URL?) = {
            if let l = model.line { return (l.text, l.kind, l.detail, l.link) }
            let st = model.statusText
            if st.0.isEmpty, let host = model.state.hostTempo { return ("Session \(PluginSend.bpmText(host))", .info, nil, nil) }
            return (st.0, st.1, nil, nil)
        }()
        HStack(spacing: 4) {
            Text(text)
                .font(FaceType.face(10, bold: false))
                .foregroundColor(kind == .error ? Color(.sRGB, red: 1, green: 106 / 255, blue: 92 / 255, opacity: 1)
                                 : kind == .ok ? accent.color(1) : accent.color(0.62))
                .lineLimit(1).truncationMode(.tail)
                .help(detail ?? text)
            if let link {
                Button("GET IT") { NSWorkspace.shared.open(link) }
                    .buttonStyle(FaceChipStyle())
            }
        }
        .frame(height: 18)
    }
}

/// MORE: one click away from the main screen.
struct FaceMore: View {
    @ObservedObject var model: FaceModel
    @ObservedObject var settings = FaceSettings.shared
    @Environment(\.accent) private var accent

    var body: some View {
        let s = model.state
        VStack(alignment: .leading, spacing: 12) {
            section("TOP KEYS") {
                HStack(spacing: 6) {
                    if s.top.isEmpty {
                        Text("Listening…").font(FaceType.face(11, bold: false)).foregroundColor(accent.color(0.62))
                    }
                    ForEach(s.top, id: \.name) { k in
                        Button("\(k.name)  \(k.percent)%") { model.togglePin(k.name) }
                            .buttonStyle(FaceChipStyle(lit: s.pin == k.name))
                            .help(FaceTips.topKey)
                    }
                    Spacer(minLength: 0)
                    Menu(s.pin.map { "PIN \($0)" } ?? "PIN…") {
                        ForEach(KeyNames.all, id: \.self) { k in Button(k) { model.togglePin(k) } }
                        if s.pin != nil { Divider(); Button("Unpin") { model.unpin() } }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(FaceType.caption)
                }
            }
            section("TEMPO") {
                HStack(spacing: 6) {
                    ForEach([TempoFactor.half, .one, .double], id: \.mult) { f in
                        Button(f == .half ? "÷2" : f == .double ? "×2" : "×1") { model.setFactor(f) }
                            .buttonStyle(FaceChipStyle(lit: s.factor == f))
                    }
                    Spacer(minLength: 0)
                    Text(s.hostTempo.map { "SESSION \(PluginSend.bpmText($0))" } ?? "SESSION —")
                        .font(FaceType.caption).tracking(FaceType.captionTracking).foregroundColor(accent.color(0.62))
                }
            }
            section("TUNING") {
                let ref = AutoTuneButton.referencePitch()
                Text(Tuning.meter(s.tuningCents, reference: ref).map(\.text) ?? "No confident tuning yet.")
                    .font(FaceType.face(11, bold: false).monospacedDigit()).foregroundColor(accent.color(0.85))
            }
            HStack(spacing: 6) {
                Button("NEW SONG") { model.newSong() }.buttonStyle(FaceChipStyle()).help(FaceTips.newSong)
                Spacer(minLength: 0)
            }
            section("COLOR") {
                HStack(spacing: 6) {
                    ForEach(FaceSettings.swatches, id: \.self) { a in
                        Button { settings.set(a) } label: {
                            Circle().fill(a.color).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.white.opacity(settings.accent == a.readable().accent ? 0.9 : 0.15), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(a == .amber ? "Amber (default)" : a.described)
                    }
                }
            }
            Divider().overlay(accent.color(0.16))
            HStack(spacing: 6) {
                Button("REPORT") { model.report() }.buttonStyle(FaceChipStyle()).help(FaceTips.report)
                Button("MANUAL") { model.openPage("Manual.html", "Manual") }.buttonStyle(FaceChipStyle())
                Button("WHAT'S NEW") { model.openPage("WhatsNew.html", "What's New") }.buttonStyle(FaceChipStyle())
                Spacer(minLength: 0)
            }
            Text("Beat Key \(model.version) · \(s.format)").font(FaceType.caption).foregroundColor(Color.white.opacity(0.4))
        }
        .padding(14)
        .frame(width: 320)
        .background(PlateGrey.body)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(FaceType.caption).tracking(FaceType.captionTracking).foregroundColor(accent.color(0.62))
            c()
        }
    }
}

extension FaceModel {
    func report() {
        let l = FaceHouse.report(token: token, state: state, version: version)
        show(l.text, kind: l.kind)
    }

    func openPage(_ name: String, _ title: String) {
        if !FaceHouse.open(page: name, title: title, token: token) { show("\(title) missing. Reinstall Beat Key.", kind: .error) }
    }
}
