import CoreGraphics
@testable import IguanaCore

/// The screen that `TreeTests`, `LayoutTests` and `StackTests` lay their trees out on. The
/// frames they expect are all worked out for 1000 by 600, so it is written down once.
protocol TestScreen {}

extension TestScreen {
    var screen: CGRect { CGRect(x: 0, y: 0, width: 1000, height: 600) }

    func frames(_ t: Tree, visible: Set<WindowID>? = nil, gap: CGFloat = 0, mins: [WindowID: CGSize] = [:], peek: CGFloat = 32) -> [WindowID: CGRect] {
        computeLayout(t, in: screen, gap: gap, visible: visible, minSizes: mins, peek: peek)
    }
}
