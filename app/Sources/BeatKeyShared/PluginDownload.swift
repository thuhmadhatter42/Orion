import Foundation

/// DOWNLOAD from the plug-in (overnight plan 2026-11-20 §4-§5): the plug-in asks, the app downloads.
/// The download needs the app's yt-dlp, deno, ffmpeg and saved YouTube login, and a host process
/// (Logic's sandboxed AU service, Pro Tools) is no place to spawn them, so the plug-in hands the link to
/// the Beat Key app over the same transport as SEND BPM (PluginSend.swift). The app downloads, reads
/// BPM + key with the core, names the file with them, then imports it into Pro Tools over PTSL
/// (CId_Import) when the host is Pro Tools and a placement was picked, else saves it and shows it in
/// Finder. Both sides compile this file, so the names and keys exist once.
///
///   com.jshriver.orion.download    plug-in -> app
///     requestID     String   a fresh UUID per press
///     url           String   the link pasted in the face (http/https)
///     placement     String   DownloadPlacement.wire ("" = save only, show in Finder)
///     hostBundleID  String   the host's bundle id
///     hostName      String   the host's name
///     hostPid       Int      the host's process id
///     proto         Int      1
///   com.jshriver.orion.downloaded  app -> plug-in (zero or more `progress`, then one final)
///     requestID     String   the request's
///     final         Bool     false = a progress line, true = the outcome
///     ok            Bool     (final) the file is on disk (and imported, when asked)
///     message       String   one line for the face
///     path          String   (final, ok) the file on disk
///     imported      Bool     (final) Pro Tools took the file
///     bpm           String   (final, ok) "140.00" or ""
///     key           String   (final, ok) "Cm" or ""
public enum PluginDownload {
    public static let requestName = Notification.Name("com.jshriver.orion.download")
    public static let replyName = Notification.Name("com.jshriver.orion.downloaded")
    public static let proto = 1
    /// The plug-in gives up on a silent app after this long (a download is up to 600 s per yt-dlp
    /// call; the app sends progress lines, and each one restarts this clock).
    public static let quietTimeout: TimeInterval = 45

    public struct Request: Equatable {
        public var requestID: String
        public var url: String
        public var placement: DownloadPlacement?
        public var hostBundleID: String
        public var hostName: String
        public var hostPid: Int
        public var proto: Int = PluginDownload.proto

        public init(requestID: String, url: String, placement: DownloadPlacement?, hostBundleID: String,
                    hostName: String, hostPid: Int, proto: Int = PluginDownload.proto) {
            self.requestID = requestID
            self.url = url
            self.placement = placement
            self.hostBundleID = hostBundleID
            self.hostName = hostName
            self.hostPid = hostPid
            self.proto = proto
        }

        public var userInfo: [String: Any] {
            ["requestID": requestID, "url": url, "placement": placement?.wire ?? "", "hostBundleID": hostBundleID,
             "hostName": hostName, "hostPid": hostPid, "proto": proto]
        }

        /// The request, or why it is not one (with its requestID when it had one, so it can be answered).
        public static func decode(_ info: [AnyHashable: Any]?) -> (request: Request?, requestID: String?, refusal: String?) {
            guard let info else { return (nil, nil, "no payload") }
            guard let rid = info["requestID"] as? String, !rid.isEmpty, rid.count <= 64 else { return (nil, nil, "no requestID") }
            guard let p = (info["proto"] as? NSNumber)?.intValue, p == PluginDownload.proto else {
                return (nil, rid, "protocol \(String(describing: info["proto"])) is not \(PluginDownload.proto); update the plug-in and the app together")
            }
            guard let url = info["url"] as? String, PluginDownload.isLink(url) else { return (nil, rid, "that is not an http(s) link") }
            let wire = info["placement"] as? String ?? ""
            let placement = DownloadPlacement(wire: wire)
            if !wire.isEmpty && placement == nil { return (nil, rid, "placement \"\(wire)\" is unknown") }
            return (Request(requestID: rid, url: url.trimmingCharacters(in: .whitespacesAndNewlines), placement: placement,
                            hostBundleID: info["hostBundleID"] as? String ?? "", hostName: info["hostName"] as? String ?? "",
                            hostPid: (info["hostPid"] as? NSNumber)?.intValue ?? 0), rid, nil)
        }
    }

    public struct Reply: Equatable {
        public var requestID: String
        public var final: Bool
        public var ok: Bool
        public var message: String
        public var path: String
        public var imported: Bool
        public var bpm: String
        public var key: String

        public init(requestID: String, final: Bool, ok: Bool, message: String, path: String = "", imported: Bool = false,
                    bpm: String = "", key: String = "") {
            self.requestID = requestID
            self.final = final
            self.ok = ok
            self.message = message
            self.path = path
            self.imported = imported
            self.bpm = bpm
            self.key = key
        }

        public static func progress(_ requestID: String, _ message: String) -> Reply {
            Reply(requestID: requestID, final: false, ok: true, message: message)
        }

        public var userInfo: [String: Any] {
            ["requestID": requestID, "final": final, "ok": ok, "message": message, "path": path, "imported": imported,
             "bpm": bpm, "key": key]
        }

        public static func decode(_ info: [AnyHashable: Any]?) -> Reply? {
            guard let info, let rid = info["requestID"] as? String, let ok = (info["ok"] as? NSNumber)?.boolValue else { return nil }
            return Reply(requestID: rid, final: (info["final"] as? NSNumber)?.boolValue ?? true, ok: ok,
                         message: info["message"] as? String ?? "", path: info["path"] as? String ?? "",
                         imported: (info["imported"] as? NSNumber)?.boolValue ?? false,
                         bpm: info["bpm"] as? String ?? "", key: info["key"] as? String ?? "")
        }
    }

    /// An http(s) URL on its own, with a host.
    public static func isLink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: { $0.isWhitespace }), let u = URL(string: t),
              let s = u.scheme?.lowercased(), s == "http" || s == "https", u.host != nil else { return false }
        return true
    }

    /// The host is Pro Tools (the only host Beat Key imports into).
    public static func isProTools(bundleID: String, name: String) -> Bool {
        bundleID.lowercased().hasPrefix("com.avid.protools") || name.lowercased().contains("pro tools")
    }
}

/// Where a download goes in Pro Tools: PTSL CId_Import, IType_Audio, AOperations_ConvertAudio, and one
/// destination + location. J picks it every time from the menu beside DOWNLOAD (nothing pre-selected).
public struct DownloadPlacement: Equatable, Hashable {
    public enum Destination: String, CaseIterable { case newTrack, clipList }
    /// selection = the edit cursor / selection start; spot = SpotLocationData at the edit cursor (samples).
    public enum Location: String, CaseIterable { case selection, sessionStart, songStart, spot }

    public var destination: Destination
    /// nil for the Clip List (it has no timeline place).
    public var location: Location?

    public init(destination: Destination, location: Location?) {
        self.destination = destination
        self.location = destination == .clipList ? nil : (location ?? .selection)
    }

    /// Every choice the menu lists, in menu order.
    public static let all: [DownloadPlacement] =
        Location.allCases.map { DownloadPlacement(destination: .newTrack, location: $0) } + [DownloadPlacement(destination: .clipList, location: nil)]

    /// "newTrack.selection", "clipList".
    public var wire: String { location.map { "\(destination.rawValue).\($0.rawValue)" } ?? destination.rawValue }

    public init?(wire: String) {
        let parts = wire.split(separator: ".").map(String.init)
        guard let d = parts.first.flatMap(Destination.init(rawValue:)) else { return nil }
        if d == .clipList { guard parts.count == 1 else { return nil }; self.init(destination: d, location: nil); return }
        guard parts.count == 2, let l = Location(rawValue: parts[1]) else { return nil }
        self.init(destination: d, location: l)
    }

    /// The menu's words.
    public var label: String {
        switch (destination, location) {
        case (.clipList, _): return "Clip List"
        case (_, .selection?), (_, nil): return "New Track at Cursor"
        case (_, .sessionStart?): return "New Track at Session Start"
        case (_, .songStart?): return "New Track at Song Start"
        case (_, .spot?): return "New Track, Spot at Cursor"
        }
    }

    /// PTSL's enum names (Pro Tools 2025.06+; the client speaks API 2026.04).
    public var ptslDestination: String { destination == .clipList ? "MDestination_ClipList" : "MDestination_NewTrack" }
    public var ptslLocation: String {
        switch location {
        case .selection?: return "MLocation_Selection"
        case .sessionStart?: return "MLocation_SessionStart"
        case .songStart?: return "MLocation_SongStart"
        case .spot?: return "MLocation_Spot"
        case nil: return "MLocation_None"
        }
    }
}

/// The DOWNLOAD menu's history: the last picks, newest first, at most `limit`. History only: the
/// menu shows them, nothing is pre-selected, and nothing is applied without a click.
public struct DownloadHistory: Equatable {
    public static let limit = 4
    public private(set) var picks: [DownloadPlacement]

    public init(picks: [DownloadPlacement] = []) { self.picks = Array(picks.prefix(DownloadHistory.limit)) }

    public init(wires: [String]) { self.init(picks: wires.compactMap(DownloadPlacement.init(wire:))) }

    public var wires: [String] { picks.map(\.wire) }

    public mutating func record(_ p: DownloadPlacement) {
        picks.removeAll { $0 == p }
        picks.insert(p, at: 0)
        if picks.count > DownloadHistory.limit { picks.removeLast(picks.count - DownloadHistory.limit) }
    }
}
