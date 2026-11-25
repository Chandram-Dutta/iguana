import Foundation
import IguanaCore

/// What registers global shortcuts with the system. `Hotkeys` is the real one; a test has
/// one that registers nothing.
protocol ShortcutService: AnyObject {
    /// Replace all shortcuts. Returns a message for each binding that could not be registered.
    func register(_ bindings: [KeyBinding], run: @escaping (KeyBinding) -> Void) -> [String]
    func unregisterAll()
}

extension Hotkeys: ShortcutService {}

/// Keeps the system's shortcuts in step with the config and the mode. It remembers what could
/// not be registered and which shortcut came last, for `status`, the menu and the settings.
final class HotkeyRegistrar {
    private let wm: WindowManager
    private let makeService: () -> ShortcutService
    private let log: (String) -> Void
    private let now: () -> Date
    /// Runs the command of a shortcut that was pressed, and gives its reply.
    private let run: (KeyBinding) -> String
    private var service: ShortcutService?

    /// One message for each shortcut that is not in force, in any mode.
    private(set) var problems: [String] = []
    /// How many shortcuts the system took.
    private(set) var registered = 0
    private(set) var last: (keys: String, reply: String, at: Date)?

    init(wm: WindowManager, makeService: @escaping () -> ShortcutService = { Hotkeys() },
         log: @escaping (String) -> Void = Log.write, now: @escaping () -> Date = Date.init,
         run: @escaping (KeyBinding) -> String) {
        self.wm = wm
        self.makeService = makeService
        self.log = log
        self.now = now
        self.run = run
    }

    /// Making the service installs its handler with the system, so it waits for the app to
    /// have launched. Until then `register` does nothing.
    func start() {
        service = makeService()
    }

    /// Put the shortcuts of the mode in use in place of those registered now.
    func register() {
        guard let service else { return }
        let bindings = wm.config.bindings(inMode: wm.mode) ?? wm.config.bindings
        problems = service.register(bindings) { [weak self] binding in
            guard let self else { return }
            let reply = self.run(binding)
            self.last = (binding.source, reply, self.now())
            if reply.hasPrefix("error") { self.log("\(binding.source): \(reply)") }
        }
        registered = bindings.count - problems.count
        // A mode whose ways out all failed to register would leave no way back to [bindings]:
        // go back to the default shortcuts, which then register on the next pass.
        if wm.mode != Config.defaultMode {
            let failed = Set(problems.compactMap { problem -> String? in
                guard problem.hasPrefix("binding '"), let end = problem.dropFirst(9).firstIndex(of: "'") else { return nil }
                return String(problem.dropFirst(9).prefix(upTo: end))
            })
            if !Config.hasWayOut(bindings.filter { !failed.contains($0.source) }) {
                log("mode \(wm.mode): no key to leave it could be registered; back to the default shortcuts")
                wm.switchMode(Config.defaultMode)
            }
        }
        // A mistyped key in a mode would otherwise only come to light once the mode is on.
        for (name, list) in wm.config.modes.sorted(by: { $0.key < $1.key }) where name != wm.mode {
            for b in list where Hotkeys.keyCodes[b.combo.key] == nil {
                problems.append("binding '\(b.source)' in [mode.\(name)]: unknown key '\(b.combo.key)'")
            }
        }
        for p in problems { log(p) }
    }

    /// Release every shortcut, for example while the settings window records a new one.
    func unregisterAll() {
        service?.unregisterAll()
    }
}
