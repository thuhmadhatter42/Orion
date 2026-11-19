import AppKit
import SwiftUI

// Add key + BPM to a file's name (J, 2026-11-18, idea 2). Chairs, one owner each:
//   the tag's FORMAT and its recogniser ... app_run.py (renamed_name / is_tagged / rename_file);
//                                          Swift never builds or parses a name.
//   the POLICY (ask / remember / Pro Tools guard) ... RenameCoordinator, below.
//   the remembered choice ... RenameSettings (Settings shows and changes the same value).
//   running the helper and refreshing the paths ... Engine.rename / Engine.applyRenamed.
// Every step is logged to beatkey.log (counts and answers, never a file name).

/// What Beat Key does after it reads a file: ask, or the remembered answer.
enum RenameChoice: String, CaseIterable {
    case ask, always, never
}

/// The remembered choice, in UserDefaults. The prompt's "Remember my choice" and the Settings
/// picker both write it through `set`.
final class RenameSettings: ObservableObject {
    static let key = "renameChoice"
    private let defaults: UserDefaults

    @Published private(set) var choice: RenameChoice

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = defaults.string(forKey: RenameSettings.key).flatMap(RenameChoice.init(rawValue:)) ?? .ask
    }

    /// `from` = where the change came from ("prompt", "Settings"); it goes in the log.
    func set(_ new: RenameChoice, from source: String) {
        guard new != choice else { return }
        AppLog.log("rename: remembered choice \(choice.rawValue) -> \(new.rawValue) (\(source))")
        choice = new
        defaults.set(new.rawValue, forKey: RenameSettings.key)
    }
}

/// A file inside a Pro Tools session: its folder is named "Audio Files" and that folder's parent
/// holds a .ptx session. Renaming such a file makes Pro Tools lose it.
enum ProToolsGuard {
    static func inSession(_ file: URL, fm: FileManager = .default) -> Bool {
        let folder = file.deletingLastPathComponent()
        guard folder.lastPathComponent.lowercased() == "audio files" else { return false }
        let session = folder.deletingLastPathComponent()
        guard let names = try? fm.contentsOfDirectory(atPath: session.path) else { return false }
        return names.contains { ($0 as NSString).pathExtension.lowercased() == "ptx" }
    }
}

/// One file to tag: the helper's `rename <file> <bpm> <key>...` arguments. `keys` = the key in use
/// first, then the detector's others; the helper writes the first `KEY_COUNT` (app_run.py).
struct RenameItem: Equatable {
    let file: URL
    let bpm: String
    let keys: [String]

    /// What the name carries for `r` right now: the key in use (the pin, else the detector's #1,
    /// `Result.keyInUse`) then the other keys as Auto-Tune spells them, and the BPM as shown (the
    /// analyzer's own text at x1, the half / double of it otherwise). nil = nothing to tag: no BPM,
    /// no key, a read error, or Beat Key's own tag already there.
    static func make(_ r: Result, choice: KeyChoice?, factor: TempoFactor = .one) -> RenameItem? {
        guard let bpm = r.bpm, r.readError == nil, !r.tagged, !r.keys.isEmpty else { return nil }
        let shown = r.respelled(choice: choice)
        guard let first = shown.keyInUse?.name else { return nil }
        let firstClass = KeyNames.parse(first)
        let others = shown.keys.map { $0.0 }.filter { name in
            guard let c = KeyNames.parse(name), let f = firstClass else { return name != first }
            return !(c.pitchClass == f.pitchClass && c.minor == f.minor)
        }
        let text: String
        if factor == .one { text = bpm }
        else if let v = Double(bpm) { text = String(format: "%.1f", v * factor.multiplier) }
        else { text = bpm }
        return RenameItem(file: r.file, bpm: text, keys: [first] + others)
    }
}

/// How the app asks. The soft ask never blocks; the Pro Tools confirm always does. Tests fake it.
protocol RenameAsker: AnyObject {
    /// Non-blocking "Rename the file?" with a Remember box. `answer(rename, remember)` once.
    func ask(count: Int, answer: @escaping (_ rename: Bool, _ remember: Bool) -> Void)
    /// The soft ask is no longer wanted (a newer reading arrived): take it down.
    func dismissAsk()
    /// Blocking, always. True = rename anyway.
    func confirmProToolsLoss(count: Int) -> Bool
}

/// The rename policy, the one chair: after an analysis, which files are tagged, which are asked
/// about, which are guarded, which are skipped. Calls `perform` (Engine.rename) with the items.
final class RenameCoordinator {
    private let settings: RenameSettings
    private let asker: RenameAsker
    private let item: (Result) -> RenameItem?
    private let isProToolsFile: (URL) -> Bool
    private let perform: ([RenameItem]) -> Void
    private var generation = 0
    private var asking = false

    /// `item` builds a file's tag when the answer comes (so a key pinned while the ask is up counts).
    init(settings: RenameSettings, asker: RenameAsker,
         item: @escaping (Result) -> RenameItem?,
         isProToolsFile: @escaping (URL) -> Bool = { ProToolsGuard.inSession($0) },
         perform: @escaping ([RenameItem]) -> Void) {
        self.settings = settings
        self.asker = asker
        self.item = item
        self.isProToolsFile = isProToolsFile
        self.perform = perform
    }

    private static func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }

    /// Called with every analysis's results (not downloads: the helper tags those itself).
    func offer(_ results: [Result]) {
        generation += 1
        let gen = generation
        if asking {
            asking = false
            asker.dismissAsk()
            AppLog.log("rename: ask dismissed (a newer reading arrived)")
        }
        let tagged = results.filter { $0.tagged }
        if !tagged.isEmpty { AppLog.log("rename: skipped \(RenameCoordinator.files(tagged.count)) already tagged by Beat Key") }
        let eligible = results.filter { !$0.tagged && $0.bpm != nil && !$0.keys.isEmpty && $0.readError == nil }
        guard !eligible.isEmpty else { return }
        let guarded = eligible.filter { isProToolsFile($0.file) }
        let plain = eligible.filter { !isProToolsFile($0.file) }
        if !guarded.isEmpty { proToolsGuard(guarded) }
        if !plain.isEmpty { decide(plain, gen: gen) }
    }

    /// Pro Tools would lose these: always a blocking confirm, whatever was remembered.
    private func proToolsGuard(_ rs: [Result]) {
        AppLog.log("rename: Pro Tools guard triggered (\(RenameCoordinator.files(rs.count)) in a session's Audio Files)")
        let yes = asker.confirmProToolsLoss(count: rs.count)
        AppLog.log("rename: Pro Tools guard answer \(yes ? "yes" : "no")")
        if yes { run(rs) }
    }

    private func decide(_ rs: [Result], gen: Int) {
        switch settings.choice {
        case .never:
            AppLog.log("rename: remembered no, not asking (\(RenameCoordinator.files(rs.count)))")
        case .always:
            AppLog.log("rename: remembered yes, renaming \(RenameCoordinator.files(rs.count))")
            run(rs)
        case .ask:
            asking = true
            AppLog.log("rename: asked (\(RenameCoordinator.files(rs.count)))")
            asker.ask(count: rs.count) { [weak self] yes, remember in
                guard let self, gen == self.generation, self.asking else { return }
                self.asking = false
                AppLog.log("rename: answer \(yes ? "yes" : "no") (\(remember ? "remembered" : "not remembered"))")
                if remember { self.settings.set(yes ? .always : .never, from: "prompt") }
                if yes { self.run(rs) }
            }
        }
    }

    private func run(_ rs: [Result]) {
        let items = rs.compactMap(item)
        guard !items.isEmpty else { return }
        perform(items)
    }
}

extension Result {
    /// The reading after its file was renamed: the same reading under the new path and name.
    func moved(to url: URL) -> Result {
        Result(file: url, name: url.lastPathComponent, bpm: bpm, keys: keys, readError: readError,
               bpmExact: bpmExact, tuningCents: tuningCents, chroma: chroma, pin: pin, tagged: true)
    }
}

extension SpellingSettings {
    /// The file the pin belongs to was renamed: the pin follows it (same key, same slot).
    func moved(from old: URL, to new: URL) {
        guard let m = manualKey, m.file == old else { return }
        manualKey = KeyChoice(file: new, name: new.lastPathComponent, pitchClass: m.pitchClass,
                              minor: m.minor, slot: m.slot)
    }
}

extension Faceplate {
    /// The caption under the readout when a rename failed: the reading stands, this says why the
    /// name did not change.
    static func renameFailedNote(_ message: String) -> String {
        "COULDN'T RENAME THE FILE · " + errorText(message)
    }
}

// MARK: the app's own asker (the part no test clicks)

/// "Rename the file?": a small card in the corner of the screen, beside the window, that does not
/// take focus or block anything; and the Pro Tools confirm, a real modal alert.
final class RenamePrompt: RenameAsker {
    private var panel: NSPanel?
    private var answered = false

    func ask(count: Int, answer: @escaping (Bool, Bool) -> Void) {
        let show = { [self] in
            close()
            answered = false
            let view = RenameAskView(count: count) { [weak self] yes, remember in
                guard let self, !self.answered else { return }
                self.answered = true
                self.close()
                answer(yes, remember)
            }
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.contentView = host
            p.isReleasedWhenClosed = false
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.appearance = NSAppearance(named: .darkAqua)
            p.setFrameOrigin(RenamePrompt.origin(for: size))
            p.orderFrontRegardless()
            panel = p
        }
        if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }
    }

    func dismissAsk() {
        answered = true
        if Thread.isMainThread { close() } else { DispatchQueue.main.async { self.close() } }
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Under the Beat Key window's bottom-right corner, else the main screen's top right.
    private static func origin(for size: NSSize) -> NSPoint {
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.title == Brand.name }) ?? NSApp.mainWindow {
            return NSPoint(x: w.frame.maxX - size.width - 16, y: max(w.frame.minY + 16, 16))
        }
        let f = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        return NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 16)
    }

    func confirmProToolsLoss(count: Int) -> Bool {
        let run = { () -> Bool in
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = count == 1 ? "Pro Tools will lose this file" : "Pro Tools will lose \(count) of these files"
            a.informativeText = (count == 1 ? "This file is" : "These files are")
                + " in a Pro Tools session's Audio Files folder. Renaming "
                + (count == 1 ? "it" : "them") + " makes the session show "
                + (count == 1 ? "it" : "them") + " as missing."
            a.addButton(withTitle: "Don't Rename")
            a.addButton(withTitle: "Rename Anyway")
            NSApp.activate(ignoringOtherApps: true)
            return a.runModal() == .alertSecondButtonReturn
        }
        return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
    }
}

struct RenameAskView: View {
    let count: Int
    let answer: (_ rename: Bool, _ remember: Bool) -> Void
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(count == 1 ? "Rename the file?" : "Rename \(count) files?")
                .font(.system(size: 13, weight: .semibold))
            Text("Adds the key and BPM to its name.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Toggle("Remember my choice", isOn: $remember)
                .font(.system(size: 11))
            HStack(spacing: 8) {
                Button("Don't Rename") { answer(false, remember) }
                Button("Rename") { answer(true, remember) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
    }
}
