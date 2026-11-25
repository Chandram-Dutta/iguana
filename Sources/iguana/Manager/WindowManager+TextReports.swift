import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    // MARK: Reports

    func label(_ id: CGWindowID) -> String {
        guard let w = windows[id] else { return "window \(id) (not seen yet)" }
        let app = apps[w.pid]?.app.localizedName ?? "pid \(w.pid)"
        let title = w.element.string(kAXTitleAttribute) ?? ""
        let shown = lastVisible.contains(id) ? "" : "  (not on screen)"
        return "\(app): \(title.prefix(50)) #\(id)\(shown)"
    }

    func describeTrees() -> String {
        var out: [String] = []
        for d in displays {
            let where_ = d.spaceIndex.map { "desktop \(d.desktopOffset + $0)" } ?? "fullscreen Space (not managed)"
            out.append("\(d.name), \(where_)")
            if let tree = trees[d.treeKey], !tree.isEmpty {
                out.append(tree.describe(label: label).split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
            } else if d.isDesktop {
                out.append("  (no tiled windows)")
            }
        }
        let others = trees.filter { key, tree in !tree.isEmpty && !displays.contains { $0.treeKey == key } }
        if !others.isEmpty { out.append("\(others.count) other Space(s) have a remembered layout") }
        return out.joined(separator: "\n")
    }

    func listWindows() -> String {
        let onScreen = Set(system.snapshot().onScreen.keys)
        let rows = windows.values.sorted { $0.id < $1.id }.map { w -> String in
            let state: String
            if lastFrames[w.id] != nil {
                state = "tiled"
            } else if !onScreen.contains(w.id) {
                state = "not on screen"
            } else if w.floating {
                state = "floating"
            } else {
                state = w.tileable ? "tiled" : "unmanaged"
            }
            let app = apps[w.pid]?.app.localizedName ?? "pid \(w.pid)"
            let mark = w.id == focusedWindow ? "*" : " "
            return "\(mark) \(w.id)\t\(state)\t\(app)\t\(w.element.string(kAXTitleAttribute) ?? "")"
        }
        return rows.isEmpty ? "no windows on this Space" : rows.joined(separator: "\n")
    }

    func listSpaces() -> String {
        lookAtDisplays()
        return displays.sorted { $0.number < $1.number }.map { d in
            let now = d.spaceIndex.map { "desktop \(d.desktopOffset + $0) of \(d.totalDesktops)" } ?? "a fullscreen Space"
            return "Display \(d.number), \(d.name): showing \(now); this display has \(d.spaceCount) desktop(s)"
        }.joined(separator: "\n")
    }

    func status() -> String {
        guard system.isTrusted else {
            return "Iguana \(Iguana.version): waiting for Accessibility permission\n(System Settings > Privacy & Security > Accessibility, switch on Iguana)"
        }
        var lines = ["Iguana \(Iguana.version): \(paused ? "paused" : "tiling")"]
        lines.append("config: \(FileManager.default.fileExists(atPath: configURL().path) ? configURL().path : "built-in defaults")")
        lines.append(contentsOf: configWarnings.map { "  warning: \($0)" })
        lines.append("windows: \(lastFrames.count) tiled on screen, \(windows.count) known, \(apps.count) apps watched")
        let strip = system.stageManager.reservedWidth(config)
        lines.append("stage manager: \(system.stageManager.isOn ? "on" : "off")\(strip > 0 ? ", leaving \(Int(strip)) pt for the strip" : "")")
        lines.append(listSpaces())
        if mode != Config.defaultMode { lines.append("mode: \(mode)") }
        lines.append(contentsOf: statusExtras?() ?? [])
        return lines.joined(separator: "\n")
    }
}
