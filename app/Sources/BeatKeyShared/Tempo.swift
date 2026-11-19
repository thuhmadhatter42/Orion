import Foundation

/// Clicking the BPM cycles x1 > x2 > x0.5 > x1: the half- or double-time reading of the same tempo.
public enum TempoFactor: Equatable {
    case one, double, half

    public var next: TempoFactor {
        switch self {
        case .one: return .double
        case .double: return .half
        case .half: return .one
        }
    }
    public var multiplier: Double {
        switch self {
        case .one: return 1
        case .double: return 2
        case .half: return 0.5
        }
    }
    /// The tag beside the BPM; nil at x1.
    public var label: String? {
        switch self {
        case .one: return nil
        case .double: return "×2"
        case .half: return "×0.5"
        }
    }
}

/// The tempo as text. The app adds `Tempo.text(_ r: Result, factor:)` on top (Reading.swift); the
/// plug-in's face calls `text(bpm:exact:factor:)` with the core's numbers.
public enum Tempo {
    /// The BPM as the LCD shows it: two decimals when measured (140.82), else the analyzer's own
    /// text ("142.0"), times the factor. nil = no BPM.
    public static func text(bpm: String?, exact: Double?, factor: TempoFactor = .one) -> String? {
        if let exact, exact > 0 { return String(format: "%.2f", exact * factor.multiplier) }
        guard let s = bpm, let v = Double(s) else { return bpm }
        return factor == .one ? s : String(format: "%.1f", v * factor.multiplier)
    }

    /// The BPM as the readout draws it (J 2026-11-09, "decimals small"): the whole number big,
    /// the decimals (with their point) small beside it. "141.98" -> ("141", ".98"); "142" ->
    /// ("142", nil); "---.-" or text with no digits before the point stays whole.
    public static func split(_ text: String) -> (whole: String, fraction: String?) {
        guard let dot = text.firstIndex(of: "."), dot != text.startIndex,
              text[..<dot].allSatisfy(\.isNumber) else { return (text, nil) }
        let frac = String(text[dot...])
        return (String(text[..<dot]), frac.count > 1 ? frac : nil)
    }
}
