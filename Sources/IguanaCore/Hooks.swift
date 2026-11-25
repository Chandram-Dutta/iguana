import Foundation

/// The things a `[hooks]` command can be run for. The raw value is the key in the config file
/// and the value of `IGUANA_EVENT`.
public enum HookEvent: String, CaseIterable, Hashable {
    /// The desktop a display is showing changed, however the user got there.
    case desktopChanged = "desktop-changed"
    /// A different window has the focus, or none has it any more.
    case focusChanged = "focus-changed"
    /// A standard window, tiled or floating, opened. The windows there were at Iguana's first look are not new.
    case windowCreated = "window-created"
    /// A standard window Iguana knew went away for good.
    case windowClosed = "window-closed"
    /// A desktop on screen is arranged differently: other windows in its layout, another shape
    /// or other proportions, a stack, a zoomed window, or tiling resumed.
    case layoutChanged = "layout-changed"
    /// Tiling was paused or resumed.
    case pauseChanged = "pause-changed"

    /// What the event means, in one line. The settings window shows it beside the event.
    public var summary: String {
        switch self {
        case .desktopChanged: return "The desktop a display is showing changed."
        case .focusChanged: return "A different window has the focus, or none has it any more."
        case .windowCreated: return "A window opened."
        case .windowClosed: return "A window closed. Minimising or hiding one does not count."
        case .layoutChanged: return "The windows of a desktop on screen were arranged differently."
        case .pauseChanged: return "Tiling was paused or resumed."
        }
    }

    /// The events that are about one window, and give its id, app and title.
    var isAboutAWindow: Bool { self == .focusChanged || self == .windowCreated || self == .windowClosed }
}

/// Decides when a hook is due. Iguana looks at the displays, the windows and the focus many
/// times a second while windows move; a hook runs only when what it reports is really different
/// from last time.
public struct HookTracker {
    /// What one display is showing.
    public struct Showing: Equatable {
        /// An identifier of the display that stays the same while it is connected.
        public var display: String
        /// An identifier of the Space being shown.
        public var space: String
        /// Its number as Mission Control counts desktops, nil for a fullscreen Space.
        public var desktop: Int?

        public init(display: String, space: String, desktop: Int?) {
            self.display = display
            self.space = space
            self.desktop = desktop
        }
    }

    /// A standard window, as a hook is told about it.
    public struct Window: Equatable {
        public var id: WindowID
        public var app: String
        public var title: String
        /// Nil when it cannot be told, and on a fullscreen Space.
        public var desktop: Int?
        public var display: String?

        public init(id: WindowID, app: String, title: String, desktop: Int?, display: String?) {
            self.id = id
            self.app = app
            self.title = title
            self.desktop = desktop
            self.display = display
        }
    }

    /// How a desktop on screen is arranged. Frames are not in here, so a window gliding to its
    /// tile is no change; any other difference between two of these is one.
    public struct Arrangement: Equatable {
        public var layout: NodeSnapshot
        /// The windows of the layout that are on screen.
        public var visible: Set<WindowID>
        /// The window that fills the desktop, if one does.
        public var zoomed: WindowID?

        public init(layout: NodeSnapshot, visible: Set<WindowID>, zoomed: WindowID?) {
            self.layout = layout
            self.visible = visible
            self.zoomed = zoomed
        }
    }

    /// One look at everything a hook can be run for.
    public struct Look {
        public var showing: [Showing]
        public var focused: WindowID?
        public var paused: Bool
        /// Every window the system has, on any desktop: on screen, minimised or hidden.
        public var existing: Set<WindowID>
        /// The standard windows Iguana knows, tiled or floating, wherever they are.
        public var standard: Set<WindowID>
        /// How the desktop each display is showing is arranged, by display. A display showing
        /// a fullscreen Space has no arrangement.
        public var arrangements: [String: Arrangement]

        public init(showing: [Showing], focused: WindowID?, paused: Bool = false, existing: Set<WindowID> = [],
                    standard: Set<WindowID> = [], arrangements: [String: Arrangement] = [:]) {
            self.showing = showing
            self.focused = focused
            self.paused = paused
            self.existing = existing
            self.standard = standard
            self.arrangements = arrangements
        }
    }

    public enum Change: Equatable {
        /// The display with this identifier shows another desktop, or its desktop has another number.
        case desktop(display: String)
        /// Tiling was paused (true) or resumed (false).
        case paused(Bool)
        /// A standard window that opened since the first look.
        case created(Window)
        /// A standard window that is gone, as it was last seen.
        case closed(Window)
        /// The desktop this display is showing is arranged differently.
        case layout(display: String)
        /// The focus went to this window, or to no window.
        case focus(WindowID?)
    }

    /// A display that goes away for a moment (sleep, a cable) keeps its entry, so that coming
    /// back to the same desktop is not a change.
    private var seen: [String: Showing] = [:]
    private var focused: WindowID?
    private var paused = false
    /// The windows the system had at the first look. Some are on other desktops and only become
    /// known when their desktop is shown; they were open before Iguana, so they are not new.
    private var old = Set<WindowID>()
    /// Every standard window known, as last seen, so that one that closes can still be described.
    private var windows: [WindowID: Window] = [:]
    /// The last arrangement of each desktop, by Space and display.
    private var arranged: [String: Arrangement] = [:]
    /// Tiling has resumed, and the desktops on screen have not been looked at since.
    private var resumed = false
    private var started = false

    public init() {}

    /// A look at the desktops and the focus only.
    public mutating func observe(showing: [Showing], focused now: WindowID?) -> [Change] {
        observe(Look(showing: showing, focused: now)) { Window(id: $0, app: "", title: "", desktop: nil, display: nil) }
    }

    /// Take a new look and say what changed since the last one. The first look changes
    /// nothing: it is where Iguana starts from. Desktops come first and the focus last, so a
    /// status bar hears about the new desktop, and about a window that opened there, before it
    /// hears which window has the focus.
    ///
    /// `describe` is asked about each standard window once, the first time it is seen.
    public mutating func observe(_ look: Look, describe: (WindowID) -> Window) -> [Change] {
        var changes: [Change] = []
        let started = started
        func report(_ change: Change) { if started { changes.append(change) } }

        for display in look.showing where seen[display.display] != display {
            seen[display.display] = display
            report(.desktop(display: display.display))
        }
        if paused != look.paused {
            paused = look.paused
            report(.paused(paused))
            resumed = !paused
        }

        if !started { old = look.existing }
        for id in look.standard.sorted() where windows[id] == nil {
            let window = describe(id)
            windows[id] = window
            if !old.contains(id) { report(.created(window)) }
        }
        // A minimised or hidden window, or one on another desktop, still exists.
        for id in windows.keys.sorted() where !look.existing.contains(id) {
            if let window = windows.removeValue(forKey: id) { report(.closed(window)) }
        }

        // Nothing is arranged while tiling is paused. Resuming arranges every desktop on screen again.
        if !paused {
            for display in look.showing {
                guard let arrangement = look.arrangements[display.display] else { continue }
                let before = arranged.updateValue(arrangement, forKey: display.space + "|" + display.display)
                // A desktop seen for the first time is where it starts from.
                if resumed || (before != nil && before != arrangement) { report(.layout(display: display.display)) }
            }
            resumed = false
        }

        if focused != look.focused {
            focused = look.focused
            report(.focus(look.focused))
        }
        self.started = true
        return changes
    }

    /// What a known window is like now. A window that closes is described as it was last seen.
    public mutating func remember(_ window: Window) {
        if windows[window.id] != nil { windows[window.id] = window }
    }
}

/// What a hook's command is given. The facts travel as environment variables and are never
/// written into the command: a window title is text that a web page can choose, and a shell
/// must only ever meet it as the value of a variable.
public enum HookEnvironment {
    /// Set for a window that got the focus, opened or closed. Left empty when the focus went to no window.
    public static let windowVariables = ["IGUANA_WINDOW_ID", "IGUANA_APP", "IGUANA_TITLE"]
    public static let allVariables = ["IGUANA_EVENT", "IGUANA_DESKTOP", "IGUANA_DISPLAY"] + windowVariables + ["IGUANA_PAUSED"]

    /// The longest value handed over, in bytes of UTF-8. The system limits the size of a
    /// program's environment, and a title of any length must not be able to stop a hook from starting.
    public static let longestValue = 4096

    /// The variables for one event. `desktop` is empty for a fullscreen Space. The window
    /// variables are there only for the events about a window. `pause-changed` is about all of
    /// Iguana: it has `IGUANA_PAUSED`, and no desktop or display.
    public static func variables(event: HookEvent, desktop: Int? = nil, display: String? = nil,
                                 window: (id: WindowID, app: String, title: String)? = nil, paused: Bool = false) -> [String: String] {
        var v = ["IGUANA_EVENT": event.rawValue]
        if event == .pauseChanged {
            v["IGUANA_PAUSED"] = paused ? "true" : "false"
            return v
        }
        v["IGUANA_DESKTOP"] = desktop.map(String.init) ?? ""
        v["IGUANA_DISPLAY"] = clean(display ?? "")
        if event.isAboutAWindow {
            v["IGUANA_WINDOW_ID"] = window.map { String($0.id) } ?? ""
            v["IGUANA_APP"] = clean(window?.app ?? "")
            v["IGUANA_TITLE"] = clean(window?.title ?? "")
        }
        return v
    }

    /// The variables for an event about a window the tracker knows, where it is or last was.
    public static func variables(event: HookEvent, window w: HookTracker.Window) -> [String: String] {
        variables(event: event, desktop: w.desktop, display: w.display, window: (w.id, w.app, w.title))
    }

    /// Text as an environment variable can carry it: no NUL character, which would end the
    /// value early, and no longer than `longestValue`.
    public static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars where scalar.value != 0 {
            bytes += UTF8.width(scalar)
            if bytes > longestValue { break }
            out.append(scalar)
        }
        return String(out)
    }

    /// The environment of the command: what Iguana itself was started with, and the event's
    /// variables on top. Variables of an event that does not apply are taken out, so nothing
    /// is left over from wherever Iguana was started.
    public static func merged(inherited: [String: String], variables: [String: String]) -> [String: String] {
        var env = inherited
        for name in allVariables { env[name] = nil }
        env.merge(variables) { _, new in new }
        env["PATH"] = path(inherited["PATH"])
        return env
    }

    /// An app opened from the Finder has a short `PATH` without Homebrew's folders, where status
    /// bars such as SketchyBar are installed. They are added at the end, so nothing that was
    /// already found is found somewhere else.
    public static func path(_ inherited: String?) -> String {
        var folders = (inherited ?? "").split(separator: ":").map(String.init)
        if folders.isEmpty { folders = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !folders.contains(extra) { folders.append(extra) }
        return folders.joined(separator: ":")
    }
}
