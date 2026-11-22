import AppKit
import SwiftUI

// The app's half of Help (the face's tips are Face/Help.swift): help mode's saved switch, the tips for
// the app's own windows (Settings, the permissions guide, Doctor, shortcuts) and the help window's table.

/// Help mode on / off, remembered between launches (UserDefaults `helpMode`, default off).
final class HelpSettings: ObservableObject {
    static let key = "helpMode"
    static let shared = HelpSettings()
    private let defaults: UserDefaults

    @Published var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            defaults.set(isOn, forKey: HelpSettings.key)
            AppLog.log("help mode \(isOn ? "on" : "off")")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let v = defaults.object(forKey: HelpSettings.key), !(v is Bool) && !(v is NSNumber) {
            AppLog.log("help mode: stored value is not a switch; starting off")
            defaults.removeObject(forKey: HelpSettings.key)
        }
        isOn = defaults.bool(forKey: HelpSettings.key)
    }

    /// The HELP chip (window or pocket) or the View menu.
    func toggle(from place: String) {
        AppLog.log("help mode toggled from \(place)")
        isOn.toggle()
    }
}

extension HelpText {
    /// A Quick Keys row's shortcut for a tip, "" when the row has none (so the tip shows words alone).
    static func keys(_ id: String) -> String {
        let d = QuickKeys.tipDisplay(id)
        return d == "no shortcut" ? "" : d
    }

    // Settings (the Settings window)
    static let settingsHighContrast = HelpTip(title: "HIGH CONTRAST", body: "Brighter text, no glow.")
    static let settingsListenTo = HelpTip(title: "LISTEN TO", body: "Where LISTEN hears from: System Audio, an input or an app.")
    static let settingsChannel = HelpTip(title: "CHANNEL", body: "Interface channel to read, or all.")
    static let settingsStartOver = HelpTip(title: "START OVER AFTER", body: "Silence length that ends a song.")
    static let settingsRename = HelpTip(title: "FILE NAMES", body: "Add key + BPM to names. Pro Tools session files: asks first.")
    static let settingsOpenAtLogin = HelpTip(title: "OPEN AT LOGIN", body: "Start Beat Key at login.")
    static let settingsShortcuts = HelpTip(title: "SHORTCUTS", body: "Quick Keys: every shortcut. Click one, type new keys.")

    // Permissions guide
    static let permissionGuide = HelpTip(title: "SET UP PERMISSIONS", body: "Walks you through each Mac permission Beat Key needs.")
    /// One line per permission (the guide window's own longer text is PermissionKind.why).
    static func permission(_ k: PermissionKind) -> HelpTip {
        let body: String
        switch k {
        case .screen: body = "Hear Mac audio. Allow Beat Key in System Settings."
        case .microphone: body = "Hear a mic or interface. Allow Beat Key in System Settings."
        case .accessibility: body = "Type BPM/key in your DAW. Allow Beat Key in System Settings."
        }
        return HelpTip(title: k.title.uppercased(), body: body)
    }
    static let permissionScreen = permission(.screen)
    static let permissionMicrophone = permission(.microphone)
    static let permissionAccessibility = permission(.accessibility)

    // Doctor
    static let runDoctor = HelpTip(title: "RUN DOCTOR", body: "Check and repair downloader, ffmpeg, analyzer.")

    // Keys and shortcuts
    static let keysOctave = HelpTip(title: "OCTAVE · Z X", body: "Z octave down, X up. Link field empty.")
    static let keysMode = HelpTip(title: "MAJOR / MINOR · SPACE", body: "Space flips the keyboard major/minor.")
    static let keysPaging = HelpTip(title: "PAGE FILES · ← →", body: "Arrows page files. Link field empty.")
    static let keysAutoTune = HelpTip(title: "AUTO-TUNE SHORTCUT", body: withKeys("Send key to Auto-Tune", keys("sendAutoTune")))
    static let keysAdvanced = HelpTip(title: "ADVANCED SHORTCUT", body: "Advanced on/off (\(QuickKeys.tipDisplay("advancedMode")))")
    static let keysHelp = HelpTip(title: "HELP WINDOW · ⌘?", body: "Help › Beat Key Help. Help Mode: hover tips.")

    /// The help window's contents, in order. THE one list: the window draws it, the launch check
    /// and the tests read it, and `all` is made from it, so a tip cannot be missing from the window.
    static let sections: [HelpSection] = [
        HelpSection(title: "Window and pocket: the readout",
                    tips: [readout, bpm, tempoFactor, keyDial, confidence, topKeys, manual, manualReset, keyboard, scale,
                           tuning, camelot, fileLine, showInFinder, prevFile, nextFile, status]),
        HelpSection(title: "Window and pocket: getting audio in",
                    tips: [linkField, download, login, openAudio, findKey, source, listen, hold, reset]),
        HelpSection(title: "Window and pocket: sending", tips: [sendDAW, autoTune, exportMidi]),
        HelpSection(title: "Menu bar pocket only", tips: [dropZone, openWindow]),
        HelpSection(title: "Footer", tips: [recent, settings, color, report, advanced, help]),
        HelpSection(title: "Advanced mode",
                    tips: [pitchToFit, keyWheel, notesHeard, chords, quality, voicing, bars, borrowed, matchTo, matchShift, mini]),
        HelpSection(title: "Beat Key Mini", tips: [miniPanel, miniSound]),
        HelpSection(title: "Settings",
                    tips: [settingsHighContrast, settingsListenTo, settingsChannel, settingsStartOver, settingsRename, settingsOpenAtLogin,
                           settingsShortcuts]),
        HelpSection(title: "Permissions guide",
                    tips: [permissionGuide, permissionScreen, permissionMicrophone, permissionAccessibility]),
        HelpSection(title: "Doctor", tips: [runDoctor, doctorResult]),
        HelpSection(title: "Keys and shortcuts",
                    tips: [keysOctave, keysMode, keysPaging, keysAutoTune, keysAdvanced, keysHelp]),
    ]

    static let all: [HelpTip] = sections.flatMap { $0.tips }

    /// Lines that break the table's rules (empty, too long, a title used twice); logged at launch.
    static func problems(_ tips: [HelpTip] = all) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for t in tips {
            if t.title.isEmpty || t.body.trimmingCharacters(in: .whitespaces).isEmpty { out.append("empty: \(t.title)") }
            if t.body.count > HelpTip.maxBody { out.append("too long (\(t.body.count)): \(t.title)") }
            if !seen.insert(t.id).inserted { out.append("title used twice: \(t.title)") }
        }
        return out
    }

    static func checkAtLaunch() {
        for p in problems() { AppLog.log("help text: \(p)") }
    }
}
