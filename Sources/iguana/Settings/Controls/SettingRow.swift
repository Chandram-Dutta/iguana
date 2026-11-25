import SwiftUI

/// One setting: what it is on the left, the control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            control
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}
