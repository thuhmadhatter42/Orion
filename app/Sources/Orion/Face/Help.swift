import AppKit
import SwiftUI

// Help mode (J, 2026-11-09): a HELP chip in the window's and the pocket's footer (and View › Help
// Mode). Off = the faceplate as it is, no extra text. On = hovering anything explainable shows a
// short amber card, the key wheel's own hover card look. One table (HelpText) holds every line;
// one modifier (.helpTip) attaches them; one layer per surface (.helpTipLayer) draws the card
// above every other view, at the mouse like a tooltip (down-right of the pointer, following it,
// flipped and kept inside the surface, never under the pointer; J 2026-11-09).

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
    /// A body with its shortcut last in parentheses (Board Talk); no shortcut = the words alone (the
    /// plug-in has no global shortcuts: AutoTuneSend.shortcutDisplay is "" there).
    static func withKeys(_ words: String, _ keys: String) -> String { keys.isEmpty ? words : "\(words) (\(keys))" }
    // keys(_:) — a Quick Keys row's shortcut, "" when none: HelpApp.swift (app), FaceHostPlugin.swift (plug-in).

    // the readout
    static let bpm = HelpTip(title: "BPM", body: "Click: normal, double or half time.")
    static let pitchToFit = HelpTip(title: "PITCH TO FIT", body: "Semitones to pitch the beat into your key.")
    static let tempoFactor = HelpTip(title: "×0.5 · ×1 · ×2", body: "Halve or double the BPM.")
    static let keyDial = HelpTip(title: "KEY", body: "The song's key. Ring and % show how sure Beat Key is.")
    static let confidence = HelpTip(title: "LOCKED · UNSURE", body: "LOCKED: 70% sure or more. UNSURE: under 70%.")
    static let topKeys = HelpTip(title: "TOP KEYS", body: "Three likeliest keys. Click to pin, again to unpin.")
    static let manual = HelpTip(title: "MANUAL", body: "Click to pin any of the 24 keys.")
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
    static let download = HelpTip(title: "DOWNLOAD", body: "Download MP3 from YouTube (pasted or copied link).")
    static let openAudio = HelpTip(title: "OPEN AUDIO", body: "Open audio file/s from Finder.")
    static let findKey = HelpTip(title: "ANALYZE", body: "Get BPM and key of the file. ← → page files.")
    /// The pocket's drop zone (a drop anywhere on the pocket, or a click: Analyze a File…).
    static let dropZone = HelpTip(title: "DROP AUDIO", body: withKeys("Get BPM and key of audio, video or MIDI files.", keys("analyzeFile")))
    static let source = HelpTip(title: "SOURCE", body: "System Audio, External Input, or App Input.")
    static let listen = HelpTip(title: "LISTEN", body: withKeys("Live BPM and key.", keys("listen")))
    static let hold = HelpTip(title: "HOLD", body: withKeys("Freeze the reading. Click again to unfreeze.", keys("hold")))
    static let reset = HelpTip(title: "NEW SONG", body: withKeys("Clear listen history.", keys("newSong")))

    // sending
    static let sendDAW = HelpTip(title: "SEND TO DAW", body: withKeys("Send BPM and key to the open DAW.", keys("sendDAW")))
    // the doctor's result on the LCD
    static let doctorResult = HelpTip(title: "DOCTOR RESULT", body: "OK · FIXED IT · FOUND A PROBLEM (see line below)")
    static let autoTune = HelpTip(title: "SEND TO AUTO-TUNE", body: withKeys("Set key in Auto-Tune", keys("sendAutoTune")))
    static let exportMidi = HelpTip(title: "EXPORT MIDI", body: withKeys("Export a MIDI file with tempo and key.", keys("exportMidi")))

    // the footer
    static let recent = HelpTip(title: "RECENT", body: "Past readings. Pick one to bring it back.")
    static let settings = HelpTip(title: "SETTINGS", body: withKeys("Open Beat Key Settings.", keys("settings")))
    static let color = HelpTip(title: "COLOR", body: "Pick the display colour. Reset to Amber.")
    static let report = HelpTip(title: "REPORT", body: "Email a report with log attached.")
    static let advanced = HelpTip(title: "ADVANCED", body: withKeys("Select to get the full Beat Key experience.", keys("advancedMode")))
    /// The pocket's OPEN BEAT KEY ›.
    static let openWindow = HelpTip(title: "OPEN BEAT KEY", body: "Open the full window: YouTube, MIDI export, chords.")
    static let help = HelpTip(title: "HELP", body: "Help on. Hover for tips. Click to turn off.")

    // Advanced mode
    static let keyWheel = HelpTip(title: "KEY WHEEL", body: "Circle of fifths. Click a key to pin it.")
    static let notesHeard = HelpTip(title: "NOTES HEARD", body: "Note strength. Dotted = in the scale.")
    static let chords = HelpTip(title: "CHORDS", body: "Click to play chord. Drag to a DAW as MIDI.")
    static let quality = HelpTip(title: "TRIAD · 7TH · 9TH", body: "Chord size: 3 notes, add 7th, add 7th and 9th.")
    static let voicing = HelpTip(title: "INVERSION", body: "Root position, 1st inversion, 2nd inversion. OPEN = spread.")
    static let bars = HelpTip(title: "BAR", body: "Bars per chord when dragged out as MIDI.")
    static let borrowed = HelpTip(title: "BORROWED", body: "Borrowed chords (modal interchange): parallel major/minor.")
    static let matchTo = HelpTip(title: "MATCH TO", body: "Pick your project's key. See the pitch to fit.")
    static let matchShift = HelpTip(title: "−6 … +6", body: "Semitones to pitch. The lit one fits.")
    static let mini = HelpTip(title: "MINI", body: "Small always-on-top chord pad. Plays over MIDI.")
    static let miniPanel = HelpTip(title: "BEAT KEY MINI", body: "Pads play MIDI in \"Beat Key\". Keys 1-7, Q W E R.")
    static let miniSound = HelpTip(title: "SOUND", body: "Also play chords on Beat Key's piano.")

    // YouTube sign-in (its own button, not the DOWNLOAD cap's tip)
    static let login = HelpTip(title: "LOG IN TO YOUTUBE", body: "Needed only for age-restricted videos.")
    // paging and the empty readout
    static let prevFile = HelpTip(title: "PREVIOUS FILE", body: "Previous file (←)")
    static let nextFile = HelpTip(title: "NEXT FILE", body: "Next file (→)")
    static let readout = HelpTip(title: "READOUT", body: "Paste, open or listen to read a beat.")

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

    /// One explainable frame on a surface, as the layer sees it (its own coordinates, y down).
    struct TipFrame: Equatable {
        let id: String
        let rect: CGRect
        /// A panel that sits over controls (the DOWNLOAD menu): the pointer over it explains nothing under it.
        var occludes = false
    }

    /// Which tip the pointer is on: the index into `frames`, nil = none. The innermost frame wins
    /// (the smallest one holding the pointer: a chip inside its group, the % inside the dial), a
    /// later one on a tie; an occluding panel holding the pointer wins over every tip under it.
    /// Decided from the frames and the pointer alone: SwiftUI's own `.onHover` did not report whole
    /// stretches of the window (the keyboard, scale, tuning), and a hover that never ended left
    /// the previous control's card up on the next one.
    static func resolve(at p: CGPoint, in frames: [TipFrame]) -> Int? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        var best: Int?
        for (i, f) in frames.enumerated() where !f.rect.isNull && !f.rect.isInfinite && f.rect.contains(p) {
            if f.occludes { return nil }
            if let b = best {
                let a = f.rect.width * f.rect.height, o = frames[b].rect.width * frames[b].rect.height
                if a <= o { best = i }
            } else { best = i }
        }
        return best
    }

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

    /// Which side of the pointer a card is on. Remembered between mouse moves so a card only flips
    /// at a surface edge and does not flicker back and forth there (`flipSlack`).
    struct FollowSide: Equatable {
        var left = false
        var above = false
    }
    /// How far from an edge the pointer must come back before a flipped card flips back.
    static let flipSlack: CGFloat = 24

    /// The one placement rule for a card that follows the mouse (J 2026-11-19: it jumped above or
    /// below the key wheel and spazzed; it must sit next to the mouse). A fixed offset down-right of
    /// the pointer, moving exactly with it (1 px of mouse = 1 px of card). It flips left / above
    /// only when it would leave the surface, and flips back only once `flipSlack` clears the edge;
    /// then it is kept inside the margins. It never covers the pointer unless the surface is too
    /// small to avoid it. A cursor, surface or card that is not a real number is logged once and
    /// the card goes to the margin, so a card is always placed.
    static func followOrigin(cursor p: CGPoint, card: CGSize, in bounds: CGSize,
                             side: FollowSide = FollowSide()) -> (origin: CGPoint, side: FollowSide) {
        guard p.x.isFinite, p.y.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              card.width.isFinite, card.height.isFinite else {
            logOnce("placement got a non-finite cursor/surface/card (\(p), \(bounds), \(card)); card put at the margin")
            return (CGPoint(x: margin, y: margin), side)
        }
        let m = margin, off = cursorOffset
        // the pointer hangs down-right of its hot spot, so the left / above sides need less gap
        let right = p.x + off.width, left = p.x - 8 - card.width
        let below = p.y + off.height, above = p.y - 6 - card.height
        func fitsRight(_ slack: CGFloat) -> Bool { right + card.width <= bounds.width - m - slack }
        func fitsBelow(_ slack: CGFloat) -> Bool { below + card.height <= bounds.height - m - slack }
        let fitsLeft = left >= m, fitsAbove = above >= m
        var next = side
        // a side changes only when the new side fits and the old one does not (back: with flipSlack
        // to spare); where neither fits (a surface narrower than the card) the card stays put on
        // its side, clamped, rather than jumping across the surface
        if side.left { if fitsRight(flipSlack) { next.left = false } }
        else if !fitsRight(0) && fitsLeft { next.left = true }
        if side.above { if fitsBelow(flipSlack) { next.above = false } }
        else if !fitsBelow(0) && fitsAbove { next.above = true }
        var x = next.left ? left : right
        var y = next.above ? above : below
        x = min(max(x, m), max(m, bounds.width - card.width - m))
        y = min(max(y, m), max(m, bounds.height - card.height - m))
        // clamped back over the pointer: move to the other side vertically if that side has room
        if CGRect(x: x, y: y, width: card.width, height: card.height).intersects(cursorRect(p)) {
            if y >= p.y, above >= 0 { y = above; next.above = true }
            else if y < p.y, below + card.height <= bounds.height { y = below; next.above = false }
        }
        return (CGPoint(x: x, y: y), next)
    }

    /// The same rule with no memory of the last side (first frame, tests).
    static func cardOrigin(cursor p: CGPoint, card: CGSize, in bounds: CGSize) -> CGPoint {
        followOrigin(cursor: p, card: card, in: bounds).origin
    }

    /// Things that should never happen, logged once each (a hover would repeat them every frame).
    private static var loggedOnce = Set<String>()
    static func logOnce(_ line: String) {
        guard loggedOnce.insert(line).inserted else { return }
        AppLog.log("hover card: " + line)
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
    /// any other control or readable part (J 2026-11-17: DOWNLOAD's card covered ANALYZE, then
    /// SEND TO AUTO-TUNE's covered itself, EXPORT MIDI, HELP and ADVANCED, PREVIOUS FILE's covered
    /// "3 OF 3"). `control` is the hovered control's frame, `others` every frame the card avoids.
    /// The card follows the mouse as before when that covers nothing; otherwise it takes the
    /// clearest spot anywhere on the surface (next to the hovered control first, then the empty
    /// parts of the panel), and when no spot is fully clear, the one that covers least. Never the
    /// pointer, always inside the surface. The spot depends only on the control, so the card holds
    /// still while the mouse moves inside it.
    static func cardOrigin(cursor p: CGPoint, card: CGSize, in bounds: CGSize,
                           control: CGRect, avoiding others: [CGRect]) -> CGPoint {
        var side = FollowSide()
        return plan(cursor: p, card: card, in: bounds, control: control, avoiding: others, side: &side).origin
    }

    /// `follow` = a hover card over a big surface (the key wheel): the card sits next to the mouse
    /// and nothing else decides where it goes (the hovered "control" is the whole wheel; keeping
    /// off it threw the card above or below it, b982707). Without `follow` (help mode's
    /// tips over buttons) the card also keeps off the hovered control and its neighbours, so a
    /// tip never covers its own button. `side` is the card's remembered side (hysteresis).
    static func plan(cursor p: CGPoint, card: CGSize, in bounds: CGSize,
                     control: CGRect, avoiding others: [CGRect],
                     follow: Bool = false, side: inout FollowSide) -> Plan {
        let f = followOrigin(cursor: p, card: card, in: bounds, side: side)
        side = f.side
        let base = f.origin
        if follow { return Plan(origin: base, covers: 0) }
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
    /// Sits next to the mouse and nothing else (the key wheel's cards), not around the control.
    var follow = false
}

/// What the surface's card layer collects: the hovered control's tip (if any) and, in help mode,
/// where every explainable control sits, so the card can keep off the neighbours.
struct HelpTipPrefs {
    /// An always-on hover card (`hoverCard`): the key wheel's, the pinned dial's.
    var tip: HelpTipAnchor?
    var controls: [Anchor<CGRect>] = []
    /// Help mode: every `.helpTip` control, whose card shows while the pointer is on it.
    var frames: [HelpTipFrameAnchor] = []
}

struct HelpTipFrameAnchor {
    let tip: HelpTip
    let anchor: Anchor<CGRect>
    var forced = false
    var occludes = false
}

struct HelpTipKey: PreferenceKey {
    static var defaultValue = HelpTipPrefs()
    static func reduce(value: inout HelpTipPrefs, nextValue: () -> HelpTipPrefs) {
        let n = nextValue()
        if n.tip != nil { value.tip = n.tip }
        value.controls += n.controls
        value.frames += n.frames
    }
}

private struct HelpTipModifier: ViewModifier {
    let tip: HelpTip
    @Environment(\.helpMode) private var helpOn
    @Environment(\.helpTipForced) private var forced

    func body(content: Content) -> some View {
        // the same view tree whether help is on or off (nothing inside resets on a toggle). It only
        // reports where it is: the surface's layer finds the tip under the pointer from these frames.
        content.transformAnchorPreference(key: HelpTipKey.self, value: .bounds) { v, a in
            guard helpOn else { return }
            v.controls.append(a)
            v.frames.append(HelpTipFrameAnchor(tip: tip, anchor: a, forced: forced == tip.id))
        }
    }
}

/// A panel drawn over controls: in help mode the pointer on it explains nothing under it.
private struct HelpOccluderModifier: ViewModifier {
    @Environment(\.helpMode) private var helpOn

    func body(content: Content) -> some View {
        content.transformAnchorPreference(key: HelpTipKey.self, value: .bounds) { v, a in
            if helpOn {
                v.controls.append(a)
                v.frames.append(HelpTipFrameAnchor(tip: HelpTip(title: "", body: ""), anchor: a, occludes: true))
            }
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
    @Published var point: CGPoint? {
        didSet { if point == nil { side = HelpTipLogic.FollowSide() } }
    }
    /// Which side of the mouse the card is on (not published: only the card's placement reads it).
    var side = HelpTipLogic.FollowSide()
}

private struct HelpTipLayer: ViewModifier {
    @StateObject private var cursor = HelpCursor()

    func body(content: Content) -> some View {
        content
            .overlay(tracker)
            .overlayPreferenceValue(HelpTipKey.self) { prefs in
                HelpCardHost(prefs: prefs, cursor: cursor).allowsHitTesting(false)
            }
    }

    /// The surface-wide mouse tracker (lets every click through). Offscreen renders have no mouse.
    @ViewBuilder private var tracker: some View {
        if !Pocket.snapshot {
            MouseTracker { [cursor] p in cursor.point = p }
        }
    }
}

/// What the layer draws: the always-on hover card if there is one, else (help mode) the card of the
/// control under the pointer, found from the frames (HelpTipLogic.resolve). Only this view observes
/// the mouse, so a move redraws the card, never the surface.
private struct HelpCardHost: View {
    let prefs: HelpTipPrefs
    @ObservedObject var cursor: HelpCursor

    var body: some View {
        GeometryReader { g in
            let shown = shownTip(g)
            ZStack(alignment: .topLeading) {
                Color.clear
                if let v = shown {
                    FloatingHelpCard(tip: v.tip, width: v.width, control: v.control, bounds: g.size,
                                     follow: v.follow, others: prefs.controls.map { g[$0] }, cursor: cursor)
                        // one card for the whole wheel: crossing a section swaps its text, no fade-out and in
                        .id(v.follow ? "follow-card" : v.tip.id).transition(.opacity)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .animation(.easeOut(duration: 0.12), value: shown?.tip.id)
        }
    }

    private struct Shown {
        let tip: HelpTip
        let control: CGRect
        var width: CGFloat = HelpCard.width
        var follow = false
    }

    private func shownTip(_ g: GeometryProxy) -> Shown? {
        if let v = prefs.tip { return Shown(tip: v.tip, control: g[v.anchor], width: v.width, follow: v.follow) }
        // an offscreen render's forced tip stands in for a mouse
        if let f = prefs.frames.first(where: { $0.forced }) { return Shown(tip: f.tip, control: g[f.anchor]) }
        guard let p = cursor.point, !prefs.frames.isEmpty else { return nil }
        let frames = prefs.frames.map { HelpTipLogic.TipFrame(id: $0.tip.id, rect: g[$0.anchor], occludes: $0.occludes) }
        guard let i = HelpTipLogic.resolve(at: p, in: frames) else { return nil }
        return Shown(tip: prefs.frames[i].tip, control: frames[i].rect)
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
    /// Sits next to the mouse and nothing else (HelpTipLogic.plan).
    var follow = false
    /// Every explainable control's frame: the card keeps off the neighbours.
    var others: [CGRect] = []
    @ObservedObject var cursor: HelpCursor
    @State private var size: CGSize = .zero

    var body: some View {
        // no mouse reading (the tracker has not reported yet, or an offscreen render): the control's
        // centre stands in, so the card still goes down-right of where the mouse must be
        if cursor.point == nil && !Pocket.snapshot {
            HelpTipLogic.logOnce("\"\(tip.id)\" shown with no mouse position; placed down-right of the control's centre")
        }
        let p = cursor.point ?? CGPoint(x: control.midX, y: control.midY)
        let card = size == .zero ? CGSize(width: width, height: 52) : size
        let plan = HelpTipLogic.plan(cursor: p, card: card, in: bounds, control: control, avoiding: others,
                                     follow: follow, side: &cursor.side)
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

    /// A panel drawn over controls (the DOWNLOAD menu): help mode shows no card for what is under it.
    func helpOccluder() -> some View { modifier(HelpOccluderModifier()) }

    /// A readable part or control with no tip of its own (the "3 OF 3" counter): in help mode the
    /// cards keep off it too.
    func helpBlocker() -> some View { modifier(HelpBlockerModifier()) }

    /// An always-on hover card (the key wheel's): shown at the mouse while `tip` is non-nil, help
    /// mode or not, on the surface's card layer.
    func hoverCard(_ tip: HelpTip?, width: CGFloat = HelpCard.width, follow: Bool = false) -> some View {
        transformAnchorPreference(key: HelpTipKey.self, value: .bounds) { v, a in
            if let t = tip, v.tip == nil { v.tip = HelpTipAnchor(tip: t, anchor: a, width: width, follow: follow) }
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
