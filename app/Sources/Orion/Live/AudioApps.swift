import AppKit
import CoreAudio
import Darwin
import Foundation

/// An open app Listen can be pointed at (Listen's Input > Add App submenu).
struct AudioApp: Equatable {
    let bundleID: String
    let name: String
    let pid: pid_t
}

/// A client process Core Audio knows about, as reported while it plays out (helpers included:
/// a browser's sound comes from a helper process, not the app).
struct AudioProcess: Equatable {
    let pid: pid_t
    let bundleID: String?
}

/// The one chair for "which apps are open and which are playing right now".
///
/// Contract. Inputs: the open regular apps (NSWorkspace) and, where the OS can say, the processes
/// outputting audio (Core Audio process objects). Output: the apps in menu order, apps playing
/// now first, then everyone else, each group A-Z ignoring case. Callers: `SourceMenu` (the menu),
/// `LiveController` (is the chosen app still open). It never captures anything; the filter an
/// app choice makes lives in `SystemAudioCapture`. It refuses nothing: with no playing-now answer
/// the list is plain A-Z and the gap is logged once.
///
/// "Playing now" API: `kAudioHardwarePropertyProcessObjectList` (the system object's list of
/// process objects) and, per process, `kAudioProcessPropertyIsRunningOutput`, `...PID`,
/// `...BundleID`, all in Core Audio's AudioHardware.h:
/// https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunningoutput
/// https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyprocessobjectlist
/// Apple's symbol pages state no OS version; the process objects arrive with Core Audio taps, which
/// Apple documents as macOS 14.2 or later
/// (https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
/// So the lookup is gated `#available(macOS 14.2, *)`, and on any older Mac, or if Core Audio
/// refuses the list, the menu is plain A-Z.
enum AudioApps {
    struct Listing: Equatable {
        let apps: [AudioApp]
        let playingCount: Int
    }

    // MARK: pure (tested)

    /// Playing apps first, then the rest; each group A-Z ignoring case (ties by bundle id).
    static func ordered(_ apps: [AudioApp], playing: Set<String>) -> [AudioApp] {
        func before(_ a: AudioApp, _ b: AudioApp) -> Bool {
            let c = a.name.caseInsensitiveCompare(b.name)
            return c == .orderedSame ? a.bundleID < b.bundleID : c == .orderedAscending
        }
        let on = apps.filter { playing.contains($0.bundleID) }.sorted(by: before)
        let off = apps.filter { !playing.contains($0.bundleID) }.sorted(by: before)
        return on + off
    }

    /// Which open apps own the processes that are outputting audio: the process is the app
    /// (same pid), a helper named after it ("com.brave.Browser.helper" under "com.brave.Browser"),
    /// or a descendant of it (`parentOf` = a pid's parent; the walk stops after a few steps).
    static func playingIDs(outputProcesses: [AudioProcess], apps: [AudioApp],
                           parentOf: (pid_t) -> pid_t?) -> Set<String> {
        var out = Set<String>()
        for proc in outputProcesses {
            if let hit = apps.first(where: { $0.pid == proc.pid }) { out.insert(hit.bundleID); continue }
            if let id = proc.bundleID,
               let hit = apps.first(where: { id.hasPrefix($0.bundleID + ".") }) { out.insert(hit.bundleID); continue }
            var pid = proc.pid
            for _ in 0..<8 {
                guard let parent = parentOf(pid), parent > 1 else { break }
                if let hit = apps.first(where: { $0.pid == parent }) { out.insert(hit.bundleID); break }
                pid = parent
            }
        }
        return out
    }

    /// The menu's list. `outputProcesses` nil = the OS can't say what is playing: plain A-Z.
    static func listing(apps: [AudioApp], outputProcesses: [AudioProcess]?,
                        parentOf: (pid_t) -> pid_t?) -> Listing {
        guard let procs = outputProcesses else {
            noteUnavailable()
            let l = Listing(apps: ordered(apps, playing: []), playingCount: 0)
            AppLog.log("add app: list built, \(l.apps.count) apps, playing-now unknown (A-Z only)")
            return l
        }
        let playing = playingIDs(outputProcesses: procs, apps: apps, parentOf: parentOf)
        let l = Listing(apps: ordered(apps, playing: playing), playingCount: apps.filter { playing.contains($0.bundleID) }.count)
        AppLog.log("add app: list built, \(l.apps.count) apps, \(l.playingCount) playing")
        return l
    }

    // MARK: the system

    /// The list for the menu right now.
    static func current() -> Listing {
        listing(apps: openApps(), outputProcesses: outputProcesses(), parentOf: parentPID)
    }

    /// Every open regular (Dock) app with a bundle id, one per bundle id; Beat Key itself is left
    /// out (its own sound is never captured).
    static func openApps() -> [AudioApp] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { r in
            guard r.activationPolicy == .regular, !r.isTerminated, let id = r.bundleIdentifier, id != me,
                  seen.insert(id).inserted else { return nil }
            return AudioApp(bundleID: id, name: r.localizedName ?? id, pid: r.processIdentifier)
        }
    }

    static func runningBundleIDs() -> Set<String> { Set(openApps().map(\.bundleID)) }

    /// An app's name for the Input readout; the bundle id when it isn't open or installed.
    static func displayName(bundleID: String) -> String {
        if let n = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    /// Processes outputting audio now; nil = this Mac can't say (macOS before 14.2, or Core Audio
    /// refused the list). Never throws, never blocks beyond the Core Audio calls.
    static func outputProcesses() -> [AudioProcess]? {
        guard #available(macOS 14.2, *) else { return nil }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let st = AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size)
        guard st == noErr else {
            AppLog.log("add app: Core Audio process list refused (OSStatus \(st))")
            return nil
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        var got = size
        let st2 = AudioObjectGetPropertyData(sys, &addr, 0, nil, &got, &ids)
        guard st2 == noErr else {
            AppLog.log("add app: Core Audio process list unreadable (OSStatus \(st2))")
            return nil
        }
        var unreadable = 0
        let out: [AudioProcess] = ids.compactMap { obj in
            guard let running = value(UInt32.self, obj, kAudioProcessPropertyIsRunningOutput) else { unreadable += 1; return nil }
            guard running != 0, let pid = value(pid_t.self, obj, kAudioProcessPropertyPID) else { return nil }
            return AudioProcess(pid: pid, bundleID: bundleID(obj))
        }
        if unreadable > 0 { AppLog.log("add app: \(unreadable) of \(ids.count) audio processes could not be read") }
        return out
    }

    private static func value<T>(_ type: T.Type, _ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, raw) == noErr else { return nil }
        return raw.load(as: T.self)
    }

    private static func bundleID(_ obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let s = cf else { return nil }
        return s.takeRetainedValue() as String
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n == Int32(MemoryLayout<proc_bsdinfo>.size) ? pid_t(info.pbi_ppid) : nil
    }

    // MARK: the "can't say what is playing" log, once

    private static let noteLock = NSLock()
    private static var unavailableLogged = false

    private static func noteUnavailable() {
        noteLock.lock(); defer { noteLock.unlock() }
        guard !unavailableLogged else { return }
        unavailableLogged = true
        let v = ProcessInfo.processInfo.operatingSystemVersion
        AppLog.log("add app: playing-now is not available on macOS \(v.majorVersion).\(v.minorVersion) "
                   + "(Core Audio process list needs 14.2 or newer, or it refused); the app list is A-Z only")
    }

    static func resetUnavailableLogForTests() {
        noteLock.lock(); unavailableLogged = false; noteLock.unlock()
    }
}
