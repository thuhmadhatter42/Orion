import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The whole window: observes the app's objects and hands FaceplateFace plain values (the
/// popover's PocketState and PocketActions: one state source, one wiring for both surfaces).
struct FaceplateView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var model: FaceplateModel
    @ObservedObject var login: YouTubeSession
    @ObservedObject var tuning: TuningSettings
    @ObservedObject var live: LiveController
    @ObservedObject var display: DisplaySettings
    @ObservedObject var recents: RecentStore
    @ObservedObject var shortcuts: ShortcutStore
    @ObservedObject var extras: PocketExtras
    /// PocketActions.wired: the popover's controls, wired the same way.
    let actions: PocketActions
    @ObservedObject private var spelling = SpellingSettings.shared
    @ObservedObject private var watcher = DAWWatcher.shared
    @ObservedObject private var help = HelpSettings.shared
    @ObservedObject private var mini = MiniController.shared
    @ObservedObject private var accent = AccentSettings.shared
    @State private var keyMonitor: Any?
    @State private var pasteboardCount = NSPasteboard.general.changeCount
    private let clipboardTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        FaceplateFace(state: state, picked: model.picked, url: $model.url, fieldFocused: $model.fieldFocused,
                      pickFocused: $model.pickFocused, actions: windowActions,
                      files: FaceplateFace.FileActions(openAudio: openAudio, find: find))
        // the display colour and High Contrast, from their one owner each, for every view below
        .paletteRoot(display: display)
        .environment(\.liveLevel, live.meter)   // the meter ticks on its own (LiveLevel)
        .acceptsFileDrops(via: "window", isTargeted: dropBinding)
        .onReceive(engine.$state) { s in
            // a download, an analysis, Run Doctor or a recent reading takes the LCD back from Listen
            if s != .idle && live.state != .off { live.stop(reason: "the LCD went to \(LiveController.engineLabel(s))") }
            switch s {
            case .done: model.url = ""; model.tempoFactor = .one
            case .analyzed(let rs): model.pager.reset(count: rs.count); model.picked = []; model.tempoFactor = .one
            default: break
            }
            login.refresh()   // a stale login was just dropped, or a new one saved
        }
        .onReceive(model.$url) { u in
            // changing the link drops a pending login prompt (it belongs to the old link)
            let t = u.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .needsLogin(let p) = engine.state, t != p.url { engine.clearLogin() }
        }
        .onReceive(model.$pager) { _ in model.tempoFactor = .one }   // each file reads at x1
        // the clipboard line and the source name: on show, on coming to the front, on a new copy
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            extras.refresh(live: live)
        }
        .onReceive(clipboardTick) { _ in
            let n = NSPasteboard.general.changeCount
            if n != pasteboardCount { pasteboardCount = n; extras.refresh(live: live) }
        }
        .onAppear { extras.refresh(live: live) }
        .onAppear(perform: installKeys)
        .onAppear(perform: installIntake)
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) }; Intake.handler = nil }
    }

    // MARK: derived state

    /// The popover's state (PocketState.make), with the window's drag-hover readout.
    private var state: PocketState {
        var s = PocketState.make(engine: engine, model: model, live: live, tuning: tuning, recents: recents,
                                 display: display, shortcuts: shortcuts, extras: extras, spelling: spelling,
                                 daw: watcher.target?.name)
        s.dropTargeted = showDrop
        s.miniOpen = mini.isOpen
        s.colorOpen = accent.panelOpen
        return s
    }

    /// The shared wiring; the window runs the YouTube login itself (the popover sends it here)
    /// and its own Advanced mode switch (the harmony wiring is shared with the pocket).
    private var windowActions: PocketActions {
        var a = actions
        a.openLogin = openLogin
        let (e, m, l, d) = (engine, model, live, display)
        a.wireHarmony(surface: "window", engine: e, model: m, live: l, display: d)
        a.toggleAdvanced = { d.advanced.toggle() }   // the window's box = ⌥⌘A = Settings › Display
        return a
    }

    private var loginPrompt: LoginPrompt? { Faceplate.loginPrompt(engine.state, url: model.url) }
    private var findLit: Bool { Faceplate.isFindLit(model.picked, busy: engine.state.isBusy) }
    private var showDrop: Bool { model.pinnedDrop || model.dropTargeted }   // a drop while busy is queued, so it shows too

    private var dropBinding: Binding<Bool> {
        Binding(get: { model.dropTargeted }, set: { model.dropTargeted = $0 })
    }

    // MARK: actions

    /// LOG IN TO YOUTUBE: Beat Key's own login window. Once it has the login, the same link runs
    /// again with it (if that link is still the one waiting).
    private func openLogin() {
        guard let p = loginPrompt, !engine.state.isBusy, YouTubeLogin.inApp else { return }
        AppLog.log("window: log in to YouTube")
        LoginWindow.open(saving: login.file) { [engine, model, login] in
            login.refresh()
            guard Faceplate.loginPrompt(engine.state, url: model.url)?.url == p.url else { return }
            model.lastAction = .download
            engine.download(p.url, useLogin: true)
        }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// The audio-only open panel (the drop filter's allowlist), several files allowed.
    private func openAudio() {
        guard !engine.state.isBusy else { return }
        AppLog.log("window: open audio")
        let panel = Intake.makePanel()
        let pick = { (resp: NSApplication.ModalResponse) in
            guard resp == .OK else { return }
            let files = Faceplate.audioFiles(panel.urls)
            if !files.isEmpty { model.picked = files }
        }
        if let w = NSApp.keyWindow ?? NSApp.windows.first { panel.beginSheetModal(for: w, completionHandler: pick) }
        else { pick(panel.runModal()) }
    }

    /// Every drop, Open With, the Dock icon, the Finder service and Analyze a File… arrive here
    /// (Intake.receive) and join the Engine's queue: read now when idle, after the running job when busy.
    private func installIntake() {
        Intake.handler = { [engine, model] files in
            model.lastAction = .analyze
            engine.submit(files)
            return true
        }
    }

    private func find() {
        guard findLit else { return }
        AppLog.log("window: find key/bpm (\(model.picked.count) files)")
        model.lastAction = .analyze
        engine.analyze(model.picked)
    }

    /// Left/right arrows page through several dropped files (unless the caret is in a link).
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 123 || e.keyCode == 124, case .analyzed = engine.state,
                  model.pager.count > 1 else { return e }
            if let tv = e.window?.firstResponder as? NSTextView, !tv.string.isEmpty { return e }
            if e.keyCode == 123 { model.pager.previous() } else { model.pager.next() }
            return nil
        }
    }
}

extension Faceplate {
    /// What the readout shows for the engine and Listen: one derivation for the window's LCD and
    /// the menu-bar popover. Listen's reading wins while it is on; else the engine's state.
    static func readout(_ state: ViewState, live: LiveState, liveSource: String, page: Pager,
                        factor: TempoFactor, lastAction: LastAction, note: String?, reference: Double,
                        onCycleTempo: (() -> Void)?, held: Bool = false, liveNotice: String? = nil) -> Readout {
        if let l = liveReadout(live, source: liveSource, factor: factor, onCycleTempo: onCycleTempo, held: held,
                               reference: reference, notice: liveNotice) { return l }
        let dl = lastAction == .download
        func options(_ r: Result) -> ResultOptions {
            ResultOptions(factor: factor, tuning: Tuning.meter(r.tuningCents, reference: reference),
                          onCycleTempo: onCycleTempo)
        }
        switch state {
        case .idle: return .idle
        case .working(let s): return .working(stage: s, download: dl)
        case .doctor(let r): return .doctor(r)
        case .done(let r0):
            let r = r0.respelled()
            return .result(r, page: nil, download: true, options: options(r))
        case .analyzed(let rs):
            guard !rs.isEmpty else { return .idle }
            let i = min(page.index, rs.count - 1)
            let r = rs[i].respelled()
            return .result(r, page: page.caption, download: false, note: note, options: options(r))
        case .failed(let m): return .error(m, download: dl)
        case .needsLogin(let p):
            let (a, b) = loginLines(p)
            return .login(a, b, caption: nil)
        }
    }
}
