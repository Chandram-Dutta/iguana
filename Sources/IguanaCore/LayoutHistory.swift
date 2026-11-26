import Foundation

/// The changes the user made to each layout, so that `undo` can take them back and `redo` can
/// make them again. A layout is known by its tree key: one desktop on one display. Only the
/// user's own changes are steps; windows opening and closing are not.
public struct LayoutHistory {
    /// The steps kept for each layout. Beyond this the oldest is forgotten.
    public static let limit = 50

    private var undoable: [String: [NodeSnapshot]] = [:]
    private var redoable: [String: [NodeSnapshot]] = [:]

    public init() {}

    /// The user changed a layout from `before` to `after`. A change that left it as it was is
    /// not a step. A new step means there is nothing left to redo.
    public mutating func record(key: String, before: NodeSnapshot, after: NodeSnapshot) {
        guard before != after else { return }
        Self.push(before, onto: &undoable[key, default: []])
        redoable[key] = nil
    }

    /// The layout to go back to, or nil when there is none. `current` is kept for `redo`, so
    /// redo brings back the layout as it was just now, windows that have opened since included.
    /// The windows in `current` are the ones that are still there: a step that would only put
    /// back a window that is not among them is not a layout to go back to.
    public mutating func undo(key: String, current: NodeSnapshot) -> NodeSnapshot? {
        guard let before = Self.pop(&undoable[key, default: []], unlike: current) else { return nil }
        Self.push(current, onto: &redoable[key, default: []])
        return before
    }

    /// The layout an undo went back from, or nil when there is none. `current` can be undone again.
    public mutating func redo(key: String, current: NodeSnapshot) -> NodeSnapshot? {
        guard let after = Self.pop(&redoable[key, default: []], unlike: current) else { return nil }
        Self.push(current, onto: &undoable[key, default: []])
        return after
    }

    public mutating func forget(key: String) {
        undoable[key] = nil
        redoable[key] = nil
    }

    private static func push(_ snapshot: NodeSnapshot, onto list: inout [NodeSnapshot]) {
        list.append(snapshot)
        if list.count > limit { list.removeFirst(list.count - limit) }
    }

    /// A layout that is the one on screen already would change nothing, so it is passed over.
    /// So is one that differs from it only by windows that `current` no longer has. Those have
    /// closed, floated or gone to another desktop, and going back does not bring them back.
    private static func pop(_ list: inout [NodeSnapshot], unlike current: NodeSnapshot) -> NodeSnapshot? {
        let here = Set(Tree(snapshot: current).windows)
        while let last = list.popLast() {
            guard last != current else { continue }
            // What the layout would be once `last` is put back and the windows that have gone are left out.
            let tree = Tree(snapshot: last)
            tree.prune { here.contains($0) }
            if tree.snapshot != current { return last }
        }
        return nil
    }
}
