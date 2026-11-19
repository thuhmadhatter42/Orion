import Foundation

/// The log hook of the shared code. BeatKeyShared writes no file of its own: each side points the
/// sink at its one writer at start-up, so a shared line lands in the right log.
///   the app       -> AppLog (beatkey.log), set first thing in OrionApp.launch
///   the plug-in   -> bk_log (plugin.log), set when the face module loads (FaceBridge.swift)
/// Unset (a unit test of the shared code alone), lines go nowhere.
public enum SharedLog {
    /// (tag, line): tag = the shared file's name ("AutoTuneSend"), line = the text.
    public static var sink: ((String, String) -> Void)?

    static func log(_ line: String, file: String = #fileID) {
        let tag = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        sink?(tag, line)
    }
}
