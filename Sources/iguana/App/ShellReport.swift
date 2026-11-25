import Foundation
import IguanaCore

/// What the app shell knows and the window manager does not, for `status`: the shortcuts, the
/// welcome tour and a newer release. The text and the JSON document say the same facts.
struct ShellReport {
    let wm: WindowManager
    let shortcuts: HotkeyRegistrar
    let tourShowing: () -> Bool
    /// Tiling has not started yet because the tour is still on screen.
    let tilingHeld: () -> Bool
    /// The newer release to tell the user about, if there is one and it may be told.
    let knownUpdate: () -> UpdateCheck.Update?
    var now: () -> Date = Date.init

    /// The extra lines of `iguana status`.
    func statusLines() -> [String] {
        var lines = ["shortcuts: \(shortcuts.registered) active"] + shortcuts.problems.map { "  warning: \($0)" }
        if tourShowing() {
            lines.append(tilingHeld() ? "welcome tour: on screen; tiling starts when it ends" : "welcome tour: on screen; shortcuts act on its practice desktop")
        }
        if let last = shortcuts.last {
            lines.append("last shortcut: \(last.keys), \(Int(now().timeIntervalSince(last.at))) s ago, answered \"\(last.reply)\"")
        } else {
            lines.append("last shortcut: none received since Iguana started")
        }
        if let update = knownUpdate() { lines.append(UpdateCheck.statusLine(update)) }
        return lines
    }

    /// A report as a JSON document (`--json`). The window manager fills in what it knows and
    /// the app shell hands over its part, the same facts `statusLines` gives the text.
    func json(_ command: Command) -> String {
        let last = shortcuts.last.map {
            Report.LastShortcut(keys: $0.keys, secondsAgo: Int(now().timeIntervalSince($0.at)), reply: $0.reply)
        }
        return wm.jsonReport(command, shortcuts: Report.Shortcuts(active: shortcuts.registered, warnings: shortcuts.problems),
                             tourShowing: tourShowing(), lastShortcut: last,
                             update: knownUpdate().map { Report.Update(version: $0.version, url: $0.page.absoluteString) })
    }
}
