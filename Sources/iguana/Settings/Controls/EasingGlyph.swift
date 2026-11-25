import IguanaCore
import SwiftUI

/// The curve of a pacing option, so the choice can be seen as well as read.
struct EasingGlyph: View {
    let easing: Easing

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let steps = 24
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let point = CGPoint(x: 1 + (size.width - 2) * t, y: size.height - 1 - (size.height - 2) * easing.apply(t))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 18, height: 12)
        .accessibilityHidden(true)
    }
}

extension Easing {
    var title: String {
        switch self {
        case .easeOut: return "Ease out"
        case .easeInOut: return "Ease in and out"
        case .linear: return "Linear"
        }
    }

    /// The closest SwiftUI curve, for previews.
    func animation(duration: Double) -> Animation {
        switch self {
        case .linear: return .linear(duration: duration)
        case .easeOut: return .timingCurve(0.215, 0.61, 0.355, 1, duration: duration)
        case .easeInOut: return .timingCurve(0.645, 0.045, 0.355, 1, duration: duration)
        }
    }
}
