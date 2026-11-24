import CoreGraphics
import Foundation

/// Split `total` among children by weight while honouring each child's minimum length.
/// A child that would fall below its minimum is pinned to it and the rest share what is left.
func distribute(total: CGFloat, weights: [CGFloat], mins: [CGFloat]) -> [CGFloat] {
    let n = weights.count
    guard n > 0 else { return [] }
    var sizes = [CGFloat](repeating: 0, count: n)
    var pinned = Set<Int>()
    while true {
        let free = total - pinned.reduce(0) { $0 + mins[$1] }
        let wsum = (0..<n).filter { !pinned.contains($0) }.reduce(0) { $0 + weights[$1] }
        var changed = false
        for i in 0..<n where !pinned.contains(i) {
            let s = wsum > 0 ? free * weights[i] / wsum : 0
            if s < mins[i] - 0.5 {
                pinned.insert(i)
                changed = true
            } else {
                sizes[i] = s
            }
        }
        if !changed { break }
    }
    for i in pinned { sizes[i] = mins[i] }
    if pinned.count == n {
        // The minimums do not fit. Scale them down together so nothing leaves the screen.
        let sum = sizes.reduce(0, +)
        if sum > total, sum > 0 { sizes = sizes.map { $0 * total / sum } }
    }
    return sizes
}

/// Compute the frame of every visible window of a tree inside `rect`.
public func computeLayout(
    _ tree: Tree,
    in rect: CGRect,
    gap: CGFloat = 0,
    visible: Set<WindowID>? = nil,
    minSizes: [WindowID: CGSize] = [:]
) -> [WindowID: CGRect] {
    var out: [WindowID: CGRect] = [:]

    func minSize(_ n: Node) -> CGSize {
        if let id = n.windowID { return minSizes[id] ?? .zero }
        let kids = n.children.filter { tree.hasVisible($0, visible) }
        guard let o = n.orientation, !kids.isEmpty else { return .zero }
        let sizes = kids.map(minSize)
        let gaps = gap * CGFloat(kids.count - 1)
        let widths = sizes.map(\.width), heights = sizes.map(\.height)
        return o == .horizontal
            ? CGSize(width: widths.reduce(0, +) + gaps, height: heights.max() ?? 0)
            : CGSize(width: widths.max() ?? 0, height: heights.reduce(0, +) + gaps)
    }

    func place(_ n: Node, _ r: CGRect) {
        if let id = n.windowID {
            out[id] = r
            return
        }
        let kids = n.children.filter { tree.hasVisible($0, visible) }
        guard let o = n.orientation, !kids.isEmpty else { return }
        let horizontal = o == .horizontal
        let total = (horizontal ? r.width : r.height) - gap * CGFloat(kids.count - 1)
        let lengths = distribute(
            total: total,
            weights: kids.map { CGFloat($0.weight) },
            mins: kids.map { horizontal ? minSize($0).width : minSize($0).height })
        var cursor = horizontal ? r.minX : r.minY
        for (kid, len) in zip(kids, lengths) {
            let a = cursor.rounded(), b = (cursor + len).rounded()
            place(kid, horizontal
                ? CGRect(x: a, y: r.minY, width: b - a, height: r.height)
                : CGRect(x: r.minX, y: a, width: r.width, height: b - a))
            cursor += len + gap
        }
    }

    place(tree.root, rect)
    return out
}

/// The closest window in a direction, judged by what is on screen. Coordinates have y growing downwards.
public func nearestWindow(from origin: CGRect, direction: Direction, among frames: [WindowID: CGRect], excluding: WindowID? = nil) -> WindowID? {
    struct Candidate {
        let id: WindowID
        let overlaps: Bool
        let distance: CGFloat
        let offset: CGFloat
    }
    var best: Candidate?
    for (id, f) in frames where id != excluding {
        let ahead: Bool, distance: CGFloat, overlap: CGFloat, offset: CGFloat
        switch direction {
        case .left:
            ahead = f.midX < origin.midX - 1 && f.minX < origin.minX - 1
            distance = max(0, origin.minX - f.maxX)
        case .right:
            ahead = f.midX > origin.midX + 1 && f.maxX > origin.maxX + 1
            distance = max(0, f.minX - origin.maxX)
        case .up:
            ahead = f.midY < origin.midY - 1 && f.minY < origin.minY - 1
            distance = max(0, origin.minY - f.maxY)
        case .down:
            ahead = f.midY > origin.midY + 1 && f.maxY > origin.maxY + 1
            distance = max(0, f.minY - origin.maxY)
        }
        guard ahead else { continue }
        if direction.orientation == .horizontal {
            overlap = min(f.maxY, origin.maxY) - max(f.minY, origin.minY)
            offset = abs(f.minY - origin.minY)
        } else {
            overlap = min(f.maxX, origin.maxX) - max(f.minX, origin.minX)
            offset = abs(f.minX - origin.minX)
        }
        let c = Candidate(id: id, overlaps: overlap > 1, distance: distance, offset: offset)
        guard let b = best else {
            best = c
            continue
        }
        let better: Bool
        if c.overlaps != b.overlaps {
            better = c.overlaps
        } else if abs(c.distance - b.distance) > 1 {
            better = c.distance < b.distance
        } else if abs(c.offset - b.offset) > 1 {
            better = c.offset < b.offset
        } else {
            better = c.id < b.id
        }
        if better { best = c }
    }
    return best?.id
}
