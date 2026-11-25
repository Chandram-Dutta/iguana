import AppKit
import IguanaCore
import SwiftUI

/// What the window switcher shows: the windows, what has been typed, and the row picked.
final class SwitcherModel: ObservableObject {
    @Published private(set) var windows: [Switcher.Window] = []
    @Published private(set) var icons: [WindowID: NSImage] = [:]
    @Published var query = "" {
        didSet { if query != oldValue { update() } }
    }
    @Published private(set) var matches: [Switcher.Match] = []
    @Published var selection = 0

    /// A row was picked, with return or a click.
    var onChoose: (WindowID) -> Void = { _ in }
    /// The list changed length, so the panel changes height.
    var onResize: () -> Void = {}

    /// Several desktops are in use, so each row says which one it is on.
    var showsDesktops: Bool { Set(windows.compactMap(\.desktop)).count > 1 }

    func load(_ windows: [Switcher.Window], icons: [WindowID: NSImage]) {
        self.windows = windows
        self.icons = icons
        query = ""
        update()
    }

    private func update() {
        matches = Switcher.filter(windows, query: query)
        selection = 0
        onResize()
    }

    /// Down (1) or up (-1) a row, round from the last row to the first.
    func move(_ step: Int) {
        guard !matches.isEmpty else { return }
        selection = (selection + step % matches.count + matches.count) % matches.count
    }

    func choose(_ index: Int? = nil) {
        let index = index ?? selection
        guard matches.indices.contains(index) else { return }
        onChoose(matches[index].window.id)
    }
}

/// A search field over a list of windows, on a pane of glass, as the tour's panels are.
struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    /// Solid even without Reduce Transparency, for the development snapshots.
    var solid = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static let width: CGFloat = 600
    static let rowHeight: CGFloat = 44
    static let visibleRows = 10
    private static let fieldHeight: CGFloat = 56
    private static let footerHeight: CGFloat = 34
    private static let listPadding: CGFloat = 7
    private static let rowSpacing: CGFloat = 2
    static let cornerRadius: CGFloat = 24

    /// The height of the panel for a list of `rows` windows. The rows have a fixed height, so the
    /// window can be given its size before SwiftUI lays it out.
    static func height(rows: Int) -> CGFloat {
        let shown = CGFloat(min(max(rows, 1), visibleRows))
        return fieldHeight + 1 + listPadding * 2 + shown * rowHeight + (shown - 1) * rowSpacing + 1 + footerHeight
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let solid = solid || reduceTransparency
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                SearchField(text: $model.query)
            }
            .padding(.horizontal, 20)
            .frame(height: Self.fieldHeight)

            Rectangle().fill(Theme.hairline).frame(height: 1)
            list
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .frame(width: Self.width, height: Self.height(rows: model.matches.count))
        .background {
            // With Reduce Transparency the panel is solid, so the text never sits on a busy desktop.
            if solid {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                // The desktop behind the panel, softened, under the glass. In the development
                // snapshots the desktop is a picture inside the window.
                VisualEffect(material: .popover, state: .active, blending: SnapshotStage.picture == nil ? .behindWindow : .withinWindow)
                    .clipShape(shape)
            }
        }
        .modifier(GlassUnlessSolid(shape: shape, solid: solid))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .tint(Theme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: model.matches.count > Self.visibleRows) {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(model.matches.enumerated()), id: \.element.window.id) { index, match in
                        SwitcherRow(match: match, icon: model.icons[match.window.id], selected: index == model.selection,
                                    showsDesktop: model.showsDesktops)
                            .frame(height: Self.rowHeight)
                            .id(match.window.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.choose(index) }
                    }
                    if model.matches.isEmpty {
                        Text(model.windows.isEmpty ? "No windows" : "No window matches “\(model.query)”")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                    }
                }
                .padding(Self.listPadding)
            }
            .onChange(of: model.selection) { _, index in
                guard model.matches.indices.contains(index) else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(model.matches[index].window.id) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(model.matches.count == 1 ? "1 window" : "\(model.matches.count) windows")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            hint(["↑", "↓"], "Choose")
            hint(["↩"], "Focus").padding(.leading, 10)
            hint(["esc"], "Close").padding(.leading, 10)
        }
        .padding(.horizontal, 18)
        .frame(height: Self.footerHeight)
        .accessibilityElement(children: .combine)
    }

    private func hint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(Theme.rounded(10.5, .medium))
                    .frame(minWidth: 11)
                    .padding(.horizontal, 4)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(Color.primary.opacity(0.075)))
            }
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.leading, 2)
        }
    }
}

/// Glass, unless the panel has to be solid.
private struct GlassUnlessSolid<S: InsettableShape>: ViewModifier {
    let shape: S
    let solid: Bool

    func body(content: Content) -> some View {
        if solid { content.clipShape(shape) } else { content.glass(shape) }
    }
}

/// One window: its app's icon, its title and app, and where it is when that is not in front of you.
private struct SwitcherRow: View {
    let match: Switcher.Match
    let icon: NSImage?
    let selected: Bool
    let showsDesktop: Bool

    private var window: Switcher.Window { match.window }

    /// Why the window is not on screen, when there is a reason worth saying.
    private var note: String? {
        switch window.visibility {
        case .onScreen: return nil
        case .minimised: return "Minimised"
        case .hidden: return "Hidden"
        case .otherStage: return "Other stage"
        // The desktop number says where it is, when it is known.
        case .elsewhere: return window.desktop == nil || !showsDesktop ? "Not on screen" : nil
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.secondary).padding(3)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                // A window without a title goes by its app's name.
                if window.title.isEmpty {
                    Self.marked(window.app, match.appHits, size: 13.5, weight: .medium)
                } else {
                    Self.marked(window.title, match.titleHits, size: 13.5, weight: .medium)
                    Self.marked(window.app, match.appHits, size: 11.5, weight: .regular, base: .secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)

            Spacer(minLength: 8)

            if let note {
                Text(note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(Capsule().fill(Theme.well))
            }
            if showsDesktop, let desktop = window.desktop {
                Text("Desktop \(desktop)")
                    .font(Theme.rounded(11.5, .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.accent.opacity(0.17))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([window.title.isEmpty ? window.app : "\(window.title), \(window.app)", note,
                             showsDesktop ? window.desktop.map { "desktop \($0)" } : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The text with the characters that matched in the accent colour.
    private static func marked(_ text: String, _ hits: [Int], size: CGFloat, weight: Font.Weight, base: Color = .primary) -> Text {
        let hit = Set(hits)
        var out = AttributedString()
        for (i, c) in text.enumerated() {
            var piece = AttributedString(String(c))
            piece.foregroundColor = hit.contains(i) ? Theme.accent : base
            piece.font = .system(size: size, weight: hit.contains(i) ? .bold : weight)
            out += piece
        }
        return Text(out)
    }
}

/// The search field. An AppKit field, so that it can be handed the keyboard the moment the
/// panel is shown; the keys that move through the list are taken before they reach it.
private struct SearchField: NSViewRepresentable {
    @SwiftUI.Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = SwitcherSearchField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 19, weight: .regular)
        field.font = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 19) } ?? font
        field.placeholderString = "Find a window"
        field.setAccessibilityLabel("Find a window")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: SwiftUI.Binding<String>
        init(text: SwiftUI.Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            text.wrappedValue = (notification.object as? NSTextField)?.stringValue ?? ""
        }
    }
}

/// Found by the panel, which gives it the keyboard whenever the panel becomes key.
final class SwitcherSearchField: NSTextField {}
