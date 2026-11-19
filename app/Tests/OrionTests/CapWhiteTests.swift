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
        let c = CapWhite.rgb(accent: a, highContrast: false, tint: 0.10)
        XCTAssertEqual(c.0, 255, accuracy: 1e-9)
        XCTAssertEqual(c.1, 255 + (a.g - 255) * 0.10, accuracy: 1e-9)
        XCTAssertEqual(c.2, 255 + (a.b - 255) * 0.10, accuracy: 1e-9)
        // zero tint = the base, whatever the accent
        let z = CapWhite.rgb(accent: a, highContrast: false, tint: 0)
        XCTAssertEqual(z.2, 255)
        // out-of-range clamps, never fails
        let big = CapWhite.rgb(accent: a, highContrast: false, tint: 7)
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

    private func srgb(_ c: Color) -> NSColor { NSColor(c).usingColorSpace(.sRGB)! }

    /// J 2026-11-19: the Manual Key Selection's white leans toward the display colour by the same
    /// tint as the caps; High Contrast stays pure white.
    func testManualWhiteIsTheCapWhiteTintedTowardTheAccent() {
        let blue = Accent(80, 170, 255)
        for a in [Accent.amber, blue, Accent(40, 220, 90)] {
            let p = Palette(accent: a)
            let want = CapWhite.rgb(accent: a, highContrast: false)
            XCTAssertEqual(srgb(p.manualWhite).redComponent * 255, want.0, accuracy: 0.01)
            XCTAssertEqual(srgb(p.manualWhite).greenComponent * 255, want.1, accuracy: 0.01)
            XCTAssertEqual(srgb(p.manualWhite).blueComponent * 255, want.2, accuracy: 0.01)
            XCTAssertEqual(srgb(p.manualWhite), srgb(p.capWhite))
            let hc = srgb(Palette(accent: a, highContrast: true).manualWhite)
            XCTAssertEqual([hc.redComponent, hc.greenComponent, hc.blueComponent], [1, 1, 1])
        }
        // amber leans warm (blue lowest), blue leans cool (red lowest)
        let am = srgb(Palette(accent: .amber).manualWhite), bl = srgb(Palette(accent: blue).manualWhite)
        XCTAssertLessThan(am.blueComponent, am.redComponent)
        XCTAssertLessThan(bl.redComponent, bl.blueComponent)
    }
}
