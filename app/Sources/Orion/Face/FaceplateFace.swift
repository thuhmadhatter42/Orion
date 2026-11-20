import AppKit
import SwiftUI

// The shared face (overnight plan 2026-11-20 §2): the app window and the plug-in render this same view
// tree. It draws plain values (PocketState) and calls plain closures (PocketActions); each side wires
// them (the app: FaceplateView, PocketActions.wired; the plug-in: plugin/ui/FaceBridge + FaceModel).
// Everything under app/Sources/Orion/Face/ compiles into the app AND into each plug-in format's own
// Swift module (plugin/ui/build-face.sh); see FaceHost.swift for what each side provides.

/// The window as plain values (so it can be rendered offscreen and tested, like PocketView):
/// the desk, the plate, the rail, the module and the footer. Every control that the popover has
/// is the popover's own view, fed the same PocketState and PocketActions.
struct FaceplateFace: View {
    let state: PocketState
    /// Audio chosen with the Open Audio... field, waiting for FIND KEY/BPM.
    let picked: [URL]
    @Binding var url: String
    @Binding var fieldFocused: Bool
    @Binding var pickFocused: Bool
    var actions = PocketActions()
    var files = FileActions()

    /// The content below the title bar (the window adds the 28 pt bar): the plate with the
    /// rail, the readout (dial, BPM, top keys, keyboard), the link / audio / listen rows, the
    /// send caps and the footer links. Advanced mode adds the harmony column to the right: the
    /// window grows wider, never taller (laptop screens have width to spare, not height).
    static func size(advanced: Bool) -> CGSize {
        CGSize(width: plateWidth(advanced: advanced) + margin * 2, height: height)
    }
    static let size = size(advanced: false)
    /// A plug-in window has no title bar above the face: this much more desk on top, so the plate's
    /// outer ring clears the edge as it clears the window's title bar.
    static let pluginTopInset: CGFloat = 6
    /// The plug-in view's size (plugin/shared/bkp_view.h BKP_VIEW_W x BKP_VIEW_H is the default one;
    /// plugin/test/face_test.swift checks the two agree).
    static func pluginSize(advanced: Bool) -> CGSize {
        let s = size(advanced: advanced)
        return CGSize(width: s.width, height: s.height + pluginTopInset)
    }
    /// The dark band between the window edge and the plate, sides and bottom (J 2026-11-19: "make
    /// those black bars smaller": 16 -> 8), and above it, under the 28 pt title bar (6 -> 2: the
    /// plate's outer ring starts 4 pt up, so it still clears the traffic lights).
    static let margin: CGFloat = 8
    static let topMargin: CGFloat = 2
    /// The plate's own height (the rail, readout, rows and footer), both modes.
    static let plateHeight: CGFloat = 734
    /// The window's content height, both modes (J 2026-11-09: 732 + 12 for the taller keyboard,
    /// + 12 for the bigger key dial).
    static let height: CGFloat = plateHeight + topMargin + margin
    /// The module column inside the plate's 12 pt padding (J 2026-11-09: "the whole left side is
    /// too wide": 496 -> 472, as narrow as SEND TO AUTO-TUNE and the source name allow at full size).
    static let moduleWidth: CGFloat = 472
    static let columnGap: CGFloat = Theme.S.l
    /// The gap between a field and its cap, and between the send caps (one column grid).
    static let gridGap: CGFloat = Theme.S.m
    /// SEND TO DAW and SEND TO AUTO-TUNE split what the cap column leaves.
    static var sendWidth: CGFloat { (moduleWidth - capWidth - gridGap * 2) / 2 }
    /// The send caps' legend padding: S.xs, so SEND TO AUTO-TUNE (132.5 pt) fits 148 at full size.
    static let sendPadding: CGFloat = Theme.S.xs
    /// The plate: the module in its 12 pt padding, plus the gap and the harmony column in Advanced mode.
    static func plateWidth(advanced: Bool) -> CGFloat {
        let plate = moduleWidth + 24
        return advanced ? plate + columnGap + HarmonyPanel.width : plate
    }
    /// Every cap on the right of a field shares one width so the fields line up; it fits the
    /// longest legend in that column (PASTE + DOWNLOAD).
    static let capWidth: CGFloat = 152
    /// The scale keyboard in the window's readout (J 2026-11-09: taller and narrower, not stubby):
    /// 432 x 96, white keys about 62 x 96 (was 456 x 84).
    static let keyboardHeight: CGFloat = 96

    /// The window's own second row: pick audio into the field, then read it.
    struct FileActions {
        var openAudio: () -> Void = {}
        var find: () -> Void = {}
    }

    var body: some View {
        let size = FaceplateFace.size(advanced: state.advanced)
        VStack(spacing: 0) {
            Plate(width: FaceplateFace.plateWidth(advanced: state.advanced)) {
                VStack(spacing: 0) {
                    Rail(status: .of(state))
                    HStack(alignment: .top, spacing: FaceplateFace.columnGap) {
                        module.frame(width: FaceplateFace.moduleWidth)
                        if state.advanced {
                            HarmonyPanel(state: state, actions: actions).frame(width: HarmonyPanel.width)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.S.l)
                    footer.padding(.top, Theme.S.l)
                }
            }
            .padding(.top, FaceplateFace.topMargin)   // + the 28 pt title bar above: the traffic lights clear the plate's ring
            .padding(.horizontal, FaceplateFace.margin)
            .padding(.bottom, FaceplateFace.margin)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.helpMode, state.help)
        .helpTipLayer()
        // the desk runs up under the hidden title bar; SwiftUI adds the bar's 28 pt to the window
        .background(Theme.desk.edgesIgnoringSafeArea(.all))
    }

    private var findLit: Bool { Faceplate.isFindLit(picked, busy: state.busy) }
    private var capWidth: CGFloat { FaceplateFace.capWidth }

    // MARK: module: readout + rows

    /// The module on the plate itself (no extra panel box, F5): the LCD, 16, the three input rows
    /// 8 apart, 16 / rule / 16, the send row. One column grid: every cap on the right (DOWNLOAD,
    /// FIND, LISTEN, EXPORT MIDI) shares one x and one width; the two other send caps split the rest.
    private var module: some View {
        let gap = FaceplateFace.gridGap
        return VStack(spacing: 0) {
            LCD(state: state, actions: actions)
            HStack(spacing: gap) {
                LinkField(text: $url, focused: $fieldFocused, onSubmit: { actions.downloadPressed(state) })
                if state.needsLogin, let cap = Faceplate.loginCap(busy: state.busy) {
                    Button(action: actions.openLogin) {
                        SSLCapStyle.label(cap.label).lineLimit(1).fixedSize().frame(minWidth: capWidth - SSLCapStyle.sidePadding * 2)
                    }
                    .buttonStyle(SSLCapStyle(lit: cap.lit, height: Theme.H.lg))
                    .accessibility(label: Text(cap.label.capitalized))
                    .helpTip(HelpText.login)
                } else {
                    DownloadCap(state: state, action: { actions.downloadPressed(state) }).frame(width: capWidth)
                }
            }
            .overlay(downloadMenu, alignment: .topTrailing)
            // the menu draws over the rows below it (only while open: the paint order stays the window's)
            .zIndex(state.downloadMenu == nil ? 0 : 1)
            .padding(.top, Theme.S.l)
            if state.surface.showsFileControls { fileRow.padding(.top, Theme.S.s) } else {
                StatusStrip(status: state.status).padding(.top, Theme.S.s)
            }
            // the window keeps its size: HOLD and the reset key stay put, dim until Listen is on
            HStack(spacing: gap) {
                SourceField(source: state.source, level: state.level, listening: state.listening,
                            meterGap: 1, action: actions.pickSource)
                if state.surface.showsListen {
                    HStack(spacing: Pocket.transportGap) {
                        HoldCap(state: state, action: actions.toggleHold).frame(width: 72)
                        NewSongCap(lit: state.listening, keys: state.newSongKeys, action: actions.newSong)
                    }
                    ListenCap(state: state, action: actions.toggleListen).frame(width: capWidth)
                } else {
                    // a plug-in always listens to its track: NEW SONG only, in LISTEN's column
                    NewSongCap(lit: state.listening, keys: state.newSongKeys, action: actions.newSong)
                        .frame(width: capWidth, alignment: .trailing)
                }
            }
            .padding(.top, Theme.S.s)
            ModuleRule().padding(.vertical, Theme.S.l)
            HStack(spacing: gap) {
                SendDAWCap(state: state, padding: FaceplateFace.sendPadding, action: actions.sendDAW)
                    .frame(width: FaceplateFace.sendWidth)
                AutoTuneCap(state: state, padding: FaceplateFace.sendPadding, send: actions.sendAutoTune)
                    .frame(width: FaceplateFace.sendWidth)
                ExportMidiCap(state: state, action: actions.exportMidi, drag: actions.midiDrag).frame(width: capWidth)
            }
        }
    }

    /// The DOWNLOAD menu under the cap, when open (the plug-in's; FaceStatus.swift).
    @ViewBuilder private var downloadMenu: some View {
        if let m = state.downloadMenu {
            DownloadMenuPanel(menu: m, pick: actions.pickPlacement, dismiss: actions.closeDownloadMenu)
                .offset(y: Theme.H.lg + Theme.S.xs)
        }
    }

    /// The window's own second row: pick audio into the field, then read it.
    private var fileRow: some View {
        let gap = FaceplateFace.gridGap
        return HStack(spacing: gap) {
                AudioPickField(label: Faceplate.pickLabel(picked), focused: $pickFocused,
                               onOpen: files.openAudio, onSubmit: { findLit ? files.find() : files.openAudio() })
                    .helpTip(HelpText.openAudio)
                Button(action: files.find) { SSLCapStyle.label("FIND KEY/BPM").lineLimit(1).frame(maxWidth: .infinity) }
                    .buttonStyle(SSLCapStyle(lit: findLit, height: Theme.H.lg))
                    .frame(width: capWidth)
                    .accessibility(label: Text("Find key and BPM"))
                    .accessibility(hint: Text(findLit ? "Finds the BPM and key of the chosen audio" : "Open an audio file first"))
                    .helpTip(HelpText.findKey)
        }
    }

    // MARK: footer

    /// RECENT ▾ · SETTINGS · COLOR · REPORT · HELP, one chip each (FooterChip), 16 apart; ADVANCED on the right.
    /// REPORT is the house kit's Report button (Help > Send Report… is the same sheet), in the window's own chip look.
    private var footer: some View {
        HStack(spacing: Theme.S.l) {
            RecentLink(state: state, action: actions.showRecents)
            if state.surface.showsSettings {
                FooterChip(title: "SETTINGS", label: "Settings", action: actions.settings).helpTip(HelpText.settings)
            }
            ColorChip(on: state.colorOpen, action: actions.color)
            FooterChip(title: "REPORT", label: "Send a report", action: actions.report).helpTip(HelpText.report)
            HelpChip(on: state.help, action: actions.toggleHelp)
            Spacer(minLength: 0)
            AdvancedBox(on: state.advanced, action: actions.toggleAdvanced)
        }
        // clear of the corner screws, on the LCD's text edge
        .padding(.horizontal, Theme.S.lcd)
        .frame(height: Theme.H.xs)
    }
}

