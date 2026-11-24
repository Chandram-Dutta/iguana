import CoreGraphics
import Foundation

// What a stack changes outside the layout itself. The windows of a stack overlap, so two things
// that are otherwise read off the screen have to come from the tree instead: which window is
// "next" in a direction, and which window has to be in front of which.

extension Tree {
    /// The stacked containers a window sits in, outermost first.
    func stacks(around id: WindowID) -> [Node] {
        var found: [Node] = []
        var n = node(id)?.parent
        while let p = n {
            if p.stacked { found.append(p) }
            n = p.parent
        }
        return found.reversed()
    }

    private func visibleLeaves(_ n: Node, _ visible: Set<WindowID>?) -> [WindowID] {
        n.leaves().filter { visible?.contains($0) != false }
    }

    /// Where `focus` goes next from a window inside a stack, as long as that is still inside the
    /// outermost stack around it. `inStack` says whether the step is to the next window of a
    /// stack (true) or to a tile that sits beside the current one (false). Nil means the window
    /// is in no stack, or is at the end of it in this direction.
    func stepInsideStack(from id: WindowID, _ dir: Direction, visible: Set<WindowID>? = nil) -> (node: Node, inStack: Bool)? {
        guard let w = node(id), let outer = stacks(around: id).first else { return nil }
        let step = dir.isForward ? 1 : -1
        var branch = w
        while let p = branch.parent {
            if p.orientation == dir.orientation, let i = p.children.firstIndex(where: { $0 === branch }) {
                var j = i + step
                while p.children.indices.contains(j) {
                    if hasVisible(p.children[j], visible) { return (p.children[j], p.stacked) }
                    j += step
                }
            }
            if p === outer { return nil }
            branch = p
        }
        return nil
    }

    /// The windows to bring forward, in this order, so that the stack around the focused window
    /// shows every one of its windows. Empty when they already are in a good order.
    ///
    /// The focused window is in front. Of the others, each has a strip that only the windows
    /// further from the focused one could cover, so on both sides the nearer window has to be
    /// above the further one. Clicking through a stack in any order breaks that, and then a
    /// window ends up entirely behind two others.
    ///
    /// - `frontToBack`: the windows on screen as they are ordered now.
    public func stackRaiseOrder(focused: WindowID, frontToBack: [WindowID], visible: Set<WindowID>? = nil) -> [WindowID] {
        guard let outer = stacks(around: focused).first else { return [] }
        var rank: [WindowID: Int] = [:]
        for (i, id) in frontToBack.enumerated() where rank[id] == nil { rank[id] = i }

        /// Back to front: raising the windows in this order gives a good arrangement.
        var paint: [WindowID] = []
        var rules: [(above: [WindowID], below: [WindowID])] = []
        func holds(_ n: Node, _ id: WindowID) -> Bool { n.leaves().contains(id) }
        func walk(_ n: Node) {
            if let id = n.windowID {
                paint.append(id)
                return
            }
            let kids = n.children.filter { hasVisible($0, visible) }
            guard n.stacked, kids.count > 1 else {
                // Tiles side by side do not cover each other. The one with the focus goes last,
                // so that the focused window is the last one raised.
                for k in kids where !holds(k, focused) { walk(k) }
                for k in kids where holds(k, focused) { walk(k) }
                return
            }
            // The child in front: the one with the focus, or for a stack the focus is not in,
            // the one that is in front already.
            func nearest(_ k: Node) -> Int { visibleLeaves(k, visible).compactMap { rank[$0] }.min() ?? Int.max }
            let front = kids.firstIndex { holds($0, focused) }
                ?? kids.indices.min { nearest(kids[$0]) < nearest(kids[$1]) } ?? 0
            for k in kids[(front + 1)...].reversed() { walk(k) }
            for k in kids[..<front] { walk(k) }
            walk(kids[front])
            for i in front..<(kids.count - 1) { rules.append((visibleLeaves(kids[i], visible), visibleLeaves(kids[i + 1], visible))) }
            for i in stride(from: front, to: 0, by: -1) { rules.append((visibleLeaves(kids[i], visible), visibleLeaves(kids[i - 1], visible))) }
        }
        walk(outer)

        // Raise as few windows as possible: the longest run at the back that is in order among
        // itself stays where it is, and the rest is raised on top of it.
        for keep in stride(from: paint.count, through: 0, by: -1) {
            let kept = Set(paint[..<keep])
            let inOrder = rules.allSatisfy { rule in
                rule.above.allSatisfy { a in
                    rule.below.allSatisfy { b in
                        // A window the system does not list cannot be judged; leave it alone.
                        guard kept.contains(a), kept.contains(b), let ra = rank[a], let rb = rank[b] else { return true }
                        return ra < rb
                    }
                }
            }
            if inOrder { return Array(paint[keep...]) }
        }
        return paint
    }

    /// The window of a stack that `focus` should land on when the stack is entered from the
    /// side, across its direction. Seen from there all of its windows are equally near, and the
    /// one to go to is the one in front: it is the one the user sees.
    fileprivate func frontOfStacks(
        around first: WindowID, comingFrom current: WindowID, at origin: CGRect, direction: Direction,
        among frames: [WindowID: CGRect], visible: Set<WindowID>?, frontToBack: [WindowID]
    ) -> WindowID {
        var rank: [WindowID: Int] = [:]
        for (i, id) in frontToBack.enumerated() where rank[id] == nil { rank[id] = i }
        var pick = first
        /// The stack looked at last. The next one to look at is inside it.
        var done: Node?
        while true {
            var chain = stacks(around: pick)
            if let done, let i = chain.firstIndex(where: { $0 === done }) { chain.removeFirst(i + 1) }
            guard let stack = chain.first(where: { $0.orientation != direction.orientation && !$0.leaves().contains(current) }) else { return pick }
            done = stack
            let kids = stack.children.filter { hasVisible($0, visible) }
            func nearest(_ k: Node) -> Int { visibleLeaves(k, visible).compactMap { rank[$0] }.min() ?? Int.max }
            guard let front = kids.min(by: { nearest($0) < nearest($1) }), nearest(front) != Int.max,
                  !front.leaves().contains(pick) else { continue }
            let leaves = visibleLeaves(front, visible)
            pick = nearestWindow(from: origin, direction: direction, among: frames.filter { leaves.contains($0.key) })
                ?? leaves.min { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) } ?? pick
        }
    }
}

/// The window `focus` goes to from `current`. Outside stacks this is `nearestWindow`: what is
/// on screen decides. The windows of a stack overlap, and there the tree decides:
///
/// - inside a stack, the direction the stack runs in steps to the next or previous window of the
///   stack, and at its end carries on to whatever is beyond the stack;
/// - a stack that is entered across its direction gives the window it has in front.
///
/// - `origin`: the frame of `current`. `trees`: the layouts being shown. `frontToBack`: the
///   windows on screen as they are ordered now.
public func focusTarget(
    from current: WindowID, at origin: CGRect, direction: Direction, among frames: [WindowID: CGRect],
    trees: [Tree], visible: Set<WindowID>? = nil, frontToBack: [WindowID] = []
) -> WindowID? {
    var pick: WindowID?
    if let tree = trees.first(where: { $0.contains(current) }),
       let next = tree.stepInsideStack(from: current, direction, visible: visible) {
        let leaves = next.node.leaves().filter { visible?.contains($0) != false }
        // A tile beside this one does not overlap it, so what is on screen can pick the window in it.
        if !next.inStack { pick = nearestWindow(from: origin, direction: direction, among: frames.filter { leaves.contains($0.key) }) }
        // The next window of the stack overlaps this one. Take the end of it that is on this side.
        pick = pick ?? (direction.isForward ? leaves.first : leaves.last)
    }
    guard let found = pick ?? nearestWindow(from: origin, direction: direction, among: frames, excluding: current) else { return nil }
    guard let tree = trees.first(where: { $0.contains(found) }) else { return found }
    return tree.frontOfStacks(around: found, comingFrom: current, at: origin, direction: direction,
                              among: frames, visible: visible, frontToBack: frontToBack)
}
