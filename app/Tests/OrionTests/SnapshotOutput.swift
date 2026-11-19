import Foundation
import XCTest

/// Where the offscreen-render tests write their PNGs. ORION_SNAPSHOT_DIR=<dir> keeps them there
/// (for the marketing page and for looking at); without it they go to a fresh temp folder that is
/// removed afterwards. Either way the test is real: when it ends, at least one PNG written during
/// the test must be there and every one of them must be a real image (a failed render writes
/// nothing or an empty file), so a broken view fails `swift test` instead of being skipped.
enum SnapshotOutput {
    static func folder(for test: XCTestCase) throws -> URL {
        let fm = FileManager.default
        let keep = ProcessInfo.processInfo.environment["ORION_SNAPSHOT_DIR"]
        let dir = keep.map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory.appendingPathComponent("orion-snapshots-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let started = Date()
        test.addTeardownBlock {
            var written = 0
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".png") {
                let attrs = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)) ?? [:]
                guard let modified = attrs[.modificationDate] as? Date, modified >= started else { continue }
                written += 1
                let size = (attrs[.size] as? Int) ?? 0
                XCTAssertGreaterThan(size, 500, "\(name) is not a real image (\(size) bytes)")
            }
            XCTAssertGreaterThan(written, 0, "the render wrote no PNG into \(dir.path)")
            if keep == nil { try? fm.removeItem(at: dir) }
        }
        return dir
    }
}
