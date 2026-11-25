import Foundation

/// A mode is a second set of shortcuts, a `[mode.NAME]` table, that takes the place of
/// `[bindings]` until `mode default` brings those back.
extension Command {
    /// The argument of `mode`: the name of a mode, or `default`.
    static func modeName(_ args: [String]) throws -> String {
        guard args.count == 1, Config.isModeName(args[0]) else {
            throw CommandError("'mode' needs the name of a mode, or 'default'")
        }
        return args[0]
    }

    /// The modes this command switches to, inside a chain too.
    var modeNames: [String] {
        switch self {
        case .mode(let name): return [name]
        case .sequence(let commands): return commands.flatMap(\.modeNames)
        default: return []
        }
    }
}

extension Config {
    /// The name that stands for `[bindings]`. No `[mode.NAME]` table can have it.
    public static let defaultMode = "default"

    /// Lower-case letters, digits and `-`.
    static func isModeName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// Whether a set of live shortcuts still has a way out of the mode: a binding whose command
    /// is `mode`, or a chain that holds one, can switch back to `[bindings]`.
    public static func hasWayOut(_ bindings: [Binding]) -> Bool {
        bindings.contains { !$0.command.modeNames.isEmpty }
    }

    /// The shortcuts that are live in a mode, nil when there is no such mode. A mode that does
    /// not bind esc itself gets esc for `mode default`, so that there is always a way out.
    public func bindings(inMode name: String) -> [Binding]? {
        if name == Self.defaultMode { return bindings }
        guard var list = modes[name] else { return nil }
        if !list.contains(where: { $0.combo.modifiers.isEmpty && ["esc", "escape"].contains($0.combo.key) }) {
            list.append(Binding(combo: KeyCombo(modifiers: [], key: "esc"), command: .mode(Self.defaultMode),
                                source: "esc", commandText: "mode \(Self.defaultMode)"))
        }
        return list
    }

    /// Read the `[mode.NAME]` tables. Their entries are written like those of `[bindings]`,
    /// except that a key needs no modifier and nothing is merged: a mode has only the shortcuts
    /// it lists.
    static func loadModes(_ value: TOMLValue?, into c: inout Config, warnings: inout [String]) {
        if let value, value.tableValue == nil { warnings.append("modes are written as [mode.NAME] sections") }
        for name in (value?.tableValue ?? [:]).keys.sorted() {
            guard name != defaultMode else {
                warnings.append("[mode.default]: 'default' stands for [bindings] and cannot be a mode; ignoring this table")
                continue
            }
            guard isModeName(name) else {
                warnings.append("[mode.\(name)]: a mode name is lower-case letters, digits and -; ignoring this table")
                continue
            }
            guard let table = value?.tableValue?[name]?.tableValue else {
                warnings.append("mode.\(name) must be a table of shortcuts, written as [mode.\(name)]")
                continue
            }
            var list: [Binding] = []
            var seen = Set<KeyCombo>()
            for key in table.keys.sorted() {
                do {
                    let combo = try KeyCombo.parse(key, requireModifier: false)
                    guard seen.insert(combo).inserted else {
                        warnings.append("binding '\(key)' in [mode.\(name)] is defined twice")
                        continue
                    }
                    let value = table[key]
                    if value == .bool(false) || value?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty == true { continue }
                    guard let text = value?.stringValue else {
                        warnings.append("binding '\(key)' in [mode.\(name)]: the command must be a string (or \"\" to leave the key unbound)")
                        continue
                    }
                    let command = try Command.parse(text)
                    if case .subscribe = command {
                        warnings.append("binding '\(key)' in [mode.\(name)]: subscribe only works from the command line")
                        continue
                    }
                    list.append(Binding(combo: combo, command: command, source: key, commandText: text))
                } catch {
                    warnings.append("binding '\(key)' in [mode.\(name)]: \(error)")
                }
            }
            c.modes[name] = list
        }

        // A shortcut for a mode that is not there. It stays, and answers with an error.
        let tables = [("", c.bindings)] + c.modes.sorted { $0.key < $1.key }.map { (" in [mode.\($0.key)]", $0.value) }
        for (place, list) in tables {
            for b in list {
                for name in b.command.modeNames where name != defaultMode && c.modes[name] == nil {
                    warnings.append("binding '\(b.source)'\(place): no mode '\(name)' (there is no [mode.\(name)] table)")
                }
            }
        }
    }
}
