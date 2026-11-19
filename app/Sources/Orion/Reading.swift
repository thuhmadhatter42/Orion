import Foundation

// The readout's own logic (tempo cycling, tuning, confidence, recent readings), kept out of the
// views so it can be tested.

// TempoFactor, Tempo (text, split), Tuning and TuningMeter live in BeatKeyShared (Tempo.swift,
// Tuning.swift): the plug-in's face shares them. The app's reading-shaped helpers are here.
extension Tempo {
    /// The BPM as the LCD shows it: two decimals when measured (140.82), else the analyzer's own
    /// text ("142.0"), times the factor. nil = no BPM.
    static func text(_ r: Result, factor: TempoFactor = .one) -> String? {
        text(bpm: r.bpm, exact: r.bpmExact, factor: factor)
    }

    /// The whole-number reading that is in the file name, beside a decimal one; nil when the two
    /// would say the same thing (no decimal measured).
    static func rounded(_ r: Result, factor: TempoFactor = .one) -> String? {
        guard r.bpmExact != nil, let v = (text(r, factor: factor)).flatMap(Double.init) else { return nil }
        return String(Int(v.rounded()))
    }
}

/// The reference pitch, remembered between launches.
final class TuningSettings: ObservableObject {
    static let key = Tuning.defaultsKey
    private let defaults: UserDefaults

    @Published var reference: Double {
        didSet {
            let c = Tuning.clamp(reference)
            if c != reference { reference = c; return }
            defaults.set(reference, forKey: TuningSettings.key)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: TuningSettings.key) as? Double
        reference = Tuning.clamp(saved ?? Tuning.defaultReference)
    }
}

/// How sure the top key is. The analyzer's own measure: 85 % and up was right 85 % of the time,
/// 70 to 85 % about 75 %, below that it is a coin toss between neighbours (docs/research).
enum KeyConfidence: Equatable {
    case locked, unsure, none

    static let lockedMin = 70

    static func of(_ keys: [(String, Int)]) -> KeyConfidence {
        guard let top = keys.first else { return .none }
        return top.1 >= lockedMin ? .locked : .unsure
    }
}

extension Faceplate {
    /// The status line under the key: "LOCKED 85%", or for an unsure key the candidates it is
    /// choosing between ("UNSURE · Cm 41 · Eb 22 · Gm 18"). nil when there is no key.
    static func confidenceLine(_ keys: [(String, Int)]) -> String? {
        switch KeyConfidence.of(keys) {
        case .none: return nil
        case .locked: return "LOCKED \(keys[0].1)%"
        case .unsure: return "UNSURE · " + keys.prefix(3).map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        }
    }
}

// MARK: recent readings

/// One saved reading (the last 30 are kept, newest first).
struct Reading: Codable, Equatable {
    struct Key: Codable, Equatable { let name: String; let percent: Int }
    let path: String
    let name: String
    let bpm: String?
    let bpmExact: Double?
    let tuningCents: Double?
    /// Absent in readings saved before 0.1.37 (decodes as nil).
    let chroma: [Double]?
    let keys: [Key]
    let date: Date

    init(_ r: Result, date: Date = Date()) {
        path = r.file.path; name = r.name; bpm = r.bpm
        bpmExact = r.bpmExact; tuningCents = r.tuningCents; chroma = r.chroma
        keys = r.keys.map { Key(name: $0.0, percent: $0.1) }
        self.date = date
    }

    var result: Result {
        Result(file: URL(fileURLWithPath: path), name: name, bpm: bpm, keys: keys.map { ($0.name, $0.percent) },
               bpmExact: bpmExact, tuningCents: tuningCents, chroma: chroma)
    }

    /// The menu title: name, then what was read.
    var title: String {
        var parts = [name]
        if let b = Tempo.text(result) { parts.append("\(b) BPM") }
        if let k = keys.first { parts.append(k.name) }
        return parts.joined(separator: " · ")
    }
}

final class RecentStore: ObservableObject {
    static let key = "recentReadings"
    static let limit = 30

    @Published private(set) var readings: [Reading]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: RecentStore.key).flatMap { try? JSONDecoder().decode([Reading].self, from: $0) }
        readings = Array((saved ?? []).prefix(RecentStore.limit))
    }

    /// A file read again replaces its earlier entry and moves to the top. A file nothing could be
    /// read from is not a reading.
    func record(_ r: Result, now: Date = Date()) {
        guard r.bpm != nil || !r.keys.isEmpty else { return }
        var list = readings.filter { $0.path != r.file.path }
        list.insert(Reading(r, date: now), at: 0)
        readings = Array(list.prefix(RecentStore.limit))
        save()
    }

    /// A recent reading's file was renamed: the entry keeps its place and date and points at the new path.
    func moved(from oldPath: String, to url: URL) {
        guard let i = readings.firstIndex(where: { $0.path == oldPath }) else { return }
        readings[i] = Reading(readings[i].result.moved(to: url), date: readings[i].date)
        save()
    }

    func clear() {
        readings = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(readings) { defaults.set(data, forKey: RecentStore.key) }
    }
}
