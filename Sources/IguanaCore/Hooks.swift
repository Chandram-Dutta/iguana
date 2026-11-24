import Foundation

/// The things a `[hooks]` command can be run for. The raw value is the key in the config file
/// and the value of `IGUANA_EVENT`.
public enum HookEvent: String, CaseIterable, Hashable {
    /// The desktop a display is showing changed, however the user got there.
    case desktopChanged = "desktop-changed"
    /// A different window has the focus, or none has it any more.
    case focusChanged = "focus-changed"
}

/// Decides when a hook is due. Iguana looks at the displays and the focus many times a second
/// while windows move; a hook runs only when what it reports is really different from last time.
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

    public enum Change: Equatable {
        /// The display with this identifier shows another desktop, or its desktop has another number.
        case desktop(display: String)
        /// The focus went to this window, or to no window.
        case focus(WindowID?)
    }

    /// A display that goes away for a moment (sleep, a cable) keeps its entry, so that coming
    /// back to the same desktop is not a change.
    private var seen: [String: Showing] = [:]
    private var focused: WindowID?
    private var started = false

    public init() {}

    /// Take a new look and say what changed since the last one. The first look changes
    /// nothing: it is where Iguana starts from. Desktops come before the focus, so a status bar
    /// hears about the new desktop before it hears about the window on it.
    public mutating func observe(showing: [Showing], focused now: WindowID?) -> [Change] {
        var changes: [Change] = []
        for display in showing where seen[display.display] != display {
            seen[display.display] = display
            if started { changes.append(.desktop(display: display.display)) }
        }
        if focused != now {
            focused = now
            if started { changes.append(.focus(now)) }
        }
        started = true
        return changes
    }
}

/// What a hook's command is given. The facts travel as environment variables and are never
/// written into the command: a window title is text that a web page can choose, and a shell
/// must only ever meet it as the value of a variable.
public enum HookEnvironment {
    /// Set for a window that got the focus. Left empty when the focus went to no window.
    public static let windowVariables = ["IGUANA_WINDOW_ID", "IGUANA_APP", "IGUANA_TITLE"]
    public static let allVariables = ["IGUANA_EVENT", "IGUANA_DESKTOP", "IGUANA_DISPLAY"] + windowVariables

    /// The longest value handed over, in bytes of UTF-8. The system limits the size of a
    /// program's environment, and a title of any length must not be able to stop a hook from starting.
    public static let longestValue = 4096

    /// The variables for one event. `desktop` is empty for a fullscreen Space. The window
    /// variables are there only for `focus-changed`.
    public static func variables(event: HookEvent, desktop: Int?, display: String?,
                                 window: (id: WindowID, app: String, title: String)? = nil) -> [String: String] {
        var v = [
            "IGUANA_EVENT": event.rawValue,
            "IGUANA_DESKTOP": desktop.map(String.init) ?? "",
            "IGUANA_DISPLAY": clean(display ?? ""),
        ]
        if event == .focusChanged {
            v["IGUANA_WINDOW_ID"] = window.map { String($0.id) } ?? ""
            v["IGUANA_APP"] = clean(window?.app ?? "")
            v["IGUANA_TITLE"] = clean(window?.title ?? "")
        }
        return v
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
