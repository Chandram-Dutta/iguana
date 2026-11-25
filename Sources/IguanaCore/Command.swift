import Foundation

public enum SpaceTarget: Equatable {
    case index(Int)
    case next
    case prev
    /// The desktop the display showed before the one it shows now.
    case recent
}

public struct CommandError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Command: Equatable {
    case focus(Direction)
    /// `focus --window ID`: focus the window the request names. Only a line from the command
    /// line can name a window, so a shortcut never runs this.
    case focusWindow
    /// Back to the window that had the focus before the focused one.
    case focusRecent
    case move(Direction)
    case join(Direction)
    /// `grow` is +1 or -1; `axis` nil means the nearest container that can change.
    case resize(axis: Orientation?, grow: Int)
    case flip
    case stack
    case balance
    /// Where the next window that opens beside the focused one goes; nil leaves it to `auto-split`.
    case split(Orientation?)
    /// Rebuild the layout of the focused window's desktop once.
    case arrange(Arrangement)
    case float
    case zoom
    case close
    /// Take back the last change to the layout of the active desktop, or make it again.
    case undo
    case redo
    /// An app by bundle id or by part of its name, as in rules: its window gets the focus, or
    /// the app is opened.
    case focusApp(String)
    case space(SpaceTarget)
    /// `follow` switches to the target Space along with the window.
    case moveToSpace(SpaceTarget, follow: Bool)
    case focusDisplay(DisplayTarget)
    case moveToDisplay(DisplayTarget)
    case pause
    case reload
    case listWindows
    case listSpaces
    case tree
    case status
    case settings
    case tour
    /// Ask now whether a newer Iguana has been released.
    case update
    case quit

    public static let usage = """
    focus left|right|up|down|recent  focus the window in that direction, or the one focused before
    focus --window ID               focus the window with that id (see list-windows)
    move left|right|up|down         move the focused window within the layout (or to the next display)
    join left|right|up|down         group the focused window with its neighbour
    resize grow|shrink [width|height]
    flip                            switch the focused container between side-by-side and top-to-bottom
    stack                           switch the focused container between tiles and a stack of overlapping windows
    balance                         give every window an equal share again
    split horizontal|vertical|auto  choose where the next new window opens: beside the focused one, below it, or as auto-split says
    arrange columns|rows|grid|main  rearrange every window on the focused window's desktop at once
    float                           toggle tiling for the focused window
    zoom                            toggle the focused window filling the Space
    close                           close the focused window
    undo                            take back the last change to the layout of this desktop
    redo                            make the last change that was undone again
    focus-app NAME|BUNDLE-ID        focus that app's window, or open the app
    space N|next|prev|recent        switch to a native Space, or back to the one before
    move-to-space N|next|prev|recent  take the focused window to a native Space and go with it
    move-to-space N|next|prev|recent --stay  send it there and stay where you are
    focus-display next|prev|N       focus a window on another display
    move-to-display next|prev|N     take the focused window to another display
    pause                           toggle tiling on or off
    reload                          reload the config file
    list-windows | list-spaces | tree | status    reports; add --json for a JSON document
    settings                        open the settings window
    tour                            show the welcome tour again
    update                          ask now whether a newer Iguana has been released
    quit
    """

    public static func parse(_ text: String) throws -> Command {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.lowercased() }
        guard let name = words.first else { throw CommandError("empty command") }
        let args = Array(words.dropFirst())

        func direction() throws -> Direction {
            guard args.count == 1, let d = Direction(rawValue: args[0]) else {
                throw CommandError("'\(name)' needs one of: left, right, up, down\(name == "focus" ? ", recent" : "")")
            }
            return d
        }
        func spaceTarget(allowFlags: Bool = false) throws -> SpaceTarget {
            let args = allowFlags ? args.filter { $0 != "--follow" && $0 != "--stay" } : args
            guard args.count == 1 else { throw CommandError("'\(name)' needs a Space number, 'next', 'prev' or 'recent'") }
            switch args[0] {
            case "next": return .next
            case "prev", "previous": return .prev
            case "recent": return .recent
            default:
                guard let n = Int(args[0]), n >= 1, n <= 16 else {
                    throw CommandError("'\(name)' needs a Space number from 1 to 16, 'next', 'prev' or 'recent'")
                }
                return .index(n)
            }
        }
        func choice<T>(_ options: [(String, T)]) throws -> T {
            guard args.count == 1, let match = options.first(where: { $0.0 == args[0] }) else {
                throw CommandError("'\(name)' needs one of: \(options.map(\.0).joined(separator: ", "))")
            }
            return match.1
        }
        func noArgs(_ c: Command) throws -> Command {
            guard args.isEmpty else { throw CommandError("'\(name)' takes no arguments") }
            return c
        }

        switch name {
        case "focus": return args == ["recent"] ? .focusRecent : .focus(try direction())
        case "move": return .move(try direction())
        case "join": return .join(try direction())
        case "resize":
            var axis: Orientation?
            var grow: Int?
            for a in args {
                switch a {
                case "grow": grow = 1
                case "shrink": grow = -1
                case "width": axis = .horizontal
                case "height": axis = .vertical
                default: throw CommandError("resize: unknown word '\(a)' (use grow|shrink and optionally width|height)")
                }
            }
            guard let grow else { throw CommandError("resize needs 'grow' or 'shrink'") }
            return .resize(axis: axis, grow: grow)
        case "flip": return try noArgs(.flip)
        case "stack": return try noArgs(.stack)
        case "balance": return try noArgs(.balance)
        case "split": return .split(try choice([("horizontal", .horizontal), ("vertical", .vertical), ("auto", nil)]))
        case "arrange": return .arrange(try choice(Arrangement.allCases.map { ($0.rawValue, $0) }))
        case "float": return try noArgs(.float)
        case "zoom": return try noArgs(.zoom)
        case "close": return try noArgs(.close)
        case "undo": return try noArgs(.undo)
        case "redo": return try noArgs(.redo)
        // An app's name can be several words. They were lower-cased above, which the matching ignores.
        case "focus-app": return .focusApp(try {
                guard !args.isEmpty else { throw CommandError("'focus-app' needs the name or bundle id of an app") }
                return args.joined(separator: " ")
            }())
        case "space": return .space(try spaceTarget())
        case "move-to-space": return .moveToSpace(try spaceTarget(allowFlags: true), follow: try {
                if args.contains("--stay") && args.contains("--follow") { throw CommandError("move-to-space: use --stay or --follow, not both") }
                return !args.contains("--stay")
            }())
        case "focus-display": return .focusDisplay(try DisplayTarget.parse(args, command: name))
        case "move-to-display": return .moveToDisplay(try DisplayTarget.parse(args, command: name))
        case "pause": return try noArgs(.pause)
        case "reload": return try noArgs(.reload)
        case "list-windows": return try noArgs(.listWindows)
        case "list-spaces": return try noArgs(.listSpaces)
        case "tree": return try noArgs(.tree)
        case "status": return try noArgs(.status)
        case "settings": return try noArgs(.settings)
        case "tour": return try noArgs(.tour)
        case "update": return try noArgs(.update)
        case "quit": return try noArgs(.quit)
        default: throw CommandError("unknown command '\(name)'")
        }
    }
}

public enum Modifier: String, CaseIterable, Hashable {
    case cmd, ctrl, option, shift
}

/// A keyboard shortcut such as `option-shift-h`.
public struct KeyCombo: Hashable {
    public let modifiers: Set<Modifier>
    public let key: String

    public static func parse(_ text: String) throws -> KeyCombo {
        let parts = text.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard var key = parts.last else { throw CommandError("empty key binding") }
        var modParts = parts.dropLast()
        // "option--" means Option and the minus key.
        if key.isEmpty, modParts.last == "" {
            key = "minus"
            modParts = modParts.dropLast()
        }
        guard !key.isEmpty else { throw CommandError("'\(text)': no key after the modifiers") }
        var mods = Set<Modifier>()
        for p in modParts {
            switch p {
            case "cmd", "command", "super": mods.insert(.cmd)
            case "ctrl", "control": mods.insert(.ctrl)
            case "option", "opt": mods.insert(.option)
            // The name other window managers give the same key. It is read, so that a config
            // brought over from one of them works, but Iguana itself never writes or shows it.
            case "alt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            default: throw CommandError("'\(text)': unknown modifier '\(p)' (use cmd, ctrl, option, shift)")
            }
        }
        guard !mods.isEmpty else { throw CommandError("'\(text)': a binding needs at least one modifier") }
        return KeyCombo(modifiers: mods, key: key)
    }
}
