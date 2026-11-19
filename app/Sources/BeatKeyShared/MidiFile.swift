import Foundation

// BeatKeyShared: THE standard-MIDI-file writer (moved from the app's MidiExport.swift for plug-in plan
// step 15, one copy). The app's File > Export MIDI Tempo/Key File..., its chord clips (ChordClip) and
// the plug-in MIDI variant's drag-out .mid all write through MidiExport.data.

/// A standard MIDI file (format 0) with a set-tempo and a key-signature meta event, for any DAW that
/// imports tempo / key from MIDI; optionally a chord held (the chord clips).
public enum MidiExport {
    public static let ticksPerQuarter: UInt16 = 480
    /// The velocity of every note Beat Key writes (chord clips, the MIDI variant's held chord).
    public static let defaultVelocity: UInt8 = 96

    /// A key name as the analyzer writes it ("Cm", "Ebm", "F#", "Bb", "C#m") to the key-signature
    /// bytes: sharps(+) / flats(-) -7...+7 and minor. nil = not a key name.
    public static func keySignature(_ name: String) -> (sharps: Int, minor: Bool)? {
        guard let k = KeyNames.parse(name) else { return nil }
        // a spelling with no standard signature (G# major = 8 sharps): the key it equals (Ab = -4)
        let sharps = (-7...7).contains(k.sharps) ? k.sharps : ((k.sharps + 6) % 12 + 12) % 12 - 6
        return (sharps, k.minor)
    }

    /// The file's bytes. `bpm` outside 1...1000 or nil writes no tempo event; an unknown key
    /// writes no key event. `notes` (MIDI numbers, channel 1) start together at tick 0 and end
    /// together at `noteTicks`; none = the tempo / key file.
    public static func data(bpm: Double?, key: String?, trackName: String? = nil,
                     notes: [Int] = [], noteTicks: UInt32 = 0, velocity: UInt8 = defaultVelocity) -> Data {
        var t = [UInt8]()
        func event(_ bytes: [UInt8], delta: UInt32 = 0) { t += varLen(delta); t += bytes }
        if let name = trackName, !name.isEmpty {
            let b = Array(name.utf8.prefix(120))
            event([0xFF, 0x03, UInt8(b.count)] + b)
        }
        if let bpm, (1...1000).contains(bpm) {
            let us = UInt32((60_000_000 / bpm).rounded())
            event([0xFF, 0x51, 0x03, UInt8(us >> 16 & 0xFF), UInt8(us >> 8 & 0xFF), UInt8(us & 0xFF)])
            event([0xFF, 0x58, 0x04, 4, 2, 24, 8])   // 4/4, so the DAW has a full meter
        }
        if let key, let k = keySignature(key) {
            event([0xFF, 0x59, 0x02, UInt8(bitPattern: Int8(k.sharps)), k.minor ? 1 : 0])
        }
        let held = notes.map { UInt8(clamping: max(0, min(127, $0))) }
        for n in held { event([0x90, n, min(velocity, 127)]) }
        for (i, n) in held.enumerated() { event([0x80, n, 0], delta: i == 0 ? noteTicks : 0) }
        event([0xFF, 0x2F, 0x00])
        var out = Data("MThd".utf8)
        out += be32(6) + be16(0) + be16(1) + be16(ticksPerQuarter)
        out += Data("MTrk".utf8) + be32(UInt32(t.count)) + Data(t)
        return out
    }

    /// A MIDI variable-length quantity (7 bits a byte, high bit = more follows).
    public static func varLen(_ v: UInt32) -> [UInt8] {
        var bytes = [UInt8(v & 0x7F)]
        var rest = v >> 7
        while rest > 0 { bytes.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
        return bytes
    }

    private static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    /// "<track> (<bpm> BPM <key>).mid": the track name without its extension or an earlier
    /// "(142.0 BPM Cm Dm)" tag, and without characters a file name cannot hold.
    public static func suggestedName(track: String, bpm: String?, key: String?) -> String {
        var base = (track as NSString).deletingPathExtension
        if let r = base.range(of: #" \([^()]*BPM[^()]*\)$"#, options: .regularExpression) { base.removeSubrange(r) }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let tag = [bpm.map { "\($0) BPM" }, key].compactMap { $0 }.joined(separator: " ")
        return (tag.isEmpty ? base : "\(base) (\(tag))") + ".mid"
    }
}
