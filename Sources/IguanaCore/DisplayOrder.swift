import CoreGraphics
import Foundation

/// How displays are numbered wherever a display is named by number (commands, rules and
/// settings): from 1, left to right by the left edge of each display, and top to bottom where
/// two displays share a left edge. Frames are in top-left coordinates.
public enum DisplayOrder {
    /// The positions in `frames`, in display order: the first one is display 1.
    public static func order(_ frames: [CGRect]) -> [Int] {
        frames.indices.sorted { a, b in
            frames[a].minX != frames[b].minX ? frames[a].minX < frames[b].minX : frames[a].minY < frames[b].minY
        }
    }

    /// The number of each display, from 1, in the order the frames are given.
    public static func numbers(_ frames: [CGRect]) -> [Int] {
        var result = [Int](repeating: 0, count: frames.count)
        for (n, i) in order(frames).enumerated() { result[i] = n + 1 }
        return result
    }
}
