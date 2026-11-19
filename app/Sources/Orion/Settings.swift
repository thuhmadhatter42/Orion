import AppKit
import SwiftUI

/// Beat Key › Settings… (⌘,): shortcuts (a door to Quick Keys), Open at Login, listening, display.
struct SettingsView: View {
    @ObservedObject var loginItem: LoginItemSettings
    @ObservedObject var live: LiveSettings
    @ObservedObject var display: DisplaySettings
    @ObservedObject var rename: RenameSettings
    @ObservedObject private var help = HelpSettings.shared
    /// Read before the first draw: a popup whose current choice isn't in its list draws blank.
    @State private var devices: [InputDevice] = InputDevice.all()

    var body: some View {
        Form {
            Section(header: Text("Display").font(.headline)) {
                Toggle("Advanced Mode", isOn: $display.advanced).helpTip(HelpText.advanced)
                Toggle("High Contrast Readout", isOn: $display.highContrast).helpTip(HelpText.settingsHighContrast)
            }
            Divider().padding(.vertical, 6)
            Section(header: Text("Listen").font(.headline)) {
                Picker("Listen to", selection: deviceBinding) {
                    if LiveSource.systemAvailable { Text("System Audio").tag("system") }
                    Text("Default Input").tag("default")
                    ForEach(devices) { d in Text(d.name).tag("uid:\(d.uid)") }
                    // chosen with Add App in the Listen menu; shown here so the picker isn't blank
                    if case .app(let id) = live.source {
                        Text(LiveSettings.name(of: live.source, devices: [])).tag("app:\(id)")
                    }
                }
                .helpTip(HelpText.settingsListenTo)
                if case .input(let uid, _) = live.source, !savedDeviceMissing {
                    let count = uid.flatMap { u in devices.first { $0.uid == u }?.channels } ?? 2
                    if count > 1 {
                        Picker("Channel", selection: channelBinding) {
                            Text("All channels").tag(0)
                            ForEach(1...count, id: \.self) { Text("Channel \($0)").tag($0) }
                        }
                        .helpTip(HelpText.settingsChannel)
                    }
                }
                Picker("Start over after", selection: $live.gap) {
                    ForEach(LiveSettings.gaps, id: \.self) { Text("\(Int($0)) s of silence").tag($0) }
                }
                .helpTip(HelpText.settingsStartOver)
            }
            .onAppear {
                devices = InputDevice.all()
                logFallback()
            }
            Divider().padding(.vertical, 6)
            Section(header: Text("File names").font(.headline)) {
                Picker("Add key + BPM", selection: Binding(
                    get: { rename.choice }, set: { rename.set($0, from: "Settings") })) {
                    Text("Ask me each time").tag(RenameChoice.ask)
                    Text("Always").tag(RenameChoice.always)
                    Text("Never").tag(RenameChoice.never)
                }
                .helpTip(HelpText.settingsRename)
            }
            Divider().padding(.vertical, 6)
            Section(header: Text("General").font(.headline)) {
                Toggle("Open at Login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
                    .helpTip(HelpText.settingsOpenAtLogin)
                if let m = loginItem.message {
                    HStack {
                        Text(m).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        if loginItem.canOpenSystemSettings {
                            Button("Open System Settings") { loginItem.openSystemSettings() }
                        }
                    }
                }
            }
            .onAppear { loginItem.refresh() }
            Divider().padding(.vertical, 6)
            Section(header: Text("Shortcuts").font(.headline)) {
                // ONE list: Quick Keys (⇧⌃K) holds every shortcut, the system-wide ones included.
                Button("Open Quick Keys (\(QuickKeys.tipDisplay(QuickKeys.quickKeysID)))") { QuickKeys.openFromElsewhere() }
                    .helpTip(HelpText.settingsShortcuts)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Help Mode explains these controls too (the amber card, drawn above the form)
        .environment(\.palette, Palette(accent: AccentSettings.shared.effective, highContrast: display.highContrast))
        .environment(\.helpMode, help.isOn)
        .helpTipLayer()
    }

    /// The saved device isn't in the list (unplugged, renamed, lookup failed): Listen opens Mac
    /// audio instead (LiveSourcePlan.afterLoss), so the popup shows that, never blank. The saved
    /// choice stays until J picks something.
    private var savedDeviceMissing: Bool {
        if case .input(let uid?, _) = live.source { return !devices.contains { $0.uid == uid } }
        return false
    }

    private func logFallback() {
        if savedDeviceMissing {
            AppLog.log("settings: saved listen device not found (\(devices.count) inputs listed); popup shows \(LiveSource.systemAvailable ? "System Audio" : "Default Input")")
        }
    }

    /// "system" | "default" | "uid:<device uid>" | "app:<id>"; a new device starts on all channels.
    private var deviceBinding: Binding<String> {
        Binding(get: {
            switch live.source {
            case .system: return "system"
            case .input(nil, _): return "default"
            case .input(let uid?, _):
                if savedDeviceMissing { return LiveSource.systemAvailable ? "system" : "default" }
                return "uid:\(uid)"
            case .app(let id): return "app:\(id)"
            }
        }, set: { tag in
            if tag.hasPrefix("app:") { return }   // the current app choice re-selected: nothing to change
            if tag == "system" { live.source = .system }
            else if tag == "default" { live.source = .input(uid: nil, channel: 0) }
            else { live.source = .input(uid: String(tag.dropFirst(4)), channel: 0) }
        })
    }

    private var channelBinding: Binding<Int> {
        Binding(get: {
            if case .input(_, let ch) = live.source { return ch }
            return 0
        }, set: { ch in
            if case .input(let uid, _) = live.source { live.source = .input(uid: uid, channel: ch) }
        })
    }
}

/// How the window looks, remembered between launches: High Contrast Readout (Settings and the
/// View menu; the one owner: each surface's root puts it in the environment as `\.palette`,
/// View.paletteRoot), Advanced Mode (View › Advanced Mode ⌥⌘A and Settings) and Advanced mode's own choices (chord quality, voicing, length, the MATCH TO
/// key). Views that observe this object redraw when any of them changes.
final class DisplaySettings: ObservableObject {
    static let key = "highContrast"
    /// The window's Advanced mode (the key from before the pocket had one).
    static let advancedKey = "advancedMode"
    /// The menu-bar pocket's Advanced mode; a first run copies the window's (`advancedMode`).
    static let pocketAdvancedKey = "pocketAdvancedMode"
    static let matchKeyKey = "matchToKey"
    static let qualityKey = "chordQuality"
    static let voicingKey = "chordVoicing"
    static let barsKey = "chordBars"
    private let defaults: UserDefaults

    @Published var highContrast: Bool {
        didSet {
            defaults.set(highContrast, forKey: DisplaySettings.key)
        }
    }

    /// The window's Advanced mode: the window grows a harmony column (Camelot, chords, MATCH TO,
    /// the key wheel, notes heard). Off = the default, minimal window. Its footer box, View ›
    /// Advanced Mode (⌥⌘A) and Settings › Display all set this one.
    @Published var advanced: Bool {
        didSet {
            guard advanced != oldValue else { return }
            defaults.set(advanced, forKey: DisplaySettings.advancedKey)
            AppLog.log("advanced mode (window) \(advanced ? "on" : "off")")
            linkFirstChange(window: true)
        }
    }

    /// The menu-bar pocket's Advanced mode: the harmony pieces under its usual content.
    @Published var pocketAdvanced: Bool {
        didSet {
            guard pocketAdvanced != oldValue else { return }
            defaults.set(pocketAdvanced, forKey: DisplaySettings.pocketAdvancedKey)
            AppLog.log("advanced mode (menu bar) \(pocketAdvanced ? "on" : "off")")
            linkFirstChange(window: false)
        }
    }

    /// J 2026-11-09: "first change per launch affects both the window and menu bar, second change
    /// only affects where it was clicked". False until the first change this launch (a new
    /// DisplaySettings each launch starts it over).
    private(set) var advancedLinkUsed = false

    private func linkFirstChange(window: Bool) {
        guard !advancedLinkUsed else { return }
        advancedLinkUsed = true            // before the copy: the other side's didSet must not link back
        if window { pocketAdvanced = advanced } else { advanced = pocketAdvanced }
        AppLog.log("advanced mode: first change this launch, window and menu bar both \(advanced ? "on" : "off")")
    }

    /// The project's key MATCH TO compares against ("Eb", "F#m"); nil = none picked.
    @Published var matchKey: String? {
        didSet {
            if let k = matchKey { defaults.set(k, forKey: DisplaySettings.matchKeyKey) }
            else { defaults.removeObject(forKey: DisplaySettings.matchKeyKey) }
        }
    }

    @Published var chordQuality: ChordQuality {
        didSet { defaults.set(chordQuality.rawValue, forKey: DisplaySettings.qualityKey) }
    }

    @Published var chordVoicing: Voicing {
        didSet { defaults.set(chordVoicing.rawValue, forKey: DisplaySettings.voicingKey) }
    }

    /// 1, 2 or 4 bars (ChordClip.barChoices).
    @Published var chordBars: Int {
        didSet {
            if !ChordClip.barChoices.contains(chordBars) { chordBars = 1; return }
            defaults.set(chordBars, forKey: DisplaySettings.barsKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        highContrast = defaults.bool(forKey: DisplaySettings.key)
        advanced = defaults.bool(forKey: DisplaySettings.advancedKey)
        // migrate: a first run of this version starts the pocket as the window was
        let migrate = defaults.object(forKey: DisplaySettings.pocketAdvancedKey) == nil
        let pocket = migrate ? defaults.bool(forKey: DisplaySettings.advancedKey)
                             : defaults.bool(forKey: DisplaySettings.pocketAdvancedKey)
        pocketAdvanced = pocket
        if migrate {
            defaults.set(pocket, forKey: DisplaySettings.pocketAdvancedKey)
            AppLog.log("advanced mode: menu bar setting created from the window's (\(pocket ? "on" : "off"))")
        }
        matchKey = defaults.string(forKey: DisplaySettings.matchKeyKey).flatMap { AutoTuneSend.keyClass($0) == nil ? nil : $0 }
        chordQuality = defaults.string(forKey: DisplaySettings.qualityKey).flatMap(ChordQuality.init(rawValue:)) ?? .triad
        chordVoicing = defaults.string(forKey: DisplaySettings.voicingKey).flatMap(Voicing.init(rawValue:)) ?? .root
        let bars = defaults.integer(forKey: DisplaySettings.barsKey)
        chordBars = ChordClip.barChoices.contains(bars) ? bars : 1
    }
}

/// Opens the Settings window from outside the app menu (the menu-bar item). The SwiftUI
/// selectors changed name between macOS releases, so the app menu's own ⌘, item is clicked.
enum SettingsOpener {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let i = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { NSSound.beep(); return }
        appMenu.performActionForItem(at: i)
    }
}
