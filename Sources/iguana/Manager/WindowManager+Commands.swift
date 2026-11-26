import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    // MARK: Commands

    /// `window` is the one a request named with `--window`. The command acts on it as it would
    /// on the focused window, and the focus stays where it is. Nil means the focused window.
    func run(_ command: Command, window: CGWindowID? = nil) -> String {
        // A stack that will not come into order is left alone until the user does something
        // (`orderStack`). A command is the user doing something, unless it only asks how things
        // are: a status bar asks every second, and would have the stack raised for ever.
        switch command {
        case .status, .listWindows, .listSpaces, .tree, .subscribe: break
        default: stackOrderTries = 0
        }
        if started, system.isTrusted {
            lookAtDisplays()
            updateFocus(system.snapshot())
        }
        // These work before the permission is granted, so the app can always be inspected and stopped.
        switch command {
        case .status: return status()
        case .reload: return reloadConfig()
        case .settings:
            onOpenSettings?()
            return "ok"
        case .tour:
            onOpenTour?()
            return "ok"
        case .update:
            // From the command line the app shell answers this one itself, once GitHub has
            // answered. A shortcut has nowhere to print an answer: it starts the check, and
            // what is found appears in the menu.
            onCheckForUpdate?()
            return "ok: checking"
        case .quit:
            scheduler.after(0.1) { [system] in system.terminate() }
            return "ok"
        // Without the permission there must still be a way out of a mode.
        case .mode(let name): return switchMode(name)
        // Each command of a chain asks for the permission itself.
        case .sequence(let commands): return Command.runChain(commands) { self.run($0) }
        default: break
        }
        guard system.isTrusted else {
            return "error: Iguana needs Accessibility permission (System Settings > Privacy & Security > Accessibility)"
        }
        if let window, windows[window] == nil { return "error: no window \(window)" }
        switch command {
        case .focus(let dir): return focus(dir)
        case .focusWindow:
            guard let window else { return "error: 'focus' needs one of: left, right, up, down" }
            focusWindow(window)
            return "ok"
        case .focusRecent: return focusRecent()
        case .move(let dir): return recording { move(dir, window) }
        case .join(let dir):
            return recording { withTile(window) { id, tree, _ in
                tree.join(id, with: dir, visible: lastVisible) ? "ok" : "ok: no neighbour in that direction"
            } }
        case .resize(let axis, let grow):
            return recording { withTile(window) { id, tree, key in
                // Start from the sizes on screen, which differ from the weights where a window is
                // held at its minimum size.
                let before = tree.snapshot
                tree.matchWeights(to: slots, visible: lastVisible)
                guard tree.changeShare(of: id, along: axis, .delta(Double(grow) * config.resizeStep), visible: lastVisible) else {
                    // Nothing was resized, so the weights go back as they were. Left matched to
                    // the screen they would be a step for `undo` that takes nothing back.
                    tree.restore(before)
                    return "ok: nothing to resize against"
                }
                recheckMinimums(in: tree, key: key)
                return "ok"
            } }
        case .flip:
            return recording { withTile(window) { id, tree, _ in tree.flip(id) ? "ok" : "error: cannot flip" } }
        case .stack:
            return recording { withTile(window) { id, tree, _ in
                guard let stacked = tree.toggleStack(id) else { return "ok: no other window to stack with" }
                return stacked ? "ok: stacked" : "ok: unstacked"
            } }
        case .balance:
            return recording { withTile(window) { _, tree, key in
                tree.balance()
                recheckMinimums(in: tree, key: key)
                return "ok"
            } }
        case .split(let hint):
            return withTile(window) { id, tree, _ in
                if hint != nil, tree.newWindowJoinsStack(beside: id) {
                    splitHints[id] = nil
                    return "ok: new windows join the stack this window is in"
                }
                splitHints[id] = hint
                switch hint {
                case .horizontal: return "ok: the next window opens beside it"
                case .vertical: return "ok: the next window opens below it"
                case nil: return "ok: automatic"
                }
            }
        case .arrange(let arrangement):
            return recording { withTile(window) { id, tree, key in
                let shown = tree.windows.filter { lastVisible.contains($0) }
                guard shown.count > 1 || arrangement == .main else { return "ok: nothing to arrange" }
                tree.arrange(arrangement, order: readingOrder(slots.filter { shown.contains($0.key) }), main: id,
                             hidden: tree.windows.filter { !lastVisible.contains($0) })
                zoomed[key] = nil
                recheckMinimums(in: tree, key: key)
                return "ok"
            } }
        case .zoom:
            return withTile(window) { id, _, key in
                zoomed[key] = zoomed[key] == id ? nil : id
                if let w = windows[id] { w.element.perform(kAXRaiseAction) }
                return "ok"
            }
        case .float:
            guard let w = targetWindow(window) else { return "error: no focused window" }
            guard w.tileable else { return "error: this window cannot be tiled" }
            if let key = treeEntry(containing: w.id)?.0 ?? display(holding: w)?.treeKey { restore.stop(key) }
            w.userFloat = !w.floating
            if w.floating { for tree in trees.values { tree.remove(w.id) } }
            refresh()
            return w.floating ? "ok: floating" : "ok: tiled"
        case .place(let placement): return place(placement, window)
        case .switcher: return onOpenSwitcher?() ?? "ok"
        case .close:
            guard let w = targetWindow(window) else { return "error: no focused window" }
            guard let button = w.element.element(kAXCloseButtonAttribute) else { return "error: this window has no close button" }
            button.perform(kAXPressAction)
            return "ok"
        case .undo: return undo(redoing: false)
        case .redo: return undo(redoing: true)
        case .focusApp(let text): return focusApp(text)
        case .space(let target): return switchSpace(target)
        case .moveToSpace(let target, let follow): return moveToSpace(target, follow: follow, window: window)
        case .focusDisplay(let target): return focusDisplay(target)
        case .moveToDisplay(let target): return recording { moveToDisplay(target, window) }
        case .pause:
            setPaused(!paused)
            return paused ? "ok: paused" : "ok: tiling"
        case .reload: return reloadConfig()
        case .applyRules: return applyRules()
        case .settings, .tour, .update: return "ok"
        case .subscribe: return "error: subscribe only works from the command line"
        case .listWindows: return listWindows()
        case .listSpaces: return listSpaces()
        case .tree: return describeTrees()
        case .status: return status()
        case .quit:
            scheduler.after(0.1) { [system] in system.terminate() }
            return "ok"
        case .mode(let name): return switchMode(name)
        case .sequence(let commands): return Command.runChain(commands) { self.run($0) }
        }
    }

    /// The window a command acts on: the one a request named with `--window`, or else the
    /// focused window. Every command that acts on a window finds it here.
    func targetWindow(_ named: CGWindowID?) -> WindowState? {
        (named ?? focusedWindow).flatMap { windows[$0] }
    }

    /// What a command that needs a tile answers when the window it acts on has none on screen.
    func notTiled(_ named: CGWindowID?) -> String {
        named.map { "error: window \($0) is not tiled on a desktop being shown" } ?? "error: the focused window is not tiled"
    }

    /// Runs a command on the tile of the window it acts on (`targetWindow`), then lays out again.
    func withTile(_ named: CGWindowID?, _ body: (CGWindowID, Tree, String) -> String) -> String {
        guard let id = targetWindow(named)?.id, lastFrames[id] != nil, let (key, tree) = treeEntry(containing: id) else {
            return notTiled(named)
        }
        let result = body(id, tree, key)
        restore.stop(key)
        refresh()
        return result
    }

    /// Run a change of layout the user asked for, and remember it as one step on every desktop
    /// it changed, for `undo`. Wrapping a change that is already being recorded adds nothing.
    @discardableResult
    func recording<T>(_ body: () -> T) -> T {
        guard !isRecording else { return body() }
        let before = trees.mapValues(\.snapshot)
        isRecording = true
        let result = body()
        isRecording = false
        for (key, tree) in trees { if let b = before[key] { history.record(key: key, before: b, after: tree.snapshot) } }
        return result
    }

    /// The layout of the active desktop: the one the focused window is tiled in, or else the
    /// one the active display is showing.
    var activeTreeKey: String? {
        if let id = focusedWindow, lastFrames[id] != nil, let (key, _) = treeEntry(containing: id) { return key }
        return activeDisplay.flatMap { $0.isDesktop ? $0.treeKey : nil }
    }

    func undo(redoing: Bool) -> String {
        let nothing = redoing ? "ok: nothing to redo" : "ok: nothing to undo"
        guard let key = activeTreeKey, let tree = trees[key] else { return nothing }
        let current = tree.snapshot
        guard let snapshot = redoing ? history.redo(key: key, current: current) : history.undo(key: key, current: current) else { return nothing }
        let here = Set(tree.windows)
        tree.restore(snapshot)
        restore.stop(key)
        // A window that has closed, floated or gone to another desktop since stays gone. One that
        // has arrived since is not in the snapshot, and the refresh places it as a new window.
        tree.prune { here.contains($0) }
        recheckMinimums(in: tree, key: key)
        refresh()
        return redoing ? "ok: redone" : "ok: undone"
    }
}
