import AppKit
import SwiftUI

@main
struct OrionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var login: YouTubeSession
    @StateObject private var engine: Engine
    @StateObject private var model = FaceplateModel()
    @StateObject private var updater: AppUpdater
    @StateObject private var tuning = TuningSettings()
    @StateObject private var recents: RecentStore
    @StateObject private var shortcuts = ShortcutStore()
    @StateObject private var loginItem = LoginItemSettings()
    @StateObject private var display = DisplaySettings()
    @StateObject private var rename = RenameSettings()
    @StateObject private var spelling = SpellingSettings.shared
    @StateObject private var help = HelpSettings.shared
    /// The clipboard link and the source name, shared by the window and the popover.
    @StateObject private var extras = PocketExtras()
    @StateObject private var live = LiveController(settings: LiveSettings(),
                                                   launch: CoreLive.launcher())

    init() {
        let session = YouTubeSession()
        let updater = AppUpdater()
        let recents = RecentStore()
        _login = StateObject(wrappedValue: session)
        _updater = StateObject(wrappedValue: updater)
        _recents = StateObject(wrappedValue: recents)
        _engine = StateObject(wrappedValue: Engine(downloadsProbe: Engine.defaultProbe(),
                                                   savedLogin: { session.savedLogin },
                                                   dropLogin: { session.file.delete() },
                                                   afterDoctor: { updater.checkForUpdates() },
                                                   recents: recents))
    }

    var body: some Scene {
        WindowGroup {
            FaceplateView(engine: engine, model: model, login: login, tuning: tuning, live: live, display: display,
                          recents: recents, shortcuts: shortcuts, extras: extras, actions: windowActions)
                .background(WindowConfigurator())
                .quickKeysSheet()    // house kit: Quick Keys (⇧⌃K), Send Report…, Uninstall: each is a sheet of the window
                .reportSheet(extra: Self.reportFacts)
                .uninstallSheet(what: "Beat Key and the tools it downloaded")
                .onAppear(perform: launch)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        // one window: opened files (Dock, Open With, `open -a`) go to the app delegate's
        // application(_:open:) → Intake.receive, never to a new copy of this scene
        // (0.1.75 on Studio D stacked a new window per open, 2026-11-18)
        .handlesExternalEvents(matching: [])
        .commands {
            // one window: no File > New; the File menu is for reading files instead
            CommandGroup(replacing: .newItem) {
                Button("Analyze a File…") { Intake.analyzeAFile() }
                    .quickKey("analyzeFile")
                    .disabled(engine.state.isBusy)
                Menu("Recent Readings") {
                    ForEach(Array(recents.readings.enumerated()), id: \.offset) { _, r in
                        Button(r.title) { showAgain(r) }.disabled(engine.state.isBusy)
                    }
                    Divider()
                    Button("Clear Menu") { recents.clear() }
                }
                .disabled(recents.readings.isEmpty)
                ExportMidiMenuItem(engine: engine)
            }
            CommandMenu("Reading") {
                Button(live.state.isActive ? "Stop Listening" : "Start Listening") { toggleListening() }   // the computed closure, run now
                    .quickKey("listen")
                    .disabled(engine.state.isBusy && !live.state.isActive)
                Button("New Song (Reset Listening)") { newSong() }
                    .quickKey("newSong")
                    .disabled(!live.state.isActive)
                Toggle("Hold Reading", isOn: Binding(get: { live.isHeld }, set: { _ in toggleHold() }))
                    .quickKey("hold")
                    .disabled(!live.isHeld && !(live.state.isActive && live.state.result != nil))
                Divider()
                Menu("Reference Pitch") {
                    ForEach(Tuning.presets, id: \.self) { hz in
                        Toggle("A = \(Tuning.refText(hz)) Hz", isOn: referenceBinding(hz))
                    }
                    Divider()
                    if !Tuning.presets.contains(tuning.reference) {
                        Toggle("Custom: A = \(Tuning.refText(tuning.reference)) Hz", isOn: referenceBinding(tuning.reference))
                    }
                    Button("Custom…") { if let hz = ReferencePrompt.ask(current: tuning.reference) { tuning.reference = hz } }
                }
                SendToAutoTuneMenuItem(engine: engine, tuning: tuning)
                Button("Half / Double Tempo") { model.tempoFactor = model.tempoFactor.next }
                DAWSendMenuItems(engine: engine, shortcuts: shortcuts)
            }
            // View menu: Advanced Mode (orra-parity §2.1) and the readout's accessibility switch (plan 5.1)
            CommandGroup(before: .toolbar) {
                Toggle("Advanced Mode", isOn: $display.advanced)
                    .quickKey("advancedMode")
                Toggle("High Contrast Readout", isOn: $display.highContrast)
            }
            // Help menu: the in-app Help window (⌘?) and the HELP chip's switch (no shortcut:
            // ⌥⌘H is Hide Others). Replaces the system's "Beat Key Help" item, which had no help book.
            CommandGroup(replacing: .help) {
                Button(Brand.help) { HelpWindow.shared.open(why: "menu") }
                    .keyboardShortcut("?", modifiers: .command)
                // House kit, help-menu: the bundled pages (HelpPages.swift); a missing one is logged + alerted
                Button("Manual") { HouseHelp.open(HouseHelp.manual) }
                Button("What's New") { HouseHelp.open(HouseHelp.whatsNew) }
                Divider()
                Toggle("Help Mode", isOn: $help.isOn)
            }
            // House kit: App > Quick Keys (⇧⌃K) and Uninstall Beat Key…, Help > Send Report…
            QuickKeysCommands()
            UninstallCommands()
            ReportCommands()
            // The app menu says Beat Key whatever the process is called (swift run = "Orion").
            CommandGroup(replacing: .appInfo) {
                Button(Brand.about) {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: Brand.name])
                }
                CheckForUpdatesButton(updater: updater)
                Button(Brand.runDoctor) { engine.runDoctor() }
                    .disabled(engine.state.isBusy)
                Button(Brand.setUpPermissions) { PermissionGuide.shared.open(at: nil, why: "menu") }
                Button(Brand.licenses) { HouseHelp.open(HouseHelp.licenses) }
                if login.loggedIn && YouTubeLogin.inApp {
                    Button("Log Out of YouTube") { login.logOut() }
                        .disabled(engine.state.isBusy)
                }
            }
            CommandGroup(replacing: .appVisibility) {
                Button(Brand.hide) { NSApp.hide(nil) }.keyboardShortcut("h")
                Button("Hide Others") { NSApp.hideOtherApplications(nil) }.keyboardShortcut("h", modifiers: [.command, .option])
                Button("Show All") { NSApp.unhideAllApplications(nil) }
            }
            CommandGroup(replacing: .appTermination) {
                Button(Brand.quit) { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        Settings {
            SettingsView(loginItem: loginItem, live: live.settings, display: display, rename: rename)
        }
    }

    /// App facts in every Report (the log has the rest): what Beat Key was listening to and the DAW it saw.
    private static func reportFacts() -> [String] {
        ["Architecture: \(Runtime.detectArch())"]
    }

    /// Reading › Start / Stop Listening, the global shortcut and the menu-bar item. Not while a
    /// download or an analysis is running (the LCD belongs to it).
    private static func toggleListening(live: LiveController, engine: Engine, model: FaceplateModel) {
        if !live.state.isActive && engine.state.isBusy { NSSound.beep(); return }
        live.toggle()   // the song starts or ends: the tempo factor follows it (FaceplateModel.follow)
    }

    /// The objects themselves, captured (not the App struct's wrappers), for callers outside a view update.
    private var toggleListening: () -> Void {
        let (l, e, m) = (live, engine, model)
        return { OrionApp.toggleListening(live: l, engine: e, model: m) }
    }

    /// Reading › New Song, its global shortcut, the menu-bar menu and the popover: Listen drops
    /// what it heard and its lock, and starts over on the same source. A new song: a picked key
    /// and the tempo factor belong to the old one (LiveSession.song).
    private var newSong: () -> Void {
        let l = live
        return {
            guard l.state.isActive else { NSSound.beep(); return }
            l.reset()
        }
    }

    /// Reading › Hold Reading, its global shortcut, the menu-bar menu and the popover's HOLD key: a
    /// button, never automatic. Holds the reading on show (listening carries on); again to follow
    /// the music. Nothing to hold yet = a beep.
    private var toggleHold: () -> Void {
        let l = live
        return { if !l.toggleHold() { NSSound.beep() } }
    }

    /// The window's controls: the popover's own wiring (PocketActions.wired), one mechanism for both.
    private var windowActions: PocketActions {
        let (e, m) = (engine, model)
        return PocketActions.wired(surface: "window", engine: engine, model: model, live: live, tuning: tuning,
                                   recents: recents, extras: extras, toggleListening: toggleListening,
                                   newSong: newSong, toggleHold: toggleHold,
                                   showAgain: { OrionApp.showAgain($0, engine: e, model: m) })
    }

    /// After a file is read: ask (or follow the remembered choice) about adding key + BPM to its name.
    /// The tag carries the BPM as shown, so a half / double tempo on the page on show counts.
    private func wireRename() {
        let (e, m) = (engine, model)
        let coordinator = RenameCoordinator(
            settings: rename, asker: RenamePrompt(),
            item: { r in
                var factor = TempoFactor.one
                if case .analyzed(let rs) = e.state, !rs.isEmpty, rs[min(max(m.pager.index, 0), rs.count - 1)].file == r.file {
                    factor = m.tempoFactor
                }
                return RenameItem.make(r, choice: SpellingSettings.shared.manualKey, factor: factor)
            },
            perform: { [weak e] in e?.rename($0) })
        engine.afterAnalysis = { coordinator.offer($0) }
    }

    /// A checkmark row that sets the reference pitch to `hz`.
    private func referenceBinding(_ hz: Double) -> Binding<Bool> {
        Binding(get: { tuning.reference == hz }, set: { _ in tuning.reference = hz })
    }

    /// File › Recent Readings: put an earlier reading back on the LCD.
    private func showAgain(_ r: Reading) { OrionApp.showAgain(r, engine: engine, model: model) }

    /// One path for File › Recent Readings and the popover's RECENT list.
    static func showAgain(_ r: Reading, engine: Engine, model: FaceplateModel) {
        guard !engine.state.isBusy else { NSSound.beep(); return }
        model.lastAction = .analyze
        engine.show(r.result)
    }

    private func launch() {
        // The shared code (BeatKeyShared: the Auto-Tune hand-off, ...) logs into beatkey.log.
        SharedLog.sink = { tag, line in AppLog.log(line, file: tag) }
        wireRename()
        live.songs.recents = recents   // each live song its own Recent Readings entry
        model.follow(live)             // each live song reads at x1
        HelpText.checkAtLaunch()
        let accent = AccentSettings.shared   // the saved display colour (its one owner loads it once)
        if accent.picked != .amber { AppLog.log("accent: \(accent.picked.described) restored") }
        let env = ProcessInfo.processInfo.environment
        if let fake = env["ORION_FAKE_STATE"], !fake.isEmpty {
            FakeState.apply(fake, engine: engine, model: model)
            if fake != "idle" {   // the mockup shows the field unfocused in every other state
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApp.windows.forEach { $0.makeFirstResponder(nil) }
                }
            }
            // ORION_FAKE_FLIP_MODE=1: Advanced Mode flips at 2 s and back at 5 s (screenshots of
            // the window resizing between modes, no clicks needed); the saved setting ends as it was.
            if env["ORION_FAKE_FLIP_MODE"] == "1" {
                let d = display
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { d.advanced.toggle() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { d.advanced.toggle() }
            }
            if fake == "login-window" {   // the window LOG IN TO YOUTUBE opens (videos); saves nowhere real
                let scratch = CookieFile(url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("orion-fake-\(CookieFile.fileName)"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    LoginWindow.open(saving: scratch) { scratch.delete() }
                }
            }
            return
        }
        // Debug: open the real login window straight away (a login test). Saves the real cookie file.
        if env["ORION_OPEN_LOGIN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [login] in
                LoginLog.write("login window opened (ORION_OPEN_LOGIN)")
                LoginWindow.open(saving: login.file) { login.refresh() }
            }
        }
        // The menu-bar readout ("Ebm 128" + lamp) follows the LCD from here on.
        let (e, m) = (engine, model)
        StatusItemController.shared.install(engine: engine, model: model, live: live, tuning: tuning,
                                            recents: recents, display: display, shortcuts: shortcuts,
                                            extras: extras, toggleListening: toggleListening, newSong: newSong, toggleHold: toggleHold,
                                            showAgain: { OrionApp.showAgain($0, engine: e, model: m) })
        // Global shortcuts (Settings › Global shortcuts), live in every app.
        HotkeyCenter.shared.actions[.listen] = toggleListening
        HotkeyCenter.shared.actions[.newSong] = newSong
        HotkeyCenter.shared.actions[.hold] = toggleHold
        HotkeyCenter.shared.actions[.analyzeFile] = {
            StatusItemController.bringWindowForward()
            Intake.analyzeAFile()
        }
        HotkeyCenter.shared.actions[.analyzeSelection] = { DAWSendController.analyzeSelection() }
        shortcuts.keepRegistered()   // registers the system-wide rows of Quick Keys, and again after every rebind
        // Play to find the key (the computer keyboard as a piano) + ⇧⌘A, while Beat Key is in front.
        let l = live
        PlayToFind.shared.install(shown: { PocketState.shown(e.state, live: l.state, page: m.pager) },
                                  sendAutoTune: windowActions.sendAutoTune)
        // Tell Artemis (and answer its "what is the key now?") what the app shows: Broadcast.swift.
        Broadcast.shared.install(engine: engine, model: model, live: live)
        // SEND BPM from the plug-in: the app sends the tempo for it (PluginSendListener.swift).
        PluginSendListener.shared.install()
        // Is this the latest version? One Sparkle background check per launch (the same updater as
        // Check for Updates…); it only shows a window when a newer Beat Key exists.
        updater.checkInBackgroundAtLaunch()
        // Seed yt-dlp into Application Support, then the weekly self-update, on the shared
        // maintenance queue. The Engine stays idle; downloads and Run Doctor wait their turn.
        Runtime.appDefault().launchMaintenance()
        // Permissions Beat Key needs and doesn't have: the walkthrough, once the window is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { PermissionGuide.shared.openAtLaunch() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ n: Notification) {
        AppLog.launched()
        TwinCheck.run()   // another Beat Key already running: take over from it, or yield to a newer one
        // Finder › Services › Analyze with Beat Key. Registered under the NSPortName in Info.plist,
        // and as the default provider, so the name does not have to match the process name.
        NSRegisterServicesProvider(services, Brand.name)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        // `swift run` has no bundle: make it a regular, frontmost app all the same.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        HelpMenuItem.shared.install()   // Help > Beat Key Help: AppKit's own item (showHelp:, key ?, Command)
    }
    /// Files dropped on the Dock icon, Open With, `open -a "Beat Key" file` (the Info.plist's
    /// CFBundleDocumentTypes make the Dock icon accept them).
    func application(_ app: NSApplication, open urls: [URL]) { Intake.receive(urls, via: "dock") }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) {
        MiniController.shared.shutdown()   // every Mini note-on gets its note-off before the port goes
        AppLog.quitting("app quit")
    }
}

/// The window tweaks SwiftUI on macOS 11 cannot express: fixed size, dragged by its plate,
/// dark title area, no tabs.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.styleMask.remove(.resizable)
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(srgbRed: 8 / 255, green: 8 / 255, blue: 10 / 255, alpha: 1)
            w.appearance = NSAppearance(named: .darkAqua)
            w.tabbingMode = .disallowed
            w.collectionBehavior.insert(.fullScreenNone)
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            w.title = Brand.name
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Reading › Reference Pitch › Custom…: a number from 400 to 480 Hz.
enum ReferencePrompt {
    static func ask(current: Double) -> Double? {
        let alert = NSAlert()
        alert.messageText = "Reference pitch"
        alert.informativeText = "The A that tuning is measured against, \(Int(Tuning.range.lowerBound)) to \(Int(Tuning.range.upperBound)) Hz."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = Tuning.refText(current)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if let hz = Tuning.parse(field.stringValue) { return hz }
            alert.informativeText = "Enter a number from \(Int(Tuning.range.lowerBound)) to \(Int(Tuning.range.upperBound)), for example 432."
        }
        return nil
    }
}
