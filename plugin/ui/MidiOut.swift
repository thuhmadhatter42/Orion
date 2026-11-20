import AppKit
import SwiftUI

// The MIDI variant's face side (plan step 15, §Q2 default): the chords the instance plays (asked for
// once by the C side, bkp_view_midi_enable), the face's MIDI line, and the drag-out .mid (tempo + key
// signature). The notes are the app's Harmony (KeyNotes.triad); the file is the app's writer
// (MidiExport.data). Nothing here is a second copy of either.

/// The C side's chord table (bkp_view.h): for each of the core's 24 keys (bk_key_name order), its notes.
/// Returns the notes per chord (0 = refused, logged) and sets *velocity.
@_cdecl("bkp_face_midi_chords")
public func bkp_face_midi_chords(_ notes: UnsafeMutableRawPointer?, _ velocity: UnsafeMutablePointer<Int32>?) -> Int32 {
    FaceLog.install()
    guard let notes, let velocity else {
        FaceLog.line(0, "REFUSED: MIDI chords: no table to fill")
        return 0
    }
    let table = MidiOut.table()
    guard let n = table.first?.count, n > 0, n <= Int(BKP_MIDI_NOTES), table.count == Int(BKP_MIDI_KEYS),
          table.allSatisfy({ $0.count == n && $0.allSatisfy { (0...127).contains($0) } }) else {
        FaceLog.line(0, "REFUSED: MIDI chords: the chord table is not \(BKP_MIDI_KEYS) chords of equal size (\(table))")
        return 0
    }
    let out = notes.bindMemory(to: UInt8.self, capacity: Int(BKP_MIDI_KEYS) * Int(BKP_MIDI_NOTES))
    for (k, chord) in table.enumerated() {
        for (i, note) in chord.enumerated() { out[k * Int(BKP_MIDI_NOTES) + i] = UInt8(note) }
    }
    velocity.pointee = Int32(KeyNotes.velocity)
    return Int32(n)
}

enum MidiOut {
    /// The core's 24 key names, by index (bk_key_name): the same names the instance reads out.
    static var coreKeys: [String] { (0..<Int(BKP_MIDI_KEYS)).map { String(cString: bk_key_name(Int32($0))) } }

    /// The chord of each core key: KeyNotes.triad, the app's tonic triad in root position.
    static func table() -> [[Int]] { coreKeys.map { KeyNotes.triad($0) } }

    /// "A C E": the notes of a chord by name (sharps or flats as the key is spelled).
    static func noteNames(_ key: String) -> String {
        let sharps = Scale.of(key)?.sharps ?? true
        return KeyNotes.triad(key).map { KeyNames.pitchName($0 % 12, sharps: sharps) }.joined(separator: " ")
    }

    /// The face's MIDI line when nothing more urgent is up; nil = say nothing (no audio yet).
    static func line(_ s: FaceState) -> (text: String, kind: FaceLine.Kind, detail: String)? {
        guard s.midi else { return nil }
        switch s.midiRoute {
        case 1:
            if let k = s.midiSounding {
                return ("MIDI out: \(k) chord", .info, "Beat Key holds \(noteNames(k)) on MIDI channel 1 while \(k) is the key.")
            }
            return ("MIDI out: waiting for a key.", .info, "The chord starts when a key shows.")
        case 2:
            return ("No MIDI out in this host. Drag .MID.", .error,
                    "This host gives plug-ins no MIDI output here. Drag .MID into the session instead: tempo and key.")
        default:
            return nil
        }
    }

    /// Where dragged files are written (the system temp folder; macOS clears it).
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Beat Key MIDI", isDirectory: true)
    }

    /// The drag-out file for what the face shows: the BPM in use (tempo, 4/4) and the key in use
    /// (key signature), MidiExport's one writer. nil + a log line when there is nothing to write or
    /// the write failed.
    static func write(token: UInt64, state s: FaceState, in dir: URL = directory) -> URL? {
        guard s.alive, s.bpm != nil || s.key != nil else {
            FaceLog.line(token, "MIDI DRAG REFUSED: no key or BPM yet; nothing written")
            return nil
        }
        let name = MidiExport.suggestedName(track: "Beat Key", bpm: s.bpmText, key: s.key)
        let url = dir.appendingPathComponent(name)
        let bytes = MidiExport.data(bpm: s.bpm, key: s.key, trackName: "Beat Key")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
            FaceLog.line(token, "MIDI DRAG: wrote \(url.path) (\(bytes.count) bytes, tempo \(s.bpmText ?? "none"), key \(s.key ?? "none"))")
            return url
        } catch {
            FaceLog.line(token, "MIDI DRAG FAILED: could not write \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// What .onDrag hands the host: the file, by URL (as the app's chord clips do).
    static func provider(token: UInt64, state: FaceState) -> NSItemProvider {
        guard let url = write(token: token, state: state) else { NSSound.beep(); return NSItemProvider() }
        let p = NSItemProvider(object: url as NSURL)
        p.suggestedName = url.lastPathComponent
        return p
    }
}
