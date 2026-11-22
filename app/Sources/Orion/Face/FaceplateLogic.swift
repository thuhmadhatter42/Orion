import Foundation
import UniformTypeIdentifiers

/// The faceplate's own logic, kept out of the views so it can be tested.
enum Faceplate {
    /// DOWNLOAD lights when the field holds a link and nothing is running.
    static func isLit(_ text: String, busy: Bool) -> Bool {
        !busy && text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http")
    }

    /// ANALYZE lights when audio is picked and nothing is running (DOWNLOAD's rule).
    static func isFindLit(_ picked: [URL], busy: Bool) -> Bool { !busy && !picked.isEmpty }

    /// The picker field's text: nil = the "Open Audio..." placeholder, else "x.wav" / "3 files".
    static func pickLabel(_ picked: [URL]) -> String? {
        switch picked.count {
        case 0: return nil
        case 1: return picked[0].lastPathComponent
        default: return "\(picked.count) files"
        }
    }

    /// The TEMPO light's period in seconds: one flash per beat. nil = no light.
    static func tempoPeriod(_ bpm: String?) -> TimeInterval? {
        guard let s = bpm, let v = Double(s), v.isFinite, v > 0 else { return nil }
        return 60 / v
    }

    /// The LCD line for a progress stage (the download helper, the file jobs, Run Doctor).
    static func stageText(_ stage: String) -> String {
        switch stage {
        case "downloading": return "DOWNLOADING"
        case "updating": return "UPDATING THE DOWNLOADER"
        case "allow-downloads": return "ALLOW DOWNLOADS ACCESS"
        case "analyzing": return "FINDING BPM AND KEY"
        case "renaming": return "RENAMING THE FILE"
        case "doctor-ytdlp": return "DOCTOR · YT-DLP"
        case "doctor-ffmpeg": return "DOCTOR · FFMPEG"
        case "doctor-js": return "DOCTOR · JS"
        case "doctor-analyzer": return "DOCTOR · ANALYZER"
        case "doctor-downloads": return "DOCTOR · DOWNLOADS"
        default: return stage.uppercased()
        }
    }

    // MARK: YouTube login (only after a video asks for it)

    static let loginCapLabel = "LOG IN TO YOUTUBE"
    static let loginNextLine = "LOG IN TO YOUTUBE ONCE TO DOWNLOAD IT"
    static let cantDownloadLine = "\(Brand.wordmark) CAN'T DOWNLOAD IT"

    /// The two LCD lines. inApp = the login window is on (YouTubeLogin.inApp); off = the
    /// fallback readout, which only says the video can't be downloaded.
    static func loginLines(_ p: LoginPrompt, inApp: Bool = FaceLogin.inApp) -> (String, String) {
        let first: String
        switch p.reason {
        case "age": first = "THIS VIDEO IS AGE-RESTRICTED"
        case "members": first = "THIS VIDEO IS FOR MEMBERS"
        default: first = "YOUTUBE WANTS A LOGIN"
        }
        return (first, inApp ? loginNextLine : cantDownloadLine)
    }

    /// The login cap: shown only with the login window on; lit unless something is running.
    static func loginCap(busy: Bool, inApp: Bool = FaceLogin.inApp) -> (label: String, lit: Bool)? {
        inApp ? (loginCapLabel, !busy) : nil
    }

    enum Step: Equatable { case done, on, off }

    /// DOWNLOAD / ANALYZE / RENAME lights for a download in progress.
    static func steps(_ stage: String) -> [(String, Step)] {
        let order = ["DOWNLOAD", "ANALYZE", "RENAME"]
        let at: Int
        switch stage {
        case "analyzing": at = 1
        case "renaming": at = 2
        default: at = 0
        }
        return order.enumerated().map { i, n in (n, i < at ? .done : (i == at ? .on : .off)) }
    }

    /// The doctor's five lights, done / on / off, for a doctor stage.
    static func doctorSteps(_ stage: String) -> [(String, Step)] {
        let names = ["YT-DLP", "FFMPEG", "JS", "ANALYZER", "DOWNLOADS"]
        let at = DoctorReport.stages.firstIndex(of: stage) ?? 0
        return names.enumerated().map { i, n in (n, i < at ? .done : (i == at ? .on : .off)) }
    }

    static func isDoctorStage(_ stage: String) -> Bool { stage.hasPrefix("doctor-") }

    /// The lights under the working readout, window and pocket alike: the doctor's five, a
    /// download's three, or the one ANALYZE light for a file that was dropped or opened.
    static func stepLights(stage: String, download: Bool) -> [(String, Step)] {
        if isDoctorStage(stage) { return doctorSteps(stage) }
        return download ? steps(stage) : [("ANALYZE", .on)]
    }

    /// The window's empty readout: the invitation, and what VoiceOver says for it.
    static let idleTitle = "Drop a beat"
    static let idleHint = "or paste a YouTube link, open a file or listen"
    static let idleLabel = "No reading yet. Paste a link, analyze a file or listen."
    /// The pocket's empty readout: it has no link field, only the drop zone and LISTEN.
    static let pocketIdleHint = "on the drop zone below, or listen"
    static let pocketIdleLabel = "No reading yet. Drop or analyze a file, or listen."

    /// macOS said no to the Downloads folder (the user clicked Don't Allow): EPERM.
    static func isPermissionError(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("operation not permitted") || m.contains("eperm") || m.contains("[errno 1]")
    }

    /// The one-line hint under every red FAILED readout.
    static func failureHint(download: Bool) -> String { download ? Brand.downloadHint : Brand.doctorHint }

    /// The caption under a partial analysis: some files read, the helper then stopped.
    static func partialNote(_ unread: Int) -> String {
        "\(unread) \(unread == 1 ? "FILE" : "FILES") COULDN'T BE READ · \(Brand.doctorHint)"
    }

    /// An error sentence from explain_error, as the LCD shows it. A permission refusal becomes
    /// the place to allow it.
    static func errorText(_ message: String) -> String {
        if isPermissionError(message) { return DoctorReport.permissionHint.uppercased() }
        var m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        while m.hasSuffix(".") { m.removeLast() }
        return m.uppercased()
    }

    /// Audio, the audio track of a video (ffmpeg decodes it; a .mov or .mp4 is not UTType .audio,
    /// so it is listed here), and MIDI files (the core reads those without ffmpeg).
    static let audioExtensions: Set<String> = ["mp3", "wav", "aif", "aiff", "flac", "m4a", "aac", "ogg", "caf",
                                               "mp4", "m4v", "mov", "mid", "midi"]

    /// The dropped items worth analyzing: regular audio files. Folders, PDFs and the rest are
    /// left out, so they never show up as empty rows or inflate "N OF M".
    static func audioFiles(_ urls: [URL]) -> [URL] {
        urls.filter { u in
            guard u.isFileURL,
                  (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return false }
            let ext = u.pathExtension.lowercased()
            if audioExtensions.contains(ext) { return true }
            return UTType(filenameExtension: ext)?.conforms(to: .audio) ?? false
        }
    }

    /// Dropped folders become their direct children, one level deep (sorted by name, hidden files
    /// and packages left out); a folder inside a folder is not entered. Files pass through in the
    /// order they came. The result still goes through `audioFiles`.
    static func expandFolders(_ urls: [URL]) -> [URL] {
        urls.flatMap { u -> [URL] in
            guard u.isFileURL,
                  let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                  v.isDirectory == true, v.isPackage != true else { return [u] }
            let kids = (try? FileManager.default.contentsOfDirectory(
                at: u, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
            return kids.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
    }

    /// "Name.wav · Folder", the LCD's file line: the user's file in its own case (design pass F6).
    static func fileLine(_ r: Result) -> String {
        let p = fileParts(r)
        return "\(p.name) · \(p.folder)"
    }

    /// The file line's two halves: the name (warm white) and its folder (dimmer).
    static func fileParts(_ r: Result) -> (name: String, folder: String) {
        (r.name, r.file.deletingLastPathComponent().lastPathComponent)
    }
}

/// "1 of N" paging through several dropped files.
struct Pager: Equatable {
    private(set) var count: Int = 0
    private(set) var index: Int = 0

    /// A new set of results opens on the last one.
    mutating func reset(count: Int) {
        self.count = max(0, count)
        index = max(0, self.count - 1)
    }
    mutating func next() { if index + 1 < count { index += 1 } }
    mutating func previous() { if index > 0 { index -= 1 } }
    var caption: String? { count > 1 ? "\(index + 1) OF \(count)" : nil }
}

enum LastAction { case download, analyze }

