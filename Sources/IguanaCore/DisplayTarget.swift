import CoreGraphics
import Foundation

/// The display `focus-display` and `move-to-display` go to: the next or previous one in
/// display order, or one by its number (see `DisplayOrder`).
public enum DisplayTarget: Equatable {
    case next
    case prev
    case index(Int)

    /// The display numbers a command can name.
    public static let numbers = 1...16

    /// Why there is no display to go to, as the command's reply: `ok: …` when there is simply
    /// nothing to do, `error: …` when the display named is not there.
    public struct Refusal: Error, Equatable {
        public let reply: String
        public init(_ reply: String) { self.reply = reply }
    }

    /// The position in display order of the display aimed at, 0 for display 1. `active` is the
    /// position of the display that has the focus; `next` and `prev` count from it and wrap
    /// around at the ends.
    public func resolve(active: Int?, count: Int) -> Result<Int, Refusal> {
        guard count > 0 else { return .failure(Refusal("error: no display")) }
        // A display can always be named by number, so `focus-display 1` works with one display.
        guard count > 1 else {
            if case .index(let n) = self {
                guard n == 1 else { return .failure(Refusal("error: there is no display \(n) (there is 1)")) }
                return .success(0)
            }
            return .failure(Refusal("ok: only one display"))
        }
        let active = active.flatMap { (0..<count).contains($0) ? $0 : nil }
        switch self {
        case .next: return .success(active.map { ($0 + 1) % count } ?? 0)
        case .prev: return .success(active.map { ($0 + count - 1) % count } ?? count - 1)
        case .index(let n):
            guard n >= 1, n <= count else {
                return .failure(Refusal("error: there is no display \(n) (there \(count == 1 ? "is 1" : "are \(count)"))"))
            }
            return .success(n - 1)
        }
    }

    /// The argument of `focus-display` and `move-to-display`, already in lower case.
    static func parse(_ args: [String], command name: String) throws -> DisplayTarget {
        guard args.count == 1 else { throw CommandError("'\(name)' needs a display number, 'next' or 'prev'") }
        switch args[0] {
        case "next": return .next
        case "prev", "previous": return .prev
        default:
            guard let n = Int(args[0]), numbers.contains(n) else {
                throw CommandError("'\(name)' needs a display number from \(numbers.lowerBound) to \(numbers.upperBound), 'next' or 'prev'")
            }
            return .index(n)
        }
    }

    /// The window `focus-display` gives the focus to on a display: the one last focused in the
    /// layout there, else the tile nearest the centre of the display, else the frontmost of the
    /// other windows on it. Nil when the display has no window.
    /// - Parameters:
    ///   - remembered: the window last focused in the layout of the desktop the display shows.
    ///   - tiles: the tiled windows on screen there, with their frames.
    ///   - others: the other windows on screen there, such as floating ones, front to back.
    ///   - centre: the centre of the display's usable area.
    public static func windowToFocus(remembered: WindowID?, tiles: [WindowID: CGRect], others: [WindowID], centre: CGPoint) -> WindowID? {
        if let remembered, tiles[remembered] != nil { return remembered }
        func distance(_ r: CGRect) -> CGFloat { hypot(r.midX - centre.x, r.midY - centre.y) }
        // The lower id settles a tie, so the same layout always gives the same window.
        if let nearest = tiles.min(by: { (distance($0.value), $0.key) < (distance($1.value), $1.key) }) { return nearest.key }
        return others.first
    }

    /// Where a floating window lands on another display. It keeps its size, made smaller where
    /// the display has not got the room, and its place in proportion: a window against the left
    /// edge of `from` lands against the left edge of `to`, a window in the middle lands in the
    /// middle. It always lands inside `to`.
    public static func floatingFrame(_ frame: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, to.width), height: min(frame.height, to.height))
        /// How far along the room it has to move in the window is, from 0 to 1.
        func along(_ start: CGFloat, _ length: CGFloat, _ areaStart: CGFloat, _ areaLength: CGFloat) -> CGFloat {
            let room = areaLength - length
            return room > 0 ? min(max((start - areaStart) / room, 0), 1) : 0.5
        }
        return CGRect(x: to.minX + along(frame.minX, frame.width, from.minX, from.width) * (to.width - size.width),
                      y: to.minY + along(frame.minY, frame.height, from.minY, from.height) * (to.height - size.height),
                      width: size.width, height: size.height)
    }
}
