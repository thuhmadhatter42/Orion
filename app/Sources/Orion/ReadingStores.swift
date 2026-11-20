import Foundation

// The app's stores behind the readout: the reference pitch and the recent readings (UserDefaults).
// The values they hold are the shared face's (Face/Reading.swift).

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
