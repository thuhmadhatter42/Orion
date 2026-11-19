import AppKit
import SwiftUI

// The house kit rows of a plug-in (plan A7), for the settings popover: Report, Manual, What's New,
// the version. The kit's Report / HelpMenu are app modules (an app menu, an app window); a plug-in
// lives in someone else's window, so these are the same rules written for a face.
//   Report:  Mail compose to contact@fourletterrecords.com, plugin.log (+ .1) attached, plus the host's
//            newest crash report when plugin.log has a HOST DIED line. No Mail: a mailto: link.
//   Pages:   Manual.html and WhatsNew.html in the bundle's Resources (plugin/build.sh copies app/pages),
//            opened in the default browser: offline, no network.

enum FaceHouse {
    /// House rule: an app other people use reports to Four Letter Records.
    static let reportTo = "contact@fourletterrecords.com"

    static var bundle: Bundle { Bundle(for: FaceHostView.self) }

    // MARK: pages

    @discardableResult
    static func open(page name: String, title: String, token: UInt64) -> Bool {
        let ns = name as NSString
        guard let u = bundle.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension) else {
            FaceLog.line(token, "ERROR help: \(name) is not in \(bundle.bundlePath)")
            return false
        }
        let ok = NSWorkspace.shared.open(u)
        FaceLog.line(token, ok ? "help: opened \(name)" : "ERROR help: macOS would not open \(u.path)")
        return ok
    }

    // MARK: report

    /// The host's newest crash report, when the log says a host died with Beat Key in it.
    static func hostCrashReport(logs: [URL]) -> URL? {
        let died = logs.contains { u in
            (try? String(contentsOf: u, encoding: .utf8))?.contains("HOST DIED") ?? false
        }
        guard died else { return nil }
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let host = ProcessInfo.processInfo.processName
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return items.filter { $0.lastPathComponent.hasPrefix(host) && ["ips", "crash"].contains($0.pathExtension) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    static func reportBody(state: FaceState, version: String) -> String {
        let host = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return """
        What happened (one line is enough):


        ---
        Beat Key plug-in \(version) \(state.format) in \(host)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        key \(state.key ?? "-") · BPM \(state.bpmText ?? "-") · readings \(state.readings)\(state.status.isEmpty ? "" : " · \(state.status)")
        """
    }

    /// Opens the report. Returns the line for the face.
    static func report(token: UInt64, state: FaceState, version: String) -> FaceLine {
        var logs = FaceLog.files
        if let crash = hostCrashReport(logs: logs) { logs.append(crash) }
        let subject = "Beat Key plug-in \(version) report"
        let body = reportBody(state: state, version: version)
        let items: [Any] = [body] + logs
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) {
            service.recipients = [reportTo]
            service.subject = subject
            service.perform(withItems: items)
            FaceLog.line(token, "report: composed to \(reportTo) (\(logs.count) file(s): \(logs.map(\.lastPathComponent).joined(separator: ", ")))")
            return FaceLine(text: "Report ready in Mail.", kind: .ok)
        }
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = reportTo
        c.queryItems = [URLQueryItem(name: "subject", value: subject),
                        URLQueryItem(name: "body", value: body + "\n\nPlease attach: " + logs.map(\.path).joined(separator: ", "))]
        if let u = c.url, NSWorkspace.shared.open(u) {
            if let first = logs.first { NSWorkspace.shared.activateFileViewerSelecting([first]) }
            FaceLog.line(token, "report: no Mail compose here; mailto opened and the log revealed in Finder")
            return FaceLine(text: "Attach the log shown in Finder.", kind: .info)
        }
        FaceLog.line(token, "ERROR report: no Mail compose and no mailto: handler")
        return FaceLine(text: "No mail app. Log: ~/Library/Logs/Beat Key", kind: .error)
    }
}
