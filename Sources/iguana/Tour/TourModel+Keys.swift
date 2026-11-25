import IguanaCore
import SwiftUI

/// One key of the keys shown under a lesson.
struct KeyHint: Identifiable, Equatable {
    /// The key's config-file name (`h`, `minus`), or the whole shortcut when the keys of a lesson
    /// do not share their modifiers.
    let id: String
    let label: String
    /// An SF Symbol that says what the key does: an arrow, a number sign.
    var symbol: String?
    let command: Command
}

/// The keys of a lesson: the modifiers to hold, and the keys to press with them.
struct LessonKeys: Equatable {
    var modifiers: [Modifier] = []
    var keys: [KeyHint] = []
}

extension TourModel {
    // MARK: Keys

    private func binding(_ matches: (Command) -> Bool) -> KeyBinding? { bindings.first { matches($0.command) } }

    private static let arrows: [Direction: String] = [.left: "arrow.left", .down: "arrow.down", .up: "arrow.up", .right: "arrow.right"]

    private func keys(_ wanted: [(command: (Command) -> Bool, label: String?, symbol: String?)]) -> LessonKeys? {
        var found: [(KeyBinding, String?, String?)] = []
        for item in wanted {
            guard let b = binding(item.command) else { return nil }
            found.append((b, item.label, item.symbol))
        }
        guard let first = found.first else { return nil }
        let shared = found.allSatisfy { $0.0.combo.modifiers == first.0.combo.modifiers }
        let order: [Modifier] = [.ctrl, .option, .shift, .cmd]
        return LessonKeys(
            modifiers: shared ? order.filter { first.0.combo.modifiers.contains($0) } : [],
            keys: found.map { b, label, symbol in
                let name = ShortcutFormat.keys(b.combo).last ?? b.combo.key
                return KeyHint(id: shared ? b.combo.key : b.source, label: shared ? (label ?? name) : ShortcutFormat.display(b.combo),
                               symbol: symbol, command: b.command)
            })
    }

    private func directionKeys(_ make: @escaping (Direction) -> Command) -> LessonKeys? {
        // In the order the keys sit on the keyboard when they are H J K L.
        keys([Direction.left, .down, .up, .right].map { dir in
            (command: { $0 == make(dir) }, label: nil, symbol: Self.arrows[dir])
        })
    }

    func numberKeys(_ matches: @escaping (Command, Int) -> Bool) -> LessonKeys? {
        keys((1...Self.desktopCount).map { n in (command: { matches($0, n) }, label: nil, symbol: nil) })
    }

    func keys(for step: TourStep) -> LessonKeys? {
        switch step {
        case .focus: return directionKeys { .focus($0) }
        case .move: return directionKeys { .move($0) }
        case .resize:
            return keys([
                (command: { if case .resize(_, let grow) = $0 { return grow < 0 }; return false }, label: nil, symbol: "arrow.down.right.and.arrow.up.left"),
                (command: { if case .resize(_, let grow) = $0 { return grow > 0 }; return false }, label: nil, symbol: "arrow.up.left.and.arrow.down.right"),
            ])
        case .stack:
            return keys([(command: { $0 == .stack }, label: nil, symbol: "square.stack.3d.up.fill")])
        case .desktops:
            switch desktopGoal {
            case .jump: return numberKeys { $0 == .space(.index($1)) }
            case .carry: return numberKeys { command, n in
                    if case .moveToSpace(.index(n), _) = command { return true }
                    return false
                }
            }
        default: return nil
        }
    }

    /// The keys on screen now. The second half of the stack lesson is done with the focus keys.
    var deck: LessonKeys? {
        step == .stack && stackGoal == .step ? keys(for: .focus) : keys(for: step)
    }

    /// The window the focus goes to in a direction. Tiles are judged by where they are; the
    /// windows of a stack overlap, and there the layout says which is next.
    func neighbour(_ dir: Direction) -> WindowID? {
        let placed = frames(current)
        guard let from = focusedWindow, let origin = placed[from] else { return nil }
        return focusTarget(from: from, at: origin, direction: dir, among: placed, trees: [desktops[current]], frontToBack: order)
    }

    /// The focus key that leads to the window that calls.
    private func steer(to beacon: WindowID?) -> Command? {
        guard let beacon, let from = focusedWindow else { return nil }
        let placed = frames(current)
        guard let origin = placed[from], let target = placed[beacon] else { return nil }
        if let direct = Direction.allCases.first(where: { neighbour($0) == beacon }) {
            return .focus(direct)
        }
        let dx = target.midX - origin.midX, dy = target.midY - origin.midY
        return .focus(abs(dx) >= abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down))
    }

    /// The key that takes the next step towards the goal, so that it can be pointed out.
    var suggested: Command? {
        switch step {
        case .focus:
            return steer(to: beacon)
        case .stack:
            return stackGoal == .press ? keys(for: .stack)?.keys.first?.command : steer(to: beacon)
        case .move:
            return goalWindow == focusedWindow ? .move(goalDirection) : nil
        case .resize:
            return goalWindow == focusedWindow ? keys(for: .resize)?.keys.last?.command : nil
        case .desktops:
            if let desktopBeacon { return desktopGoal == .jump ? .space(.index(desktopBeacon + 1)) : nil }
            if let ghost { return keys(for: .desktops)?.keys.dropFirst(ghost.desktop).first?.command }
            return nil
        default:
            return nil
        }
    }

    /// A key that has nothing to do here. There is no sound for it: a sound for "no" is what the
    /// system makes when something is wrong, and nothing is. The keys on screen give a small shake.
    func refuse() {
        withAnimation(.linear(duration: 0.32)) { refusals += 1 }
    }

    func flash(_ command: Command, binding: KeyBinding?) {
        let id: String
        if let hint = deck?.keys.first(where: { $0.command == command }) {
            id = hint.id
        } else if let binding {
            id = binding.combo.key
        } else {
            return
        }
        lit.insert(id)
        after(0.22) { [weak self] in self?.lit.remove(id) }
    }
}
