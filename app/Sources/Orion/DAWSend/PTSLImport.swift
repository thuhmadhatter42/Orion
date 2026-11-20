import Foundation

/// Import a downloaded file into Pro Tools over PTSL (CId_Import, plan 2026-11-20 §5).
/// `body` is the pure part (what is sent); `run` connects, registers, asks the session where its
/// "Audio Files" folder is, reads the edit cursor when the placement is a spot, imports, and maps
/// every failure to a stage (for the log) and one sentence (for the plug-in's face).
enum PTSLImport {
    /// How it ended: Pro Tools has the file, or why not. `stage` is the log's word: "ptsl-connect"
    /// (Pro Tools never took the connection) or "ptsl-import" (it did, and the import failed).
    enum Outcome: Equatable {
        case imported
        case failed(stage: String, message: String)
    }

    /// The CId_Import request body: IType_Audio, convert the file into the session's own format,
    /// into the session's "Audio Files" folder, to the placement's destination and location. A spot
    /// carries the edit cursor as samples (SpotLocationData, SLType_Start, TLType_Samples).
    static func body(file: URL, placement: DownloadPlacement, audioFilesFolder: String?, spotSamples: Int64?) -> [String: Any] {
        var audio: [String: Any] = [
            "file_list": [file.path],
            "audio_operations": "AOperations_ConvertAudio",
            "audio_destination": placement.ptslDestination,
            "audio_location": placement.ptslLocation,
        ]
        if let folder = audioFilesFolder, !folder.isEmpty { audio["destination_path"] = folder }
        // Pro Tools 2025.6 refuses CId_Import without location_data ("Missing required parameter:
        // audio_data.location_data", Studio D 2026-11-20), whatever the placement. A spot carries the
        // edit cursor; every other placement sends sample 0, which audio_location overrides.
        let samples = placement.location == .spot ? (spotSamples ?? 0) : 0
        audio["location_data"] = ["location_type": "SLType_Start",
                                  "location": ["location": String(samples), "time_type": "TLType_Samples"]] as [String: Any]
        return ["import_type": "IType_Audio", "audio_data": audio]
    }

    /// The session's "Audio Files" folder from CId_GetSessionPath's `session_path.path` (the .ptx
    /// file): its folder + "Audio Files".
    static func audioFilesFolder(sessionPath: String) -> String {
        URL(fileURLWithPath: sessionPath).deletingLastPathComponent().appendingPathComponent("Audio Files").path
    }

    static func notAnswering(_ savedName: String) -> String {
        "Pro Tools isn't answering on PTSL: it isn't open, or PTSL isn't enabled. File saved: \(savedName)."
    }

    /// Blocking; call off the main thread.
    static func run(file: URL, placement: DownloadPlacement, port: UInt16 = PTSLClient.port) -> Outcome {
        let name = file.lastPathComponent
        let c: PTSLClient
        do {
            c = try PTSLClient(port: port, timeout: 120)   // converting a long file takes a while
            try c.register()
        } catch PTSLClient.Failure.notRunning {
            return .failed(stage: "ptsl-connect", message: notAnswering(name))
        } catch {
            return .failed(stage: "ptsl-connect", message: "Pro Tools didn't take the connection (\(error)). File saved: \(name).")
        }
        do {
            let session = try c.call(.getSessionPath)
            guard let path = (session["session_path"] as? [String: Any])?["path"] as? String, !path.isEmpty else {
                return .failed(stage: "ptsl-import", message: "Pro Tools has no session open. File saved: \(name).")
            }
            var spot: Int64?
            if placement.location == .spot {
                let sel = try c.call(.getEditSelection, ["location_type": "TLType_Samples"])
                guard let text = sel["in_time"] as? String, let v = Int64(text.trimmingCharacters(in: .whitespaces)) else {
                    return .failed(stage: "ptsl-import", message: "Pro Tools gave no cursor position. File saved: \(name).")
                }
                spot = v
            }
            try c.call(.importData, body(file: file, placement: placement, audioFilesFolder: audioFilesFolder(sessionPath: path), spotSamples: spot))
            return .imported
        } catch let PTSLClient.Failure.failed(command, error) {
            let why = PTSLClient.errorText(error)
            return .failed(stage: "ptsl-import", message: command == PTSLClient.Command.getSessionPath.name
                           ? "Pro Tools has no session open. File saved: \(name)."
                           : "Pro Tools refused the import: \(why). File saved: \(name).")
        } catch {
            return .failed(stage: "ptsl-import", message: "\(error) File saved: \(name).")
        }
    }
}
