import Foundation

/// House kit error logging for the plug-in (overnight plan §6): every plug-in failure path (download
/// hand-off, PTSL connect, PTSL import, app-listener hand-off, face load) writes ONE line into the
/// app's own log, ~/Library/Logs/Beat Key/beatkey.log, the file the app's REPORT button attaches:
///
///   2026-11-20 03:12:44.120 [plugin host=Pro Tools] download: the Beat Key app didn't answer in 45 s
///
/// One O_APPEND write per line, so the app and any number of plug-ins can share the file.
/// $BEATKEY_LOG_DIR moves the folder (tests; the same variable the core's plugin.log honours).
public enum PluginErrorLog {
    public enum Source: String { case download, ptslConnect = "ptsl-connect", ptslImport = "ptsl-import", appListener = "app-listener", faceLoad = "face-load" }

    public static var directory: URL {
        if let d = ProcessInfo.processInfo.environment["BEATKEY_LOG_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        var home = FileManager.default.homeDirectoryForCurrentUser.path
        // a sandboxed host's home is its container: the account's real home is in the passwd entry
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { home = String(cString: dir) }
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/Beat Key")
    }

    public static var file: URL { directory.appendingPathComponent("beatkey.log") }

    /// The host's name as the line prints it.
    public static var hostName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ProcessInfo.processInfo.processName
    }

    /// The line exactly as written (tests read it back).
    public static func format(_ source: Source, _ text: String, host: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let oneLine = text.replacingOccurrences(of: "\n", with: " | ")
        return "\(f.string(from: date)) [plugin host=\(host)] \(source.rawValue): \(oneLine)\n"
    }

    /// Writes the line; false = it could not (the face still shows its status line).
    @discardableResult
    public static func write(_ source: Source, _ text: String, host: String = PluginErrorLog.hostName) -> Bool {
        let line = format(source, text, host: host)
        SharedLog.sink?("PluginErrorLog", "\(source.rawValue): \(text)")
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("beatkey.log").path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        return bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == bytes.count
    }
}
