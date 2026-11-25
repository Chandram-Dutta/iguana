import Foundation

/// The windows in the order they last had the focus, most recent first. `focus recent` goes
/// back along it, so that pressing it twice returns to where you started.
public struct FocusHistory {
    /// How many windows are remembered. The oldest ones are forgotten first.
    public static let limit = 50
    /// Most recent first. A window is in it once, where it last had the focus.
    public private(set) var windows: [WindowID] = []

    public init() {}

    /// `id` has the focus now.
    public mutating func record(_ id: WindowID) {
        guard windows.first != id else { return }
        windows.removeAll { $0 == id }
        windows.insert(id, at: 0)
        if windows.count > Self.limit { windows.removeLast(windows.count - Self.limit) }
    }

    /// The window has closed.
    public mutating func forget(_ id: WindowID) {
        windows.removeAll { $0 == id }
    }

    /// The window that had the focus most recently, other than `current`, among those
    /// `eligible` accepts. Windows that are not on screen now are passed over, not forgotten.
    public func previous(current: WindowID?, eligible: (WindowID) -> Bool) -> WindowID? {
        windows.first { $0 != current && eligible($0) }
    }
}

/// The desktops each display has shown, so that `space recent` can go back to the one before.
/// A desktop is remembered by its Space id and not by its number, because the numbers shift
/// when a desktop is added or removed in Mission Control.
public struct DesktopHistory {
    /// For each display, the last two desktops it showed, the latest last.
    private var shown: [String: [UInt64]] = [:]

    public init() {}

    /// `display` shows the desktop `space` now. Fullscreen Spaces are not desktops and are
    /// not recorded.
    public mutating func record(display: String, space: UInt64) {
        let list = shown[display] ?? []
        guard list.last != space else { return }
        shown[display] = Array((list + [space]).suffix(2))
    }

    /// The desktop `display` showed before the one it shows now. `showing` is the Space it
    /// shows now: when that is a fullscreen Space, which was never recorded, the way back is
    /// the last desktop it showed.
    public func previous(display: String, showing: UInt64? = nil) -> UInt64? {
        guard let list = shown[display], let last = list.last else { return nil }
        if let showing, showing != last { return last }
        return list.dropLast().last
    }
}
