import AppKit
import SwiftUI
import XCTest
@testable import Orion

/// 2026-11-19: the key wheel's hover card sits next to the mouse (J: it jumped above / below the
/// wheel and spazzed). One placement function (HelpTipLogic.followOrigin / plan) owns it.
final class HoverFollowTests: XCTestCase {
    private let card = CGSize(width: 196, height: 84)
    private let bounds = CGSize(width: 376, height: 420)     // the pocket: narrower than card + pointer on its right half
    private let wide = CGSize(width: 552, height: 640)       // the window
    private typealias L = HelpTipLogic

    /// Walks the mouse through `points`, carrying the side like the live card does.
    private func walk(_ points: [CGPoint]) -> [(origin: CGPoint, side: L.FollowSide)] {
        var side = L.FollowSide()
        return points.map { p in
            let r = L.followOrigin(cursor: p, card: card, in: wide, side: side)
            side = r.side
            return r
        }
    }

    func testNoFlipAnywhereThePointerHasRoom() {
        let m = L.margin, off = L.cursorOffset
        for x in stride(from: 0.0, through: Double(bounds.width), by: 7) {
            for y in stride(from: 0.0, through: Double(bounds.height), by: 7) {
                let p = CGPoint(x: x, y: y)
                guard p.x + off.width + card.width <= bounds.width - m,
                      p.y + off.height + card.height <= bounds.height - m else { continue }
                let r = L.followOrigin(cursor: p, card: card, in: bounds)
                XCTAssertEqual(r.side, L.FollowSide(), "flipped with room at \(p)")
                XCTAssertEqual(r.origin.x, max(m, p.x + off.width), accuracy: 0.001)
                XCTAssertEqual(r.origin.y, max(m, p.y + off.height), accuracy: 0.001)
            }
        }
    }

    func testFlipsOnlyAtTheEdgeAndThenKeepsInside() {
        let m = L.margin
        // right edge: the card flips left of the pointer exactly when down-right would leave the surface
        let edgeX = wide.width - m - card.width - L.cursorOffset.width     // last x that fits on the right
        let before = L.followOrigin(cursor: CGPoint(x: edgeX, y: 100), card: card, in: wide)
        XCTAssertFalse(before.side.left)
        let after = L.followOrigin(cursor: CGPoint(x: edgeX + 1, y: 100), card: card, in: wide)
        XCTAssertTrue(after.side.left)
        XCTAssertLessThan(after.origin.x + card.width, edgeX + 1)
        // bottom edge: above
        let edgeY = wide.height - m - card.height - L.cursorOffset.height
        XCTAssertFalse(L.followOrigin(cursor: CGPoint(x: 100, y: edgeY), card: card, in: wide).side.above)
        let up = L.followOrigin(cursor: CGPoint(x: 100, y: edgeY + 1), card: card, in: wide)
        XCTAssertTrue(up.side.above)
        XCTAssertLessThan(up.origin.y + card.height, edgeY + 1)
        // always inside the margins, never over the pointer
        for p in stride(from: 0.0, through: Double(bounds.width), by: 9).flatMap({ x in
            stride(from: 0.0, through: Double(bounds.height), by: 9).map { CGPoint(x: x, y: $0) } }) {
            let o = L.followOrigin(cursor: p, card: card, in: bounds).origin
            let r = CGRect(origin: o, size: card)
            XCTAssertGreaterThanOrEqual(r.minX, m - 0.001); XCTAssertGreaterThanOrEqual(r.minY, m - 0.001)
            XCTAssertLessThanOrEqual(r.maxX, bounds.width - m + 0.001); XCTAssertLessThanOrEqual(r.maxY, bounds.height - m + 0.001)
            XCTAssertFalse(r.intersects(L.cursorRect(p)), "card covers the pointer at \(p)")
        }
    }

    func testHysteresisAtTheEdgeDoesNotFlicker() {
        let edgeX = wide.width - L.margin - card.width - L.cursorOffset.width
        // jitter +-6 px around the edge: one flip at most, not one per wobble
        let jitter = (0..<60).map { CGPoint(x: edgeX + 1 + CGFloat($0 % 2 == 0 ? -6 : 6) * 0.5, y: 100) }
        let flips = zip(walk(jitter), walk(jitter).dropFirst()).filter { $0.0.side != $0.1.side }.count
        XCTAssertLessThanOrEqual(flips, 1)
        // sweep out past the edge and back: it flips left at the edge, back to the right only flipSlack later
        let out = stride(from: edgeX - 40, through: edgeX + 40, by: 1).map { CGPoint(x: $0, y: 100) }
        let back = Array(out.reversed())
        let steps = walk(out + back)
        let leftAt = out[steps.firstIndex { $0.side.left }!].x
        XCTAssertEqual(leftAt, edgeX + 1, accuracy: 0.001)
        let rightAgain = steps.indices.dropFirst(out.count).first { !steps[$0].side.left }!
        let backX = (out + back)[rightAgain].x
        XCTAssertEqual(backX, edgeX - L.flipSlack, accuracy: 1.001)       // flipSlack of travel before it flips back
        // and it flips exactly twice over the round trip
        XCTAssertEqual(zip(steps, steps.dropFirst()).filter { $0.0.side != $0.1.side }.count, 2)
    }

    func testOnePixelOfMouseIsAtMostOnePixelOfCard() {
        var sideLeft = false
        for y in stride(from: 40.0, through: 380.0, by: 20) {
            var side = L.FollowSide()
            var last: (CGPoint, L.FollowSide)?
            for x in stride(from: 0.0, through: Double(bounds.width), by: 1) {
                let r = L.followOrigin(cursor: CGPoint(x: x, y: y), card: card, in: bounds, side: side)
                side = r.side
                if let l = last, l.1 == r.side {
                    XCTAssertLessThanOrEqual(abs(r.origin.x - l.0.x), 1.0001, "x jumped at \(x),\(y)")
                    XCTAssertLessThanOrEqual(abs(r.origin.y - l.0.y), 1.0001, "y jumped at \(x),\(y)")
                }
                if r.side.left { sideLeft = true }
                last = (r.origin, r.side)
            }
        }
        for x in stride(from: 30.0, through: 340.0, by: 20) {
            var side = L.FollowSide()
            var last: (CGPoint, L.FollowSide)?
            for y in stride(from: 0.0, through: Double(bounds.height), by: 1) {
                let r = L.followOrigin(cursor: CGPoint(x: x, y: y), card: card, in: bounds, side: side)
                side = r.side
                if let l = last, l.1 == r.side {
                    XCTAssertLessThanOrEqual(abs(r.origin.x - l.0.x), 1.0001, "x jumped at \(x),\(y)")
                    XCTAssertLessThanOrEqual(abs(r.origin.y - l.0.y), 1.0001, "y jumped at \(x),\(y)")
                }
                last = (r.origin, r.side)
            }
        }
        XCTAssertTrue(sideLeft, "the sweep never reached the flip, so it proved nothing about it")
    }

    /// The bug: with the whole key wheel as the hovered control the old search threw the card
    /// above or below the wheel, a different side as the mouse moved. A following card is next to
    /// the pointer wherever it is on the wheel, whatever the wheel's frame.
    func testFollowCardIgnoresTheWheelsFrame() {
        let wheel = CGRect(x: 80, y: 120, width: 216, height: 216)
        var sideOld = L.FollowSide(), sideNew = L.FollowSide()
        var oldLeftThePointer = 0
        for x in stride(from: 100.0, through: 270.0, by: 10) {
            let p = CGPoint(x: x, y: 200)
            let old = L.plan(cursor: p, card: card, in: bounds, control: wheel, avoiding: [], side: &sideOld)
            let new = L.plan(cursor: p, card: card, in: bounds, control: wheel, avoiding: [], follow: true, side: &sideNew)
            XCTAssertEqual(new.origin.y, p.y + L.cursorOffset.height, accuracy: 0.001)      // beside, never above / below the wheel
            if x + L.cursorOffset.width + card.width <= bounds.width - L.margin {
                XCTAssertEqual(new.origin.x, p.x + L.cursorOffset.width, accuracy: 0.001)
            }
            if abs(old.origin.y - (p.y + L.cursorOffset.height)) > 20 { oldLeftThePointer += 1 }
        }
        // the old search (still what help mode's button tips use) threw the card off the pointer: this is the bug
        XCTAssertGreaterThan(oldLeftThePointer, 0)
    }

    func testHelpModeButtonTipsStillKeepOffTheirButton() {
        // follow == false is the 0.1.74-bug guard: a tip never covers its own button
        let button = CGRect(x: 100, y: 200, width: 140, height: 36)
        var side = L.FollowSide()
        let p = CGPoint(x: 120, y: 210)
        let plan = L.plan(cursor: p, card: card, in: bounds, control: button, avoiding: [button], side: &side)
        XCTAssertFalse(CGRect(origin: plan.origin, size: card).intersects(button))
    }

    func testBadNumbersStillPlaceTheCard() {
        let r = L.followOrigin(cursor: CGPoint(x: CGFloat.nan, y: 5), card: card, in: bounds)
        XCTAssertEqual(r.origin, CGPoint(x: L.margin, y: L.margin))
        let z = L.followOrigin(cursor: CGPoint(x: 10, y: 10), card: card, in: .zero)
        XCTAssertTrue(z.origin.x.isFinite && z.origin.y.isFinite)
    }

    func testTheWheelAsksForAFollowingCard() throws {
        let src = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/OrionTests/HoverFollowTests.swift", with: "Sources/Orion/Face/HarmonyView.swift"))
        XCTAssertTrue(src.contains(".hoverCard(hover.map(tip(for:)), width: 196, follow: true)"))
    }

    // MARK: renders (swift test --filter HoverFollowTests/testRender)

    @MainActor
    func testRenderBeforeAfter() throws {
        guard #available(macOS 13.0, *) else { throw XCTSkip("ImageRenderer is macOS 13+") }
        Pocket.snapshot = true
        defer { Pocket.snapshot = false }
        let dir = ProcessInfo.processInfo.environment["ORION_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("hover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let raw = Result(file: URL(fileURLWithPath: "/x/Beats/Beat A.wav"), name: "Beat A.wav", bpm: "141.98",
                         keys: [("Ebm", 80), ("F#", 12), ("Bbm", 8)], bpmExact: 141.98, tuningCents: 0,
                         chroma: [1.0, 0.08, 0.42, 0.81, 0.06, 0.37, 0.1, 0.93, 0.62, 0.05, 0.48, 0.12])
        let s = SpellingSettings()
        var st = PocketState()
        st.readout = .result(raw, page: nil, download: false, options: ResultOptions(
            factor: .one, tuning: Tuning.meter(0, reference: 440), onCycleTempo: {}))
        let wheel = HarmonyPanel.wheel(st, settings: s)
        let frame = CGRect(x: (bounds.width - KeyWheel.side) / 2, y: 110, width: KeyWheel.side, height: KeyWheel.side)

        struct Spot { let name: String; let p: CGPoint; let section: Int }
        let spots = [Spot(name: "upper left of the wheel", p: CGPoint(x: frame.minX + 60, y: frame.minY + 50), section: 20),
                     Spot(name: "centre, mouse moved 40 px right", p: CGPoint(x: frame.midX + 40, y: frame.midY), section: 2),
                     Spot(name: "right edge of the window", p: CGPoint(x: frame.maxX - 20, y: frame.midY - 30), section: 3),
                     Spot(name: "bottom of the wheel", p: CGPoint(x: frame.midX - 30, y: frame.maxY - 25), section: 12)]

        func scene(_ spot: Spot, follow: Bool) -> some View {
            var side = L.FollowSide()
            let tip = wheel.tip(for: spot.section)
            let c = L.plan(cursor: spot.p, card: CGSize(width: 196, height: 84), in: bounds, control: frame,
                           avoiding: [], follow: follow, side: &side)
            return ZStack(alignment: .topLeading) {
                Color(red: 0.08, green: 0.06, blue: 0.04)
                wheel.environment(\.manualHoverForced, nil).offset(x: frame.minX, y: frame.minY)
                Path { q in   // the pointer: a small arrow at its hot spot
                    q.move(to: spot.p); q.addLine(to: CGPoint(x: spot.p.x, y: spot.p.y + 15))
                    q.addLine(to: CGPoint(x: spot.p.x + 4, y: spot.p.y + 11)); q.addLine(to: CGPoint(x: spot.p.x + 10, y: spot.p.y + 11))
                    q.closeSubpath()
                }.fill(Color.white).overlay(Path { q in
                    q.move(to: spot.p); q.addLine(to: CGPoint(x: spot.p.x, y: spot.p.y + 15))
                    q.addLine(to: CGPoint(x: spot.p.x + 4, y: spot.p.y + 11)); q.addLine(to: CGPoint(x: spot.p.x + 10, y: spot.p.y + 11))
                    q.closeSubpath()
                }.stroke(Color.black, lineWidth: 1))
                HelpCard(title: tip.title, text: tip.body, width: 196).fixedSize().offset(x: c.origin.x, y: c.origin.y)
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        }
        func write<V: View>(_ v: V, _ name: String) throws {
            let r = ImageRenderer(content: v.environment(\.colorScheme, .dark))
            r.scale = 2
            guard let cg = r.cgImage else { return XCTFail("no image for \(name)") }
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        for (i, spot) in spots.enumerated() {
            try write(scene(spot, follow: false), "before-\(i + 1)")
            try write(scene(spot, follow: true), "after-\(i + 1)")
        }
        // one sheet: left column before (the old search), right column after
        let sheet = HStack(alignment: .top, spacing: 12) {
            ForEach([false, true], id: \.self) { follow in
                VStack(spacing: 12) {
                    Text(follow ? "AFTER: next to the mouse" : "BEFORE: avoids the wheel")
                        .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 12) {
                            scene(spots[row * 2], follow: follow)
                            scene(spots[row * 2 + 1], follow: follow)
                        }
                    }
                }
            }
        }.padding(12).background(Color.black)
        try write(sheet, "before-after-sheet")
    }
}
