import AppKit
import ApplicationServices
import IguanaCore
import QuartzCore

/// Sends frames to one app's windows on that app's own queue.
///
/// Setting a window's frame is a round trip to the app that owns it, and a busy app answers
/// slowly. Giving every app its own queue means a slow one cannot hold up the others, and keeping
/// only the newest frame per window means a slow app skips frames instead of falling behind.
private final class AppWriter {
    struct Write {
        let element: UIElement
        let frame: CGRect
        let final: Bool
    }

    private let app: UIElement?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [CGWindowID: Write] = [:]
    private var draining = false
    // Touched only on `queue`.
    private var lastSize: [CGWindowID: CGSize] = [:]
    private var enhancedWasOn = false
    private var restoreGeneration = 0

    var landed: ((CGWindowID, CGRect, CGSize?) -> Void)?

    init(pid: pid_t, app: UIElement?) {
        self.app = app
        queue = DispatchQueue(label: "iguana.frames.\(pid)", qos: .userInteractive)
    }

    func submit(_ id: CGWindowID, _ write: Write) {
        lock.lock()
        pending[id] = write
        let start = !draining
        if start { draining = true }
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func drop(_ id: CGWindowID) {
        lock.lock()
        pending[id] = nil
        lock.unlock()
    }

    private func drain() {
        restoreGeneration += 1
        while true {
            lock.lock()
            let batch = pending
            pending.removeAll()
            if batch.isEmpty {
                draining = false
                lock.unlock()
                break
            }
            lock.unlock()

            // Apps that switch this on for assistive tools animate every resize themselves.
            if !enhancedWasOn, app?.bool("AXEnhancedUserInterface") == true {
                app?.set("AXEnhancedUserInterface", false)
                enhancedWasOn = true
            }
            for (id, w) in batch {
                w.element.setPosition(w.frame.origin)
                var sized = true
                if w.final || lastSize[id] != w.frame.size {
                    sized = w.element.setSize(w.frame.size)
                    lastSize[id] = w.frame.size
                }
                if w.final {
                    // Once more: a size change near a screen edge can nudge the window.
                    w.element.setPosition(w.frame.origin)
                    // A window that did not take the request says nothing about how small it can get.
                    let actual = sized ? w.element.size : nil
                    lastSize[id] = nil
                    DispatchQueue.main.async { self.landed?(id, w.frame, actual) }
                }
            }
        }
        guard enhancedWasOn else { return }
        // Put the app's setting back once things have been quiet for a moment, not between frames.
        let generation = restoreGeneration
        queue.asyncAfter(deadline: .now() + 0.4) {
            guard self.restoreGeneration == generation, self.enhancedWasOn else { return }
            self.app?.set("AXEnhancedUserInterface", true)
            self.enhancedWasOn = false
        }
    }
}

/// Moves windows to their new frames, either at once or as a short glide.
final class Animator: NSObject, FrameMover {
    private struct Motion {
        let pid: pid_t
        let element: UIElement
        let from: CGRect
        let to: CGRect
        let start: CFTimeInterval
        let duration: Double
        let easing: Easing
        var current: CGRect
    }

    private var motions: [CGWindowID: Motion] = [:]
    /// Final frames that have been sent but not yet confirmed by the app.
    private var landing: [CGWindowID: CGRect] = [:]
    private var writers: [pid_t: AppWriter] = [:]
    private var link: CADisplayLink?

    /// Called on the main thread when a window has been given its final frame, with the frame
    /// that was asked for and the size the window actually took.
    var onLanded: ((CGWindowID, CGRect, CGSize?) -> Void)?

    /// Where a window is on its way to, if it is being moved.
    func destination(of id: CGWindowID) -> CGRect? { motions[id]?.to ?? landing[id] }

    func isMoving(_ id: CGWindowID) -> Bool { motions[id] != nil || landing[id] != nil }

    /// On its way as a glide, as opposed to having been placed at once.
    func isGliding(_ id: CGWindowID) -> Bool { motions[id] != nil }

    var isIdle: Bool { motions.isEmpty && landing.isEmpty }

    /// Take a window to `to`. A window that is already gliding continues from where it is now.
    func move(_ id: CGWindowID, pid: pid_t, element: UIElement, app: UIElement?,
              from: CGRect, to: CGRect, duration: Double, easing: Easing) {
        let start = motions[id]?.current ?? from
        let writer = writer(pid, app)
        landing[id] = nil
        guard duration > 0 else {
            motions[id] = nil
            landing[id] = to
            writer.submit(id, .init(element: element, frame: to, final: true))
            return
        }
        motions[id] = Motion(pid: pid, element: element, from: start, to: to, start: CACurrentMediaTime(),
                             duration: duration, easing: easing, current: start)
        startLink()
    }

    /// Stop moving a window and leave it where it is (the user grabbed it, or it is gone).
    ///
    /// A frame that still waits on its app's queue is not sent. That goes for the last frame
    /// too, of a glide or of a window placed at once: sent after this, it would put the window
    /// back where the caller no longer wants it. Only a gliding window is known here by its
    /// app, so the frame is dropped from every queue; a window is on one of them at most.
    func cancel(_ id: CGWindowID) {
        motions[id] = nil
        landing[id] = nil
        for writer in writers.values { writer.drop(id) }
    }

    func forget(pid: pid_t) {
        for (id, m) in motions where m.pid == pid { motions[id] = nil }
        writers[pid] = nil
    }

    private func writer(_ pid: pid_t, _ app: UIElement?) -> AppWriter {
        if let w = writers[pid] { return w }
        let w = AppWriter(pid: pid, app: app)
        w.landed = { [weak self] id, frame, actual in
            guard let self else { return }
            // A newer move may have started since this frame was sent.
            guard self.landing[id] == frame, self.motions[id] == nil else { return }
            self.landing[id] = nil
            self.onLanded?(id, frame, actual)
        }
        writers[pid] = w
        return w
    }

    private func startLink() {
        guard link == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let l = screen.displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        for (id, m) in motions {
            guard let writer = writers[m.pid] else {
                motions[id] = nil
                continue
            }
            let t = (now - m.start) / m.duration
            if t >= 1 {
                motions[id] = nil
                landing[id] = m.to
                writer.submit(id, .init(element: m.element, frame: m.to, final: true))
                continue
            }
            let f = interpolate(m.from, m.to, m.easing.apply(t))
            let frame = CGRect(x: f.minX.rounded(), y: f.minY.rounded(), width: f.width.rounded(), height: f.height.rounded())
            guard frame != m.current else { continue }
            var next = m
            next.current = frame
            motions[id] = next
            writer.submit(id, .init(element: m.element, frame: frame, final: false))
        }
        if motions.isEmpty {
            link?.invalidate()
            link = nil
        }
    }
}
