import AppKit
import IguanaCore

/// A user desktop (not a fullscreen Space), in the order Mission Control shows them.
struct Desktop {
    let id: UInt64
    let key: String
    let displayID: String
    /// 1-based, counted across all displays the way Mission Control names them ("Desktop 3").
    let number: Int

    static func all() -> [Desktop] {
        var result: [Desktop] = []
        for entry in Private.managedDisplaySpaces() {
            let display = entry["Display Identifier"] as? String ?? ""
            for space in (entry["Spaces"] as? [[String: Any]]) ?? [] where (space["type"] as? NSNumber)?.intValue == 0 {
                guard let id = (space["id64"] as? NSNumber)?.uint64Value ?? (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                let uuid = space["uuid"] as? String ?? ""
                result.append(Desktop(id: id, key: uuid.isEmpty ? "space-\(id)" : uuid, displayID: display, number: result.count + 1))
            }
        }
        return result
    }
}

/// One display together with the native Space it is showing right now.
struct DisplayInfo {
    let uuid: String
    /// The identifier the system's Space list uses for this display ("Main" when all displays share Spaces).
    let managedID: String
    let name: String
    /// Whole display, top-left coordinates.
    let frame: CGRect
    /// The display minus the menu bar and the Dock, top-left coordinates.
    let visibleFrame: CGRect
    let spaceID: UInt64
    /// Stable identifier of the Space, survives restarts.
    let spaceKey: String
    /// 1-based position among the user's desktops on this display, nil on a fullscreen Space.
    let spaceIndex: Int?
    let spaceCount: Int
    /// Desktops on the displays that come before this one. Mission Control numbers desktops across displays.
    let desktopOffset: Int
    let totalDesktops: Int
    let isMain: Bool
    /// From 1, left to right, as `DisplayOrder` numbers displays.
    var number = 0
    /// Stage Manager as it was when the display was looked at, for the room its strip takes.
    var stage = StageManager.State()

    /// Fullscreen apps, and anything else that is not a normal desktop, are left alone.
    var isDesktop: Bool { spaceIndex != nil }
    var treeKey: String { "\(spaceKey)|\(uuid)" }

    static func current() -> [DisplayInfo] {
        let managed = Private.managedDisplaySpaces()
        let main = NSScreen.screens.first
        var list: [DisplayInfo] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(number).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "display-\(number)"
            // With "Displays have separate Spaces" off there is a single entry that covers every display.
            let entry = managed.first { ($0["Display Identifier"] as? String) == uuid }
                ?? managed.first { ($0["Display Identifier"] as? String) == "Main" }
                ?? managed.first
            let current = entry?["Current Space"] as? [String: Any]
            let spaceID = (current?["id64"] as? NSNumber)?.uint64Value ?? (current?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
            let spaceUUID = current?["uuid"] as? String ?? ""
            let desktops = ((entry?["Spaces"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? NSNumber)?.intValue == 0 }
            let index = desktops.firstIndex { (($0["id64"] as? NSNumber)?.uint64Value ?? ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value) == spaceID }
            func desktopCount(_ e: [String: Any]) -> Int {
                ((e["Spaces"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? NSNumber)?.intValue == 0 }.count
            }
            let position = managed.firstIndex { ($0["Display Identifier"] as? String) == (entry?["Display Identifier"] as? String) } ?? 0
            let offset = managed.prefix(position).reduce(0) { $0 + desktopCount($1) }
            let total = managed.reduce(0) { $0 + desktopCount($1) }
            return DisplayInfo(
                uuid: uuid,
                managedID: entry?["Display Identifier"] as? String ?? uuid,
                name: screen.localizedName,
                frame: topLeftRect(screen.frame),
                visibleFrame: topLeftRect(screen.visibleFrame),
                spaceID: spaceID,
                spaceKey: spaceUUID.isEmpty ? "space-\(spaceID)" : spaceUUID,
                spaceIndex: index.map { $0 + 1 },
                spaceCount: desktops.count,
                desktopOffset: offset,
                totalDesktops: total,
                isMain: screen == main)
        }
        let stage = StageManager.current
        for (i, n) in DisplayOrder.numbers(list.map(\.frame)).enumerated() {
            list[i].number = n
            list[i].stage = stage
        }
        return list
    }

    /// What `[[display]]` and `[gaps]` come to on this display.
    func settings(_ config: Config) -> DisplaySettings.Effective {
        config.displaySettings(name: name, number: number)
    }

    /// The area windows are tiled into, zoomed ones too: the visible frame minus this display's
    /// outer gaps and the Stage Manager strip, and no wider than its `max-width`.
    func usableFrame(_ config: Config) -> CGRect {
        let s = settings(config)
        var r = visibleFrame
        r.origin.x += s.outer.left
        r.origin.y += s.outer.top
        r.size.width -= s.outer.left + s.outer.right
        r.size.height -= s.outer.top + s.outer.bottom
        let strip = stage.reservedWidth(config)
        if strip > 0, r.width - strip > 400 {
            // The strip of recent apps sits on the left, or on the right when the Dock is on the left.
            if !stage.stripOnRight { r.origin.x += strip }
            r.size.width -= strip
        }
        return DisplaySettings.narrow(r, maxWidth: s.maxWidth)
    }
}

enum StageManager {
    private static let prefs = UserDefaults(suiteName: "com.apple.WindowManager")
    private static let dock = UserDefaults(suiteName: "com.apple.dock")

    struct State: Equatable {
        var isOn = false
        /// "Show recent apps in Stage Manager" switched off: the strip only appears at the screen edge.
        var stripAutoHides = false
        var stripOnRight = false

        func reservedWidth(_ config: Config) -> CGFloat {
            switch config.stripReserve {
            case .off: return 0
            case .points(let p): return isOn ? p : 0
            case .auto: return isOn && !stripAutoHides ? config.stripWidth : 0
            }
        }
    }

    /// The user's settings as they are now.
    static var current: State {
        State(isOn: prefs?.bool(forKey: "GloballyEnabled") ?? false,
              stripAutoHides: prefs?.bool(forKey: "AutoHide") ?? false,
              stripOnRight: dock?.string(forKey: "orientation") == "left")
    }
}

/// What the window server says is on screen. Needs no permission and costs one call.
struct ScreenSnapshot {
    /// Normal-level windows that are ordered in right now, with their frames (top-left coordinates).
    var onScreen: [CGWindowID: CGRect] = [:]
    /// Front to back.
    var order: [CGWindowID] = []
    /// Every window that exists, on any Space.
    var all = Set<CGWindowID>()

    static func take() -> ScreenSnapshot {
        var snap = ScreenSnapshot()
        let everything = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in everything {
            if let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value { snap.all.insert(id) }
        }
        let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in visible {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            snap.onScreen[id] = rect
            snap.order.append(id)
            snap.all.insert(id)
        }
        return snap
    }
}

/// Accessibility and CoreGraphics measure from the top-left corner of the primary display with y
/// growing downwards. AppKit measures from its bottom-left corner with y growing upwards.
func topLeftRect(_ appKit: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: appKit.minX, y: primaryHeight - appKit.maxY, width: appKit.width, height: appKit.height)
}

func nearlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1.5) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}
