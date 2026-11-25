import SwiftUI

/// A short message among the settings: something to fix, or something to know.
struct Callout<Trailing: View>: View {
    enum Kind { case attention, good, note }
    let kind: Kind
    let text: String
    @ViewBuilder var trailing: Trailing

    private var symbol: String {
        switch kind {
        case .attention: return "exclamationmark.triangle.fill"
        case .good: return "checkmark.circle.fill"
        case .note: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .attention: return Theme.attention
        case .good: return Theme.accent
        case .note: return .secondary
        }
    }

    var body: some View {
        // A row of the form it sits in: the symbol's colour says what kind of message it is.
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension Callout where Trailing == EmptyView {
    init(_ kind: Kind, _ text: String) {
        self.init(kind: kind, text: text) { EmptyView() }
    }
}
