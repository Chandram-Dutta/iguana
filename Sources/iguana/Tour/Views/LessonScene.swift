import IguanaCore
import SwiftUI

// MARK: Lessons

struct LessonScene: View {
    @ObservedObject var model: TourModel
    let size: CGSize
    let k: CGFloat
    let safeTop: CGFloat
    @Environment(\.tourPalette) private var palette

    private var words: (title: String, detail: String) {
        switch model.step {
        case .open: return ("Open a few windows", "Each one finds its own place.")
        case .focus: return ("Move between them", "Hold the key and steer to the window that calls.")
        case .move: return ("Take the window along", "Add shift, and bring it to the outline.")
        case .resize: return ("Give it more room", "Grow the window until it fills the outline.")
        case .stack:
            return model.stackGoal == .press
                ? ("Stack a crowded column", "One key, and the window fills the outline.")
                : ("Reach the ones behind", "A strip of each stays in view. Steer to the one that calls.")
        case .desktops:
            return model.desktopGoal == .jump
                ? ("Jump to another desktop", "Each desktop has its number.")
                : ("Bring a window with you", "Add shift, and it travels to the desktop you name.")
        default: return ("", "")
        }
    }

    var body: some View {
        let stageHeight = min(size.height * 0.48, size.width * 0.9 / 2600 * 1000)
        VStack(spacing: 0) {
            Spacer().frame(height: safeTop + 60 * k)
            ZStack {
                Headline(title: words.title, detail: words.detail, k: k)
                    .id(words.title)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)),
                                            removal: .opacity.combined(with: .offset(y: -14))))
            }
            .frame(height: 96 * k)
            Spacer().frame(height: 26 * k)
            StageView(model: model, height: stageHeight)
                .frame(width: size.width, height: stageHeight)
            Spacer().frame(height: 34 * k)
            ZStack {
                if model.step == .open {
                    Prompt(label: "New window", enabled: model.windowCount < TourModel.windowsToOpen, action: model.primary)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                } else if let keys = model.deck {
                    KeyDeck(model: model, keys: keys)
                        .id(keys.modifiers)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
            .frame(height: 74)
            Spacer(minLength: 0)
            LessonProgress(model: model)
                .padding(.bottom, 30 * k)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LessonProgress: View {
    @ObservedObject var model: TourModel
    @Environment(\.tourPalette) private var palette

    var body: some View {
        let lessons = model.lessons
        ZStack {
            HStack(spacing: 7) {
                ForEach(lessons, id: \.self) { lesson in
                    Capsule()
                        .fill(lesson == model.step ? palette.ink : (lesson < model.step ? palette.ink.opacity(0.42) : palette.ink.opacity(0.14)))
                        .frame(width: lesson == model.step ? 22 : 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \((lessons.firstIndex(of: model.step) ?? 0) + 1) of \(lessons.count)")

            HStack {
                Spacer()
                Button("Skip this step", action: model.skipStep)
                    .buttonStyle(.plain)
                    .font(Theme.rounded(12.5, .medium))
                    .foregroundStyle(palette.faint)
                    .padding(.trailing, 34)
            }
        }
    }
}
