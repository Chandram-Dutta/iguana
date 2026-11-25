import IguanaCore
import SwiftUI

extension TourModel {
    // MARK: Commands

    /// A command from a shortcut or the command line. Returns nil for the commands the tour
    /// leaves to the window manager.
    func handle(_ command: Command, binding: KeyBinding? = nil) -> String? {
        switch command {
        // `mode default` is the way out of a mode, and must work here too. Other modes and
        // chains are refused below: the tour teaches the keys of [bindings], one at a time.
        case .status, .reload, .quit, .listWindows, .listSpaces, .tree, .update, .mode(Config.defaultMode): return nil
        default: break
        }
        guard !closing else { return "ok: the tour is closing" }
        flash(command, binding: binding)

        switch command {
        case .focus(let dir) where step >= .focus && step.isLesson:
            focus(dir)
        case .move(let dir) where step >= .move && step.isLesson:
            move(dir)
        case .resize(let axis, let grow) where step >= .resize && step.isLesson:
            resize(axis, grow)
        case .stack where step >= .stack && step.isLesson:
            stack()
        case .space(let target) where step == .desktops:
            if let index = desktopIndex(target) { jump(to: index) }
        case .moveToSpace(let target, let follow) where step == .desktops:
            if let index = desktopIndex(target) { carry(to: index, follow: follow) }
        default:
            refuse()
        }
        return "ok: in the welcome tour"
    }

    private func focus(_ dir: Direction) {
        let tree = desktops[current]
        let placed = frames(current)
        guard let from = tree.focused, let target = neighbour(dir) else {
            refuse()
            return
        }
        // Two windows that overlap are two windows of one stack: this is a step through it.
        let throughStack = overlap(placed[from], placed[target])
        changed {
            tree.focused = target
            raise(target)
        }
        touch(target)
        let centre = (placed[target]?.midX ?? 0) - panel(current).minX
        play(.focus(Int(centre / panel(current).width * 6)))

        if step == .focus, target == beacon {
            reached += 1
            if reached >= Self.focusTargets {
                succeed()
            } else {
                play(.reached)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { pickBeacon() }
            }
        }
        if step == .stack, throughStack { succeed() }
        refreshGoals()
    }

    /// Point at the window that has gone longest without the focus.
    func pickBeacon() {
        let tree = desktops[current]
        beacon = tree.windows.filter { $0 != tree.focused }.min { (visits[$0] ?? 0) < (visits[$1] ?? 0) }
    }

    private func move(_ dir: Direction) {
        let tree = desktops[current]
        guard let id = tree.focused else {
            refuse()
            return
        }
        var moved = false
        changed { moved = tree.move(id, dir) }
        guard moved else {
            refuse()
            return
        }
        play(.move)
        if step == .move, id == goalWindow {
            movesMade += 1
            if !canMove(goalDirection) || movesMade >= 5 { succeed() }
        }
        refreshGoals()
    }

    func canMove(_ dir: Direction) -> Bool {
        guard let id = goalWindow ?? focusedWindow else { return false }
        return copy(desktops[current]).move(id, dir)
    }

    private func resize(_ axis: Orientation?, _ grow: Int) {
        let tree = desktops[current]
        guard let id = tree.focused else {
            refuse()
            return
        }
        var resized = false
        changed { resized = tree.changeShare(of: id, along: axis, .delta(Double(grow) * resizeStep)) }
        guard resized else {
            refuse()
            return
        }
        play(.resize(grow: grow > 0))
        if step == .resize, id == goalWindow {
            growsNeeded -= grow
            if growsNeeded <= 0 { succeed() }
        }
        refreshGoals()
    }

    /// Turn the row or column around the focused window into a stack, or back into tiles.
    private func stack() {
        let tree = desktops[current]
        guard let id = tree.focused else {
            refuse()
            return
        }
        var stacked: Bool?
        changed { stacked = tree.toggleStack(id) }
        guard let stacked else {
            refuse()
            return
        }
        play(.move)
        // Without focus keys there is no second half to the lesson.
        if step == .stack, stacked, keys(for: .focus) == nil { succeed() }
        refreshGoals()
    }

    private func desktopIndex(_ target: SpaceTarget) -> Int? {
        switch target {
        case .index(let n): return (1...Self.desktopCount).contains(n) ? n - 1 : nil
        case .next: return current + 1 < Self.desktopCount ? current + 1 : nil
        case .prev: return current > 0 ? current - 1 : nil
        // The tour does not teach it, and its practice desktops keep no history.
        case .recent: return nil
        }
    }

    private func jump(to index: Int) {
        guard index != current else {
            refuse()
            return
        }
        changed { current = index }
        play(.desktop(index))
        // The next thing to learn needs a window to carry, so an empty desktop does not count yet.
        if desktopGoal == .jump, !desktops[index].isEmpty {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { desktopGoal = .carry }
        }
        refreshGoals()
    }

    private func carry(to index: Int, follow: Bool) {
        let tree = desktops[current]
        guard index != current, let id = tree.focused else {
            refuse()
            return
        }
        changed {
            tree.remove(id)
            tree.focused = tree.windows.last
            adopt(id, into: index)
            if follow { current = index }
        }
        touch(id)
        play(.carry)
        succeed()
    }

    /// The second desktop starts with a window of its own, so that there is something to see
    /// there and something to carry away.
    func prepareDesktops() {
        guard desktops[1].isEmpty, desktops[2].isEmpty else { return }
        let id = nextID
        nextID += 1
        colors[id] = Self.desktopColor
        order.insert(id, at: 0)
        adopt(id, into: 1)
    }

    /// Work out what to point at, from where things are now. Goals are never stored as places:
    /// whatever the windows have been through, the outline shows the way from here.
    func refreshGoals() {
        guard !advancing else { return }
        switch step {
        case .move:
            guard let id = goalWindow else { return }
            let twin = copy(desktops[current])
            var steps = 0
            while steps < 6, twin.move(id, goalDirection) { steps += 1 }
            ghost = steps > 0 ? frames(current, tree: twin)[id].map { TourGhost(desktop: current, rect: $0, window: id) } : nil
        case .resize:
            guard let id = goalWindow else { return }
            let twin = copy(desktops[current])
            for _ in 0..<max(growsNeeded, 0) { twin.changeShare(of: id, .delta(resizeStep)) }
            ghost = frames(current, tree: twin)[id].map { TourGhost(desktop: current, rect: $0, window: id) }
        case .stack:
            let placed = frames(current)
            let stacked = desktops[current].windows.filter { id in placed.contains { $0.key != id && overlap($0.value, placed[id]) } }
            let goal: StackGoal = stacked.isEmpty || keys(for: .focus) == nil ? .press : .step
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                stackGoal = goal
                switch goal {
                case .press:
                    // The outline is the place the focused window has once its column is a stack.
                    beacon = nil
                    let twin = copy(desktops[current])
                    if let id = focusedWindow, twin.toggleStack(id) == true {
                        ghost = frames(current, tree: twin)[id].map { TourGhost(desktop: current, rect: $0, window: id) }
                    } else {
                        ghost = nil
                    }
                case .step:
                    // A window of the stack that is one key away. From outside the stack, its front window.
                    ghost = nil
                    let from = focusedWindow.flatMap { placed[$0] }
                    beacon = [Direction.up, .left, .down, .right].compactMap(neighbour).first { overlap(placed[$0], from) }
                        ?? stacked.filter { $0 != focusedWindow }.min { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
                }
            }
        case .desktops:
            switch desktopGoal {
            case .jump:
                let others = [1, 0, 2].filter { $0 != current && !desktops[$0].isEmpty }
                desktopBeacon = others.first
                ghost = nil
            case .carry:
                if let id = focusedWindow {
                    let others = desktops.indices.filter { $0 != current }
                    let target = others.first { desktops[$0].isEmpty } ?? others.last ?? 0
                    let twin = copy(desktops[target])
                    adopt(id, into: target, tree: twin)
                    ghost = frames(target, tree: twin)[id].map { TourGhost(desktop: target, rect: $0, window: id) }
                    desktopBeacon = nil
                } else {
                    // Nothing to carry from an empty desktop: point at one that has windows.
                    ghost = nil
                    desktopBeacon = desktops.indices.first { !desktops[$0].isEmpty }
                }
            }
        default:
            break
        }
    }
}
