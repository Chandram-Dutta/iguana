import Foundation

public struct Edges: Equatable {
    public var top, left, bottom, right: Double
    public init(all v: Double) {
        top = v
        left = v
        bottom = v
        right = v
    }
}

/// How much room to leave for the Stage Manager strip of recent apps.
public enum StripReserve: Equatable {
    /// Leave room only while Stage Manager is on and its strip is set to stay visible.
    case auto
    case off
    case points(Double)
}

public struct Rule: Equatable {
    /// Bundle identifier (exact) or part of the app name, case-insensitive.
    public var app: String?
    /// Regular expression matched against the window title.
    public var title: String?
    public var float: Bool

    public init(app: String?, title: String?, float: Bool = true) {
        self.app = app
        self.title = title
        self.float = float
    }

    public func matches(bundleID: String?, appName: String?, title: String?) -> Bool {
        if let app {
            let a = app.lowercased()
            let idMatch = bundleID?.lowercased() == a
            let nameMatch = appName?.lowercased().contains(a) ?? false
            if !idMatch && !nameMatch { return false }
        }
        if let pattern = self.title {
            guard let title, title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        }
        return app != nil || self.title != nil
    }
}

public struct Binding: Equatable {
    public let combo: KeyCombo
    public let command: Command
    /// The shortcut as written, for example `option-shift-h`.
    public let source: String
    /// The command as written, for example `move left`.
    public let commandText: String
}

/// How a window's motion is paced between its old frame and its new one.
public enum Easing: String, CaseIterable, Equatable {
    case linear
    case easeOut = "ease-out"
    case easeInOut = "ease-in-out"

    /// Progress 0...1 in, eased progress 0...1 out.
    public func apply(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}

/// Which desktops the menu bar icon draws.
public enum MenuBarDesktops: String, CaseIterable, Equatable {
    /// Only the desktop being used.
    case current
    /// Every desktop that has windows, and the one being used.
    case occupied
    case all
}

public struct Config: Equatable {
    public var gapInner: Double = 8
    public var gapOuter = Edges(all: 8)
    /// New windows split the focused window along its longer side instead of widening the row.
    public var autoSplit = true
    public var resizeStep = 0.05
    public var mouseFollowsFocus = false
    public var stripReserve = StripReserve.auto
    public var stripWidth: Double = 150
    public var menuBarDesktops = MenuBarDesktops.current
    /// A click on a desktop drawn in the menu bar goes to it, instead of opening the menu.
    public var menuBarClickSwitches = false
    /// Windows glide to their new place instead of jumping.
    public var animate = true
    /// Seconds a window takes to reach its new place.
    public var animationDuration = 0.16
    public var animationEasing = Easing.easeOut
    public var bindings: [Binding] = []
    public var rules: [Rule] = []

    public static let defaultText = """
    #:schema ./iguana.schema.json
    # Iguana configuration. Changes are picked up as soon as the file is saved.
    # Every setting is optional: anything left out keeps its built-in value.

    [gaps]
    inner = 8
    outer = 8            # or: outer = { top = 8, left = 8, bottom = 8, right = 8 }

    [layout]
    auto-split = true    # new windows split the focused window along its longer side
    resize-step = 0.05   # share of the container that one `resize` step moves
    mouse-follows-focus = false

    [animation]
    enabled = true       # windows glide to their new place instead of jumping
    duration = 0.16      # seconds, 0.05 to 1
    easing = "ease-out"  # "linear", "ease-out" or "ease-in-out"

    [stage-manager]
    # "auto" leaves room for the strip of recent apps while Stage Manager shows it.
    # Use true to always leave room, false to tile underneath it, or a number of points to reserve.
    reserve-strip = "auto"
    strip-width = 150

    [menu-bar]
    # Which desktops the menu bar icon draws: "current" for the one you are on, "all" for every
    # desktop side by side, or "occupied" to leave out the empty ones.
    desktops = "current"
    # With more than one desktop drawn, true makes a click on one of them go to it. A click on
    # the desktop you are on still opens the menu.
    click-to-switch = false

    # Keys: letters, digits, minus, equal, comma, period, slash, semicolon, quote, backslash,
    # backtick, leftbracket, rightbracket, space, tab, return, delete, esc, left, right, up, down,
    # f1-f12. Modifiers: cmd, ctrl, option, shift.
    # A shortcut you leave out keeps its built-in command. Set one to "" to switch it off.
    [bindings]
    option-h = "focus left"
    option-j = "focus down"
    option-k = "focus up"
    option-l = "focus right"
    option-shift-h = "move left"
    option-shift-j = "move down"
    option-shift-k = "move up"
    option-shift-l = "move right"
    option-ctrl-h = "join left"
    option-ctrl-j = "join down"
    option-ctrl-k = "join up"
    option-ctrl-l = "join right"
    option-minus = "resize shrink"
    option-equal = "resize grow"
    option-slash = "flip"
    option-f = "zoom"
    option-shift-space = "float"
    option-shift-b = "balance"
    option-1 = "space 1"
    option-2 = "space 2"
    option-3 = "space 3"
    option-4 = "space 4"
    option-5 = "space 5"
    option-6 = "space 6"
    option-7 = "space 7"
    option-8 = "space 8"
    option-9 = "space 9"
    # Add --stay (for example "move-to-space 1 --stay") to send the window away and stay where you are.
    option-shift-1 = "move-to-space 1"
    option-shift-2 = "move-to-space 2"
    option-shift-3 = "move-to-space 3"
    option-shift-4 = "move-to-space 4"
    option-shift-5 = "move-to-space 5"
    option-shift-6 = "move-to-space 6"
    option-shift-7 = "move-to-space 7"
    option-shift-8 = "move-to-space 8"
    option-shift-9 = "move-to-space 9"

    # Windows that should stay floating. `app` is a bundle id or part of the app name,
    # `title` is a regular expression. Dialogs, sheets and fixed-size windows float on their own.
    # Once the file has any [[rule]], the built-in rules below no longer apply by themselves.
    # The first rule that matches a window decides, so an exception (float = false) goes above
    # the general rule it is an exception to.
    [[rule]]
    app = "com.apple.systempreferences"
    float = true

    [[rule]]
    app = "com.apple.calculator"
    float = true

    [[rule]]
    app = "com.apple.ActivityMonitor"
    float = true
    """

    /// The built-in settings: what you get with no config file, and what every file starts from.
    public static let `default`: Config = {
        // The built-in text is covered by a test, so this cannot fail at run time.
        (try? load(defaultText, over: Config()).config) ?? Config()
    }()

    /// Parse a config file on top of the built-in settings. Problems that do not stop the file
    /// from loading come back as warnings.
    public static func load(_ text: String) throws -> (config: Config, warnings: [String]) {
        try load(text, over: .default)
    }

    static func load(_ text: String, over base: Config) throws -> (config: Config, warnings: [String]) {
        let doc = try TOML.parse(text)
        var c = base
        var warnings: [String] = []

        func number(_ v: TOMLValue?, _ name: String, min: Double, max: Double) -> Double? {
            guard let v else { return nil }
            guard let d = v.doubleValue, d >= min, d <= max else {
                warnings.append("\(name) must be a number from \(Int(min)) to \(Int(max)); keeping the default")
                return nil
            }
            return d
        }
        func flag(_ v: TOMLValue?, _ name: String) -> Bool? {
            guard let v else { return nil }
            guard let b = v.boolValue else {
                warnings.append("\(name) must be true or false; keeping the default")
                return nil
            }
            return b
        }
        func checkKeys(_ table: [String: TOMLValue], _ known: [String], _ section: String) {
            for k in table.keys.sorted() where !known.contains(k) {
                warnings.append("unknown key '\(k)' in \(section)")
            }
        }

        checkKeys(doc, ["gaps", "layout", "animation", "stage-manager", "menu-bar", "bindings", "rule"], "the config file")

        if let gaps = doc["gaps"]?.tableValue {
            checkKeys(gaps, ["inner", "outer"], "[gaps]")
            if let v = number(gaps["inner"], "gaps.inner", min: 0, max: 200) { c.gapInner = v }
            if let outer = gaps["outer"] {
                if let t = outer.tableValue {
                    checkKeys(t, ["top", "left", "bottom", "right"], "gaps.outer")
                    if let v = number(t["top"], "gaps.outer.top", min: 0, max: 500) { c.gapOuter.top = v }
                    if let v = number(t["left"], "gaps.outer.left", min: 0, max: 500) { c.gapOuter.left = v }
                    if let v = number(t["bottom"], "gaps.outer.bottom", min: 0, max: 500) { c.gapOuter.bottom = v }
                    if let v = number(t["right"], "gaps.outer.right", min: 0, max: 500) { c.gapOuter.right = v }
                } else if let v = number(outer, "gaps.outer", min: 0, max: 500) {
                    c.gapOuter = Edges(all: v)
                }
            }
        }

        if let layout = doc["layout"]?.tableValue {
            checkKeys(layout, ["auto-split", "resize-step", "mouse-follows-focus"], "[layout]")
            if let v = flag(layout["auto-split"], "layout.auto-split") { c.autoSplit = v }
            if let v = flag(layout["mouse-follows-focus"], "layout.mouse-follows-focus") { c.mouseFollowsFocus = v }
            if let v = layout["resize-step"] {
                if let d = v.doubleValue, d > 0, d <= 0.5 {
                    c.resizeStep = d
                } else {
                    warnings.append("layout.resize-step must be between 0 and 0.5; keeping the default")
                }
            }
        }

        if let animation = doc["animation"]?.tableValue {
            checkKeys(animation, ["enabled", "duration", "easing"], "[animation]")
            if let v = flag(animation["enabled"], "animation.enabled") { c.animate = v }
            if let v = animation["duration"] {
                if let d = v.doubleValue, d >= 0.05, d <= 1 {
                    c.animationDuration = d
                } else {
                    warnings.append("animation.duration must be between 0.05 and 1 (seconds); keeping the default")
                }
            }
            if let v = animation["easing"] {
                if let e = v.stringValue.flatMap(Easing.init(rawValue:)) {
                    c.animationEasing = e
                } else {
                    warnings.append("animation.easing must be one of: \(Easing.allCases.map(\.rawValue).joined(separator: ", "))")
                }
            }
        }

        if let sm = doc["stage-manager"]?.tableValue {
            checkKeys(sm, ["reserve-strip", "strip-width"], "[stage-manager]")
            if let v = number(sm["strip-width"], "stage-manager.strip-width", min: 0, max: 600) { c.stripWidth = v }
            if let v = sm["reserve-strip"] {
                if v.stringValue == "auto" {
                    c.stripReserve = .auto
                } else if let b = v.boolValue {
                    c.stripReserve = b ? .points(c.stripWidth) : .off
                } else if let d = v.doubleValue, d >= 0, d <= 600 {
                    c.stripReserve = d == 0 ? .off : .points(d)
                } else {
                    warnings.append("stage-manager.reserve-strip must be \"auto\", true, false or a number of points")
                }
            }
        }

        if let bar = doc["menu-bar"]?.tableValue {
            checkKeys(bar, ["desktops", "click-to-switch"], "[menu-bar]")
            if let v = flag(bar["click-to-switch"], "menu-bar.click-to-switch") { c.menuBarClickSwitches = v }
            if let v = bar["desktops"] {
                if let choice = v.stringValue.flatMap(MenuBarDesktops.init(rawValue:)) {
                    c.menuBarDesktops = choice
                } else {
                    warnings.append("menu-bar.desktops must be \"current\", \"all\" or \"occupied\"; keeping the default")
                }
            }
        }

        if let bindings = doc["bindings"]?.tableValue {
            // Entries are laid over the built-in shortcuts one by one.
            var merged: [KeyCombo: Binding] = [:]
            for b in c.bindings { merged[b.combo] = b }
            var seen = Set<KeyCombo>()
            for key in bindings.keys.sorted() {
                do {
                    let combo = try KeyCombo.parse(key)
                    guard seen.insert(combo).inserted else {
                        warnings.append("binding '\(key)' is defined twice")
                        continue
                    }
                    let value = bindings[key]
                    if value == .bool(false) || value?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                        merged[combo] = nil
                        continue
                    }
                    guard let text = value?.stringValue else {
                        warnings.append("binding '\(key)': the command must be a string (or \"\" to switch the shortcut off)")
                        continue
                    }
                    merged[combo] = Binding(combo: combo, command: try Command.parse(text), source: key, commandText: text)
                } catch {
                    warnings.append("binding '\(key)': \(error)")
                }
            }
            c.bindings = merged.values.sorted { $0.source < $1.source }
        }

        if let rules = doc["rule"] {
            guard let list = rules.arrayValue else {
                warnings.append("rules are written as [[rule]] sections")
                return (c, warnings)
            }
            // A file that lists rules lists all of them.
            c.rules = []
            for (i, entry) in list.enumerated() {
                guard let t = entry.tableValue else { continue }
                checkKeys(t, ["app", "title", "float"], "rule \(i + 1)")
                let rule = Rule(app: t["app"]?.stringValue, title: t["title"]?.stringValue, float: t["float"]?.boolValue ?? true)
                if rule.app == nil && rule.title == nil {
                    warnings.append("rule \(i + 1) needs 'app' or 'title'")
                    continue
                }
                if let pattern = rule.title, (try? NSRegularExpression(pattern: pattern)) == nil {
                    warnings.append("rule \(i + 1): title is not a valid regular expression")
                    continue
                }
                c.rules.append(rule)
            }
        }

        return (c, warnings)
    }
}
