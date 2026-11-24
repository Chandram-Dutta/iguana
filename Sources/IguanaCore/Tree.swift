import CoreGraphics
import Foundation

public typealias WindowID = UInt32

public enum Orientation: String, Codable, Equatable {
    case horizontal, vertical
    public var flipped: Orientation { self == .horizontal ? .vertical : .horizontal }
}

public enum Direction: String, CaseIterable, Equatable {
    case left, right, up, down
    public var orientation: Orientation { self == .left || self == .right ? .horizontal : .vertical }
    public var isForward: Bool { self == .right || self == .down }
}

/// A node is either a window leaf or a container that splits its area among its children.
public final class Node {
    public enum Kind: Equatable {
        case window(WindowID)
        case container(Orientation)
    }

    public fileprivate(set) var kind: Kind
    /// Share of the parent's area, relative to the sibling weights.
    public fileprivate(set) var weight: Double
    public fileprivate(set) var children: [Node] = []
    public fileprivate(set) weak var parent: Node?
    /// A stacked container gives all of its children the same area, each shifted a little so
    /// that a strip of the ones behind stays in view. Only containers are ever stacked.
    public fileprivate(set) var stacked = false

    fileprivate init(window: WindowID, weight: Double = 1) {
        kind = .window(window)
        self.weight = weight
    }

    fileprivate init(container: Orientation, weight: Double = 1) {
        kind = .container(container)
        self.weight = weight
    }

    public var windowID: WindowID? {
        if case .window(let id) = kind { return id }
        return nil
    }

    public var orientation: Orientation? {
        if case .container(let o) = kind { return o }
        return nil
    }

    fileprivate var index: Int? { parent?.children.firstIndex { $0 === self } }

    fileprivate var meanChildWeight: Double {
        children.isEmpty ? 1 : children.reduce(0) { $0 + $1.weight } / Double(children.count)
    }

    fileprivate func insert(_ child: Node, at i: Int) {
        child.parent = self
        children.insert(child, at: min(max(i, 0), children.count))
    }

    fileprivate func append(_ child: Node) { insert(child, at: children.count) }

    fileprivate func detach() {
        parent?.children.removeAll { $0 === self }
        parent = nil
    }

    public func leaves() -> [WindowID] {
        if let id = windowID { return [id] }
        return children.flatMap { $0.leaves() }
    }

    fileprivate func find(_ id: WindowID) -> Node? {
        if windowID == id { return self }
        for c in children { if let n = c.find(id) { return n } }
        return nil
    }
}

public struct NodeSnapshot: Codable, Equatable {
    public var window: WindowID?
    public var orientation: Orientation?
    public var weight: Double
    public var children: [NodeSnapshot]?
    /// Only written for a stacked container, so state saved before stacks existed still loads.
    public var stacked: Bool? = nil
}

public enum ShareChange {
    /// Add this fraction of the container to the window's share (0.05 = five percent).
    case delta(Double)
    /// Multiply the window's share by this factor.
    case ratio(Double)
}

/// The tiling tree of one Space on one display.
///
/// Windows that are currently not on screen (minimised, hidden app, another Stage Manager stage,
/// a background native tab) stay in the tree and keep their slot. Every operation that depends on
/// what the user can see takes a `visible` set and skips the rest.
public final class Tree {
    public private(set) var root: Node
    /// Last focused window of this tree. New windows open next to it.
    public var focused: WindowID?

    public init(orientation: Orientation = .horizontal) {
        root = Node(container: orientation)
    }

    public var windows: [WindowID] { root.leaves() }
    public var isEmpty: Bool { root.children.isEmpty }

    public func contains(_ id: WindowID) -> Bool { root.find(id) != nil }

    func node(_ id: WindowID) -> Node? { root.find(id) }

    public func hasVisible(_ node: Node, _ visible: Set<WindowID>?) -> Bool {
        guard let visible else { return node.windowID != nil || node.children.contains { hasVisible($0, nil) } }
        if let id = node.windowID { return visible.contains(id) }
        return node.children.contains { hasVisible($0, visible) }
    }

    // MARK: Insert / remove

    /// Insert a window next to `anchor` (or at the end of the root).
    /// - `split`: when it differs from the orientation of the anchor's container, the anchor's slot
    ///   is split in that orientation instead of widening the container (dwindle behaviour).
    /// - `sameSlot`: the new window shares the anchor's slot, used when one window replaces
    ///   another on screen (native tabs).
    ///
    /// A window that opens next to one in a stack joins the stack, whatever `split` says.
    @discardableResult
    public func insert(_ id: WindowID, after anchor: WindowID? = nil, split: Orientation? = nil, sameSlot: Bool = false) -> Bool {
        guard !contains(id) else { return false }
        guard let anchor, let an = node(anchor), let p = an.parent, let i = an.index else {
            root.append(Node(window: id, weight: root.meanChildWeight))
            return true
        }
        if sameSlot {
            p.insert(Node(window: id, weight: an.weight), at: i + 1)
            return true
        }
        if let split, split != p.orientation, !p.stacked {
            if p.children.count == 1 {
                p.kind = .container(split)
                p.insert(Node(window: id, weight: an.weight), at: i + 1)
            } else {
                let c = Node(container: split, weight: an.weight)
                an.detach()
                p.insert(c, at: i)
                an.weight = 1
                c.append(an)
                c.append(Node(window: id))
            }
            normalize()
            return true
        }
        p.insert(Node(window: id, weight: p.meanChildWeight), at: i + 1)
        return true
    }

    @discardableResult
    public func remove(_ id: WindowID) -> Bool {
        guard let n = node(id) else { return false }
        n.detach()
        normalize()
        if focused == id { focused = nil }
        return true
    }

    /// Drop every window for which `keep` returns false.
    public func prune(keeping keep: (WindowID) -> Bool) {
        for id in windows where !keep(id) { remove(id) }
    }

    // MARK: Structure changes

    /// Exchange the slots of two windows.
    @discardableResult
    public func swap(_ a: WindowID, _ b: WindowID) -> Bool {
        guard a != b, let na = node(a), let nb = node(b) else { return false }
        let k = na.kind
        na.kind = nb.kind
        nb.kind = k
        return true
    }

    /// Move a window one step in a direction, i3 style: swap with a neighbouring window, enter a
    /// neighbouring container, or leave the current container towards that side.
    @discardableResult
    public func move(_ id: WindowID, _ dir: Direction, visible: Set<WindowID>? = nil) -> Bool {
        guard let w = node(id) else { return false }
        let axis = dir.orientation
        let step = dir.isForward ? 1 : -1

        var branch = w
        while let p = branch.parent {
            if p.orientation == axis, let i = branch.index,
               let j = nextVisibleIndex(in: p, from: i, step: step, visible: visible) {
                if branch === w {
                    let neighbor = p.children[j]
                    if let no = neighbor.orientation {
                        w.detach()
                        w.weight = neighbor.meanChildWeight
                        if no == axis && dir.isForward { neighbor.insert(w, at: 0) } else { neighbor.append(w) }
                    } else {
                        let k = w.kind
                        w.kind = neighbor.kind
                        neighbor.kind = k
                    }
                } else {
                    w.detach()
                    w.weight = p.meanChildWeight
                    let bi = branch.index ?? i
                    p.insert(w, at: dir.isForward ? bi + 1 : bi)
                }
                normalize()
                return true
            }
            branch = p
        }

        // Already at the outer edge of every container along this axis.
        if w.parent === root && root.orientation == axis { return false }
        if w.parent === root && root.children.filter({ hasVisible($0, visible) }).count <= 1 { return false }
        w.detach()
        if root.orientation == axis {
            w.weight = root.meanChildWeight
            if dir.isForward { root.append(w) } else { root.insert(w, at: 0) }
        } else {
            let old = root
            let newRoot = Node(container: axis)
            root = newRoot
            old.weight = 1
            w.weight = 1
            if dir.isForward {
                newRoot.append(old)
                newRoot.append(w)
            } else {
                newRoot.append(w)
                newRoot.append(old)
            }
        }
        normalize()
        return true
    }

    /// Put the window and its neighbour in `dir` into a shared container that splits the other way.
    @discardableResult
    public func join(_ id: WindowID, with dir: Direction, visible: Set<WindowID>? = nil) -> Bool {
        guard let w = node(id) else { return false }
        let axis = dir.orientation
        let step = dir.isForward ? 1 : -1
        var branch = w
        while let p = branch.parent {
            if p.orientation == axis, let i = branch.index,
               let j = nextVisibleIndex(in: p, from: i, step: step, visible: visible) {
                let neighbor = p.children[j]
                w.detach()
                if neighbor.orientation != nil {
                    w.weight = neighbor.meanChildWeight
                    neighbor.append(w)
                } else {
                    guard let ni = neighbor.index else { return false }
                    let c = Node(container: axis.flipped, weight: neighbor.weight)
                    neighbor.detach()
                    p.insert(c, at: ni)
                    neighbor.weight = 1
                    w.weight = 1
                    c.append(neighbor)
                    c.append(w)
                }
                normalize()
                return true
            }
            branch = p
        }
        return false
    }

    /// Flip the split direction of the container that holds the window.
    @discardableResult
    public func flip(_ id: WindowID) -> Bool {
        guard let p = node(id)?.parent, let o = p.orientation else { return false }
        p.kind = .container(o.flipped)
        normalize()
        return true
    }

    /// Switch the container that holds the window between split and stacked. Returns the new
    /// state, or nil when the window has its container to itself and there is nothing to stack.
    @discardableResult
    public func toggleStack(_ id: WindowID) -> Bool? {
        guard let p = node(id)?.parent, p.children.count > 1 else { return nil }
        p.stacked.toggle()
        let now = p.stacked
        normalize()
        return now
    }

    /// The outermost stack around a window that shows as a stack: more than one of its
    /// children is on screen. A stack with a single window on screen looks like any other tile.
    func shownStack(around id: WindowID, visible: Set<WindowID>?) -> Node? {
        stacks(around: id).first { stack in stack.children.filter { hasVisible($0, visible) }.count > 1 }
    }

    /// Put a window beside another on one side, as a drop on that edge of its tile asks: the
    /// tile is cut in two across `side`, the window takes the half on that side and the anchor
    /// keeps the rest. A window that is in this tree already leaves its place first.
    ///
    /// An anchor in a stack that shows as one stands for the whole stack: the window goes
    /// beside the stack, never into it.
    @discardableResult
    public func place(_ id: WindowID, beside anchor: WindowID, on side: Direction, visible: Set<WindowID>? = nil) -> Bool {
        guard id != anchor, let leaf = node(anchor) else { return false }
        // Looked up before the window leaves, while a stack of two still is a stack. The tree
        // is put in order once, at the end, so that these nodes stay the ones in the tree.
        let target = shownStack(around: anchor, visible: visible) ?? leaf
        node(id)?.detach()
        let new = Node(window: id)
        let axis = side.orientation
        if let p = target.parent, let i = target.index {
            if p.children.count == 1 {
                // Alone in its container: the container turns to split the way that was asked.
                p.kind = .container(axis)
                p.stacked = false
                new.weight = target.weight
                p.insert(new, at: side.isForward ? 1 : 0)
            } else if p.orientation == axis, !p.stacked {
                target.weight /= 2
                new.weight = target.weight
                p.insert(new, at: side.isForward ? i + 1 : i)
            } else {
                let c = Node(container: axis, weight: target.weight)
                target.detach()
                p.insert(c, at: i)
                target.weight = 1
                c.append(target)
                c.insert(new, at: side.isForward ? 1 : 0)
            }
        } else {
            // A stack that fills the display: the display is split around it.
            let old = root
            root = Node(container: axis)
            old.weight = 1
            root.append(old)
            root.insert(new, at: side.isForward ? 1 : 0)
        }
        normalize()
        return true
    }

    /// Put a window right after another in the container that one is in, with an even share. A
    /// window that is in this tree already leaves its place first.
    ///
    /// An anchor in a stack that shows as one stands for its branch of the stack: the window
    /// becomes the next window of that stack.
    @discardableResult
    public func place(_ id: WindowID, nextTo anchor: WindowID, visible: Set<WindowID>? = nil) -> Bool {
        guard id != anchor, var branch = node(anchor) else { return false }
        if let stack = shownStack(around: anchor, visible: visible) {
            while let p = branch.parent, p !== stack { branch = p }
        }
        guard let p = branch.parent else { return false }
        node(id)?.detach()
        p.insert(Node(window: id, weight: p.meanChildWeight), at: (branch.index ?? p.children.count) + 1)
        normalize()
        return true
    }

    /// Change how much of its container a window takes. With `axis == nil` the nearest container
    /// that has more than one visible child is used. The windows of a stack all have the same
    /// size, so from inside a stack it is the stack as a whole that grows or shrinks.
    @discardableResult
    public func changeShare(of id: WindowID, along axis: Orientation? = nil, _ change: ShareChange, visible: Set<WindowID>? = nil) -> Bool {
        guard var branch = node(id) else { return false }
        while let p = branch.parent {
            let vis = p.children.filter { hasVisible($0, visible) }
            if axis == nil || p.orientation == axis, !p.stacked, vis.count > 1, vis.contains(where: { $0 === branch }) {
                let total = vis.reduce(0) { $0 + $1.weight }
                let share = branch.weight / total
                var target: Double
                switch change {
                case .delta(let d): target = share + d
                case .ratio(let r): target = share * r
                }
                let floor = min(0.08, 1 / Double(vis.count * 2))
                target = min(max(target, floor), 1 - floor * Double(vis.count - 1))
                branch.weight = target / (1 - target) * (total - branch.weight)
                let sum = p.children.reduce(0) { $0 + $1.weight }
                let scale = Double(p.children.count) / sum
                for c in p.children { c.weight *= scale }
                return true
            }
            branch = p
        }
        return false
    }

    /// Make the weights agree with what is on screen. A window that is held at its minimum size
    /// takes more room than its weight asks for, and from then on a change of weight shows
    /// nothing until it has made up the difference. After this, the next change starts from what
    /// the user sees.
    public func matchWeights(to frames: [WindowID: CGRect], visible: Set<WindowID>? = nil) {
        func extent(_ n: Node) -> CGRect? {
            if let id = n.windowID { return visible?.contains(id) == false ? nil : frames[id] }
            var all: CGRect?
            for child in n.children {
                guard let e = extent(child) else { continue }
                all = all?.union(e) ?? e
            }
            return all
        }
        func walk(_ n: Node) {
            guard let o = n.orientation else { return }
            n.children.forEach(walk)
            let kids = n.children.filter { hasVisible($0, visible) }
            // The windows of a stack overlap; their sizes say nothing about weights.
            guard kids.count > 1, !n.stacked else { return }
            let lengths = kids.map { kid -> Double in
                guard let e = extent(kid) else { return 0 }
                return Double(o == .horizontal ? e.width : e.height)
            }
            let length = lengths.reduce(0, +), weight = kids.reduce(0) { $0 + $1.weight }
            guard weight > 0, !lengths.contains(where: { $0 <= 0 }) else { return }
            // Weights that already say what is on screen, give or take a point of rounding, stay as they are.
            guard zip(kids, lengths).contains(where: { abs($0.weight / weight - $1 / length) > 0.005 }) else { return }
            for (kid, len) in zip(kids, lengths) { kid.weight = weight * len / length }
        }
        walk(root)
    }

    /// Give every window an equal share again.
    public func balance() {
        func walk(_ n: Node) {
            n.weight = 1
            n.children.forEach(walk)
        }
        walk(root)
    }

    // MARK: Internals

    private func nextVisibleIndex(in p: Node, from i: Int, step: Int, visible: Set<WindowID>?) -> Int? {
        var j = i + step
        while p.children.indices.contains(j) {
            if hasVisible(p.children[j], visible) { return j }
            j += step
        }
        return nil
    }

    /// Keep the tree canonical: no empty containers, no single-child containers, and no container
    /// nested in a parent that arranges its children the same way. A stack and a split are
    /// different arrangements even when they run in the same direction, so those stay nested.
    func normalize() {
        normalize(root)
        while root.children.count == 1, let only = root.children.first, only.orientation != nil {
            only.detach()
            only.weight = 1
            root = only
        }
        // A stack that is down to one window is an ordinary tile again, at the root as anywhere else.
        if root.children.count < 2 { root.stacked = false }
    }

    private func normalize(_ node: Node) {
        guard let orientation = node.orientation else { return }
        for c in node.children { normalize(c) }
        var i = 0
        while i < node.children.count {
            let c = node.children[i]
            guard let co = c.orientation else {
                i += 1
                continue
            }
            if c.children.isEmpty {
                c.detach()
                continue
            }
            if c.children.count == 1 {
                let only = c.children[0]
                only.detach()
                only.weight = c.weight
                c.detach()
                node.insert(only, at: i)
                continue
            }
            if co == orientation, c.stacked == node.stacked {
                let kids = c.children
                let total = kids.reduce(0) { $0 + $1.weight }
                c.detach()
                for (k, kid) in kids.enumerated() {
                    kid.detach()
                    kid.weight = c.weight * kid.weight / total
                    node.insert(kid, at: i + k)
                }
                continue
            }
            i += 1
        }
    }

    // MARK: Persistence and debugging

    public var snapshot: NodeSnapshot {
        func snap(_ n: Node) -> NodeSnapshot {
            NodeSnapshot(window: n.windowID, orientation: n.orientation, weight: n.weight,
                         children: n.orientation == nil ? nil : n.children.map(snap), stacked: n.stacked ? true : nil)
        }
        return snap(root)
    }

    public convenience init(snapshot: NodeSnapshot) {
        self.init(orientation: snapshot.orientation ?? .horizontal)
        func build(_ s: NodeSnapshot) -> Node? {
            if let id = s.window { return Node(window: id, weight: s.weight > 0 ? s.weight : 1) }
            guard let o = s.orientation else { return nil }
            let n = Node(container: o, weight: s.weight > 0 ? s.weight : 1)
            n.stacked = s.stacked ?? false
            for c in s.children ?? [] { if let child = build(c) { n.append(child) } }
            return n
        }
        var seen = Set<WindowID>()
        root.stacked = snapshot.stacked ?? false
        for c in snapshot.children ?? [] {
            if let child = build(c) { root.append(child) }
        }
        // A snapshot from disk is untrusted: drop duplicate window ids.
        for id in windows {
            if !seen.insert(id).inserted, let n = node(id) { n.detach() }
        }
        normalize()
    }

    public func describe(label: (WindowID) -> String = { "window \($0)" }) -> String {
        var lines: [String] = []
        func walk(_ n: Node, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            let share = String(format: "%.2f", n.weight)
            if let id = n.windowID {
                lines.append("\(pad)- \(label(id))  [weight \(share)]")
            } else if let o = n.orientation {
                lines.append("\(pad)\(o.rawValue)\(n.stacked ? " stack" : "")  [weight \(share)]")
                n.children.forEach { walk($0, depth + 1) }
            }
        }
        walk(root, 0)
        return lines.joined(separator: "\n")
    }
}
