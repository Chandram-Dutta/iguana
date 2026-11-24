import AppKit
import IguanaCore

/// A rule can name a desktop for the windows it matches. This keeps the books for it: which
/// windows are new, so that each one is sent once, when it first appears, and a window that
/// was already there is never moved.
final class DesktopRules {
    /// Windows the system already had when Iguana first looked, or when the config was last
    /// read. They stay where they are, also the ones on other desktops that Iguana only gets
    /// to see when their desktop is shown.
    private var old = Set<CGWindowID>()
    /// New windows whose rule names a desktop, until they are sent there or given up on.
    private var waiting: [CGWindowID: (desktop: Int, app: String, since: Date)] = [:]
    /// False until the windows that were open before Iguana have been counted as old.
    private var ready = false
    private var saidCannotStay = false

    /// A window can be reported a moment before it settles into its final role. One that is
    /// not a standard window yet gets this long to become one; later than that the user may
    /// be working in it, and it stays.
    private static let patience: TimeInterval = 2

    /// Everything that exists now was here first. Called when the config is read, so that a
    /// new rule only acts on windows that open after it was written.
    func markExisting() {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        old = Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        waiting.removeAll()
    }

    /// A window Iguana sees for the first time, matched by a rule that names a desktop.
    func note(_ id: CGWindowID, desktop: Int, app: String?) {
        guard ready, !old.contains(id) else { return }
        waiting[id] = (desktop, app ?? "an app", Date())
    }

    /// Deal with the windows that are waiting. `standard` says whether a window is a standard
    /// one, and nil when it is gone or is not one to send at all; `send` moves it and answers
    /// as the `move-to-space` command does.
    func settle(paused: Bool, standard: (CGWindowID) -> Bool?, send: (CGWindowID, Int) -> String) {
        guard ready else {
            // The first look at the windows finds the ones that were open before Iguana.
            markExisting()
            ready = true
            return
        }
        guard !waiting.isEmpty else { return }
        // While tiling is paused every window is left where it is, and stays there afterwards.
        guard !paused else { return waiting.removeAll() }

        let desktops = Desktop.all()
        for (id, entry) in waiting {
            guard let isStandard = standard(id), Date().timeIntervalSince(entry.since) <= Self.patience else {
                waiting[id] = nil
                continue
            }
            // Dialogs and sheets are not sent anywhere. Ask again while this one may still settle.
            guard isStandard else { continue }
            waiting[id] = nil

            let on = Private.spaces(of: id)
            let action = DesktopRuleAction.decide(wanted: entry.desktop, standardWindow: true,
                                                  windowDesktops: desktops.filter { on.contains($0.id) }.map(\.number),
                                                  desktopCount: desktops.count, canStay: Private.hasMoveBridge)
            let window = "window \(id) of \(entry.app)"
            switch action {
            case .leave:
                break
            case .send(let n):
                let reply = send(id, n)
                if reply == "ok" {
                    Log.write("rule: sent \(window) to desktop \(n)")
                } else if reply.hasPrefix("error: ") {
                    Log.write("rule: \(window) was not sent to desktop \(n): \(reply.dropFirst(7))")
                }
            case .missing:
                Log.write("rule: \(window) was not sent to desktop \(entry.desktop): there are only \(desktops.count) desktops")
            case .cannotStay:
                // This is the same for every window, so it is said once.
                guard !saidCannotStay else { break }
                saidCannotStay = true
                Log.write("rule: this macOS can only take a window to another desktop by going there with it, so rules with a desktop are not applied")
            }
        }
    }
}
