import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    func enumerate(_ state: AppState) {
        guard let list = state.element.elements(kAXWindowsAttribute) else { return }
        let pid = state.app.processIdentifier
        var fresh: [WindowState] = []
        for el in list {
            guard let id = el.windowID else { continue }
            if let known = windows[id] {
                // A window can be reported before it has settled into its final role.
                if !known.tileable { known.tileable = isTileable(el) }
                continue
            }
            // A window in native fullscreen cannot be resized. Pick it up when it comes back.
            if el.bool("AXFullScreen") == true { continue }
            let w = WindowState(id: id, pid: pid, element: el, tileable: isTileable(el))
            let decides = rule(for: w, app: state.app)
            w.ruleFloat = decides?.floats ?? false
            if let n = decides?.desktop { desktopRules.note(id, desktop: n, app: state.app.localizedName) }
            if let decides {
                placementRules.note(id, rule: decides, app: state.app.localizedName ?? "an app", at: scheduler.now)
                if let d = decides.display {
                    displayRules.note(id, display: d, rule: (config.rules.firstIndex(of: decides) ?? 0) + 1, app: state.app.localizedName)
                }
            }
            if restoredFloating.remove(id) != nil { w.userFloat = true }
            if restoredTiled.remove(id) != nil { w.userFloat = false }
            if let size = restoredMinSizes.removeValue(forKey: id) {
                w.minSize = size
                unverifiedMinimums.insert(id)
            }
            windows[id] = w
            fresh.append(w)
            state.observer?.watch(kAXUIElementDestroyedNotification, on: el)
        }
        refloat(fresh, app: state.app)
    }

    func isTileable(_ el: UIElement) -> Bool {
        el.string(kAXRoleAttribute) == kAXWindowRole
            && el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
            && el.isSettable(kAXSizeAttribute) && el.isSettable(kAXPositionAttribute)
    }

    /// A new native tab is a window of its own, with the frame of the window it is a tab of and
    /// on the same desktop. It stays with that window, wherever the user has it.
    func isTab(_ w: WindowState, _ frame: CGRect) -> Bool {
        let spaces = system.spaces(of: w.id)
        return windows.values.contains { other in
            other.pid == w.pid && other.id != w.id
                && (spaces.isEmpty || system.spaces(of: other.id).contains(where: spaces.contains))
                && other.element.frame.map { nearlyEqual($0, frame) } == true
        }
    }

    func display(holding w: WindowState) -> DisplayInfo? {
        w.element.frame.flatMap { displayIndex(for: $0) }.map { displays[$0] }
    }

    func isShowing(_ id: CGWindowID, _ snap: ScreenSnapshot) -> Bool {
        guard snap.onScreen[id] != nil else { return false }
        let spaces = system.spaces(of: id)
        return spaces.isEmpty || spaces.contains { s in displays.contains { $0.spaceID == s } }
    }
}
