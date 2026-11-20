import Foundation

// What the shared face (app/Sources/Orion/Face/) needs from the side that compiles it. The face draws
// PocketState and calls PocketActions; everything it needs beyond those two values is listed here, and
// each side provides it:
//
//   AppLog.log(_:)      the app: AppLog.swift (beatkey.log). The plug-in: plugin/ui/FaceHostPlugin.swift
//                       (the same file, through PluginErrorLog's folder, tagged plugin + host).
//   ReportCenter        the app: House/Report.swift. The plug-in: FaceHouse.report (log attached).
//   FaceSurface         which controls this surface hides (PocketState.surface).
//
// Nothing in Face/ may name the app's machinery (Engine, LiveController, Settings windows, singletons
// with UserDefaults); `plugin/ui/build-face.sh` compiles Face/ without them and fails if it does.

/// Whether YouTube login runs inside Beat Key (the app's login window). One state; the app's
/// YouTubeLogin.inApp reads and writes this.
enum FaceLogin {
    static var inApp = true
}

/// What the doctor found, as the LCD shows it.
struct DoctorReport: Equatable {
    enum Outcome: Equatable { case ok, fixed, failed }
    let outcome: Outcome
    let title: String     // "DOCTOR OK" | "DOCTOR FIXED IT" | "DOCTOR FOUND A PROBLEM"
    let line: String      // one line: the yt-dlp version, what it fixed, or the one thing to do

    /// The doctor's stages in order (Doctor runs them; the LCD lights them).
    static let stages = ["doctor-ytdlp", "doctor-ffmpeg", "doctor-js", "doctor-analyzer", "doctor-downloads"]
    static let permissionHint = "Allow Downloads access in System Settings › Privacy & Security › Files and Folders"
}

/// The surface drawing the face. The app's window and popover show every control; a plug-in hides
/// the ones a host can't use (overnight plan §1 table): hidden, never left dead.
enum FaceSurface: Equatable {
    case app
    case plugin

    /// Shown in this surface (the plug-in hides page arrows / SHOW IN FINDER, Open Audio + FIND, HOLD,
    /// LISTEN and SETTINGS).
    var showsFileControls: Bool { self == .app }
    var showsListen: Bool { self == .app }
    var showsSettings: Bool { self == .app }
    /// Beat Key Mini is the app's floating pad panel.
    var showsMini: Bool { self == .app }
}

/// What the faceplate asks for after a login-fixable error.
struct LoginPrompt: Equatable {
    let url: String
    let reason: String      // "age" | "bot" | "members"
}

/// Listen's input level, 0...1, on its own so its 20 Hz ticks redraw only the meter segments.
final class LiveLevel: ObservableObject {
    @Published var value: Float = 0
}
