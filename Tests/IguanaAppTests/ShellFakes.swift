import Foundation
import IguanaCore
@testable import iguana

/// Stands in for the system's hot-key service. It registers nothing with the Mac, so a test
/// never takes a shortcut away from the Iguana that is running, and "presses" a key itself.
final class FakeShortcutService: ShortcutService {
    /// The shortcuts the system will not give, as when another app owns them.
    var refused: Set<String> = []
    /// What is registered now, in the order it was asked for.
    private(set) var registered: [KeyBinding] = []
    /// How many times everything was replaced.
    private(set) var passes = 0
    private var run: ((KeyBinding) -> Void)?

    /// Answers with the messages `Hotkeys` gives.
    func register(_ bindings: [KeyBinding], run: @escaping (KeyBinding) -> Void) -> [String] {
        passes += 1
        registered = []
        self.run = run
        var problems: [String] = []
        for binding in bindings {
            if Hotkeys.keyCodes[binding.combo.key] == nil {
                problems.append("binding '\(binding.source)': unknown key '\(binding.combo.key)'")
            } else if refused.contains(binding.source) {
                problems.append("binding '\(binding.source)': the system refused it (another app may own this shortcut)")
            } else {
                registered.append(binding)
            }
        }
        return problems
    }

    func unregisterAll() {
        registered = []
        run = nil
    }

    var keys: [String] { registered.map(\.source) }

    /// Press a shortcut that is registered. False when it is not.
    @discardableResult
    func press(_ keys: String) -> Bool {
        guard let binding = registered.first(where: { $0.source == keys }), let run else { return false }
        run(binding)
        return true
    }
}

enum ShellFakes {
    /// A newer release, as the update check would have found it.
    static func update(_ version: String = "9.9.9") -> UpdateCheck.Update {
        UpdateCheck.remembered(version: version, page: nil, running: "0.1.0")!
    }

    /// A config with two modes. `[mode.move]` has a key that no keyboard has.
    static let modes = """
    [bindings]
    option-r = "mode resize"

    [mode.resize]
    h = "resize shrink width"
    l = "resize grow width"
    return = "mode default"

    [mode.move]
    h = "move left"
    nokey = "move right"
    """
}
