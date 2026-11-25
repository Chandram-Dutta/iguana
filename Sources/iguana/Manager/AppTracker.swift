import ApplicationServices
import Foundation

/// One app whose windows are watched.
final class AppState {
    let app: RunningApp
    let element: UIElement
    var observer: AppObserver?
    var attempts = 0

    init(app: RunningApp, element: UIElement) {
        self.app = app
        self.element = element
    }
}

/// Knows the apps that have windows to tile, and listens to what each says about them.
final class AppTracker {
    private let system: WindowSystem
    private let scheduler: Scheduler
    private(set) var apps: [pid_t: AppState] = [:]

    /// An app said something about one of its elements.
    var onNotification: ((UIElement, String) -> Void)?
    /// An app that was not ready to be observed has been asked again. It may have windows
    /// that were missed the first time.
    var onRetry: ((pid_t) -> Void)?

    init(system: WindowSystem, scheduler: Scheduler) {
        self.system = system
        self.scheduler = scheduler
    }

    /// Start watching an app. False for one that is watched already, and for one that has no
    /// windows of its own to tile.
    @discardableResult
    func track(_ app: RunningApp) -> Bool {
        let pid = app.processIdentifier
        guard pid > 0, pid != getpid(), app.isRegular, apps[pid] == nil else { return false }
        let state = AppState(app: app, element: system.element(forApp: pid))
        apps[pid] = state
        observe(state)
        return true
    }

    /// False for an app that was not watched.
    @discardableResult
    func untrack(_ pid: pid_t) -> Bool {
        guard let state = apps.removeValue(forKey: pid) else { return false }
        state.observer?.stop()
        return true
    }

    private static let notifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]

    private func observe(_ state: AppState) {
        let pid = state.app.processIdentifier
        if state.observer == nil {
            state.observer = system.observer(for: pid) { [weak self] element, notification in
                self?.onNotification?(element, notification)
            }
        }
        var complete = state.observer != nil
        if let o = state.observer {
            for n in Self.notifications where !o.watch(n, on: state.element) { complete = false }
        }
        // A freshly launched app often is not ready to be observed yet.
        if !complete, state.attempts < 10 {
            state.attempts += 1
            scheduler.after(0.5) { [weak self, weak state] in
                guard let self, let state, self.apps[pid] === state else { return }
                self.observe(state)
                self.onRetry?(pid)
            }
        }
    }
}
