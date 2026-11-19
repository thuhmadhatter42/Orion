import AppKit
import SwiftUI

/// Reading > Send Key to Auto-Tune. The hand-off writer itself (handoffURL, contents, write) is
/// BeatKeyShared/AutoTuneSend.swift, one copy with the plug-in's SEND AUTO-TUNE; the app's extras are here.
extension AutoTuneSend {
    /// The Reading menu's shortcut for Send Key to Auto-Tune, "⌃⌥⌘A": read from its Quick Keys row
    /// ("sendAutoTune", QuickKeyTable.swift), the one place the menu item AND the help tips take it from,
    /// so they cannot drift apart (and a rebind in Quick Keys shows in the tips at the next launch).
    static var shortcutDisplay: String { QuickKeys.tipDisplay("sendAutoTune") }
}

extension AutoTuneSend {
    /// "Send to Auto-Tune" = every pitch corrector at once: Antares Auto-Tune (Auto-Key hand-off)
    /// and Waves Tune Real-Time (the "Beat Key" preset), when installed. True = at least one took it.
    @discardableResult
    static func sendAll(key: String, referencePitch: Double) -> Bool {
        let antares = write(key: key, referencePitch: referencePitch)
        let waves = WavesTuneSend.installed ? WavesTuneSend.write(key: key) : false
        AppLog.log("send to auto-tune \(key): antares \(antares), waves tune \(waves)")
        return antares || waves
    }
}

struct SendToAutoTuneMenuItem: View {
    @ObservedObject var engine: Engine
    @ObservedObject var tuning: TuningSettings
    var body: some View {
        let key = MidiExport.current(engine.state)?.keyInUse?.name
        Button("Send Key to Auto-Tune") {
            if let key, !AutoTuneSend.sendAll(key: key, referencePitch: tuning.reference) {
                AppLog.log("send to auto-tune \(key): nothing took it (beep)")
                NSSound.beep()
            }
        }
        .quickKey("sendAutoTune")
        .disabled(key.flatMap(KeyNames.parse) == nil)
    }
}
