import AppKit
import IguanaCore

/// The icons of the apps whose windows are drawn, in the menu bar item's menu and in the
/// switcher. Asking the system for an icon is slow enough to be worth doing once per app.
final class AppIcons {
    private var cache: [pid_t: NSImage] = [:]
    private let find: (pid_t) -> NSImage?
    private var observer: NSObjectProtocol?

    /// `find` asks the system. A test answers in its place.
    init(find: @escaping (pid_t) -> NSImage? = { NSRunningApplication(processIdentifier: $0)?.icon }) {
        self.find = find
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// The icon of each window's app. An app without one is asked again next time.
    func icons(for owners: [WindowID: pid_t]) -> [WindowID: NSImage] {
        var icons: [WindowID: NSImage] = [:]
        for (id, pid) in owners {
            if cache[pid] == nil { cache[pid] = find(pid) }
            icons[id] = cache[pid]
        }
        return icons
    }

    func forget(_ pid: pid_t) {
        cache[pid] = nil
    }

    /// A pid is reused quickly; its cached icon could be another app's next time.
    func forgetAppsThatQuit() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            if let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier {
                self?.forget(pid)
            }
        }
    }
}
