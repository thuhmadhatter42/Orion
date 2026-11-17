import AppKit
import SwiftUI
import XCTest
@testable import Orion

/// Help mode: the setting, the tip decision, the placement and the one table of help lines.
final class HelpTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "help-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: the setting

    func testHelpModeDefaultsOff() {
        XCTAssertFalse(HelpSettings(defaults: freshDefaults()).isOn)
        XCTAssertFalse(PocketState().help)
    }

    func testHelpModePersists() {
        let d = freshDefaults()
        let a = HelpSettings(defaults: d)
        a.toggle(from: "test")
        XCTAssertTrue(a.isOn)
        XCTAssertTrue(d.bool(forKey: HelpSettings.key))
        XCTAssertEqual(HelpSettings.key, "helpMode")
        XCTAssertTrue(HelpSettings(defaults: d).isOn, "a new launch reads it back")
        a.isOn = false
        XCTAssertFalse(HelpSettings(defaults: d).isOn)
    }

    func testJunkStoredValueStartsOff() {
        let d = freshDefaults()
        d.set("yes please", forKey: HelpSettings.key)
        XCTAssertFalse(HelpSettings(defaults: d).isOn)
    }

    // MARK: the decision

    func testTipIsInertWhenHelpIsOff() {
        for hovering in [false, true] {
            for forced in [false, true] {
                XCTAssertFalse(HelpTipLogic.shows(helpOn: false, hovering: hovering, forced: forced))
            }
        }
    }

    func testTipShowsOnHoverWhenHelpIsOn() {
        XCTAssertTrue(HelpTipLogic.shows(helpOn: true, hovering: true))
        XCTAssertFalse(HelpTipLogic.shows(helpOn: true, hovering: false))
        XCTAssertTrue(HelpTipLogic.shows(helpOn: true, hovering: false, forced: true))
    }

    func testNativeTooltipStepsAsideInHelpMode() {
        XCTAssertEqual(HelpTipLogic.nativeTooltip("New song · reset", helpOn: false), "New song · reset")
        XCTAssertEqual(HelpTipLogic.nativeTooltip("New song · reset", helpOn: true), "")
    }

    func testFaceplateHasNoBareNativeTooltips() throws {
        // every tooltip on the faceplate goes through .nativeHelp, so help mode can silence it
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Orion").standardized
        for name in ["Pocket/PocketView.swift", "HarmonyView.swift", "Faceplate/FaceplateView.swift",
                     "Faceplate/LCD.swift", "Faceplate/Controls.swift", "Faceplate/Chassis.swift", "Help.swift"] {
            let text = try String(contentsOf: src.appendingPathComponent(name), encoding: .utf8)
            let bare = text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".help(") }
            XCTAssertEqual(bare, [], "\(name) has a bare .help(")
        }
    }

    // MARK: the placement

    func testCardStaysInsideAndOffTheControl() {
        let size = CGSize(width: 552, height: 700)
        let w = HelpCard.width
        for r in [CGRect(x: 0, y: 40, width: 30, height: 14),          // far left
                  CGRect(x: 530, y: 40, width: 20, height: 14),        // far right
                  CGRect(x: 200, y: 660, width: 80, height: 16),       // the footer
                  CGRect(x: 100, y: 300, width: 300, height: 84)] {    // the keyboard
            let p = HelpTipLogic.place(r, in: size)
            XCTAssertGreaterThanOrEqual(p.x, HelpTipLogic.margin)
            XCTAssertLessThanOrEqual(p.x + w, size.width - HelpTipLogic.margin)
        }
        XCTAssertTrue(HelpTipLogic.place(CGRect(x: 200, y: 40, width: 80, height: 14), in: size).below)
        XCTAssertFalse(HelpTipLogic.place(CGRect(x: 200, y: 660, width: 80, height: 16), in: size).below,
                       "near the bottom the card goes above")
    }

    // MARK: the table

    func testEveryHelpLineIsShortAndFilled() {
        XCTAssertGreaterThanOrEqual(HelpText.all.count, 40)
        for t in HelpText.all {
            XCTAssertFalse(t.title.isEmpty)
            XCTAssertFalse(t.body.trimmingCharacters(in: .whitespaces).isEmpty, t.title)
            XCTAssertLessThanOrEqual(t.body.count, HelpTip.maxBody, t.title)
            XCTAssertLessThanOrEqual(t.body.count, 140, t.title)
        }
        XCTAssertEqual(HelpText.problems(), [])
    }

    func testProblemsAreCaught() {
        let bad = [HelpTip(title: "A", body: ""), HelpTip(title: "B", body: String(repeating: "x", count: 141)),
                   HelpTip(title: "C", body: "ok"), HelpTip(title: "C", body: "ok")]
        XCTAssertEqual(HelpText.problems(bad).count, 3)
    }

    /// Click-to-respell is gone (2026-11-10): the KEY tip promises no click on the key.
    func testKeyTipDoesNotOfferRespelling() {
        XCTAssertEqual(HelpText.keyDial.body, "The key Beat Key hears; the ring and the % under it show how sure it is.")
        for t in HelpText.all {
            XCTAssertFalse(t.body.lowercased().contains("respell"), t.title)
            XCTAssertFalse(t.body.lowercased().contains("sharp or flat"), t.title)
        }
    }

    func testChordsTipCarriesTheClickDragLine() {
        // the always-on "CLICK = HEAR · DRAG = MIDI" moved into the tip
        XCTAssertTrue(HelpText.chords.body.contains("Click one to hear it"))
        XCTAssertTrue(HelpText.chords.body.contains("MIDI"))
    }

    func testKeyboardTipMatchesMusicalTyping() {
        // A = C and Space toggles, as PlayToFind does
        XCTAssertEqual(MusicalTyping.action(keyCode: MusicalTyping.aKey, modifiers: []), .note(0))
        XCTAssertEqual(MusicalTyping.action(keyCode: MusicalTyping.space, modifiers: []), .toggleMode)
        XCTAssertTrue(HelpText.keyboard.body.contains("A W S E D F T G Y H U J K"))
        XCTAssertTrue(HelpText.keyboard.body.contains("Space"))
    }

    // MARK: the help audit of 2026-11-17

    private var sourceDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/Orion").standardized
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: sourceDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Every control has a tip, and no two controls share a legend (title).
    func testEveryTipIsFilledAndUnique() {
        let ids = HelpText.all.map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "a tip title is used twice")
        for t in HelpText.all {
            XCTAssertFalse(t.title.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(t.body.trimmingCharacters(in: .whitespaces).isEmpty, t.title)
        }
        XCTAssertEqual(HelpText.problems(), [])
        for s in HelpText.sections { XCTAssertFalse(s.tips.isEmpty, s.title) }
    }

    /// The help window draws the same table the hover cards read: every entry, nothing extra.
    func testHelpWindowListsEveryEntry() {
        let rows = HelpWindowContent.rows()
        XCTAssertEqual(rows.count, HelpText.all.count)
        for t in HelpText.all {
            XCTAssertTrue(rows.contains { $0.title == t.title && $0.body == t.body }, "\(t.title) is missing from the help window")
        }
        let areas = Set(rows.map { $0.section })
        for a in ["Window and pocket: the readout", "Menu bar pocket only", "Beat Key Mini", "Settings", "Permissions guide",
                  "Doctor", "Keys and shortcuts"] {
            XCTAssertTrue(areas.contains(a), a)
        }
    }

    /// A tip a view uses must be in the table the window draws (no tip that only hovers).
    func testEveryTipUsedByAViewIsInTheSections() throws {
        let help = try source("Help.swift")
        let start = try XCTUnwrap(help.range(of: "static let sections"))
        let end = try XCTUnwrap(help.range(of: "static let all"))
        let block = String(help[start.lowerBound..<end.lowerBound])
        let skip: Set<String> = ["all", "sections", "problems", "checkAtLaunch", "permission", "manualLocked", "manualWheelReset", "maxBody"]
        let re = try NSRegularExpression(pattern: "HelpText\\.([A-Za-z]+)")
        let fm = FileManager.default
        var checked = 0
        for case let f as String in fm.enumerator(atPath: sourceDir.path) ?? NSEnumerator() where f.hasSuffix(".swift") {
            let text = try source(f)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let name = (text as NSString).substring(with: m.range(at: 1))
                if skip.contains(name) { continue }
                XCTAssertTrue(block.range(of: "\\b\(name)\\b", options: .regularExpression) != nil, "\(f): HelpText.\(name) is not in HelpText.sections")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 40)
    }

    func testKeyboardTipMentionsTheOctaveKeys() {
        XCTAssertEqual(MusicalTyping.action(keyCode: MusicalTyping.zKey, modifiers: []), .octaveDown)
        XCTAssertEqual(MusicalTyping.action(keyCode: MusicalTyping.xKey, modifiers: []), .octaveUp)
        let b = HelpText.keyboard.body
        XCTAssertTrue(b.contains("Z"), b)
        XCTAssertTrue(b.contains("X"), b)
        XCTAssertTrue(HelpText.keysOctave.body.contains("Z") && HelpText.keysOctave.body.contains("X"))
    }

    /// The tip and the Reading-menu item read one constant, so they cannot drift.
    func testAutoTuneTipShortcutIsTheMenuShortcut() throws {
        XCTAssertEqual(AutoTuneSend.shortcutDisplay, "⌃⌥⌘A")
        XCTAssertTrue(HelpText.autoTune.body.contains(AutoTuneSend.shortcutDisplay), HelpText.autoTune.body)
        XCTAssertTrue(HelpText.keysAutoTune.body.contains(AutoTuneSend.shortcutDisplay))
        XCTAssertFalse(HelpText.autoTune.body.contains("⇧⌘A"))
        let menu = try source("AutoTuneSend.swift")
        XCTAssertTrue(menu.contains(".keyboardShortcut(KeyEquivalent(AutoTuneSend.shortcutKey), modifiers: AutoTuneSend.shortcutModifiers)"),
                      "the menu item must take its shortcut from the same constants as the tip")
    }

    func testLoginHasItsOwnTip() throws {
        XCTAssertNotEqual(HelpText.login, HelpText.download)
        XCTAssertEqual(HelpText.login.title, Faceplate.loginCapLabel)
        XCTAssertTrue(HelpText.login.body.lowercased().contains("sign-in"))
        XCTAssertFalse(HelpText.login.body.lowercased().contains("mp3"))
        // both surfaces pick it for the login cap
        XCTAssertTrue(try source("Faceplate/FaceplateView.swift").contains(".helpTip(HelpText.login)"))
        XCTAssertTrue(try source("Pocket/PocketView.swift").contains("login ? HelpText.login : HelpText.download"))
    }

    func testPagingArrowsAndReadoutHaveTips() throws {
        XCTAssertTrue(HelpText.all.contains(HelpText.prevFile))
        XCTAssertTrue(HelpText.all.contains(HelpText.nextFile))
        XCTAssertTrue(HelpText.all.contains(HelpText.readout))
        XCTAssertTrue(try source("Pocket/PocketView.swift").contains(".helpTip(glyph == \"‹\" ? HelpText.prevFile : HelpText.nextFile)"))
        XCTAssertTrue(try source("Faceplate/LCD.swift").contains(".helpTip(HelpText.readout)"))
        XCTAssertTrue(try source("Pocket/PocketView.swift").contains(".helpTip(HelpText.readout)"))
    }

    func testSettingsPermissionsAndDoctorHaveEntries() throws {
        let titles = Set(HelpText.all.map { $0.title })
        for k in PermissionKind.allCases { XCTAssertTrue(titles.contains(k.title.uppercased()), k.title) }
        for t in [HelpText.settingsListenTo, HelpText.settingsStartOver, HelpText.settingsOpenAtLogin, HelpText.settingsShortcuts,
                  HelpText.settingsHighContrast, HelpText.permissionGuide, HelpText.runDoctor, HelpText.doctorResult] {
            XCTAssertTrue(HelpText.all.contains(t), t.title)
        }
        XCTAssertTrue(try source("Settings.swift").contains(".helpTipLayer()"))
        XCTAssertTrue(try source("Permissions/PermissionGuideWindow.swift").contains(".helpTipLayer()"))
    }

    /// Help › Beat Key Help opens the in-app window (⌘?), Help Mode lives in the Help menu, not View.
    func testHelpMenuHasTheWindowAndTheToggle() throws {
        let app = try source("OrionApp.swift")
        let help = try XCTUnwrap(app.range(of: "CommandGroup(replacing: .help)"))
        let rest = String(app[help.upperBound...])
        let body = String(rest[..<(rest.range(of: "// The app menu says")!.lowerBound)])
        XCTAssertTrue(body.contains("HelpWindow.shared.open"))
        XCTAssertTrue(body.contains(".keyboardShortcut(\"?\", modifiers: .command)"))
        XCTAssertTrue(body.contains("Toggle(\"Help Mode\""))
        let before = String(app[..<help.lowerBound])
        XCTAssertFalse(before.contains("Toggle(\"Help Mode\""), "Help Mode must not stay in the View menu")
        XCTAssertEqual(Brand.help, "Beat Key Help")
    }

    /// The standard Help item (read from a probe app, 2026-11-17): showHelp:, "?", Command only.
    func testHelpItemIsAppKitsStandardOne() {
        let bar = NSMenu()
        let helpMenu = NSMenu(title: "Help")
        let item = NSMenuItem(title: Brand.help, action: Selector(("menuAction:")), keyEquivalent: "")
        helpMenu.addItem(item)
        helpMenu.addItem(NSMenuItem(title: "Help Mode", action: nil, keyEquivalent: ""))
        let top = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        top.submenu = helpMenu
        bar.addItem(top)
        XCTAssertTrue(HelpMenuItem.shared.apply(to: bar))
        XCTAssertEqual(item.action, NSSelectorFromString("showHelp:"))
        XCTAssertTrue(item.target === HelpMenuItem.shared)
        XCTAssertEqual(item.keyEquivalent, "?")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertTrue(HelpMenuItem.shared.responds(to: NSSelectorFromString("showHelp:")))
        // a second pass changes nothing (the menu-change notifications must settle)
        XCTAssertTrue(HelpMenuItem.shared.apply(to: bar))
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
    }

    func testHelpItemMissingIsLogged() throws {
        let src = try source("HelpMenuItem.swift")
        XCTAssertTrue(src.contains("AppLog.log(\"FAILED to attach the Help shortcut"))
        XCTAssertFalse(HelpMenuItem.shared.apply(to: NSMenu()))
        XCTAssertFalse(HelpMenuItem.shared.apply(to: nil))
        let app = try source("OrionApp.swift")
        XCTAssertTrue(app.contains("HelpMenuItem.shared.install()"))
    }

    func testHelpWindowErrorsGoToTheAppLog() throws {
        let w = try source("HelpWindow.swift")
        XCTAssertTrue(w.contains("AppLog.log(\"FAILED to show the help window"))
        XCTAssertTrue(w.contains("AppLog.log(\"FAILED to build the help window"))
        // under test nothing opens, so a test run never pops a window
        HelpWindow.shared.open(why: "test")
    }

    // MARK: the card keeps off the neighbours

    func testCardAvoidsTheNeighbouringButton() {
        let bounds = CGSize(width: 552, height: 700)
        let card = CGSize(width: 212, height: 60)
        let download = CGRect(x: 400, y: 200, width: 140, height: 36)
        let findKey = CGRect(x: 400, y: 244, width: 140, height: 36)     // right under it
        let link = CGRect(x: 20, y: 200, width: 372, height: 36)         // right beside it
        let listen = CGRect(x: 20, y: 288, width: 200, height: 36)
        let cursor = CGPoint(x: 470, y: 215)
        let o = HelpTipLogic.cardOrigin(cursor: cursor, card: card, in: bounds, control: download,
                                        avoiding: [download, findKey, link, listen])
        let r = CGRect(origin: o, size: card)
        for n in [findKey, link, listen] { XCTAssertFalse(r.intersects(n), "card \(r) covers \(n)") }
        XCTAssertFalse(r.intersects(HelpTipLogic.cursorRect(cursor)))
        XCTAssertGreaterThanOrEqual(o.x, HelpTipLogic.margin)
        XCTAssertGreaterThanOrEqual(o.y, HelpTipLogic.margin)
        XCTAssertLessThanOrEqual(r.maxX, bounds.width - HelpTipLogic.margin)
        XCTAssertLessThanOrEqual(r.maxY, bounds.height - HelpTipLogic.margin)
        // and it holds still while the mouse moves inside the control
        let o2 = HelpTipLogic.cardOrigin(cursor: CGPoint(x: 430, y: 220), card: card, in: bounds, control: download,
                                         avoiding: [download, findKey, link, listen])
        XCTAssertEqual(o, o2)
    }

    func testCardFollowsTheMouseWhenNothingIsInTheWay() {
        let bounds = CGSize(width: 1000, height: 700)
        let card = CGSize(width: 212, height: 60)
        let control = CGRect(x: 100, y: 100, width: 80, height: 30)
        let p = CGPoint(x: 178, y: 110)     // at the control's right edge: down-right of the pointer is clear
        XCTAssertEqual(HelpTipLogic.cardOrigin(cursor: p, card: card, in: bounds, control: control, avoiding: [control]),
                       HelpTipLogic.cardOrigin(cursor: p, card: card, in: bounds))
        // deeper inside, the same card would sit on the control it explains: it moves off
        let inside = CGPoint(x: 120, y: 110)
        let o = HelpTipLogic.cardOrigin(cursor: inside, card: card, in: bounds, control: control, avoiding: [control])
        XCTAssertFalse(CGRect(origin: o, size: card).intersects(control))
    }

    func testCardStaysInsideWhenControlsFillTheSurface() {
        let bounds = CGSize(width: 376, height: 620)
        let card = CGSize(width: 212, height: 60)
        var rects: [CGRect] = []
        for y in stride(from: 0.0, to: 620.0, by: 40) { rects.append(CGRect(x: 0, y: y, width: 376, height: 36)) }
        for r in rects {
            let p = CGPoint(x: r.midX, y: r.midY)
            let o = HelpTipLogic.cardOrigin(cursor: p, card: card, in: bounds, control: r, avoiding: rects)
            let c = CGRect(origin: o, size: card)
            XCTAssertGreaterThanOrEqual(o.x, HelpTipLogic.margin - 0.001)
            XCTAssertGreaterThanOrEqual(o.y, HelpTipLogic.margin - 0.001)
            XCTAssertLessThanOrEqual(c.maxX, bounds.width - HelpTipLogic.margin + 0.001)
            XCTAssertLessThanOrEqual(c.maxY, bounds.height - HelpTipLogic.margin + 0.001)
        }
    }

    // MARK: no card covers a control (J 2026-11-17, Sofia check of 0.1.74)

    /// The explainable controls of the real window (default size, a reading with 3 files), as the layer reports them.
    static let windowFrames: [CGRect] = [
        CGRect(x: 419.5, y: 42.5, width: 58.5, height: 13.0),
        CGRect(x: 48.0, y: 131.0, width: 186.0, height: 80.0),
        CGRect(x: 48.0, y: 223.0, width: 264.0, height: 16.0),
        CGRect(x: 48.0, y: 245.0, width: 104.5, height: 12.0),
        CGRect(x: 390.5, y: 195.0, width: 27.5, height: 16.0),
        CGRect(x: 375.0, y: 215.0, width: 58.5, height: 12.0),
        CGRect(x: 328.0, y: 109.0, width: 152.0, height: 152.0),
        CGRect(x: 402.0, y: 266.0, width: 78.0, height: 20.0),
        CGRect(x: 48.0, y: 294.0, width: 432.0, height: 33.0),
        CGRect(x: 48.0, y: 339.0, width: 432.0, height: 96.0),
        CGRect(x: 48.0, y: 443.0, width: 432.0, height: 16.0),
        CGRect(x: 48.0, y: 467.0, width: 432.0, height: 12.0),
        CGRect(x: 28.0, y: 511.0, width: 308.0, height: 36.0),
        CGRect(x: 348.0, y: 512.0, width: 152.0, height: 34.0),
        CGRect(x: 28.0, y: 555.0, width: 308.0, height: 36.0),
        CGRect(x: 348.0, y: 556.0, width: 152.0, height: 34.0),
        CGRect(x: 28.0, y: 599.0, width: 182.0, height: 36.0),
        CGRect(x: 222.0, y: 600.0, width: 72.0, height: 34.0),
        CGRect(x: 302.0, y: 600.0, width: 34.0, height: 34.0),
        CGRect(x: 348.0, y: 600.0, width: 152.0, height: 34.0),
        CGRect(x: 28.0, y: 668.0, width: 148.0, height: 26.0),
        CGRect(x: 188.0, y: 668.0, width: 148.0, height: 26.0),
        CGRect(x: 348.0, y: 668.0, width: 152.0, height: 26.0),
        CGRect(x: 48.0, y: 710.0, width: 73.5, height: 16.0),
        CGRect(x: 137.5, y: 710.0, width: 73.0, height: 16.0),
        CGRect(x: 226.5, y: 710.0, width: 67.5, height: 16.0),
        CGRect(x: 310.0, y: 710.0, width: 46.0, height: 16.0),
        CGRect(x: 403.5, y: 710.0, width: 76.5, height: 16.0),
    ]

    /// The send row of the real 528 x 756 window, as the layer measured it (card 212 x 84): hovering
    /// SEND TO AUTO-TUNE put the card on the right half of the button, EXPORT MIDI, HELP and ADVANCED.
    func testAutoTuneCardKeepsOffItsOwnButtonAndTheFooter() {
        let bounds = CGSize(width: 528, height: 756)
        let card = CGSize(width: 212, height: 84)
        let autoTune = CGRect(x: 188, y: 668, width: 148, height: 26)
        let others = Self.windowFrames
        let cursor = CGPoint(x: 220, y: 680)
        let o = HelpTipLogic.cardOrigin(cursor: cursor, card: card, in: bounds, control: autoTune, avoiding: others)
        let r = CGRect(origin: o, size: card)
        XCTAssertFalse(r.intersects(autoTune), "card \(r) covers the hovered button")
        for n in others where n != autoTune { XCTAssertFalse(r.intersects(n), "card \(r) covers \(n)") }
    }

    /// A cramped row: the hovered arrow, a counter and a link right beside it, a group around all three.
    func testCardIgnoresAGroupAroundTheControlButAvoidsItsNeighbours() {
        let bounds = CGSize(width: 528, height: 400)
        let card = CGSize(width: 212, height: 60)
        let prev = CGRect(x: 48, y: 200, width: 16, height: 16)
        let counter = CGRect(x: 68, y: 200, width: 40, height: 16)
        let next = CGRect(x: 112, y: 200, width: 16, height: 16)
        let finder = CGRect(x: 140, y: 200, width: 100, height: 16)
        let group = CGRect(x: 48, y: 196, width: 200, height: 24)       // the row around the arrow
        let above = CGRect(x: 48, y: 120, width: 432, height: 60)       // the filename and BPM, readable
        let o = HelpTipLogic.cardOrigin(cursor: CGPoint(x: 56, y: 208), card: card, in: bounds, control: prev,
                                        avoiding: [group, prev, counter, next, finder, above])
        let r = CGRect(origin: o, size: card)
        for n in [prev, counter, next, finder, above] { XCTAssertFalse(r.intersects(n), "card \(r) covers \(n)") }
    }

    /// No spot is fully clear: the card still never covers the hovered control and covers the least.
    func testCrowdedSurfaceKeepsOffTheHoveredControlAndCoversLeast() {
        let bounds = CGSize(width: 376, height: 300)
        let card = CGSize(width: 212, height: 60)
        var rects: [CGRect] = []
        for y in stride(from: 8.0, to: 290.0, by: 34) { rects.append(CGRect(x: 8, y: y, width: 360, height: 30)) }
        let hovered = rects[4]
        let o = HelpTipLogic.cardOrigin(cursor: CGPoint(x: hovered.midX, y: hovered.midY), card: card, in: bounds,
                                        control: hovered, avoiding: rects)
        let r = CGRect(origin: o, size: card)
        XCTAssertFalse(r.intersects(hovered), "card \(r) covers the hovered control")
        let touched = rects.filter { r.intersects(HelpTipLogic.solid($0)) }.count
        XCTAssertLessThanOrEqual(touched, 2, "a 60 pt card needs at most two 34 pt rows")
    }

    /// The real window, real frames, every tip: the card covers no control, and the hovered one never.
    @MainActor
    func testRealWindowCardsCoverNoControl() throws {
        guard #available(macOS 13.0, *) else { throw XCTSkip("ImageRenderer is macOS 13+") }
        Pocket.snapshot = true
        var seen: [String: HelpTipLogic.Placement] = [:]
        HelpTipLogic.onPlace = { seen[$0.tip] = $0 }
        defer { Pocket.snapshot = false; HelpTipLogic.onPlace = nil }
        let r = Result(file: URL(fileURLWithPath: "/x/Beats/Beat C.wav"), name: "Beat C.wav", bpm: "142.0",
                       keys: [("Cm", 61), ("Eb", 18), ("Gm", 9)], bpmExact: 141.98, tuningCents: 12,
                       chroma: [1.0, 0.08, 0.42, 0.81, 0.06, 0.37, 0.1, 0.93, 0.62, 0.05, 0.48, 0.12])
        var s = PocketState()
        s.source = "System Audio"
        s.daw = "Pro Tools"
        s.help = true
        s.readout = .result(r, page: "3 OF 3", download: false, options: ResultOptions(
            factor: .one, tuning: Tuning.meter(12, reference: 440), onCycleTempo: {}))
        func face(_ st: PocketState) -> AnyView {
            AnyView(FaceplateFace(state: st, picked: [], url: .constant(""), fieldFocused: .constant(false),
                                  pickFocused: .constant(false)))
        }
        var advanced = s
        advanced.advanced = true
        advanced.harmony = HarmonyPrefs(quality: .seventh, voicing: .root, bars: 2, matchKey: "Am")
        let surfaces: [(String, AnyView)] = [("window", face(s)), ("window+advanced", face(advanced)),
                                             ("pocket", AnyView(PocketView(state: s, url: .constant(""))))]
        var checked = 0
        var crowded: [String] = []
        for (name, view) in surfaces {
            for tip in HelpText.all {
                seen[tip.id] = nil
                let v = view.environment(\.helpTipForced, tip.id).environment(\.colorScheme, .dark)
                _ = ImageRenderer(content: v).cgImage
                // a tip this surface doesn't draw has no placement
                guard let p = seen[tip.id] else { continue }
                checked += 1
                let card = CGRect(origin: p.origin, size: p.card)
                XCTAssertGreaterThan(p.card.height, 30, "\(name) \(tip.id): the card was never measured")
                XCTAssertFalse(card.intersects(p.control), "\(name) \(tip.id): card \(card) covers its own control \(p.control)")
                let blocked = HelpTipLogic.blockers(p.others, control: p.control)
                let covers = HelpTipLogic.coverage(card, control: p.control, blockers: blocked)
                // never worse than an exhaustive search of the surface (4 pt steps)
                var least = CGFloat.infinity
                for y in stride(from: HelpTipLogic.margin, through: max(HelpTipLogic.margin, p.bounds.height - p.card.height - HelpTipLogic.margin), by: 4) {
                    for x in stride(from: HelpTipLogic.margin, through: max(HelpTipLogic.margin, p.bounds.width - p.card.width - HelpTipLogic.margin), by: 4) {
                        let c = HelpTipLogic.coverage(CGRect(origin: CGPoint(x: x, y: y), size: p.card), control: p.control, blockers: blocked)
                        least = min(least, c)
                    }
                }
                XCTAssertLessThanOrEqual(covers, least + 0.15, "\(name) \(tip.id): card \(card) covers more than the best spot")
                // the window (the Sofia check): no control is touched beyond a sliver of its edge
                if name == "window" {
                    for n in blocked where card.intersects(HelpTipLogic.solid(n)) {
                        crowded.append("window \(tip.id): card \(card) covers \(n)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 25, "the real surfaces drew too few tips to prove anything")
        XCTAssertEqual(crowded, [], "a card covers part of a control in the real window")
    }

    // MARK: offscreen renders (ORION_SNAPSHOT_DIR=<dir> swift test --filter HelpTests/testRender)

    @MainActor
    func testRenderHelpMode() throws {
        guard let dir = ProcessInfo.processInfo.environment["ORION_SNAPSHOT_DIR"] else {
            throw XCTSkip("set ORION_SNAPSHOT_DIR to write the help-mode PNGs")
        }
        guard #available(macOS 13.0, *) else { throw XCTSkip("ImageRenderer is macOS 13+") }
        Pocket.snapshot = true
        defer { Pocket.snapshot = false }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let r = Result(file: URL(fileURLWithPath: "/x/Beats/Beat A.wav"), name: "Beat A.wav", bpm: "142.0",
                       keys: [("Cm", 64), ("Eb", 18), ("Gm", 9)], bpmExact: 141.98, tuningCents: 12,
                       chroma: [1.0, 0.08, 0.42, 0.81, 0.06, 0.37, 0.1, 0.93, 0.62, 0.05, 0.48, 0.12])
        var s = PocketState()
        s.source = "System Audio"
        s.daw = "Pro Tools"
        s.readout = .result(r, page: nil, download: false, options: ResultOptions(
            factor: .one, tuning: Tuning.meter(12, reference: 440), onCycleTempo: {}))
        var off = s
        off.advanced = true
        off.harmony = HarmonyPrefs(quality: .seventh, voicing: .root, bars: 2, matchKey: "Am")
        var on = off
        on.help = true
        var plainOn = s
        plainOn.help = true

        func write<V: View>(_ v: V, _ name: String) throws {
            let rr = ImageRenderer(content: v.environment(\.colorScheme, .dark))
            rr.scale = 2
            guard let cg = rr.cgImage else { return XCTFail("no image for \(name)") }
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(name).png"))
        }
        func window(_ st: PocketState, forced: HelpTip? = nil) -> some View {
            FaceplateFace(state: st, picked: [], url: .constant(""), fieldFocused: .constant(false),
                          pickFocused: .constant(false))
                .environment(\.helpTipForced, forced?.id)
        }
        try write(window(off), "window-advanced-help-off")
        try write(window(on), "window-advanced-help-on")
        try write(window(on, forced: HelpText.chords), "window-advanced-help-chords")
        var paged = plainOn
        paged.readout = .result(r, page: "3 OF 3", download: false, options: ResultOptions(
            factor: .one, tuning: Tuning.meter(12, reference: 440), onCycleTempo: {}))
        for tip in [HelpText.autoTune, HelpText.prevFile, HelpText.nextFile, HelpText.exportMidi, HelpText.advanced] {
            try write(window(paged, forced: tip), "window-help-" + tip.id.lowercased().replacingOccurrences(of: " ", with: "-"))
        }
        try write(window(plainOn, forced: HelpText.keyboard), "window-default-help-keyboard")
        try write(window(plainOn, forced: HelpText.help), "window-default-help-chip")
        // the forced tip with help off: nothing shows (inert)
        try write(window(off, forced: HelpText.chords), "window-advanced-help-off-forced")
        try write(PocketView(state: plainOn, url: .constant("")).environment(\.helpTipForced, HelpText.bpm.id),
                  "pocket-help-bpm")
        try write(PocketView(state: plainOn, url: .constant("")).environment(\.helpTipForced, HelpText.sendDAW.id),
                  "pocket-help-send")
    }
}
