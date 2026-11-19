import AppKit
import SwiftUI
import XCTest
@testable import Orion

/// The white of every white button is one function (`CapWhite`): pure white leaned toward the
/// display colour by one constant. Pure-colour tests, plus the before/after comparison renders:
/// ORION_CAPS_DIR=<dir> swift test --filter CapWhiteTests/testRenderComparison
final class CapWhiteTests: XCTestCase {
    private func lum(_ c: (Double, Double, Double)) -> Double {
        Accent(c.0, c.1, c.2).luminance
    }

    func testHighContrastIsPureWhiteInEveryAccent() {
        for a in [Accent.amber, Accent(80, 170, 255), Accent(40, 220, 90)] {
            let c = CapWhite.rgb(accent: a, highContrast: true)
            XCTAssertEqual(c.0, 255); XCTAssertEqual(c.1, 255); XCTAssertEqual(c.2, 255)
        }
    }

    func testTintIsOneConstantTowardTheAccent() {
        let a = Accent.amber
        let c = CapWhite.rgb(accent: a, highContrast: false, tint: 0.10, base: (255, 255, 255))
        XCTAssertEqual(c.0, 255, accuracy: 1e-9)
        XCTAssertEqual(c.1, 255 + (a.g - 255) * 0.10, accuracy: 1e-9)
        XCTAssertEqual(c.2, 255 + (a.b - 255) * 0.10, accuracy: 1e-9)
        // zero tint = the base, whatever the accent
        let z = CapWhite.rgb(accent: a, highContrast: false, tint: 0, base: (255, 255, 255))
        XCTAssertEqual(z.2, 255)
        // out-of-range clamps, never fails
        let big = CapWhite.rgb(accent: a, highContrast: false, tint: 7, base: (255, 255, 255))
        XCTAssertEqual(big.2, a.b, accuracy: 1e-9)
    }

    /// Reads as white, not cream: at the shipped tint the face keeps near-white luminance in
    /// the most saturated accents.
    func testDefaultTintReadsAsWhiteInEveryAccent() {
        for a in [Accent.amber, Accent(80, 170, 255), Accent(40, 220, 90), Accent(255, 60, 60), Accent(200, 80, 255)] {
            let c = CapWhite.rgb(accent: a, highContrast: false)
            XCTAssertGreaterThan(lum(c), 0.88, "\(a.described)")
            XCTAssertGreaterThanOrEqual(min(c.0, c.1, c.2), 255 * (1 - CapWhite.tint) - 0.001)
        }
    }

    // MARK: comparison renders

    @MainActor
    func testRenderComparison() throws {
        guard let dir = ProcessInfo.processInfo.environment["ORION_CAPS_DIR"] else {
            throw XCTSkip("set ORION_CAPS_DIR to write the cap comparison PNGs")
        }
        guard #available(macOS 13.0, *) else { throw XCTSkip("ImageRenderer is macOS 13+") }
        Pocket.snapshot = true
        defer {
            Pocket.snapshot = false
            CapWhite.tintOverride = nil
            CapWhite.baseOverride = nil
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var idle = PocketState()
        idle.source = "System Audio"
        idle.daw = "Pro Tools"
        var locked = idle
        let l = Result(file: URL(fileURLWithPath: "/x/Some Beat.mp3"), name: "Some Beat.mp3", bpm: "140.00",
                       keys: [("Cm", 88), ("Eb", 7), ("Gm", 3)], bpmExact: 140.00, tuningCents: 3)
        locked.readout = .result(l, page: nil, download: true, options: ResultOptions(
            factor: .one, tuning: Tuning.meter(3, reference: 440), onCycleTempo: {}))
        locked.recents = [Reading(l)]
        var listening = idle
        listening.listening = true
        listening.level = 0.62

        let accents: [(String, Accent)] = [("amber", .amber), ("blue", Accent(80, 170, 255))]
        let variants: [(String, Double, (Double, Double, Double))] = [
            ("white-0", 0, CapWhite.base), ("white-4", 0.04, CapWhite.base),
            ("white-6", 0.06, CapWhite.base), ("white-10", 0.10, CapWhite.base),
            ("silver-4", 0.04, CapWhite.silver)]
        func write<V: View>(_ v: V, _ name: String) throws {
            let r = ImageRenderer(content: v.environment(\.colorScheme, .dark))
            r.scale = 2
            guard let cg = r.cgImage else { return XCTFail("no image for \(name)") }
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(name).png"))
        }
        func win(_ s: PocketState, _ pal: Palette) -> some View {
            FaceplateFace(state: s, picked: [], url: .constant(""), fieldFocused: .constant(false),
                          pickFocused: .constant(false)).environment(\.palette, pal)
        }
        for (an, a) in accents {
            for (vn, t, base) in variants {
                CapWhite.tintOverride = t
                CapWhite.baseOverride = base
                let pal = Palette(accent: a)
                try write(win(locked, pal), "window-\(an)-\(vn)")
                try write(win(listening, pal), "window-listening-\(an)-\(vn)")
                try write(PocketView(state: locked, url: .constant("")).environment(\.palette, pal), "pocket-\(an)-\(vn)")
                try write(PocketView(state: listening, url: .constant("")).environment(\.palette, pal), "pocket-listening-\(an)-\(vn)")
            }
        }
    }
}
