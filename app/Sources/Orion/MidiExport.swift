import AppKit
import SwiftUI

/// File > Export MIDI Tempo/Key File…: the app's side of MidiExport (the writer itself is
/// BeatKeyShared/MidiFile.swift, shared with the plug-in): the reading to export and the save panel.
extension MidiExport {
    /// The reading's BPM as a number ("140.82" or "142.0"); nil when there is none.
    /// (Once Tempo.text lands from the readout work, pass its decimal text here.)
    static func bpmValue(_ r: Result) -> Double? { r.bpmExact ?? r.bpm.flatMap(Double.init) }

    /// The reading the window is showing: a finished download, or the first analysed file.
    static func current(_ state: ViewState) -> Result? {
        switch state {
        case .done(let r): return r.respelled()
        case .analyzed(let rs): return rs.first?.respelled()
        default: return nil
        }
    }

    static func runPanel(for r: Result) {
        let key = r.keyInUse?.name
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["mid"]
        panel.nameFieldStringValue = suggestedName(track: r.name, bpm: r.bpm, key: key)
        panel.directoryURL = r.file.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bytes = data(bpm: bpmValue(r), key: key, trackName: (r.name as NSString).deletingPathExtension)
        do {
            try bytes.write(to: url)
            AppLog.log("export midi: wrote \(bytes.count) bytes to \(url.path)")
        } catch {
            AppLog.log("export midi: write to \(url.path) failed: \(error)")
            NSAlert(error: error).runModal()
        }
    }
}

/// The File menu item. Disabled until there is a reading with a tempo or a key.
struct ExportMidiMenuItem: View {
    @ObservedObject var engine: Engine
    var body: some View {
        let r = MidiExport.current(engine.state)
        let usable = r.map { $0.bpm != nil || !$0.keys.isEmpty } ?? false
        Button("Export MIDI Tempo/Key File…") { if let r { MidiExport.runPanel(for: r) } }
            .quickKey("exportMidi")
            .disabled(!usable)
    }
}
