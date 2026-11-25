import SwiftUI

/// A slider with its value written beside it.
struct ValueSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: SwiftUI.Binding(get: { value }, set: { onChange(($0 / step).rounded() * step) }), in: range)
                .controlSize(.small)
                .frame(width: 190)
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
            Text(format(value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }
}
