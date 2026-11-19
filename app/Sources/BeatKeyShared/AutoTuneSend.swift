import Foundation

/// Send Key to Auto-Tune: writes the hand-off file Antares' Auto-Key plug-in writes and Auto-Tune Pro
/// watches (`~/Music/Audio Music Apps/Temp/Auto-Key.handoff`, JUCE XML, CRLF), so every Auto-Tune Pro
/// instance with Auto Key Detection on takes the key. Undocumented by Antares.
/// KeyClass = tonic pitch class 0...11 from C (the order of Auto-Key's own key list);
/// KeyType 0 = major, 1 = minor (from the one sample on disk, 11/1 = B minor).
/// One copy: the app's Reading menu / pocket / menu bar (plus Waves Tune, app side: AutoTuneSend.sendAll)
/// and the plug-in's SEND AUTO-TUNE button both write through `write`.
public enum AutoTuneSend {
    public static var handoffURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Audio Music Apps/Temp/Auto-Key.handoff")
    }

    /// The file's text, byte for byte as Auto-Key writes it. `tempo` nil = -1 (no tempo).
    public static func contents(pitchClass: Int, minor: Bool, referencePitch: Double, tempo: Double? = nil) -> String {
        func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }
        let t = tempo.map(num) ?? "-1"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n\r\n<PROPERTIES>\r\n"
            + "  <VALUE name=\"KeyClass\" val=\"\(pitchClass)\"/>\r\n"
            + "  <VALUE name=\"KeyType\" val=\"\(minor ? 1 : 0)\"/>\r\n"
            + "  <VALUE name=\"ReferencePitch\" val=\"\(num(referencePitch))\"/>\r\n"
            + "  <VALUE name=\"TempoBPM\" val=\"\(t)\"/>\r\n"
            + "</PROPERTIES>\r\n"
    }

    /// Writes temp + rename in the same folder (the watcher never sees a half file).
    /// false = not written; the reason is logged (SharedLog).
    @discardableResult
    public static func write(key: String, referencePitch: Double, to url: URL = handoffURL) -> Bool {
        guard let k = KeyNames.parse(key) else {
            SharedLog.log("auto-tune hand-off: \"\(key)\" is not a key it can take; nothing written")
            return false
        }
        let text = contents(pitchClass: k.pitchClass, minor: k.minor, referencePitch: referencePitch)
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".Auto-Key.handoff.\(ProcessInfo.processInfo.processIdentifier).tmp")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: tmp)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            SharedLog.log("auto-tune hand-off write failed (\(url.path)): \(error)")
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}
