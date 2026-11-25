import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        // The system's own split view: it brings the floating glass sidebar, the room for the
        // window buttons inside it, and the bar across the top.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            Sidebar(model: model)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(224)
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch model.pane ?? .general {
                    case .general: GeneralPane(model: model)
                    case .layout: LayoutPane(model: model)
                    case .animation: MotionPane(model: model)
                    case .shortcuts: ShortcutsPane(model: model)
                    case .rules: FloatingPane(model: model)
                    case .hooks: HooksPane(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let notice = model.notice {
                    Text(notice)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glass(Capsule())
                        .padding(.bottom, 18)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            if model.notice == notice { model.notice = nil }
                        }
                }
            }
            .animation(.snappy(duration: 0.25), value: model.notice)
            // The split view takes a column's ideal size as the least it may have, and a pane's
            // ideal height is the whole of its scrolling content. Say what is really needed.
            .frame(minWidth: 560, idealWidth: 660, minHeight: 320, idealHeight: 560)
        }
        .tint(Theme.accent)
    }
}
