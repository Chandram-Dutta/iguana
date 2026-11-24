import AppKit
import ApplicationServices
import IguanaCore

extension DisplayInfo {
    /// The desktop this display is showing, numbered across all displays as Mission Control
    /// numbers them. Nil on a fullscreen Space.
    var desktopNumber: Int? { spaceIndex.map { desktopOffset + $0 } }

    var report: Report.Display {
        Report.Display(name: name, desktop: desktopNumber, desktopCount: spaceCount, main: isMain)
    }
}

/// The four reports as JSON documents (`--json`). The shape of each document is in IguanaCore
/// (`Report`); this file fills them in from what the window manager knows. It only reads.
///
/// A window title goes to whoever ran the command on this Mac, over the socket only their own
/// account can open. Nothing here sends anything anywhere else.
extension WindowManager {
    /// - Parameters: what the app shell knows and the window manager does not, for `status`.
    func jsonReport(_ command: Command, shortcuts: Report.Shortcuts, tourShowing: Bool, lastShortcut: Report.LastShortcut?) -> String {
        let facts = facts(fresh: true)
        // Like its text, `status` answers before the permission is granted, so that the app can
        // always be inspected.
        if command == .status {
            let strip = StageManager.reservedWidth(config)
            return Report.encode(Report.Status(
                version: Self.version, permission: AXIsProcessTrusted(), paused: paused,
                configPath: Self.configURL.path, configExists: FileManager.default.fileExists(atPath: Self.configURL.path),
                configWarnings: configWarnings,
                windows: Report.WindowCounts(tiled: facts.tiled.count, known: facts.windows.count, apps: facts.apps.count),
                stageManager: Report.StageManager(on: StageManager.isOn, reserved: Double(strip)),
                displays: displays.map(\.report), shortcuts: shortcuts, tourShowing: tourShowing, lastShortcut: lastShortcut))
        }
        guard AXIsProcessTrusted() else {
            return "error: Iguana needs Accessibility permission (System Settings > Privacy & Security > Accessibility)"
        }
        switch command {
        case .listWindows: return Report.encode(windowsReport(facts))
        case .listSpaces: return Report.encode(spacesReport(facts))
        case .tree: return Report.encode(treesReport(facts))
        default: return "error: this command has no --json form"
        }
    }

    private func windowsReport(_ facts: Facts) -> Report.Windows {
        let onScreen = ScreenSnapshot.take().onScreen
        let desktops = Desktop.all()
        return Report.Windows(windows: facts.windows.values.sorted { $0.id < $1.id }.map { w in
            let app = facts.apps[w.pid]?.app
            let frame = onScreen[w.id]
            let place = place(of: w.id, frame: frame, desktops: desktops)
            return Report.Window(
                id: w.id, app: app?.localizedName ?? "pid \(w.pid)", bundleId: app?.bundleIdentifier,
                title: w.element.string(kAXTitleAttribute) ?? "",
                state: .of(inLayout: facts.tiled.contains(w.id), onScreen: frame != nil, floating: w.floating, tileable: w.tileable),
                focused: w.id == focusedWindow, desktop: place.desktop, display: place.display, frame: frame.map(Report.Frame.init))
        })
    }

    private func spacesReport(_ facts: Facts) -> Report.Spaces {
        var windowsOn: [UInt64: [CGWindowID]] = [:]
        for id in facts.windows.keys.sorted() {
            for space in Private.spaces(of: id) { windowsOn[space, default: []].append(id) }
        }
        let desktops = Desktop.all().map { desktop -> Report.Desktop in
            let showing = displays.contains { $0.spaceID == desktop.id }
            return Report.Desktop(number: desktop.number, display: owner(of: desktop)?.name, showing: showing,
                                  active: showing && facts.activeDisplay?.spaceID == desktop.id, windows: windowsOn[desktop.id] ?? [])
        }
        return Report.Spaces(desktops: desktops, displays: displays.map(\.report))
    }

    private func treesReport(_ facts: Facts) -> Report.Trees {
        let layouts = displays.map { d -> Report.Layout in
            let tree = facts.trees[d.treeKey].flatMap { $0.isEmpty ? nil : $0 }
            return Report.Layout(display: d.name, desktop: d.desktopNumber, layout: tree.map { tree in
                Report.Node(tree.snapshot) { id in
                    guard let w = facts.windows[id] else { return nil }
                    return (facts.apps[w.pid]?.app.localizedName ?? "pid \(w.pid)", w.element.string(kAXTitleAttribute) ?? "",
                            facts.visible.contains(id))
                }
            })
        }
        let others = facts.trees.filter { key, tree in !tree.isEmpty && !displays.contains { $0.treeKey == key } }
        return Report.Trees(displays: layouts, otherLayouts: others.count)
    }

    // MARK: Where a window is

    /// The display a desktop belongs to. With "Displays have separate Spaces" switched off every
    /// display shares one list of desktops, and then a desktop has no display of its own.
    private func owner(of desktop: Desktop) -> DisplayInfo? {
        let owners = displays.filter { $0.uuid == desktop.displayID || $0.managedID == desktop.displayID }
        return owners.count == 1 ? owners[0] : nil
    }

    /// The desktop number and the display name of a window, as far as they can be told.
    /// `frame` is where the window is on screen, when it is.
    func place(of id: CGWindowID, frame: CGRect?, desktops: [Desktop] = Desktop.all()) -> (desktop: Int?, display: String?) {
        let spaces = Private.spaces(of: id)
        // A window assigned to all desktops is on the one being shown.
        let desktop = desktops.first { d in spaces.contains(d.id) && displays.contains { $0.spaceID == d.id } }
            ?? desktops.first { spaces.contains($0.id) }
        let display = frame.flatMap { f in displays.first { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) } }
            ?? desktop.flatMap(owner(of:))
            // A window in native fullscreen is on a Space that is not a desktop.
            ?? displays.first { spaces.contains($0.spaceID) }
        return (desktop?.number, display?.name)
    }
}
