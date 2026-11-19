import Foundation

public enum Tuning {
    /// Shown as presets in the menu; custom values are limited to `range`.
    public static let presets: [Double] = [432, 436, 438, 440, 442, 444, 450]
    public static let range: ClosedRange<Double> = 400...480
    public static let defaultReference = 440.0
    /// The offset is folded to -50...+50, so every confident track gets a line: +50 and -50 are the
    /// same tuning seen from either neighbouring semitone (J, 2026-11-08: Spotify pitched +50 ¢ live
    /// showed no line under the old 45 ¢ cap). The analyzer names the key on the same side.
    public static let maxOffset = 50.0

    /// The app's UserDefaults key for the reference pitch (TuningSettings writes it; the plug-in only
    /// reads it, from the app's domain, so SEND AUTO-TUNE sends the same reference the app would).
    public static let defaultsKey = "referencePitch"

    /// What a person typed in the Custom… box: a number inside `range`, else nil.
    public static func parse(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              range.contains(v) else { return nil }
        return v
    }

    public static func clamp(_ hz: Double) -> Double { min(max(hz, range.lowerBound), range.upperBound) }

    /// Cents the track sits above (+) or below (-) `reference`, from its cents against A = 440.
    /// Tuning repeats every semitone, so the answer is folded to -50...+50.
    public static func offset(trackCents: Double, reference: Double) -> Double {
        let raw = trackCents - 1200 * log2(reference / 440)
        return raw - 100 * (raw / 100).rounded()
    }

    /// The LCD line ("TUNING +12¢ · A=440"), or nil when there is no confident reading.
    public static func line(_ trackCents: Double?, reference: Double) -> String? {
        guard let c = trackCents else { return nil }
        let o = offset(trackCents: c, reference: reference)
        guard abs(o) <= maxOffset else { return nil }
        let n = Int(o.rounded())
        let signed = n > 0 ? "+\(n)" : (n < 0 ? "−\(-n)" : "0")
        return "TUNING \(signed)¢ · A=\(refText(reference))"
    }

    public static func refText(_ hz: Double) -> String {
        hz == hz.rounded() ? String(Int(hz)) : String(format: "%g", hz)
    }

    /// The TUNING meter's reading (J 2026-11-09, Orra's meter), or nil when there is no confident
    /// reading: the same rule as `line`.
    public static func meter(_ trackCents: Double?, reference: Double) -> TuningMeter? {
        guard let c = trackCents else { return nil }
        let o = offset(trackCents: c, reference: reference)
        guard abs(o) <= maxOffset else { return nil }
        return TuningMeter(cents: o, reference: reference)
    }
}

/// What the TUNING meter shows: a track from −50 ¢ to +50 ¢ with a marker at the offset (green
/// when close to in tune), then "+0.1 ct  A4 = 440.0 Hz", the concert pitch the offset implies.
public struct TuningMeter: Equatable {
    /// Cents above (+) or below (−) the reference, folded to −50...+50.
    public let cents: Double
    /// The Settings reference (A = 440 by default).
    public let reference: Double

    public init(cents: Double, reference: Double) {
        self.cents = cents
        self.reference = reference
    }

    public static let span = 50.0
    /// Within this many cents the marker is green: in tune.
    public static let inTuneCents = 5.0

    /// The marker's place on the track, 0 (−50 ¢) ... 0.5 (in tune) ... 1 (+50 ¢), clamped.
    public static func fraction(_ cents: Double) -> Double {
        guard cents.isFinite else { return 0.5 }
        return (min(max(cents, -span), span) + span) / (2 * span)
    }

    public static func inTune(_ cents: Double) -> Bool { abs(cents) <= inTuneCents }

    /// The concert A the track implies: reference · 2^(cents / 1200).
    public static func concertHz(cents: Double, reference: Double) -> Double { reference * pow(2, cents / 1200) }

    /// "+0.1 ct", "−12.0 ct", "0.0 ct".
    public static func centsText(_ cents: Double) -> String {
        let r = (cents * 10).rounded() / 10
        if r == 0 { return "0.0 ct" }
        return (r > 0 ? "+" : "−") + String(format: "%.1f", abs(r)) + " ct"
    }

    /// "A4 = 440.0 Hz".
    public static func hzText(_ hz: Double) -> String { "A4 = " + String(format: "%.1f", hz) + " Hz" }

    public var fraction: Double { TuningMeter.fraction(cents) }
    public var inTune: Bool { TuningMeter.inTune(cents) }
    public var concertHz: Double { TuningMeter.concertHz(cents: cents, reference: reference) }
    public var text: String { TuningMeter.centsText(cents) + "  " + TuningMeter.hzText(concertHz) }
    public var spoken: String {
        let r = (cents * 10).rounded() / 10
        let dir = r == 0 ? "in tune" : String(format: "%.1f cents %@", abs(r), r > 0 ? "sharp" : "flat")
        return "Tuning \(dir), A4 = \(String(format: "%.1f", concertHz)) hertz"
    }
}
