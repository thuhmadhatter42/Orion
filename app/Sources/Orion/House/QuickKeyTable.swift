import AppKit

// BEAT KEY'S SHORTCUTS: the per-app file of the Quick Keys module. ONE table: a shortcut exists only as a row
// here. Menu items read their chord from their row (`.quickKey("id")`), the system-wide shortcuts are registered
// from their rows (HotkeyCenter, through ShortcutStore), and ⇧⌃K lists and rebinds them all. The standard rows
// (Quick Keys, Settings, Hide, Quit, Edit, Window) are added by QuickKeys.swift; not repeated here.
//
// Seeded 2026-11-19 from: Hotkeys.swift (HotkeyAction: the five system-wide shortcuts, which used to live in
// Settings › Global shortcuts and UserDefaults `hotkey.<id>`), the Reading / File / View menus (OrionApp.swift,
// AutoTuneSend.swift, DAWSend.swift, MidiExport.swift), PlayToFind.swift (⇧⌘A while Beat Key is in front) and the
// pocket's (menu-bar popover) New Song / Hold hints, which print their chords from these same rows.
//
//   .global  works in every app (Carbon hot key) and is also what the menu item shows
//   .menu    a menu command
//   .key     a key the window handles itself
//   .locked  a standard macOS chord, listed so the table is complete
//
// Row ids for the five .global rows are HotkeyAction's raw values ("listen", "analyzeFile", "newSong", "hold",
// "analyzeSelection"): HotkeyAction.defaultShortcut reads its default from here, so there is no second copy.
extension QuickKeys {
    nonisolated static let appRows: [QuickKeyDef] = [
        // Anywhere (system-wide). ⌃⌥⌘L (J, 2026-11-05) and ⌥⌘B (J, 2026-11-08, Bounce) are Pro Tools' own, so
        // Analyze Selection ships unassigned.
        QuickKeyDef("listen", "Start / Stop Listening", group: "Anywhere (works in every app)", kind: .global,
                    key: "k", mods: [.control, .option, .command]),
        QuickKeyDef("analyzeFile", "Analyze a File…", group: "Anywhere (works in every app)", kind: .global,
                    key: "f", mods: [.control, .option, .command]),
        QuickKeyDef("newSong", "New Song (Reset Listening)", group: "Anywhere (works in every app)", kind: .global,
                    key: "r", mods: [.control, .option, .command]),
        QuickKeyDef("hold", "Hold / Release Reading", group: "Anywhere (works in every app)", kind: .global,
                    key: "h", mods: [.control, .option, .command]),
        QuickKeyDef("analyzeSelection", "Analyze Selection in DAW", group: "Anywhere (works in every app)",
                    kind: .global, key: "", mods: []),

        // Reading menu
        QuickKeyDef("sendAutoTune", "Send Key to Auto-Tune", group: "Reading", key: "a", mods: [.control, .option, .command]),
        QuickKeyDef("sendDAW", "Send to DAW", group: "Reading", key: "s", mods: [.control, .option, .command]),
        QuickKeyDef("sendAllDAWs", "Send to All DAWs", group: "Reading", key: "d", mods: [.control, .option, .command]),

        // File menu
        QuickKeyDef("exportMidi", "Export MIDI Tempo/Key File…", group: "File", key: "e", mods: [.control, .option, .command]),

        // View menu
        QuickKeyDef("advancedMode", "Advanced Mode", group: "View", key: "a", mods: [.option, .command]),

        // Main window, while Beat Key is in front (Play to find the key: the computer keyboard is a piano)
        QuickKeyDef("playSendAutoTune", "Send to Auto-Tune (while playing keys)", group: "Main Window", kind: .key,
                    key: "a", mods: [.command, .shift]),

        // Help menu: standard macOS chord, drawn by the AppKit Help item (HelpMenuItem.swift)
        QuickKeyDef("help", "Beat Key Help", group: "App", kind: .locked, key: "?", mods: .command),
    ]
}
