import Foundation

// The app's file work, in-process since plan step 19 (it was app_run.py on the bundled Python):
// the YouTube download (Downloader.swift), reading files with the core, the tag Beat Key writes
// into a file's name, and the step after a download (read, tag, links log).

/// Beat Key's tag in a file name: "<stem> (<bpm> BPM <k1> <k2> <k3>).<ext>". The ONE place its
/// shape lives in the app: `name` writes it, `isTagged` reads it, `rename` applies it.
enum FileTag {
    /// How many keys the tag holds (J may say "top key only": change this one number).
    static let keyCount = 3
    /// Recognised with up to 3 keys whatever keyCount is now: files tagged before a change stay recognised.
    private static let pattern = try! NSRegularExpression(pattern: #"(?:^|\s)\(\d+(?:\.\d+)? BPM(?: [A-G][#b]?m?){1,3}\)$"#)

    /// "T (142.0 BPM Cm Eb Gm).mp3"; ext "" = no extension.
    static func name(stem: String, ext: String, bpm: String, keys: [String]) -> String {
        "\(stem) (\(bpm) BPM \(keys.prefix(keyCount).joined(separator: " ")))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// The name (or path) already carries Beat Key's own tag. A producer's own "140 BPM" or "Cm"
    /// in a name is not the tag.
    static func isTagged(_ name: String) -> Bool {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        return pattern.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) != nil
    }

    enum Failure: Error, Equatable {
        /// No usable BPM or no key: refused, the file stays as it is.
        case refused(String)
        /// The file system said no (errno, its sentence).
        case os(Int32, String)
    }

    /// The one renamer: `file` becomes `name(...)` in its own folder; returns the new URL. Never
    /// replaces another file unless overwrite (a re-download does; the user's rename never).
    static func rename(_ file: URL, bpm: String, keys: [String], overwrite: Bool) throws -> URL {
        guard let v = Double(bpm.trimmingCharacters(in: .whitespaces)), v > 0 else {
            throw Failure.refused("not renaming \(file.lastPathComponent): '\(bpm)' is not a BPM")
        }
        guard !keys.isEmpty else { throw Failure.refused("not renaming \(file.lastPathComponent): no key to put in the name") }
        let new = file.deletingLastPathComponent().appendingPathComponent(
            name(stem: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension, bpm: bpm, keys: keys))
        if !overwrite {
            if access(file.path, F_OK) != 0 { throw Failure.os(ENOENT, String(cString: strerror(ENOENT))) }
            if access(new.path, F_OK) == 0 { throw Failure.os(EEXIST, "a file with that name already exists") }
        }
        // rename(2) replaces an existing target: overwrite = os.replace; otherwise checked just above
        if Darwin.rename(file.path, new.path) != 0 {
            let e = errno
            throw Failure.os(e, String(cString: strerror(e)))
        }
        return new
    }
}

/// The links log a download adds to: "<Downloads>/(YY-M-D) Youtube DL LINKS.txt", one entry per
/// download, "Input URL: <url>\nDownloaded: <name>\n\n". ORION_DOWNLOADS overrides the folder.
enum LinksLog {
    static func url(now: Date = Date(), env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: now)
        return Doctor.downloadsFolder(env: env)
            .appendingPathComponent("(\(c.year! % 100)-\(c.month!)-\(c.day!)) Youtube DL LINKS.txt")
    }

    static func line(url: String, name: String) -> String { "Input URL: \(url)\nDownloaded: \(name)\n\n" }

    /// Never costs the download: a failure is logged.
    static func append(url: String, name: String, to file: URL = LinksLog.url()) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let h = try FileHandle(forWritingTo: file)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(line(url: url, name: name).utf8))
        } catch {
            AppLog.log("could not append to the links log \(file.path): \(error)")
        }
    }
}

/// The Engine's file work: each job sends Events (the ones the Python helper used to print) and
/// then ends with an exit code. Callbacks on any queue. Tests fake it.
protocol FileJobs: AnyObject {
    /// "downloading", then `needsLogin` or `error`; a good download goes on as finishDownload does
    /// ("analyzing", "renaming", `done`). cookiesFile = the saved YouTube login, one attempt only.
    func download(_ url: String, cookiesFile: URL?, onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void)
    /// "analyzing" per file, one `analyzed` row per file, or one `error` for the whole job when
    /// the install is damaged.
    func analyze(_ files: [URL], onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void)
    /// The user's yes: `renamed`, `renameSkipped` (already tagged) or `renameFailed`.
    func rename(_ item: RenameItem, onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void)
}

final class CoreFileJobs: FileJobs {
    private let reader: () -> FileReader
    private let downloader: () -> Downloader
    /// One job at a time, off the main thread.
    private let queue = DispatchQueue(label: "com.jshriver.orion.files", qos: .userInitiated)

    init(runtime: Runtime) {
        reader = { FileReader(binDir: runtime.binDir) }
        downloader = { Downloader.appDefault(runtime) }
    }

    init(reader: @escaping () -> FileReader, downloader: (() -> Downloader)? = nil) {
        self.reader = reader
        self.downloader = downloader ?? { Downloader.appDefault(.appDefault()) }
    }

    func download(_ url: String, cookiesFile: URL?, onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void) {
        queue.async {
            onEvent(.stage("downloading"))
            switch self.downloader().download(url, cookiesFile: cookiesFile) {
            case .downloaded(let file):
                self.finish(file, url: url, onEvent: onEvent, onExit: onExit)
            case .needsLogin(let reason, let stale):
                onEvent(.needsLogin(reason: reason, message: Downloader.loginMessages[reason] ?? "", stale: stale)); onExit(0)
            case .failed(let message):
                onEvent(.error(message)); onExit(0)
            }
        }
    }

    func analyze(_ files: [URL], onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void) {
        queue.async {
            let reader = self.reader()
            for f in files {
                onEvent(.stage("analyzing"))
                switch reader.read(f.standardizedFileURL) {
                case .incomplete(let why):
                    onEvent(.error(why))
                    onExit(0)
                    return
                case .reading(let r):
                    onEvent(.analyzed(r))
                }
            }
            onExit(0)
        }
    }

    /// After a download: read the file, tag its name (replacing an older copy), add it to the
    /// links log; `done`, or `error` when the install is damaged or the file vanished.
    func finishDownload(_ file: URL, url: String, onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void) {
        queue.async { self.finish(file, url: url, onEvent: onEvent, onExit: onExit) }
    }

    private func finish(_ file: URL, url: String, onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void) {
        do {
            onEvent(.stage("analyzing"))
            let r: Result
            switch self.reader().read(file) {
            case .incomplete(let why):
                // the download stands under its own name; the user is told what to do
                LinksLog.append(url: url, name: file.lastPathComponent)
                onEvent(.error(why)); onExit(0)
                return
            case .reading(let got):
                r = got
            }
            var final = file
            if let bpm = r.bpm {
                onEvent(.stage("renaming"))
                do {
                    final = try FileTag.rename(file, bpm: bpm, keys: r.keys.map { $0.0 }, overwrite: true)
                } catch {
                    AppLog.log("rename failed for \(file.lastPathComponent): \(error); kept under its own name")
                    if access(file.path, F_OK) != 0 {
                        onEvent(.error("Could not rename the downloaded file.")); onExit(0)
                        return
                    }
                }
            } else {
                AppLog.log("no BPM for the download \(file.lastPathComponent); kept under its own name")
            }
            LinksLog.append(url: url, name: final.lastPathComponent)
            let done = r.bpm == nil
                ? Result(file: final, name: final.lastPathComponent, bpm: nil, keys: [])
                : Result(file: final, name: final.lastPathComponent, bpm: r.bpm, keys: r.keys,
                         bpmExact: r.bpmExact, tuningCents: r.tuningCents, chroma: r.chroma)
            onEvent(.done(done)); onExit(0)
        }
    }

    func rename(_ item: RenameItem, onEvent: @escaping (Event) -> Void, onExit: @escaping (Int32) -> Void) {
        queue.async {
            let f = item.file
            if FileTag.isTagged(f.lastPathComponent) {
                AppLog.log("rename skipped: the file already carries Beat Key's tag")
                onEvent(.renameSkipped(file: f.path)); onExit(0)
                return
            }
            do {
                let new = try FileTag.rename(f, bpm: item.bpm, keys: item.keys, overwrite: false)
                onEvent(.renamed(from: f.path, to: new.path))
            } catch FileTag.Failure.refused(let why) {
                AppLog.log("rename refused: no usable BPM or no key, the file stays as it is")
                onEvent(.renameFailed(file: f.path, errno: 0, message: why))
            } catch FileTag.Failure.os(let e, let why) {
                onEvent(.renameFailed(file: f.path, errno: Int(e), message: why))
            } catch {
                onEvent(.renameFailed(file: f.path, errno: 0, message: "\(error)"))
            }
            onExit(0)
        }
    }
}
