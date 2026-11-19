import AppKit
import Foundation

// The MANUAL menu's reading lookup and pick. A pick pins the key like every other path
// (SpellingSettings.setManualKey) and teaches nothing: it never makes Beat Key think a key is
// more likely (J, 2026-11-18). There is no teach record any more.
enum ManualMenu {
    /// The reading as the analyzer gave it (no choice, no respelling).
    static func raw(_ state: ViewState, live: LiveState, page: Pager) -> Result? {
        if live.isActive { return live.result }
        switch state {
        case .done(let r): return r
        case .analyzed(let rs) where !rs.isEmpty: return rs[min(max(page.index, 0), rs.count - 1)]
        default: return nil
        }
    }

    /// The MANUAL menu's pick: pins the key (setManualKey logs the set / clear).
    static func pin(_ key: String, engine: Engine, live: LiveController, model: FaceplateModel) {
        guard let r = raw(engine.state, live: live.state, page: model.pager) else {
            AppLog.log("manual menu: no reading on show"); NSSound.beep(); return
        }
        SpellingSettings.shared.setManualKey(key, of: r, from: .dropdown)
    }
}
