import SwiftUI

/// A pane: its name and one line on what it is for go in the window's bar, an optional preview
/// stays put under it, and the settings are a grouped form, as in System Settings. The preview
/// stays in view while a slider is dragged.
struct PaneScaffold<Hero: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content

    private var hasHero: Bool { Hero.self != EmptyView.self }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasHero {
                hero
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Form { content }
                .formStyle(.grouped)
                // One background for the whole pane, so the preview above does not sit on a
                // different shade from the settings below it.
                .scrollContentBackground(.hidden)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
    }
}

extension PaneScaffold where Hero == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, hero: { EmptyView() }, content: content)
    }
}
