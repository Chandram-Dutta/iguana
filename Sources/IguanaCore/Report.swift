import CoreGraphics
import Foundation

/// The four reports as JSON documents: `list-windows --json`, `list-spaces --json`,
/// `tree --json` and `status --json`. These types are the shape of the documents; a status bar
/// or a script reads them, so a key is never renamed or removed, only added.
///
/// Every key is lower camel case. Something that is not known is `null` and its key stays, so
/// a script can rely on the shape. The one exception is the layout tree, where a container and
/// a window are different things with different keys.
public enum Report {
    /// The text of a document: pretty-printed with sorted keys, so that the same facts always
    /// give the same text.
    public static func encode<T: Encodable>(_ document: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // These documents hold only strings, numbers and booleans, which always encode.
        guard let data = try? encoder.encode(document) else { return "error: could not write the report as JSON" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A value that is written as `null` when there is none, instead of its key being left out.
    @propertyWrapper
    public struct Nullable<Value: Codable & Equatable>: Codable, Equatable {
        public var wrappedValue: Value?
        public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
        }
    }

    /// A rectangle in points, measured from the top-left corner of the main display.
    public struct Frame: Codable, Equatable {
        public var x, y, width, height: Double

        public init(_ rect: CGRect) {
            x = Double(rect.minX)
            y = Double(rect.minY)
            width = Double(rect.width)
            height = Double(rect.height)
        }
    }

    // MARK: list-windows

    /// How Iguana treats a window, in the words `list-windows` prints.
    public enum State: String, Codable, Equatable {
        case tiled, floating, unmanaged
        case notOnScreen

        /// The same decision `list-windows` makes for its text. `inLayout` is a window that
        /// has a tile on screen right now.
        public static func of(inLayout: Bool, onScreen: Bool, floating: Bool, tileable: Bool) -> State {
            if inLayout { return .tiled }
            if !onScreen { return .notOnScreen }
            if floating { return .floating }
            return tileable ? .tiled : .unmanaged
        }
    }

    public struct Window: Codable, Equatable {
        public var id: WindowID
        public var app: String
        @Nullable public var bundleId: String?
        public var title: String
        public var state: State
        public var focused: Bool
        /// The desktop the window is on, numbered as Mission Control numbers them.
        @Nullable public var desktop: Int?
        /// The name of the display the window is on.
        @Nullable public var display: String?
        /// Where the window is, when it is on screen.
        @Nullable public var frame: Frame?

        public init(id: WindowID, app: String, bundleId: String?, title: String, state: State, focused: Bool,
                    desktop: Int?, display: String?, frame: Frame?) {
            self.id = id
            self.app = app
            self.bundleId = bundleId
            self.title = title
            self.state = state
            self.focused = focused
            self.desktop = desktop
            self.display = display
            self.frame = frame
        }
    }

    public struct Windows: Codable, Equatable {
        public var windows: [Window]
        public init(windows: [Window]) { self.windows = windows }
    }

    // MARK: list-spaces

    public struct Desktop: Codable, Equatable {
        /// Counted across all displays, the way Mission Control numbers desktops.
        public var number: Int
        @Nullable public var display: String?
        /// A display is showing this desktop right now.
        public var showing: Bool
        /// The desktop the user is on: the one being shown on the display that has the focus.
        public var active: Bool
        /// The windows Iguana has seen on this desktop.
        public var windows: [WindowID]

        public init(number: Int, display: String?, showing: Bool, active: Bool, windows: [WindowID]) {
            self.number = number
            self.display = display
            self.showing = showing
            self.active = active
            self.windows = windows
        }
    }

    public struct Display: Codable, Equatable {
        public var name: String
        /// The display's number, from 1, as `DisplayOrder` counts them and `focus-display N` names them.
        public var number: Int
        /// The desktop this display is showing, `null` while it shows a fullscreen Space.
        @Nullable public var desktop: Int?
        /// How many desktops this display has.
        public var desktopCount: Int
        public var main: Bool

        public init(name: String, number: Int, desktop: Int?, desktopCount: Int, main: Bool) {
            self.name = name
            self.number = number
            self.desktop = desktop
            self.desktopCount = desktopCount
            self.main = main
        }
    }

    public struct Spaces: Codable, Equatable {
        public var desktops: [Desktop]
        public var displays: [Display]

        public init(desktops: [Desktop], displays: [Display]) {
            self.desktops = desktops
            self.displays = displays
        }
    }

    // MARK: tree

    /// One entry of a layout: a container that splits its area among its children, or a window.
    /// A container has `orientation`, `stacked` and `children`; a window has `id`, `onScreen`,
    /// and `app` and `title` once Iguana has looked at it.
    public struct Node: Codable, Equatable {
        public enum Kind: String, Codable, Equatable {
            case container, window
        }

        public var type: Kind
        /// Share of the parent's area, relative to the weights beside it.
        public var weight: Double
        public var orientation: Orientation?
        /// Whether the container's windows overlap as a stack instead of sharing its area.
        public var stacked: Bool?
        public var children: [Node]?
        public var id: WindowID?
        public var app: String?
        public var title: String?
        public var onScreen: Bool?

        /// A saved layout with each window described by `window`, which answers nil for a
        /// window that is in the layout but has not been looked at yet.
        public init(_ layout: NodeSnapshot, window: (WindowID) -> (app: String, title: String, onScreen: Bool)?) {
            weight = layout.weight
            if let id = layout.window {
                type = .window
                self.id = id
                let known = window(id)
                app = known?.app
                title = known?.title
                onScreen = known?.onScreen ?? false
            } else {
                type = .container
                orientation = layout.orientation
                stacked = layout.stacked ?? false
                children = (layout.children ?? []).map { Node($0, window: window) }
            }
        }
    }

    public struct Layout: Codable, Equatable {
        public var display: String
        /// `null` while the display shows a fullscreen Space, which Iguana does not manage.
        @Nullable public var desktop: Int?
        /// `null` when there is no tiled window here.
        @Nullable public var layout: Node?

        public init(display: String, desktop: Int?, layout: Node?) {
            self.display = display
            self.desktop = desktop
            self.layout = layout
        }
    }

    public struct Trees: Codable, Equatable {
        /// The layout of the desktop each display is showing.
        public var displays: [Layout]
        /// How many desktops that are not being shown have a remembered layout.
        public var otherLayouts: Int

        public init(displays: [Layout], otherLayouts: Int) {
            self.displays = displays
            self.otherLayouts = otherLayouts
        }
    }

    // MARK: status

    public struct WindowCounts: Codable, Equatable {
        /// Tiled and on screen.
        public var tiled: Int
        public var known: Int
        /// Apps being watched.
        public var apps: Int

        public init(tiled: Int, known: Int, apps: Int) {
            self.tiled = tiled
            self.known = known
            self.apps = apps
        }
    }

    public struct StageManager: Codable, Equatable {
        public var on: Bool
        /// Points left free for the strip of recent apps.
        public var reserved: Double

        public init(on: Bool, reserved: Double) {
            self.on = on
            self.reserved = reserved
        }
    }

    public struct Shortcuts: Codable, Equatable {
        public var active: Int
        /// Shortcuts that could not be registered, one line each.
        public var warnings: [String]

        public init(active: Int, warnings: [String]) {
            self.active = active
            self.warnings = warnings
        }
    }

    public struct LastShortcut: Codable, Equatable {
        public var keys: String
        public var secondsAgo: Int
        public var reply: String

        public init(keys: String, secondsAgo: Int, reply: String) {
            self.keys = keys
            self.secondsAgo = secondsAgo
            self.reply = reply
        }
    }

    /// A newer release than the one that is running.
    public struct Update: Codable, Equatable {
        public var version: String
        /// The page of that release.
        public var url: String

        public init(version: String, url: String) {
            self.version = version
            self.url = url
        }
    }

    public struct Status: Codable, Equatable {
        public var version: String
        /// Whether Iguana has the Accessibility permission.
        public var permission: Bool
        public var paused: Bool
        /// Where the config file lives, whether or not there is one.
        public var configPath: String
        /// False means the built-in defaults are in use.
        public var configExists: Bool
        public var configWarnings: [String]
        public var windows: WindowCounts
        public var stageManager: StageManager
        public var displays: [Display]
        public var shortcuts: Shortcuts
        /// The welcome tour is on screen.
        public var tourShowing: Bool
        /// `null` until a shortcut has been received.
        @Nullable public var lastShortcut: LastShortcut?
        /// `null` when no newer release is known: there is none, Iguana has not looked yet, or
        /// looking is switched off.
        @Nullable public var update: Update?

        public init(version: String, permission: Bool, paused: Bool, configPath: String, configExists: Bool,
                    configWarnings: [String], windows: WindowCounts, stageManager: StageManager, displays: [Display],
                    shortcuts: Shortcuts, tourShowing: Bool, lastShortcut: LastShortcut?, update: Update? = nil) {
            self.version = version
            self.permission = permission
            self.paused = paused
            self.configPath = configPath
            self.configExists = configExists
            self.configWarnings = configWarnings
            self.windows = windows
            self.stageManager = stageManager
            self.displays = displays
            self.shortcuts = shortcuts
            self.tourShowing = tourShowing
            self.lastShortcut = lastShortcut
            self.update = update
        }
    }
}

/// A line from the command line: a command, whether `--json` asked for its answer as a JSON
/// document, and the window `--window` named for it to act on. Shortcuts are parsed without
/// this, because a shortcut has nowhere to print an answer and no window to name.
public struct Request: Equatable {
    public var command: Command
    public var json: Bool
    /// The window the command acts on instead of the focused one.
    public var window: WindowID?

    public init(command: Command, json: Bool = false, window: WindowID? = nil) {
        self.command = command
        self.json = json
        self.window = window
    }
}

extension Command {
    /// The commands that can answer with a JSON document.
    public var hasJSONForm: Bool {
        switch self {
        case .listWindows, .listSpaces, .tree, .status: return true
        default: return false
        }
    }

    /// The commands that act on one window, and so can be told which one with `--window`.
    public var acceptsWindow: Bool {
        switch self {
        case .focusWindow, .move, .join, .resize, .flip, .stack, .balance, .float, .zoom, .close, .moveToSpace: return true
        default: return false
        }
    }

    /// Reads a line from the command line. The flags can come anywhere in it.
    public static func parseRequest(_ text: String) throws -> Request {
        var words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let json = words.contains { $0.lowercased() == "--json" }
        words.removeAll { $0.lowercased() == "--json" }
        var window: WindowID?
        if let i = words.firstIndex(where: { $0.lowercased() == "--window" }) {
            // A decimal number, as list-windows prints it.
            guard i + 1 < words.count, words[i + 1].allSatisfy({ $0.isASCII && $0.isNumber }), let id = WindowID(words[i + 1]) else {
                throw CommandError("--window needs a window id (see iguana list-windows)")
            }
            words.removeSubrange(i...(i + 1))
            guard !words.contains(where: { $0.lowercased() == "--window" }) else { throw CommandError("give --window only once") }
            window = id
        }
        if json, window != nil { throw CommandError("use --json or --window, not both") }

        let name = words.first?.lowercased() ?? ""
        // `focus` alone is not a command; with a window named it means that window.
        let command: Command = try window != nil && words.count == 1 && name == "focus" ? .focusWindow : parse(words.joined(separator: " "))
        if json, !command.hasJSONForm {
            throw CommandError("'\(name)' has no --json form (list-windows, list-spaces, tree and status have one)")
        }
        if window != nil, !command.acceptsWindow {
            if case .focus = command { throw CommandError("'focus --window ID' takes no direction: it focuses that window") }
            throw CommandError("'\(name)' does not take --window")
        }
        return Request(command: command, json: json, window: window)
    }
}
