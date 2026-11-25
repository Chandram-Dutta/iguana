import AppKit
import SwiftUI

struct Sidebar: View {
    @ObservedObject var model: SettingsModel

    private var status: String {
        if model.needsPermission { return "Needs permission" }
        if model.paused { return "Paused" }
        return model.tiledWindowCount == 1 ? "Tiling 1 window" : "Tiling \(model.tiledWindowCount) windows"
    }

    var body: some View {
        List(selection: $model.pane) {
            ForEach(Pane.allCases) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
        }
        .listStyle(.sidebar)
        .frame(minHeight: 320, idealHeight: 560)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                if let logo = Bundle.main.image(forResource: "logo") {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .accessibilityHidden(true)
                } else {
                    // Running outside the app bundle (tests, `swift run`): draw the simple mark.
                    IguanaMark().frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Iguana").font(Theme.rounded(16, .bold))
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                model.setPaused(!model.paused)
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(model.paused ? Theme.attention : Theme.accent).frame(width: 7, height: 7)
                    Text(model.paused ? "Tiling is paused" : "Tiling is on").font(.system(size: 12))
                    Spacer()
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(Capsule().fill(Theme.well))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(model.paused ? "Start tiling again" : "Leave every window where it is until you resume")
            .accessibilityLabel(model.paused ? "Resume tiling" : "Pause tiling")
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}
