import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// THE entry for files that reach the app from outside the Analyze field: a drop on the window,
/// the pocket (menu-bar icon and popover) or the Mini, a drop / Open With on the Dock icon,
/// Analyze a File… (File menu, ⌃⌥⌘F), the Finder service "Analyze with Beat Key", the DAW selection.
/// Every one calls `receive`, which expands folders one level, keeps the audio and hands it to the
/// faceplate's `handler` (Engine.submit: read now when idle, queued FIFO when busy). Files that
/// arrive while the app is still launching wait for the handler.
enum Intake {
    static var handler: (([URL]) -> Bool)? {
        didSet { if let go = handler, !waiting.isEmpty { let w = waiting; waiting = []; _ = go(w) } }
    }
    private static var waiting: [URL] = []

    /// The audio among `urls` (folders opened one level), handed to the faceplate. False = nothing
    /// was started. Counts only in the log, never names.
    @discardableResult
    static func receive(_ urls: [URL], via: String = "other") -> Bool {
        let all = Faceplate.expandFolders(urls)
        let files = Faceplate.audioFiles(all)
        AppLog.log("intake via \(via): \(urls.count) item(s), \(files.count) audio, \(all.count - files.count) skipped"
                   + (handler == nil ? ", held until the window is up" : ""))
        guard !files.isEmpty else { NSSound.beep(); return false }
        guard let go = handler else { waiting += files; return true }
        NSApp?.activate(ignoringOtherApps: true)
        if go(files) { return true }
        AppLog.log("intake via \(via): the window refused \(files.count) file(s)")
        NSSound.beep()
        return false
    }

    /// A drop of file providers (SwiftUI surfaces): reads the file URLs in drop order, then `receive`.
    /// True = the drop carried files and is being read (the result is in the log and on the LCD).
    @discardableResult
    static func drop(_ providers: [NSItemProvider], via: String) -> Bool {
        let carrying = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !carrying.isEmpty else { AppLog.log("intake via \(via): a drop with no files"); return false }
        let group = DispatchGroup()
        var urls: [Int: URL] = [:]
        let lock = NSLock()
        for (i, p) in carrying.enumerated() {
            group.enter()
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                defer { group.leave() }
                var u: URL?
                if let d = item as? Data { u = URL(dataRepresentation: d, relativeTo: nil) }
                else if let x = item as? URL { u = x }
                if let u = u, u.isFileURL { lock.lock(); urls[i] = u; lock.unlock() }
                else { AppLog.log("intake via \(via): one dropped item could not be read\(error.map { " (\($0))" } ?? "")") }
            }
        }
        group.notify(queue: .main) { receive(urls.keys.sorted().compactMap { urls[$0] }, via: via) }
        return true
    }


    /// The audio-only open panel (the drop filter's allowlist), several files allowed.
    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Faceplate.audioExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Choose"
        panel.message = "Choose a beat to find its BPM and key"
        return panel
    }

    /// File › Analyze a File…: pick, then read it straight away.
    static func analyzeAFile() {
        let panel = makePanel()
        panel.message = "Choose a beat, video or MIDI file to find its BPM and key"
        let pick = { (resp: NSApplication.ModalResponse) in
            guard resp == .OK else { return }
            receive(panel.urls, via: "analyze a file")
        }
        if let w = NSApp.keyWindow ?? NSApp.windows.first { panel.beginSheetModal(for: w, completionHandler: pick) }
        else { pick(panel.runModal()) }
    }
}

extension View {
    /// Makes this surface a drop target for audio files and folders: the only `.onDrop` in the app.
    /// `via` names the surface in the log ("window", "pocket", "mini").
    func acceptsFileDrops(via: String, isTargeted: Binding<Bool>? = nil) -> some View {
        onDrop(of: ["public.file-url"], isTargeted: isTargeted) { Intake.drop($0, via: via) }
    }
}

/// The menu-bar icon as a drop target: a transparent view over the status button. It has no
/// mouse handlers, so clicks pass up to the button; only files dragged onto the icon stop here.
final class StatusDropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return Intake.receive(urls, via: "pocket")
    }
}

/// Finder › Services › "Analyze with Beat Key" (NSServices in Info.plist, message
/// `analyzeWithBeatKey`) and Open With.
final class ServiceProvider: NSObject {
    @objc func analyzeWithBeatKey(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty { error.pointee = "Select an audio, video or MIDI file in Finder first." as NSString; return }
        if !Intake.receive(urls, via: "finder service") { error.pointee = "Beat Key found no audio in the selection." as NSString }
    }
}
