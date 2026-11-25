import SwiftUI

/// A choice between a few options, shown side by side: the system's segmented picker.
struct Segmented<Value: Hashable>: View {
    /// What is being chosen, for VoiceOver.
    let name: String
    let options: [Value]
    let selection: Value
    let onSelect: (Value) -> Void
    let title: (Value) -> String

    var body: some View {
        Picker(name, selection: SwiftUI.Binding(get: { selection }, set: onSelect)) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
