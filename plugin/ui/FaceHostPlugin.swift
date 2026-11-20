import Foundation

// What the shared face (app/Sources/Orion/Face/, listed in Face/FaceHost.swift) needs from its side,
// the plug-in's way. The app has its own of each (AppLog.swift, AutoTuneSend.swift).

/// The face's log lines: plugin.log through the core's writer (FaceLog), under "plugin".
enum AppLog {
    static func log(_ line: String) { FaceLog.line(0, line) }
}

extension AutoTuneSend {
    /// A plug-in has no global shortcuts: the SEND TO AUTO-TUNE tip shows its words alone.
    static var shortcutDisplay: String { "" }
}
