import Foundation

/// Test-only UserDefaults suite names. An absolute path keeps each suite's plist in the temp folder instead of
/// ~/Library/Preferences, where macOS leaves an empty file behind even after removePersistentDomain
/// (5,783 of them had piled up on the MacBook by 2026-11-20).
enum TestPrefs {
    static let folder = NSTemporaryDirectory() + "beatkey-test-prefs/"
    static func name(_ prefix: String) -> String {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder + prefix + UUID().uuidString
    }
}
