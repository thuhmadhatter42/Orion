import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Orion

/// The system-wide shortcuts. Their keys live in Quick Keys (one table: QuickKeyTable.swift); ShortcutStore is the
/// Carbon side of it. Every test uses its own table and its own UserDefaults, so nothing touches the user's.
@MainActor
final class HotkeyTests: XCTestCase {
    func defaults() -> UserDefaults {
        let name = TestPrefs.name("orion-tests-")
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    /// A table of Beat Key's rows on its own defaults; macOS reserves nothing here, so the test result never
    /// depends on the Mac it runs on.
    func table(_ d: UserDefaults) -> QuickKeys {
        QuickKeys(defs: QuickKeys.appRows + QuickKeys.standardRows, defaults: d, osReserved: { [] })
    }

    func store(_ d: UserDefaults? = nil) -> (ShortcutStore, QuickKeys, UserDefaults) {
        let d = d ?? defaults()
        let keys = table(d)
        return (ShortcutStore(keys: keys, defaults: d), keys, d)
    }

    // MARK: 2.2 global shortcuts

    func testDefaults() {
        XCTAssertEqual(HotkeyAction.listen.defaultShortcut!.display, "⌃⌥⌘K")
        XCTAssertEqual(HotkeyAction.analyzeFile.defaultShortcut!.display, "⌃⌥⌘F")
        XCTAssertEqual(HotkeyAction.newSong.defaultShortcut!.display, "⌃⌥⌘R")
        XCTAssertEqual(HotkeyAction.hold.defaultShortcut!.display, "⌃⌥⌘H")
        XCTAssertEqual(HotkeyAction.newSong.hotKeyID, 3)   // appended: the older IDs stay put
        XCTAssertNil(HotkeyAction.analyzeSelection.defaultShortcut)   // ⌃⌥⌘L and ⌥⌘B are Pro Tools'
        XCTAssertNil(store().0.shortcut(.analyzeSelection))
        XCTAssertEqual(HotkeyAction.analyzeSelection.hotKeyID, 5)
        XCTAssertEqual(HotkeyAction.listen.defaultShortcut!.keyCode, UInt32(kVK_ANSI_K))
        XCTAssertEqual(store().0.shortcut(.listen), HotkeyAction.listen.defaultShortcut)
    }

    /// One table: every HotkeyAction is a `.global` row of the same id, and nothing else is.
    func testEveryActionIsAGlobalRowOfTheQuickKeysTable() {
        let globals = QuickKeys.appRows.filter { $0.kind == .global }.map(\.id)
        XCTAssertEqual(Set(globals), Set(HotkeyAction.allCases.map(\.rawValue)))
        XCTAssertEqual(QuickKeys.problems(QuickKeys.appRows + QuickKeys.standardRows), [], "no clash, every modifier rule kept")
    }

    func testRecordingNeedsACommandControlOrOptionKey() {
        XCTAssertNil(Shortcut.recorded(keyCode: UInt16(kVK_ANSI_K), flags: [], characters: "k"))
        XCTAssertNil(Shortcut.recorded(keyCode: UInt16(kVK_ANSI_K), flags: [.shift], characters: "K"))
        let s = Shortcut.recorded(keyCode: UInt16(kVK_ANSI_L), flags: [.command, .shift], characters: "L")
        XCTAssertEqual(s?.display, "⇧⌘L")
        XCTAssertEqual(s?.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(Shortcut.recorded(keyCode: UInt16(kVK_F5), flags: [.option], characters: "\u{F708}")?.display, "⌥F5")
        XCTAssertNil(Shortcut.recorded(keyCode: 200, flags: [.command], characters: "\u{F730}"))   // unnamed function key
    }

    func testAChordAndItsCarbonShortcutAreTheSameKeys() {
        let c = QuickChord(key: "l", mods: [.command, .option])
        let s = Shortcut(chord: c)
        XCTAssertEqual(s?.keyCode, UInt32(kVK_ANSI_L))
        XCTAssertEqual(s?.modifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(s?.chord, c)
        XCTAssertNil(Shortcut(chord: .none), "an unassigned row has no hot key")
        XCTAssertEqual(Shortcut(chord: QuickChord(key: "f5", mods: .option))?.display, "⌥F5")
    }

    func testStoreRemembersSetsAndClears() {
        let (s, _, d) = store()
        let new = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey), key: "L")
        XCTAssertTrue(s.set(new, for: .listen))
        XCTAssertEqual(store(d).0.shortcut(.listen), new)                       // the next launch
        s.set(nil, for: .analyzeFile)
        XCTAssertNil(store(d).0.shortcut(.analyzeFile))                         // off stays off
    }

    func testOneKeyDoesOneThing() {
        let (s, _, _) = store()
        XCTAssertFalse(s.set(HotkeyAction.analyzeFile.defaultShortcut, for: .listen))
        XCTAssertEqual(s.conflict(HotkeyAction.analyzeFile.defaultShortcut!, for: .listen), "Analyze a File…")
        XCTAssertEqual(s.shortcut(.listen), HotkeyAction.listen.defaultShortcut)
        // a key a MENU item holds is as taken as a system-wide one: one table, one clash rule
        let autoTune = Shortcut(chord: QuickChord(key: "a", mods: [.control, .option, .command]))!
        XCTAssertFalse(s.set(autoTune, for: .listen))
        XCTAssertEqual(s.conflict(autoTune, for: .listen), "Send Key to Auto-Tune")
    }

    func testAShortcutNeedsACommandControlOrOptionKeyInTheTableToo() {
        let (s, _, _) = store()
        XCTAssertFalse(s.set(Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(shiftKey), key: "L"), for: .listen))
    }

    // MARK: shortcuts saved before Quick Keys

    func testOldSettingsShortcutsMoveIntoQuickKeysOnce() throws {
        let d = defaults()
        let moved = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey), key: "L")
        d.set(try JSONEncoder().encode(moved), forKey: "hotkey.listen")
        d.set(try JSONEncoder().encode(Optional<Shortcut>.none), forKey: "hotkey.hold")            // switched off
        d.set(try JSONEncoder().encode(HotkeyAction.newSong.defaultShortcut), forKey: "hotkey.newSong")  // unchanged
        let (s, keys, _) = store(d)
        XCTAssertEqual(s.shortcut(.listen), moved)
        XCTAssertNil(s.shortcut(.hold), "off stays off")
        XCTAssertEqual(s.shortcut(.newSong), HotkeyAction.newSong.defaultShortcut)
        XCTAssertNil(keys.overrides["newSong"], "a saved default is not an override")
        for a in HotkeyAction.allCases { XCTAssertNil(d.object(forKey: "hotkey.\(a.rawValue)"), "the old key is gone") }
        XCTAssertEqual(store(d).0.shortcut(.listen), moved, "and it survives the next launch")
    }

    func testOldShortcutThatCannotMoveLeavesTheDefault() throws {
        let d = defaults()
        // the old Settings never knew the menu items' keys: a saved system-wide shortcut on ⌃⌥⌘A (Send to Auto-Tune's) clashes now
        let taken = Shortcut(chord: QuickChord(key: "a", mods: [.control, .option, .command]))!
        d.set(try JSONEncoder().encode(taken), forKey: "hotkey.listen")
        let (s, _, _) = store(d)
        XCTAssertEqual(s.shortcut(.listen), HotkeyAction.listen.defaultShortcut)
    }

    func testMenuItemsReadTheirChordFromTheTable() {
        let (_, keys, _) = store()
        XCTAssertEqual(keys.shortcut(for: "analyzeFile")?.key, KeyEquivalentProxy.f)
        XCTAssertEqual(keys.shortcut(for: "analyzeFile")?.modifiers, [.control, .option, .command])
    }

    func testHotKeyIDsAreDistinct() {
        XCTAssertEqual(Set(HotkeyAction.allCases.map(\.hotKeyID)).count, HotkeyAction.allCases.count)
    }

    func testCarbonRegistrationSucceeds() {
        // an unlikely combination (⌃⌥⇧⌘F19) so the test never takes a key anyone uses
        let (s, _, _) = store()
        let all = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        s.set(Shortcut(keyCode: UInt32(kVK_F19), modifiers: all, key: "F19"), for: .listen)
        s.set(nil, for: .analyzeFile)
        HotkeyCenter.shared.apply(s)
        XCTAssertTrue(HotkeyCenter.shared.failed.isEmpty)
        HotkeyCenter.shared.unregisterAll()
    }

    func testFireRunsTheAction() {
        var ran = false
        HotkeyCenter.shared.actions[.listen] = { ran = true }
        defer { HotkeyCenter.shared.actions[.listen] = nil }
        HotkeyCenter.shared.fire(HotkeyAction.listen.hotKeyID)
        XCTAssertTrue(ran)
    }
}

import SwiftUI
enum KeyEquivalentProxy { static let f = KeyEquivalent("f") }
