import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    var tiledWindowCount: Int { lastFrames.count }

    /// The layout of the desktop being shown, for the settings window's miniature.
    func desktopPreview() -> (layout: NodeSnapshot, visible: Set<CGWindowID>, owners: [CGWindowID: pid_t], focused: CGWindowID?, screen: CGSize, usable: CGRect, display: DisplayInfo)? {
        guard let display = activeDisplay ?? displays.first, display.isDesktop, let tree = trees[display.treeKey] else { return nil }
        let visible = lastVisible.intersection(tree.windows)
        guard visible.count >= 2 else { return nil }
        var owners: [CGWindowID: pid_t] = [:]
        for id in visible { if let w = windows[id] { owners[id] = w.pid } }
        let usable = display.visibleFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        return (tree.snapshot, visible, owners, focusedWindow.flatMap { visible.contains($0) ? $0 : nil } ?? tree.focused, display.frame.size, usable, display)
    }

    /// One desktop as the menu bar shows it: its number, its layout and the windows in it.
    struct Desk {
        let number: Int
        /// The desktop the user is on.
        let isActive: Bool
        let layout: NodeSnapshot
        /// The windows to draw: those on screen for a desktop being shown, every living window otherwise.
        let windows: Set<CGWindowID>
        let focused: CGWindowID?
        let screen: CGSize
        let usable: CGRect
        let display: DisplayInfo
    }

    /// Every desktop in Mission Control order, and which app each of their windows belongs to.
    func desks() -> (desks: [Desk], owners: [CGWindowID: pid_t]) {
        guard !displays.isEmpty else { return ([], [:]) }
        // Windows on other desktops are not on screen, but the system still lists them.
        let owners = system.windowOwners()
        let active = activeDisplay ?? displays[0]
        let list = system.desktops().map { desktop -> Desk in
            let display = displays.first { $0.uuid == desktop.displayID || $0.managedID == desktop.displayID } ?? displays[0]
            let tree = trees["\(desktop.key)|\(display.uuid)"]
            let showing = display.spaceKey == desktop.key
            let living = Set(tree?.windows ?? []).filter { owners[$0] != nil }
            let drawn = showing ? living.intersection(lastVisible) : living
            let isActive = showing && display.uuid == active.uuid
            let focused = isActive ? (focusedWindow.flatMap { drawn.contains($0) ? $0 : nil } ?? tree?.focused) : tree?.focused
            return Desk(number: desktop.number, isActive: isActive, layout: tree?.snapshot ?? Tree().snapshot, windows: drawn,
                        focused: focused, screen: display.frame.size,
                        usable: display.visibleFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY), display: display)
        }
        return (list, owners.filter { id, _ in list.contains { $0.windows.contains(id) } })
    }

    /// Short text for the menu bar.
    var menuBarTitle: String {
        guard let d = activeDisplay ?? displays.first, let i = d.spaceIndex else { return "" }
        return "\(d.desktopOffset + i)"
    }

    // MARK: Facts for the JSON reports and the hooks

    /// What Reports.swift and Hooks.swift read. They only look: nothing outside this file
    /// changes a window or a layout.
    struct Facts {
        let windows: [CGWindowID: WindowState]
        let apps: [pid_t: AppState]
        let trees: [String: Tree]
        /// The windows that have a tile on screen right now.
        let tiled: Set<CGWindowID>
        let visible: Set<CGWindowID>
        let activeDisplay: DisplayInfo?
        /// Every window the system has, on any Space: on screen, minimised or hidden.
        let existing: Set<CGWindowID>
        /// The window that fills its desktop, by tree.
        let zoomed: [String: CGWindowID]
    }

    /// `fresh` looks at the displays and the focus again first, as running a command does.
    func facts(fresh: Bool = false) -> Facts {
        if fresh {
            lookAtDisplays()
            if started, system.isTrusted { updateFocus(system.snapshot()) }
        }
        return Facts(windows: windows, apps: apps, trees: trees, tiled: Set(lastFrames.keys), visible: lastVisible,
                     activeDisplay: activeDisplay, existing: lastExisting, zoomed: zoomed)
    }

    /// Where Iguana is sending a window right now, and whether it glides there or is placed
    /// at once. Nil for a window Iguana is not moving. The focus ring reads this.
    func motion(of id: CGWindowID) -> (to: CGRect, gliding: Bool)? {
        mover.destination(of: id).map { ($0, mover.isGliding(id)) }
    }
}
