import AppKit
import ApplicationServices
import IguanaCore

extension WindowManager {
    /// A window has been given its final frame. If it came out bigger than asked, it may have a
    /// minimum size. A busy window can also answer with the size it had before, so ask once
    /// more and believe only what it still says a moment later.
    func landed(_ id: CGWindowID, asked: CGRect, actual: CGSize?) {
        if let placed = placing.removeValue(forKey: id), placed.asked == asked {
            return placedLanded(id, asked: asked, actual: actual, fit: placed.fit)
        }
        guard let w = windows[id], let actual, !zoomed.values.contains(id) else { return }
        let known = w.minSize ?? .zero
        guard (actual.width > asked.width + 2 && actual.width > known.width)
            || (actual.height > asked.height + 2 && actual.height > known.height) else { return }
        w.element.setSize(asked.size)
        scheduler.after(0.15) { [weak self] in self?.confirmMinimum(id, asked: asked) }
    }

    /// The window still is bigger than it was asked to be: remember that and lay out again around it.
    func confirmMinimum(_ id: CGWindowID, asked: CGRect) {
        guard let w = windows[id], !zoomed.values.contains(id), !mover.isMoving(id), drag?.id != id,
              let wanted = w.lastSetFrame, nearlyEqual(wanted, asked), let actual = w.element.size else { return }
        var m = w.minSize ?? .zero
        var changed = false
        if actual.width > asked.width + 2, actual.width > m.width {
            m.width = actual.width
            changed = true
        }
        if actual.height > asked.height + 2, actual.height > m.height {
            m.height = actual.height
            changed = true
        }
        if changed {
            w.minSize = m
            scheduleRefresh(after: 0)
        }
    }

    /// A minimum size is something Iguana once saw, and what it saw can be wrong or out of date.
    /// When the user asks for a change of sizes, every window that the layout holds at its minimum
    /// is asked for the size it would have without one. One that takes it had no such minimum.
    func recheckMinimums(in tree: Tree, key: String) {
        guard let display = displays.first(where: { $0.isDesktop && $0.treeKey == key }) else { return }
        recheckMinimums(in: tree, key: key, visible: lastVisible.filter { tree.contains($0) },
                        usable: display.usableFrame(config), gap: display.settings(config).inner)
    }

    func recheckMinimums(in tree: Tree, key: String, visible ids: Set<CGWindowID>, usable: CGRect, gap: Double, only: Set<CGWindowID>? = nil) {
        let free = computeLayout(tree, in: usable, gap: gap, visible: ids, peek: config.stackPeek)
        for (id, slot) in free where only?.contains(id) != false {
            guard let w = windows[id], var m = w.minSize, zoomed[key] != id else { continue }
            let wide = m.width > slot.width + 2, tall = m.height > slot.height + 2
            guard wide || tall, let now = w.element.size else { continue }
            let ask = CGSize(width: wide ? slot.width : now.width, height: tall ? slot.height : now.height)
            guard w.element.setSize(ask), let got = w.element.size else { continue }
            if wide { m.width = got.width > ask.width + 2 ? got.width : 0 }
            if tall { m.height = got.height > ask.height + 2 ? got.height : 0 }
            w.minSize = m.width > 0 || m.height > 0 ? m : nil
        }
    }
}
