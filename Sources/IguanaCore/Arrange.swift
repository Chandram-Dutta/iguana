import CoreGraphics
import Foundation

/// A shape `arrange` gives a whole desktop at once. It is not kept as a mode: the tree is
/// rebuilt in that shape, and from then on it is an ordinary tree like any other.
public enum Arrangement: String, CaseIterable {
    /// Every window side by side.
    case columns
    /// Every window top to bottom.
    case rows
    /// Rows of as many windows as the square root of their number, rounded up.
    case grid
    /// One window on the left with 60% of the width, the others top to bottom on the right.
    case main
}

/// The windows in the order a page is read: top to bottom, then left to right. Windows whose top
/// edges are within 10 points of the first window of a row are in that row, so that a row a
/// point or two out of line still reads as one.
public func readingOrder(_ frames: [WindowID: CGRect]) -> [WindowID] {
    let byTop = frames.sorted { ($0.value.minY, $0.value.minX, $0.key) < ($1.value.minY, $1.value.minX, $1.key) }
    var rows: [[(key: WindowID, value: CGRect)]] = []
    for item in byTop {
        if let top = rows.last?.first?.value.minY, item.value.minY - top <= 10 {
            rows[rows.count - 1].append(item)
        } else {
            rows.append([item])
        }
    }
    return rows.flatMap { row in row.sorted { ($0.value.minX, $0.key) < ($1.value.minX, $1.key) }.map(\.key) }
}

extension Tree {
    /// Rebuild the whole tree in one of the arrangements, with equal shares and no stacks.
    ///
    /// - `order`: the windows on screen, in the order they fill the arrangement.
    /// - `main`: the window on the left in `.main`; the first of `order` when nil.
    /// - `hidden`: the windows that are not on screen. They go after the last window, in the same
    ///   container, and take no room until they come back.
    ///
    /// A window of the tree that is in neither list is kept, at the end with the hidden ones.
    public func arrange(_ arrangement: Arrangement, order: [WindowID], main: WindowID? = nil, hidden: [WindowID] = []) {
        let present = Set(windows)
        let lead = arrangement == .main ? ([main].compactMap { $0 } + order).first(where: present.contains) : nil
        // The main window is taken out first, so it is in neither of the lists below.
        var seen = Set([lead].compactMap { $0 })
        func keep(_ ids: [WindowID]) -> [WindowID] { ids.filter { present.contains($0) && seen.insert($0).inserted } }
        let shown = keep(order), rest = keep(hidden) + keep(windows)

        func leaf(_ id: WindowID, _ weight: Double = 1) -> NodeSnapshot {
            NodeSnapshot(window: id, orientation: nil, weight: weight, children: nil)
        }
        func split(_ o: Orientation, _ kids: [NodeSnapshot], _ weight: Double = 1) -> NodeSnapshot {
            NodeSnapshot(window: nil, orientation: o, weight: weight, children: kids)
        }
        let shape: NodeSnapshot
        switch arrangement {
        case .columns:
            shape = split(.horizontal, (shown + rest).map { leaf($0) })
        case .rows:
            shape = split(.vertical, (shown + rest).map { leaf($0) })
        case .grid:
            let perRow = max(1, Int(Double(shown.count).squareRoot().rounded(.up)))
            var rows = stride(from: 0, to: shown.count, by: perRow).map { Array(shown[$0..<min($0 + perRow, shown.count)]) }
            if rows.isEmpty { rows = [[]] }
            rows[rows.count - 1] += rest
            shape = split(.vertical, rows.map { row in split(.horizontal, row.map { leaf($0) }) })
        case .main:
            let others = shown + rest
            if let lead, !others.isEmpty {
                // 60% of the width for the main window, with weights that average 1 as everywhere else.
                shape = split(.horizontal, [leaf(lead, 1.2), split(.vertical, others.map { leaf($0) }, 0.8)])
            } else {
                shape = split(.horizontal, ([lead].compactMap { $0 } + others).map { leaf($0) })
            }
        }
        // Built from a snapshot, the new tree is in canonical form, with no window twice.
        root = Tree(snapshot: shape).root
    }
}
