import CryptoKit
import Foundation
import XCTest
@testable import Orion

/// Plan step 19's gate: the app's own file path (FileReader: the bundled ffmpeg, the mono mix,
/// the core) gives the goldens' answers on every bench and smoke clip (plan A5). Two checks per clip:
///   pcm      the mono samples the app hands the core are bit-identical to the ones the goldens were
///            frozen from (manifest pcm_sha256), so the core sees exactly what core/parity.sh fed it;
///   reading  the row the LCD shows: the same three keys with the same whole percentages, the BPM
///            text bpm.py printed, decimal BPM within 0.01, tuning within 0.5 cent (offered alike),
///            chroma within one unit of its 3 decimals; no reading where the reference had none.
/// Needs the bench audio, so it runs only when asked:
///   BEATKEY_PARITY_BENCH=<checkout>/docs/research  BEATKEY_PARITY_BIN=<folder with ffmpeg, ffprobe>
///   [BEATKEY_PARITY_SMOKE_BIN=<the goldens' ffmpeg folder, to rebuild the smoke clips>]
///   swift test --filter CoreParityTests
/// A miss is a bug, never a new tolerance.
final class CoreParityTests: XCTestCase {
    struct Item { let set: String, name: String, id: String, sha: String, pcm: String }

    func testAppReadingsMatchTheGoldens() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bench = env["BEATKEY_PARITY_BENCH"], let bin = env["BEATKEY_PARITY_BIN"] else {
            throw XCTSkip("set BEATKEY_PARITY_BENCH and BEATKEY_PARITY_BIN to run the app's parity gate")
        }
        let golden = CoreTestSupport.repo.appendingPathComponent("core/test/golden")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: golden.appendingPathComponent("manifest.json"))) as! [String: Any]
        let items = (manifest["items"] as! [[String: Any]]).map {
            Item(set: $0["set"] as! String, name: $0["name"] as! String, id: $0["id"] as! String,
                 sha: $0["sha256"] as! String, pcm: $0["pcm_sha256"] as! String)
        }
        let reader = FileReader(binDir: URL(fileURLWithPath: bin), weights: CoreTestSupport.weights)
        XCTAssertNil(Core.load(CoreTestSupport.weights))
        let smokeDir = FileManager.default.temporaryDirectory.appendingPathComponent("beatkey-parity-\(getpid())")
        defer { try? FileManager.default.removeItem(at: smokeDir) }
        let smoke = try smokeClips(bench: URL(fileURLWithPath: bench), out: smokeDir,
                                   ffmpeg: URL(fileURLWithPath: env["BEATKEY_PARITY_SMOKE_BIN"] ?? bin).appendingPathComponent("ffmpeg"))

        var compared = 0, pcmSame = 0, readingSame = 0, exactBpm = 0, unread = 0, absent = 0
        var misses: [String] = []
        for it in items {
            let file: URL
            if it.set == "smoke" {
                guard let f = smoke[it.name] else { absent += 1; continue }
                file = f
            } else {
                file = URL(fileURLWithPath: bench).appendingPathComponent("\(it.set)/audio/\(it.name)")
            }
            guard FileManager.default.fileExists(atPath: file.path) else { absent += 1; continue }
            guard try sha256(Data(contentsOf: file)) == it.sha else {
                misses.append("\(it.set)/\(it.name): the source file is not the one the goldens were made from"); continue
            }
            compared += 1
            let g = try JSONSerialization.jsonObject(with: Data(contentsOf: golden.appendingPathComponent("files/\(it.id).json"))) as! [String: Any]
            // 1 the samples
            let (mono, _) = try reader.decode(file)
            let pcm = mono.withUnsafeBufferPointer { sha256(Data(buffer: $0)) }
            if pcm == it.pcm { pcmSame += 1 } else { misses.append("\(it.set)/\(it.name): decoded samples differ from the goldens'") }
            // 2 the row
            guard case .reading(let r) = reader.read(file) else { misses.append("\(it.name): refused as incomplete"); continue }
            let miss = compare(r, g)
            if miss.isEmpty { readingSame += 1 } else { misses.append("\(it.set)/\(it.name): " + miss.joined(separator: "; ")) }
            if r.bpm == nil { unread += 1 }
            if let t = g["tempo"] as? [String: Any], let want = t["bpm_exact"] as? Double, r.bpmExact == want { exactBpm += 1 }
        }
        let summary = "app parity: \(compared) clips compared (\(absent) not on this Mac); samples identical \(pcmSame)/\(compared); "
            + "readings identical \(readingSame)/\(compared) (\(unread) with no reading, as the reference); decimal BPM exact \(exactBpm)"
        print(summary)
        XCTAssertGreaterThan(compared, 0, "no clip found under \(bench)")
        XCTAssertTrue(misses.isEmpty, summary + "\n" + misses.joined(separator: "\n"))
    }

    /// The reference's row for golden `g`, against the app's.
    func compare(_ r: Result, _ g: [String: Any]) -> [String] {
        var miss: [String] = []
        let key = g["key"] as! [String: Any], tempo = g["tempo"] as! [String: Any]
        let gbpm = tempo["bpm"] as? Double ?? 0
        let decided = tempo["decided"] as? Bool ?? true
        if !(gbpm > 0) && decided {
            // bpm.py exits 1: app_run.py gave the file no reading
            if r.bpm != nil || !r.keys.isEmpty { miss.append("reference had no reading, app shows bpm \(r.bpm ?? "-")") }
            return miss
        }
        let gkeys = (key["keys"] as! [[Any]]).map { ($0[0] as! String, Int(($0[1] as! NSNumber).doubleValue.rounded(.toNearestOrEven))) }
        if r.keys.map({ $0.0 }) != gkeys.map({ $0.0 }) || r.keys.map({ $0.1 }) != gkeys.map({ $0.1 }) {
            miss.append("keys \(r.keys) vs \(gkeys)")
        }
        if decided {
            if r.bpm != "\(gbpm)" { miss.append("bpm \(r.bpm ?? "-") vs \(gbpm)") }
            if let want = tempo["bpm_exact"] as? Double {
                if let got = r.bpmExact { if abs(got - want) > 0.01 + 1e-9 { miss.append("bpm_exact \(got) vs \(want)") } }
                else { miss.append("no bpm_exact, reference \(want)") }
            }
        }
        let gt = key["tuning_cents"] as? Double
        switch (r.tuningCents, gt) {
        case (nil, nil): break
        case (let a?, let b?): if abs(a - b) > 0.5 + 1e-9 { miss.append("tuning \(a) vs \(b)") }
        default: miss.append("tuning offered \(r.tuningCents as Any) vs \(gt as Any)")
        }
        let gc = (key["chroma"] as! [NSNumber]).map { $0.doubleValue }
        if let c = r.chroma {
            if zip(c, gc).contains(where: { abs($0 - $1) > 0.001 + 1e-9 }) { miss.append("chroma \(c) vs \(gc)") }
        } else { miss.append("no chroma") }
        return miss
    }

    func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// The smoke set rebuilt the way tools/parity/make_goldens.py builds it (bit-exact ffmpeg flags):
    /// name -> clip file. A clip a different ffmpeg makes differently is caught by its sha256.
    func smokeClips(bench: URL, out: URL, ffmpeg: URL) throws -> [String: URL] {
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf:
            CoreTestSupport.repo.appendingPathComponent("tools/parity/smoke_set.json"))) as! [String: Any]
        func files(_ set: String) -> [URL] {
            let d = bench.appendingPathComponent("\(set)/audio")
            return ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "mp3" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let benches = ["key-bench": files("key-bench"), "bpm-bench": files("bpm-bench")]
        guard benches.values.allSatisfy({ $0.count == 40 }), FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { return [:] }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var made: [String: URL] = [:]
        for clip in spec["clips"] as! [[String: Any]] {
            let id = clip["id"] as! String
            let inputs = clip["inputs"] as! [String]
            func src(_ s: String) -> URL {
                let p = s.split(separator: "/")
                return benches[String(p[0])]![Int(p[1])!]
            }
            if clip["copy"] as? Bool == true { made[id] = src(inputs[0]); continue }
            let dst = out.appendingPathComponent("\(id).wav")
            var args = ["-nostdin", "-v", "error", "-y"]
            for s in inputs {
                if s.hasPrefix("lavfi:") { args += ["-f", "lavfi", "-i", String(s.dropFirst(6))] } else { args += ["-i", src(s).path] }
            }
            args += (clip["args"] as! [String]) + ["-fflags", "+bitexact", "-flags:a", "+bitexact", "-map_metadata", "-1", dst.path]
            _ = try FileReader.run(ffmpeg, args)
            made[id] = dst
        }
        return made
    }
}
