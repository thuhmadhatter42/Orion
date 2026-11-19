import AppKit
import SwiftUI

// Help mode (J, 2026-11-09): a HELP chip in the window's and the pocket's footer (and View › Help
// Mode). Off = the faceplate as it is, no extra text. On = hovering anything explainable shows a
// short amber card, the key wheel's own hover card look. One table (HelpText) holds every line;
// one modifier (.helpTip) attaches them; one layer per surface (.helpTipLayer) draws the card
// above every other view, at the mouse like a tooltip (down-right of the pointer, following it,
// flipped and kept inside the surface, never under the pointer; J 2026-11-09).

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

/// One explanation: a short title (the control's legend) and a Board Talk body (docs/BOARD-TALK.md).
struct HelpTip: Equatable {
    let title: String
    let body: String
    var id: String { title }

    /// The longest body Board Talk allows (docs/BOARD-TALK.md): a phrase, not a sentence.
    static let maxBody = 60
}

/// One group of help lines in the help window.
struct HelpSection: Equatable {
    let title: String
    let tips: [HelpTip]
}

/// Every help line, in one place to edit and test. Board Talk (docs/BOARD-TALK.md): a short title,
/// a body of about 3-8 words, 60 characters at most, the shortcut last in parentheses.
enum HelpText {
    // the readout
    static let bpm = HelpTip(title: "BPM", body: "Click: normal, double or half time.")
    static let pitchToFit = HelpTip(title: "PITCH TO FIT", body: "Semitones to pitch the beat into your key.")
    static let tempoFactor = HelpTip(title: "×0.5 · ×1 · ×2", body: "Halve or double the BPM.")
    static let keyDial = HelpTip(title: "KEY", body: "Key heard. Ring and % show how sure.")
    static let confidence = HelpTip(title: "LOCKED · UNSURE", body: "LOCKED = sure. UNSURE = close call.")
    static let topKeys = HelpTip(title: "TOP KEYS", body: "Three likeliest keys. Click to pin, again to unpin.")
    static let manual = HelpTip(title: "MANUAL", body: "Pin any of the 24 keys.")
    /// Pinned key: the dial's hover card while a key is pinned (shown help mode or not, like the
    /// wheel's cards; J 2026-11-09 15:19, pin model 2026-11-18).
    static let manualReset = HelpTip(title: "PINNED KEY", body: "Click to unpin.")
    /// The wheel's hover card on the pinned key: this line, then `manualWheelReset`.
    static let manualLocked = "Pinned."
    /// What a click on that white section does, after the pinned line.
    static let manualWheelReset = "Click to unpin."
    static let keyboard = HelpTip(title: "KEYBOARD", body: "Play A W S E D F T G Y H U J K. Z X: octave.")
    static let scale = HelpTip(title: "SCALE", body: "The key's seven notes.")
    static let tuning = HelpTip(title: "TUNING", body: "Cents off standard pitch. Green = in tune.")
    static let camelot = HelpTip(title: "CAMELOT", body: "Camelot code for DJ mixing.")
    static let fileLine = HelpTip(title: "FILE", body: "File read, and its folder.")
    static let showInFinder = HelpTip(title: "SHOW IN FINDER", body: "Reveal the file in Finder.")
    static let status = HelpTip(title: "STATUS", body: "READY, WORKING, FAILED or LIVE.")

    // getting audio in
    static let linkField = HelpTip(title: "LINK", body: "Paste a YouTube link.")
    static let download = HelpTip(title: "DOWNLOAD", body: "Get MP3, BPM and key. Empty field: clipboard link.")
    static let openAudio = HelpTip(title: "OPEN AUDIO", body: "Choose or drop audio files, any number.")
    static let findKey = HelpTip(title: "FIND KEY/BPM", body: "Get BPM and key. Arrows page files.")
    static let analyzeFile = HelpTip(title: "ANALYZE FILE", body: "Pick audio files, get BPM and key.")
    static let source = HelpTip(title: "SOURCE", body: "System audio or an input. Meter shows level.")
    static let listen = HelpTip(title: "LISTEN", body: "Live BPM and key. Nothing recorded or saved.")
    static let hold = HelpTip(title: "HOLD", body: "Freeze the reading. Click again to follow.")
    static let reset = HelpTip(title: "NEW SONG", body: "Clear the listen reading, start fresh.")

    // sending
    static let sendDAW = HelpTip(title: "SEND TO DAW", body: "Send BPM and key to the open DAW.")
    static let autoTune = HelpTip(title: "SEND TO AUTO-TUNE", body: "Set key in Auto-Tune, Tune Real-Time (\(AutoTuneSend.shortcutDisplay))")
    static let exportMidi = HelpTip(title: "EXPORT MIDI", body: "MIDI file with tempo and key.")

    // the footer
    static let recent = HelpTip(title: "RECENT", body: "Past readings. Pick one to bring it back.")
    static let settings = HelpTip(title: "SETTINGS", body: "Display, listen source, shortcuts, login.")
    static let color = HelpTip(title: "COLOR", body: "Pick the display colour. Reset to Amber.")
    static let report = HelpTip(title: "REPORT", body: "Send a report, log attached.")
    static let advanced = HelpTip(title: "ADVANCED", body: "Add key wheel, chords, MATCH TO. First switch sets both.")
    static let window = HelpTip(title: "WINDOW", body: "Open the full window.")
    static let quit = HelpTip(title: "QUIT", body: "Quit Beat Key.")
    static let help = HelpTip(title: "HELP", body: "Help on. Hover for tips. Click to turn off.")

    // Advanced mode
    static let keyWheel = HelpTip(title: "KEY WHEEL", body: "Circle of fifths. Click a key to pin it.")
    static let notesHeard = HelpTip(title: "NOTES HEARD", body: "Note strength. Dotted = in the scale.")
    static let chords = HelpTip(title: "CHORDS", body: "Click to hear. Drag to a DAW as MIDI.")
    static let quality = HelpTip(title: "TRIAD · 7TH · 9TH", body: "Chord size: 3 notes, add 7th, add 7th and 9th.")
    static let voicing = HelpTip(title: "ROOT · 1ST · 2ND · OPEN", body: "Bottom note of the chord. OPEN spreads it.")
    static let bars = HelpTip(title: "BAR", body: "Bars per chord when dragged out as MIDI.")
    static let borrowed = HelpTip(title: "BORROWED", body: "Chords from the parallel major or minor.")
    static let matchTo = HelpTip(title: "MATCH TO", body: "Pick your project's key. See the pitch to fit.")
    static let matchShift = HelpTip(title: "−6 … +6", body: "Semitones to pitch. The lit one fits.")
    static let mini = HelpTip(title: "MINI", body: "Small always-on-top chord pad. Plays over MIDI.")
    static let miniPanel = HelpTip(title: "BEAT KEY MINI", body: "Pads play MIDI in \"Beat Key\". Keys 1-7, Q W E R.")
    static let miniSound = HelpTip(title: "SOUND", body: "Also play chords on Beat Key's piano.")

    // YouTube sign-in (its own button, not the DOWNLOAD cap's tip)
    static let login = HelpTip(title: "LOG IN TO YOUTUBE", body: "Open YouTube sign-in. Login stays on this Mac.")
    // paging and the empty readout
    static let prevFile = HelpTip(title: "PREVIOUS FILE", body: "Previous file (←)")
    static let nextFile = HelpTip(title: "NEXT FILE", body: "Next file (→)")
    static let readout = HelpTip(title: "READOUT", body: "Paste, open or listen to read a beat.")

    // Settings (the Settings window)
    static let settingsHighContrast = HelpTip(title: "HIGH CONTRAST", body: "Brighter text, no glow. Lamp shapes stay.")
    static let settingsListenTo = HelpTip(title: "LISTEN TO", body: "System audio or one input. Nothing saved.")
    static let settingsChannel = HelpTip(title: "CHANNEL", body: "Interface channel to read, or all.")
    static let settingsStartOver = HelpTip(title: "START OVER AFTER", body: "Silence length that ends a song.")
    static let settingsRename = HelpTip(title: "FILE NAMES", body: "Add key + BPM to names. Pro Tools files always ask.")
    static let settingsOpenAtLogin = HelpTip(title: "OPEN AT LOGIN", body: "Start Beat Key at login.")
    static let settingsShortcuts = HelpTip(title: "SHORTCUTS", body: "Quick Keys: every shortcut. Click one, type new keys.")

    // Permissions guide
    static let permissionGuide = HelpTip(title: "SET UP PERMISSIONS", body: "Checks each permission. Menu: \(Brand.setUpPermissions)")
    /// One line per permission (the guide window's own longer text is PermissionKind.why).
    static func permission(_ k: PermissionKind) -> HelpTip {
        let body: String
        switch k {
        case .screen: body = "Hear Mac audio. Turn on Beat Key."
        case .microphone: body = "Hear a mic or interface. Turn on Beat Key."
        case .accessibility: body = "Type BPM and key into your DAW. Turn on Beat Key."
        }
        return HelpTip(title: k.title.uppercased(), body: body)
    }
    static let permissionScreen = permission(.screen)
    static let permissionMicrophone = permission(.microphone)
    static let permissionAccessibility = permission(.accessibility)

    // Doctor
    static let runDoctor = HelpTip(title: "RUN DOCTOR", body: "Check and repair downloader, ffmpeg, analyzer.")
    static let doctorResult = HelpTip(title: "DOCTOR RESULT", body: "OK · FIXED IT · FOUND A PROBLEM (see line below)")

    // Keys and shortcuts
    static let keysOctave = HelpTip(title: "OCTAVE · Z X", body: "Z octave down, X up. Link field empty.")
    static let keysMode = HelpTip(title: "MAJOR / MINOR · SPACE", body: "Space flips the keyboard major/minor.")
    static let keysPaging = HelpTip(title: "PAGE FILES · ← →", body: "Arrows page files. Link field empty.")
    static let keysAutoTune = HelpTip(title: "AUTO-TUNE SHORTCUT", body: "Send key to Auto-Tune (\(AutoTuneSend.shortcutDisplay))")
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
        HelpSection(title: "Menu bar pocket only", tips: [analyzeFile, window, quit]),
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

// MARK: the decision and the placement (pure, tested)

enum HelpTipLogic {
    /// A tip shows only in help mode, while hovered (or forced by an offscreen render).
    static func shows(helpOn: Bool, hovering: Bool, forced: Bool = false) -> Bool {
        helpOn && (hovering || forced)
    }

    /// The native tooltip a control shows: its text with help off; none with help on, so the
    /// system's slow yellow tooltip never lands on top of the amber card.
    static func nativeTooltip(_ text: String, helpOn: Bool) -> String { helpOn ? "" : text }

    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    /// One card placement as the layer made it (tests only listen: the real views' real frames).
    struct Placement {
        let tip: String
        let bounds: CGSize
        let control: CGRect
        let others: [CGRect]
        let card: CGSize
        let origin: CGPoint
    }
    /// Tests only: called for every placement the floating card computes.
    static var onPlace: ((Placement) -> Void)?

    /// Where the card goes for a control at `r` on a surface of `size`: its left edge (centred on
    /// the control, kept inside the margins) and whether it sits below the control (else above).
    /// Below unless the room there is short and there is more above.
    static func place(_ r: CGRect, in size: CGSize, width: CGFloat = HelpCard.width) -> (x: CGFloat, below: Bool) {
        let x = min(max(r.midX - width / 2, margin), max(margin, size.width - width - margin))
        let roomBelow = size.height - r.maxY - gap - margin
        let roomAbove = r.minY - gap - margin
        return (x, roomBelow >= 72 || roomBelow >= roomAbove)
    }

    /// The card's offset from the mouse, down-right like a tooltip (J 2026-11-09: cards appear at
    /// the mouse, like every other help style thing).
    static let cursorOffset = CGSize(width: 14, height: 16)
    /// The arrow / pointing hand the card must never cover: from the hot spot, this far down-right.
    static let cursorSize = CGSize(width: 12, height: 16)

    /// The pointer's footprint at `p` (y down).
    static func cursorRect(_ p: CGPoint) -> CGRect {
        CGRect(x: p.x - 1, y: p.y - 1, width: cursorSize.width + 1, height: cursorSize.height + 1)
    }

    /// Where a `card`-sized card goes for the mouse at `p` on a surface of `bounds` (y down):
    /// down-right of the pointer; flipped left / above when it would leave the surface, then kept
    /// inside the margins. It never covers the pointer unless the surface is too small to avoid it.
    static func cardOrigin(cursor p: CGPoint, card: CGSize, in bounds: CGSize) -> CGPoint {
        let m = margin, off = cursorOffset
        // the pointer hangs down-right of its hot spot, so the left / above sides need less gap
        let right = p.x + off.width, left = p.x - 8 - card.width
        let below = p.y + off.height, above = p.y - 6 - card.height
        let fitsRight = right + card.width <= bounds.width - m
        let fitsLeft = left >= m
        let fitsBelow = below + card.height <= bounds.height - m
        let fitsAbove = above >= m
        var x = fitsRight || !fitsLeft && (bounds.width - p.x >= p.x) ? right : left
        var y = fitsBelow || !fitsAbove && (bounds.height - p.y >= p.y) ? below : above
        x = min(max(x, m), max(m, bounds.width - card.width - m))
        y = min(max(y, m), max(m, bounds.height - card.height - m))
        // clamped back over the pointer: move to the other side vertically if that side has room
        if CGRect(x: x, y: y, width: card.width, height: card.height).intersects(cursorRect(p)) {
            if y >= p.y, above >= 0 { y = above } else if y < p.y, below + card.height <= bounds.height { y = below }
        }
        return CGPoint(x: x, y: y)
    }

    /// The frames a card must keep off while `control` is hovered: every other explainable control
    /// or readable part on the surface. Not counted: the hovered control's own frame, a group frame
    /// around it, a part inside it (they share its space), empty frames, and a frame reported twice.
    static func blockers(_ others: [CGRect], control: CGRect) -> [CGRect] {
        let slack: CGFloat = 0.5
        var out: [CGRect] = []
        for r in others where !r.isNull && !r.isInfinite && r.width > 0 && r.height > 0 {
            if r.insetBy(dx: -slack, dy: -slack).contains(control) { continue }     // the control itself, a group around it
            if control.insetBy(dx: -slack, dy: -slack).contains(r) { continue }     // a part of it
            if out.contains(where: { abs($0.minX - r.minX) < 1 && abs($0.minY - r.minY) < 1
                                    && abs($0.width - r.width) < 1 && abs($0.height - r.height) < 1 }) { continue }
            out.append(r)
        }
        return out
    }

    /// What a card at `r` costs: covering the hovered control is the worst thing (it hides what the
    /// card explains and the button under the mouse); every other control it touches costs a flat
    /// 0.5 plus the share of it that is hidden, so one corner of a big panel beats a whole small
    /// button. 0 = the card covers nothing.
    static func coverage(_ r: CGRect, control: CGRect, blockers: [CGRect]) -> CGFloat {
        func share(_ b: CGRect) -> CGFloat {
            let i = b.intersection(r)
            guard !i.isNull, i.width * i.height > 0.5, b.width * b.height > 0 else { return 0 }
            return i.width * i.height / (b.width * b.height)
        }
        var cost: CGFloat = 0
        let own = share(control)
        if own > 0 { cost += 4 + 4 * own }
        for b in blockers { let f = share(solid(b)); if f > 0 { cost += 0.5 + f } }
        return cost
    }

    /// A measured frame is its layout box: text carries a little tracking and line-height past its
    /// glyphs. A card may overlap that margin (and nothing else of it).
    static let edgeSlack: CGFloat = 2
    static func solid(_ b: CGRect) -> CGRect {
        b.width > edgeSlack * 4 && b.height > edgeSlack * 4 ? b.insetBy(dx: edgeSlack, dy: edgeSlack) : b
    }

    /// Where the card goes, and what it still covers there (0 = nothing).
    struct Plan: Equatable {
        var origin: CGPoint
        var covers: CGFloat
    }

    /// The same as `cardOrigin(cursor:card:in:)`, but the card never covers the hovered control or
    /// any other control or readable part (J 2026-11-17: DOWNLOAD's card covered FIND KEY/BPM, then
    /// SEND TO AUTO-TUNE's covered itself, EXPORT MIDI, HELP and ADVANCED, PREVIOUS FILE's covered
    /// "3 OF 3"). `control` is the hovered control's frame, `others` every frame the card avoids.
    /// The card follows the mouse as before when that covers nothing; otherwise it takes the
    /// clearest spot anywhere on the surface (next to the hovered control first, then the empty
    /// parts of the panel), and when no spot is fully clear, the one that covers least. Never the
    /// pointer, always inside the surface. The spot depends only on the control, so the card holds
    /// still while the mouse moves inside it.
    static func cardOrigin(cursor p: CGPoint, card: CGSize, in bounds: CGSize,
                           control: CGRect, avoiding others: [CGRect]) -> CGPoint {
        plan(cursor: p, card: card, in: bounds, control: control, avoiding: others).origin
    }

    static func plan(cursor p: CGPoint, card: CGSize, in bounds: CGSize,
                     control: CGRect, avoiding others: [CGRect]) -> Plan {
        let base = cardOrigin(cursor: p, card: card, in: bounds)
        let blocked = blockers(others, control: control)
        let baseCovers = coverage(CGRect(origin: base, size: card), control: control, blockers: blocked)
        if baseCovers == 0 { return Plan(origin: base, covers: 0) }
        let key = SpotKey(card: card, bounds: bounds, control: control, blockers: blocked)
        var best = spotCache.lookup(key) ?? {
            let found = bestSpot(card: card, bounds: bounds, control: control, blockers: blocked, keepOff: nil)
            spotCache.store(key, found)
            return found
        }()
        if CGRect(origin: best.origin, size: card).intersects(cursorRect(p)) {
            best = bestSpot(card: card, bounds: bounds, control: control, blockers: blocked, keepOff: cursorRect(p))
        }
        return best.covers < baseCovers ? best : Plan(origin: base, covers: baseCovers)
    }

    /// One placement search's inputs (the cache's key).
    struct SpotKey: Equatable {
        let card: CGSize
        let bounds: CGSize
        let control: CGRect
        let blockers: [CGRect]
    }

    /// The last search's answer: a mouse move inside one control asks the same question again.
    private final class SpotCache {
        private let lock = NSLock()
        private var key: SpotKey?
        private var plan: Plan?
        func lookup(_ k: SpotKey) -> Plan? {
            lock.lock(); defer { lock.unlock() }
            return key == k ? plan : nil
        }
        func store(_ k: SpotKey, _ p: Plan) {
            lock.lock(); key = k; plan = p; lock.unlock()
        }
    }
    private static let spotCache = SpotCache()

    /// The best spot over every origin worth trying: flush to each control's edges and to the
    /// surface's margins, so a card tucks into whatever gap there is. Least covered first; among
    /// equals the closest to the hovered control (a small pull, never worth covering something).
    static func bestSpot(card: CGSize, bounds: CGSize, control: CGRect, blockers: [CGRect],
                         keepOff: CGRect?) -> Plan {
        let m = margin, w = card.width, h = card.height
        let maxX = max(m, bounds.width - w - m), maxY = max(m, bounds.height - h - m)
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, m), maxX) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, m), maxY) }
        var xs: Set<CGFloat> = [m, maxX, clampX(control.midX - w / 2)]
        var ys: Set<CGFloat> = [m, maxY, clampY(control.midY - h / 2)]
        for r in blockers + [control] {
            let c = solid(r)    // flush to a control's solid edge fits a card into a gap the margin would waste
            for x in [r.minX - gap - w, r.maxX + gap, r.minX, r.maxX - w, r.midX - w / 2, c.minX - w, c.maxX] {
                xs.insert(clampX(x).rounded(.toNearestOrEven))
            }
            for y in [r.minY - gap - h, r.maxY + gap, r.minY, r.maxY - h, r.midY - h / 2, c.minY - h, c.maxY] {
                ys.insert(clampY(y).rounded(.toNearestOrEven))
            }
        }
        for x in stride(from: m, through: maxX, by: 6) { xs.insert(x) }     // open panel anywhere
        for y in stride(from: m, through: maxY, by: 6) { ys.insert(y) }
        let reach = hypot(bounds.width, bounds.height)
        var best: (plan: Plan, score: CGFloat)?
        for y in ys {
            for x in xs {
                let r = CGRect(x: x, y: y, width: w, height: h)
                if let k = keepOff, r.intersects(k) { continue }
                let covers = coverage(r, control: control, blockers: blockers)
                var score = covers + 0.3 * hypot(r.midX - control.midX, r.midY - control.midY) / reach
                // a clear card with room around it beats one squeezed against a neighbour
                if covers == 0, coverage(r.insetBy(dx: -gap, dy: -gap), control: control, blockers: blockers) > 0 { score += 0.05 }
                if best == nil || score < best!.score - 1e-9 { best = (Plan(origin: CGPoint(x: x, y: y), covers: covers), score) }
            }
        }
        return best?.plan ?? Plan(origin: CGPoint(x: clampX(control.maxX + gap), y: clampY(control.minY)), covers: .infinity)
    }

    /// Cards that had no clear spot, logged once per tip and surface size (a hover would repeat it).
    private static var loggedCrowded = Set<String>()

    /// Writes the app log line for a card that still covers something. Not a failure for the
    /// customer (cosmetic), but it is how a crowded layout gets found.
    static func logCrowded(tip: String, bounds: CGSize, plan: Plan, card: CGSize) {
        guard plan.covers > 0 else { return }
        let key = "\(tip)|\(Int(bounds.width))x\(Int(bounds.height))|\(Int(card.height))"
        guard loggedCrowded.insert(key).inserted else { return }
        AppLog.log("help card \"\(tip)\": no clear spot on a \(Int(bounds.width))x\(Int(bounds.height)) surface for a "
                   + "\(Int(card.width))x\(Int(card.height)) card; placed at \(Int(plan.origin.x)),\(Int(plan.origin.y)) "
                   + "covering the least (cost \(String(format: "%.2f", Double(plan.covers))))")
    }
}

// MARK: the card (the key wheel's hover card: one look for every hover card)

struct HelpCard: View {
    @Environment(\.palette) private var palette
    let title: String
    let text: String
    var width: CGFloat = HelpCard.width

    static let width: CGFloat = 212

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.S.xs) {
            Text(title).labelStyle().foregroundColor(palette.a1)
            Text(text).font(Theme.T.note).foregroundColor(palette.a2)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.S.s + 2).padding(.vertical, Theme.S.s)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.R.well).fill(Theme.hex(0x15100a)))   // opaque: nothing ghosts through
        .overlay(RoundedRectangle(cornerRadius: Theme.R.well).stroke(palette.a3, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.5), radius: 6, y: 2)
    }
}

// MARK: the modifier and the layer

private struct HelpModeKey: EnvironmentKey { static let defaultValue = false }
private struct HelpTipForcedKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// Help mode for this surface (the root sets it from PocketState.help).
    var helpMode: Bool {
        get { self[HelpModeKey.self] }
        set { self[HelpModeKey.self] = newValue }
    }
    /// Offscreen renders: the tip with this title shows as if hovered.
    var helpTipForced: String? {
        get { self[HelpTipForcedKey.self] }
        set { self[HelpTipForcedKey.self] = newValue }
    }
}

/// The hovered control's tip and where it is, handed up to the surface's layer.
struct HelpTipAnchor {
    let tip: HelpTip
    let anchor: Anchor<CGRect>
    var width: CGFloat = HelpCard.width
}

/// What the surface's card layer collects: the hovered control's tip (if any) and, in help mode,
/// where every explainable control sits, so the card can keep off the neighbours.
struct HelpTipPrefs {
    var tip: HelpTipAnchor?
    var controls: [Anchor<CGRect>] = []
}

struct HelpTipKey: PreferenceKey {
    static var defaultValue = HelpTipPrefs()
    static func reduce(value: inout HelpTipPrefs, nextValue: () -> HelpTipPrefs) {
        let n = nextValue()
        if n.tip != nil { value.tip = n.tip }
        value.controls += n.controls
    }
}

private struct HelpTipModifier: ViewModifier {
    let tip: HelpTip
    @Environment(\.helpMode) private var helpOn
    @Environment(\.helpTipForced) private var forced
    @State private var hovering = false

    func body(content: Content) -> some View {
        let active = HelpTipLogic.shows(helpOn: helpOn, hovering: hovering, forced: forced == tip.id)
        // the same view tree whether help is on or off (nothing inside resets on a toggle)
        return content
            .onHover { inside in if helpOn || !inside { hovering = inside } }
            .transformAnchorPreference(key: HelpTipKey.self, value: .bounds) { v, a in
                if helpOn { v.controls.append(a) }
                // an inner control's tip wins over the group around it
                if active && v.tip == nil { v.tip = HelpTipAnchor(tip: tip, anchor: a) }
            }
    }
}

private struct HelpBlockerModifier: ViewModifier {
    @Environment(\.helpMode) private var helpOn

    func body(content: Content) -> some View {
        content.transformAnchorPreference(key: HelpTipKey.self, value: .bounds) { v, a in
            if helpOn { v.controls.append(a) }
        }
    }
}

/// A native `.help` tooltip that steps aside in help mode (the amber card explains instead).
private struct NativeHelpModifier: ViewModifier {
    let text: String
    @Environment(\.helpMode) private var helpOn

    func body(content: Content) -> some View {
        content.help(Text(HelpTipLogic.nativeTooltip(text, helpOn: helpOn)))
    }
}

/// The mouse over a surface (its own coordinates, y down), nil when outside. Only the floating
/// card observes it, so a mouse move redraws the card, never the surface.
final class HelpCursor: ObservableObject {
    @Published var point: CGPoint?
}

private struct HelpTipLayer: ViewModifier {
    @StateObject private var cursor = HelpCursor()

    func body(content: Content) -> some View {
        content
            .overlay(tracker)
            .overlayPreferenceValue(HelpTipKey.self) { prefs in
                GeometryReader { g in
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        if let v = prefs.tip {
                            FloatingHelpCard(tip: v.tip, width: v.width, control: g[v.anchor], bounds: g.size,
                                             others: prefs.controls.map { g[$0] }, cursor: cursor)
                                .id(v.tip.id).transition(.opacity)
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                }
                .animation(.easeOut(duration: 0.12), value: prefs.tip?.tip.id)
                .allowsHitTesting(false)
            }
    }

    /// The surface-wide mouse tracker (lets every click through). Offscreen renders have no mouse.
    @ViewBuilder private var tracker: some View {
        if !Pocket.snapshot {
            MouseTracker { [cursor] p in cursor.point = p }
        }
    }
}

/// The card at the mouse: down-right of the pointer, following it, flipped and kept inside the
/// surface (HelpTipLogic.cardOrigin). No mouse (an offscreen render's forced tip) = the
/// control's centre stands in for it.
private struct FloatingHelpCard: View {
    let tip: HelpTip
    let width: CGFloat
    let control: CGRect
    let bounds: CGSize
    /// Every explainable control's frame: the card keeps off the neighbours.
    var others: [CGRect] = []
    @ObservedObject var cursor: HelpCursor
    @State private var size: CGSize = .zero

    var body: some View {
        let p = cursor.point ?? CGPoint(x: control.midX, y: control.midY)
        let card = size == .zero ? CGSize(width: width, height: 52) : size
        let plan = HelpTipLogic.plan(cursor: p, card: card, in: bounds, control: control, avoiding: others)
        let o = plan.origin
        if size != .zero { HelpTipLogic.logCrowded(tip: tip.id, bounds: bounds, plan: plan, card: card) }
        HelpTipLogic.onPlace?(HelpTipLogic.Placement(tip: tip.id, bounds: bounds, control: control, others: others,
                                                     card: card, origin: o))
        return HelpCard(title: tip.title, text: tip.body, width: width)
            .fixedSize()
            .background(GeometryReader { g in Color.clear.preference(key: HelpCardSizeKey.self, value: g.size) })
            .onPreferenceChange(HelpCardSizeKey.self) { s in if s != size { size = s } }
            .offset(x: o.x, y: o.y)
    }
}

private struct HelpCardSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

extension View {
    /// In help mode, hovering this view shows `tip` on the shared amber card. Off = nothing.
    func helpTip(_ tip: HelpTip) -> some View { modifier(HelpTipModifier(tip: tip)) }

    /// A readable part or control with no tip of its own (the "3 OF 3" counter): in help mode the
    /// cards keep off it too.
    func helpBlocker() -> some View { modifier(HelpBlockerModifier()) }

    /// An always-on hover card (the key wheel's): shown at the mouse while `tip` is non-nil, help
    /// mode or not, on the surface's card layer.
    func hoverCard(_ tip: HelpTip?, width: CGFloat = HelpCard.width) -> some View {
        transformAnchorPreference(key: HelpTipKey.self, value: .bounds) { v, a in
            if let t = tip, v.tip == nil { v.tip = HelpTipAnchor(tip: t, anchor: a, width: width) }
        }
    }

    /// The native tooltip, shown only while help mode is off. Every `.help` on the faceplate goes here.
    func nativeHelp(_ text: String) -> some View { modifier(NativeHelpModifier(text: text)) }

    /// The surface's card layer (the window's face, the pocket): above every view in it.
    func helpTipLayer() -> some View { modifier(HelpTipLayer()) }
}

// MARK: the HELP chip

/// HELP in the footer: an outlined chip in the display colour when off (so it reads as a button,
/// not a disabled one; J 2026-11-17), filled amber (the ×1 chip's lit look) when on.
struct HelpChip: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        // the footer's one chip (FooterChip), lit while help mode is on
        FooterChip(title: "HELP", label: "Help mode", on: on, accent: true, action: action)
            .nativeHelp("Help mode: hover for tips")
            .helpTip(HelpText.help)
            .accessibility(hint: Text(on ? "Turns help mode off" : "Turns help mode on: hover for tips"))
    }
}
