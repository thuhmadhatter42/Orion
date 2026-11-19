import AppKit
import SwiftUI

// Accent (the colour itself, its contrast maths, ink and lit cap) lives in BeatKeyShared/Look.swift:
// one copy with the plug-in's face. Its settings, panel and chip are the app's, here.

/// The chosen colour, remembered between launches (UserDefaults `accentColor`: [r, g, b] sRGB 0...255).
/// The one owner of the colour in use (`effective`): the window's, the pocket's and the Mini's root
/// put it in the environment as `\.palette` (View.paletteRoot), and the menu-bar key takes it from
/// `$effective`. A change redraws the views that read it, nothing more (Listen's meter, ticking at
/// 20 Hz, never touches it).
final class AccentSettings: ObservableObject {
    static let key = "accentColor"
    static let shared = AccentSettings()
    private let defaults: UserDefaults
    /// While the colour wheel drags, updates are drawn at most this often.
    static let minInterval = 1.0 / 30

    /// What J picked (the wheel shows this).
    @Published private(set) var picked: Accent = .amber
    /// What the faceplate shows: `picked`, lifted if it would not read on the LCD.
    @Published private(set) var effective: Accent = .amber
    /// The colour panel is open (the COLOR chip lights).
    @Published var panelOpen = false
    private(set) var clamped = false

    private var pending: Accent?
    private var lastApply = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = AccentSettings.load(defaults)
        apply(stored ?? .amber, persist: false)
    }

    static func load(_ d: UserDefaults) -> Accent? {
        guard let raw = d.object(forKey: key) else { return nil }
        guard let a = raw as? [Double], a.count == 3, a.allSatisfy({ $0.isFinite }) else {
            AppLog.log("accent: stored \(key) unreadable (\(raw)), using amber")
            return nil
        }
        return Accent(a[0], a[1], a[2])
    }

    /// A new colour, now (Reset, tests, launch).
    func set(_ a: Accent) { pending = nil; apply(a, persist: true) }

    /// Back to amber; the stored pick is removed.
    func reset() {
        pending = nil
        apply(.amber, persist: false)
        defaults.removeObject(forKey: AccentSettings.key)
        AppLog.log("accent: reset to amber")
    }

    /// From the colour wheel while it drags: coalesced to `minInterval`, the last one always lands.
    func drag(_ a: Accent) {
        let wait = AccentSettings.minInterval - Date().timeIntervalSince(lastApply)
        if wait <= 0 { set(a); return }
        let scheduled = pending != nil
        pending = a
        if !scheduled {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self = self, let p = self.pending else { return }
                self.set(p)
            }
        }
    }

    private func apply(_ a: Accent, persist: Bool) {
        let (shown, wasClamped) = a.readable()
        // logged once each time a pick crosses into too-dark (not on every drag step); the
        // panel's close line names the final pick and what is shown
        if wasClamped && !clamped {
            AppLog.log("accent: \(a.described) too dark for the LCD (\(String(format: "%.1f", a.contrast(with: .lcd))):1), shown as \(shown.described)")
        }
        clamped = wasClamped
        lastApply = Date()
        if picked != a { picked = a }
        if effective != shown { effective = shown }
        if persist {
            defaults.set([a.r, a.g, a.b], forKey: AccentSettings.key)
        }
    }
}

/// The macOS colour wheel (the shared NSColorPanel, wheel mode, no opacity), with Reset to Amber
/// under it. Opened by the COLOR chip; the face recolours live while the wheel drags.
final class AccentPanel: NSObject {
    static let shared = AccentPanel()
    private var closeObserver: Any?
    private let settings: AccentSettings

    init(settings: AccentSettings = .shared) { self.settings = settings }

    func toggle() {
        if settings.panelOpen { NSColorPanel.shared.close() } else { open() }
    }

    func open() {
        let p = NSColorPanel.shared
        p.mode = .wheel
        p.showsAlpha = false
        p.isContinuous = true
        p.setTarget(nil); p.setAction(nil)        // setting the colour must not echo back as a pick
        p.color = settings.picked.nsColor
        p.setTarget(self)
        p.setAction(#selector(changed(_:)))
        p.accessoryView = resetView()
        p.title = "\(Brand.name) Colour"
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p,
                                                                   queue: .main) { [weak self] _ in self?.closed() }
        }
        NSApp.activate(ignoringOtherApps: true)
        p.orderFront(nil)
        settings.panelOpen = true
        AppLog.log("accent: colour panel open (\(settings.picked.described))")
    }

    @objc private func changed(_ sender: NSColorPanel) {
        guard let a = Accent(sender.color) else {
            AppLog.log("accent: panel colour \(sender.color) has no sRGB form, ignored")
            return
        }
        settings.drag(a)
    }

    @objc private func resetPressed(_ sender: Any?) {
        let p = NSColorPanel.shared
        p.setTarget(nil); p.setAction(nil)
        p.color = Accent.amber.nsColor
        p.setTarget(self); p.setAction(#selector(changed(_:)))
        settings.reset()
    }

    private func closed() {
        let p = NSColorPanel.shared
        p.setTarget(nil); p.setAction(nil)
        p.accessoryView = nil
        if let o = closeObserver { NotificationCenter.default.removeObserver(o); closeObserver = nil }
        settings.panelOpen = false
        AppLog.log("accent: colour panel closed, \(settings.picked.described)"
                   + (settings.clamped ? " (shown as \(settings.effective.described))" : ""))
    }

    private func resetView() -> NSView {
        let b = NSButton(title: "Reset to Amber", target: self, action: #selector(resetPressed(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.sizeToFit()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: b.frame.width + 16, height: b.frame.height + 12))
        b.setFrameOrigin(NSPoint(x: 8, y: 6))
        v.addSubview(b)
        return v
    }
}

/// COLOR in the window's footer, between SETTINGS and HELP: the HELP chip's look, a swatch of the
/// colour in use, lit while the colour wheel is open.
struct ColorChip: View {
    @ObservedObject var accent = AccentSettings.shared
    var action: () -> Void = { AccentPanel.shared.toggle() }

    var body: some View {
        let on = accent.panelOpen
        // the footer's one chip (FooterChip) with the swatch, lit while the wheel is open
        FooterChip(title: "COLOR", label: "Display colour", on: on, swatch: true, action: action)
            .nativeHelp("Pick the display colour")
            .helpTip(HelpText.color)
            .accessibility(hint: Text(on ? "Closes the colour wheel" : "Opens a colour wheel to change the display colour"))
    }
}
