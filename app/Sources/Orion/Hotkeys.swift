import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// A global shortcut: a virtual key code plus Carbon modifier bits (what RegisterEventHotKey
/// takes), and the key's printed name for the menus ("K", "F5", "Space").
struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    /// "⌃⌥⌘K": modifiers in the order macOS menus print them.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// A key typed in the recorder, or nil when it can't be a global shortcut: it needs ⌘, ⌃ or ⌥
    /// (Shift alone would steal ordinary typing everywhere).
    static func recorded(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Shortcut? {
        let m = carbonModifiers(flags)
        guard m & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }
        guard let name = keyName(keyCode: keyCode, characters: characters) else { return nil }
        return Shortcut(keyCode: UInt32(keyCode), modifiers: m, key: name)
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    static func keyName(keyCode: UInt16, characters: String?) -> String? {
        if let n = named[Int(keyCode)] { return n }
        guard let c = characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), c.count == 1,
              let u = c.unicodeScalars.first, !(0xF700...0xF8FF).contains(u.value) else { return nil }
        return c
    }
}

extension Shortcut {
    /// The Quick Keys chord as a Carbon shortcut. nil = unassigned, or no key on this keyboard layout types it.
    init?(chord: QuickChord) {
        guard chord.isAssigned, let code = QuickKeys.keyCode(forKey: chord.key),
              let name = Shortcut.keyName(keyCode: code, characters: chord.key) else { return nil }
        self.init(keyCode: UInt32(code), modifiers: Shortcut.carbonModifiers(chord.mods), key: name)
    }

    /// This shortcut as a Quick Keys chord.
    var chord: QuickChord {
        var mods: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mods.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mods.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mods.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mods.insert(.command) }
        let name = UInt16(exactly: keyCode).flatMap { QuickKeys.keyName(keyCode: $0) } ?? key.lowercased()
        return QuickChord(key: name, mods: mods)
    }
}

/// What a global shortcut does. Send to DAW joins this list with plan §4.
enum HotkeyAction: String, CaseIterable, Identifiable {
    // new actions go at the end: hotKeyID is the position in this list
    case listen, analyzeFile, newSong, hold, analyzeSelection
    var id: String { rawValue }

    var title: String {
        switch self {
        case .listen: return "Start / Stop Listening"
        case .analyzeFile: return "Analyze a File…"
        case .newSong: return "New Song (Reset Listening)"
        case .hold: return "Hold / Release Reading"
        case .analyzeSelection: return "Analyze Selection in DAW"
        }
    }

    /// The default keys: this action's row in Quick Keys (QuickKeyTable.swift), the one table.
    /// nil = no keys until the user sets some in Quick Keys (⇧⌃K): Analyze Selection ships unassigned.
    var defaultShortcut: Shortcut? {
        QuickKeys.appRows.first { $0.id == rawValue }.flatMap { Shortcut(chord: $0.chord) }
    }

    var hotKeyID: UInt32 { UInt32(HotkeyAction.allCases.firstIndex(of: self)! + 1) }
}

/// The system-wide shortcuts, as Carbon wants them. NOT a second store: the keys live in Quick Keys
/// (QuickKeys.swift: the table is QuickKeyTable.swift, the user's changes are UserDefaults `quickKeys`),
/// and this reads and writes the `.global` rows there. A rebind in ⇧⌃K re-registers the hot keys.
@MainActor
final class ShortcutStore: ObservableObject {
    private let keys: QuickKeys
    private var subscriptions: [AnyCancellable] = []

    /// `keys: nil` = the app's one table. Shortcuts saved before Quick Keys (UserDefaults `hotkey.<id>`) move
    /// into it once, here.
    init(keys: QuickKeys? = nil, defaults: UserDefaults = .standard) {
        self.keys = keys ?? .shared
        ShortcutMigration.run(into: self.keys, defaults: defaults)
        self.keys.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    func shortcut(_ a: HotkeyAction) -> Shortcut? { Shortcut(chord: keys.chord(for: a.rawValue)) }

    /// The title of the other row already on these keys, if any (a key does one thing).
    func conflict(_ s: Shortcut, for a: HotkeyAction) -> String? {
        let chord = s.chord
        return keys.defs.first { $0.id != a.rawValue && keys.chord(for: $0.id) == chord }?.title
    }

    /// nil turns the shortcut off. False = refused (another row has those keys, or macOS holds them).
    @discardableResult
    func set(_ s: Shortcut?, for a: HotkeyAction) -> Bool {
        guard let s else { keys.clear(a.rawValue); return true }
        return keys.set(a.rawValue, to: s.chord) == .ok
    }

    /// Keep Carbon in step with the table: register now, re-register after every change, and drop the
    /// registrations while a Quick Keys chip listens (the old keys must not fire while the new ones are typed).
    func keepRegistered(with center: HotkeyCenter = .shared) {
        center.apply(self)
        keys.$overrides.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in guard let self else { return }; center.apply(self) }
            .store(in: &subscriptions)
        keys.$listening.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self else { return }
                if id == nil { center.apply(self) } else { center.unregisterAll() }
            }
            .store(in: &subscriptions)
    }
}

/// Shortcuts saved by the old Settings › Global shortcuts (UserDefaults `hotkey.<id>`, a JSON Shortcut or null for
/// "off") move into Quick Keys once; the old key is then removed, so nothing reads it twice.
enum ShortcutMigration {
    @MainActor static func run(into keys: QuickKeys, defaults: UserDefaults) {
        for a in HotkeyAction.allCases {
            let old = "hotkey.\(a.rawValue)"
            guard let data = defaults.data(forKey: old) else { continue }
            defer { defaults.removeObject(forKey: old) }
            guard keys.overrides[a.rawValue] == nil else { continue }       // Quick Keys already has the user's word
            let saved = (try? JSONDecoder().decode(Shortcut?.self, from: data)) ?? nil
            if let saved {
                guard saved.chord != keys.chord(for: a.rawValue) else { continue }
                if case .ok = keys.set(a.rawValue, to: saved.chord) {
                    AppLog.log("shortcuts: \(a.rawValue) \(saved.display) moved into Quick Keys")
                } else {
                    AppLog.log("shortcuts: \(a.rawValue) \(saved.display) could not move into Quick Keys (taken); the default stays")
                }
            } else if keys.chord(for: a.rawValue).isAssigned {
                keys.clear(a.rawValue)                                       // it was switched off
                AppLog.log("shortcuts: \(a.rawValue) was off; still off in Quick Keys")
            }
        }
    }
}

/// Registers the shortcuts system-wide with Carbon's RegisterEventHotKey (works in any app,
/// needs no Accessibility permission). Main thread only.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    static let signature: OSType = 0x424B_6579   // 'BKey'

    var actions: [HotkeyAction: () -> Void] = [:]
    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// Keys another app holds: RegisterEventHotKey said no.
    private(set) var failed: Set<HotkeyAction> = []

    /// Registers every shortcut in `store` (unregistering the old ones first).
    func apply(_ store: ShortcutStore) {
        installHandler()
        unregisterAll()
        failed = []
        for a in HotkeyAction.allCases {
            guard let s = store.shortcut(a) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyCenter.signature, id: a.hotKeyID)
            let st = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let r = ref {
                refs[a] = r
                AppLog.log("hotkey \(a.rawValue) \(s.display): registered")
            } else {
                failed.insert(a)
                AppLog.log("hotkey \(a.rawValue) \(s.display): FAILED (OSStatus \(st)), another app holds it")
            }
        }
    }

    /// While the Settings recorder listens for new keys, the old ones must not fire.
    func unregisterAll() {
        for r in refs.values { UnregisterEventHotKey(r) }
        refs = [:]
    }

    func fire(_ id: UInt32) {
        guard let a = HotkeyAction.allCases.first(where: { $0.hotKeyID == id }) else { return }
        if let go = actions[a] { go() } else { NSSound.beep() }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard st == noErr, id.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fire(id.id) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
