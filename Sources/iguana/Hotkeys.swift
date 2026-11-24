import AppKit
import Carbon.HIToolbox
import IguanaCore

/// Global shortcuts through the system's own hot-key service. It needs no extra permission and
/// only swallows the exact combinations that are registered.
final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    static let keyCodes: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29, "rightbracket": 30, "o": 31, "u": 32,
        "leftbracket": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "quote": 39,
        "k": 40, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47,
        "tab": 48, "space": 49, "backtick": 50, "delete": 51, "esc": 53, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
    ]

    /// The config-file name of a key, for a shortcut recorded from the keyboard.
    static func keyName(for keyCode: Int) -> String? {
        let preferred = ["return", "esc"]
        let names = keyCodes.filter { $0.value == keyCode }.map(\.key)
        return names.first { preferred.contains($0) } ?? names.min { ($0.count, $0) < ($1.count, $1) }
    }

    /// Release every shortcut, for example while the settings window records a new one.
    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr else { return err }
            Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue().actions[id.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Replace all shortcuts. Returns a message for each binding that could not be registered.
    func register(_ bindings: [Binding], run: @escaping (Binding) -> Void) -> [String] {
        unregisterAll()
        var problems: [String] = []
        for (i, binding) in bindings.enumerated() {
            guard let code = Self.keyCodes[binding.combo.key] else {
                problems.append("binding '\(binding.source)': unknown key '\(binding.combo.key)'")
                continue
            }
            var mods: UInt32 = 0
            if binding.combo.modifiers.contains(.cmd) { mods |= UInt32(cmdKey) }
            if binding.combo.modifiers.contains(.shift) { mods |= UInt32(shiftKey) }
            if binding.combo.modifiers.contains(.alt) { mods |= UInt32(optionKey) }
            if binding.combo.modifiers.contains(.ctrl) { mods |= UInt32(controlKey) }
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), mods, EventHotKeyID(signature: OSType(0x4947_4E41), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else {
                problems.append("binding '\(binding.source)': the system refused it (another app may own this shortcut)")
                continue
            }
            refs.append(ref)
            actions[id] = { run(binding) }
        }
        return problems
    }
}
