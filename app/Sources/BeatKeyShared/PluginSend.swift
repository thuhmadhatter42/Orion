import Foundation

/// SEND BPM from the plug-in: the plug-in asks, the app sends (plan §S1). No plug-in format can set
/// the host's tempo, and the Accessibility permission DAWs need belongs to an app, so the plug-in hands
/// the BPM to the Beat Key app, whose Send to DAW drivers do it. This file is the contract; both sides
/// compile it, so the names and keys exist once. Full text: docs/protocol-beatkey-broadcast.md.
///
///   com.jshriver.orion.send   plug-in -> app
///     requestID     String   a fresh UUID per press
///     bpm           Double   the BPM as the face shows it (x2 / ÷2 applied), 20...999
///     hostBundleID  String   the host's bundle id ("" when it has none)
///     hostName      String   the host's name (DAW.from falls back to it)
///     hostPid       Int      the host's process id
///     proto         Int      1
///   com.jshriver.orion.sent   app -> plug-in
///     requestID     String   the request's
///     ok            Bool     the DAW took it
///     message       String   one line for the face (the app's own driver result)
///
/// Transport: distributed notifications, userInfo a property list (String / NSNumber only).
public enum PluginSend {
    public static let sendName = Notification.Name("com.jshriver.orion.send")
    public static let sentName = Notification.Name("com.jshriver.orion.sent")
    public static let proto = 1
    /// The app's bundle id: the plug-in opens it when it is not running.
    public static let appBundleID = "com.jshriver.orion"
    /// Where to get the app when it is not installed (the face shows this).
    public static let downloadURL = URL(string: "https://fourletterrecords.com/account/download/beat-key")!
    /// The plug-in waits this long for `sent` once the app is up.
    public static let pluginTimeout: TimeInterval = 8
    /// The app answers within this, even if the DAW driver is still busy, so the plug-in hears a
    /// reason before its own timeout.
    public static let appDeadline: TimeInterval = 7
    /// After launching the app, the plug-in waits at most this long for it to start listening.
    public static let launchWait: TimeInterval = 15
    public static let bpmRange: ClosedRange<Double> = 20...999

    public struct Request: Equatable {
        public var requestID: String
        public var bpm: Double
        public var hostBundleID: String
        public var hostName: String
        public var hostPid: Int
        public var proto: Int = PluginSend.proto

        public init(requestID: String, bpm: Double, hostBundleID: String, hostName: String, hostPid: Int,
                    proto: Int = PluginSend.proto) {
            self.requestID = requestID
            self.bpm = bpm
            self.hostBundleID = hostBundleID
            self.hostName = hostName
            self.hostPid = hostPid
            self.proto = proto
        }

        public var userInfo: [String: Any] {
            ["requestID": requestID, "bpm": bpm, "hostBundleID": hostBundleID, "hostName": hostName,
             "hostPid": hostPid, "proto": proto]
        }

        /// The request in `info`, or why it is not one (the app logs the reason and, when it has a
        /// requestID, answers with it).
        public static func decode(_ info: [AnyHashable: Any]?) -> (request: Request?, requestID: String?, refusal: String?) {
            let id = info?["requestID"] as? String
            guard let info else { return (nil, nil, "no payload") }
            guard let rid = id, !rid.isEmpty, rid.count <= 64 else { return (nil, nil, "no requestID") }
            guard let p = (info["proto"] as? NSNumber)?.intValue, p == PluginSend.proto else {
                return (nil, rid, "protocol \(String(describing: info["proto"])) is not \(PluginSend.proto); update the plug-in and the app together")
            }
            guard let bpm = (info["bpm"] as? NSNumber)?.doubleValue, bpm.isFinite, PluginSend.bpmRange.contains(bpm) else {
                return (nil, rid, "BPM \(String(describing: info["bpm"])) is not a tempo")
            }
            let bundle = info["hostBundleID"] as? String ?? ""
            let name = info["hostName"] as? String ?? ""
            let pid = (info["hostPid"] as? NSNumber)?.intValue ?? 0
            return (Request(requestID: rid, bpm: bpm, hostBundleID: bundle, hostName: name, hostPid: pid), rid, nil)
        }
    }

    public struct Reply: Equatable {
        public var requestID: String
        public var ok: Bool
        public var message: String

        public init(requestID: String, ok: Bool, message: String) {
            self.requestID = requestID
            self.ok = ok
            self.message = message
        }

        public var userInfo: [String: Any] { ["requestID": requestID, "ok": ok, "message": message] }

        public static func decode(_ info: [AnyHashable: Any]?) -> Reply? {
            guard let info, let rid = info["requestID"] as? String, let ok = (info["ok"] as? NSNumber)?.boolValue
            else { return nil }
            return Reply(requestID: rid, ok: ok, message: info["message"] as? String ?? "")
        }
    }

    /// The BPM as it goes on the wire and on the face: two decimals.
    public static func bpmText(_ bpm: Double) -> String { String(format: "%.2f", bpm) }
}
