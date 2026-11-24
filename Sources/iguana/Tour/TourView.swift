import AppKit
import IguanaCore
import SwiftUI

/// The colours of the tour, taken from the animal: its greens for the windows, its outline for
/// the type, and one sun-warmed amber. The fifth window colour, a blue-green, is for the window
/// that opens in the stack lesson, so that the amber one is still the only one of its kind.
struct TourPalette {
    let top, bottom, glowA, glowB: Color
    let ink, soft, faint: Color
    let panel, panelLine: Color
    let tiles: [Color]
    let key, keyLip, keyLine: Color
    let lit, litInk: Color
    /// How much of the tour's own colour lies over the blurred desktop.
    let wash: Double

    private static func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: alpha)
    }

    static func make(_ scheme: ColorScheme) -> TourPalette {
        if scheme == .dark {
            let ink = hex(0xEAF6DA)
            return TourPalette(
                top: hex(0x06191A), bottom: hex(0x0C3B2E), glowA: hex(0x18A67E, 0.34), glowB: hex(0x8FD43F, 0.13),
                ink: ink, soft: ink.opacity(0.66), faint: ink.opacity(0.34),
                panel: Color.white.opacity(0.05), panelLine: Color.white.opacity(0.10),
                tiles: [hex(0x18A67E), hex(0x8FD43F), hex(0xD5F0A0), hex(0xF2B84B), hex(0x62C6CF)],
                key: Color.white.opacity(0.11), keyLip: Color.black.opacity(0.45), keyLine: Color.white.opacity(0.14),
                lit: hex(0x8FD43F), litInk: hex(0x0C3B2E), wash: 0.5)
        }
        let ink = hex(0x0C3B2E)
        return TourPalette(
            top: hex(0xF5F4EC), bottom: hex(0xE2F0CC), glowA: hex(0xC3E86E, 0.62), glowB: hex(0x74CB70, 0.30),
            ink: ink, soft: ink.opacity(0.64), faint: ink.opacity(0.32),
            panel: ink.opacity(0.05), panelLine: ink.opacity(0.09),
            tiles: [hex(0x18A67E), hex(0x8FD43F), hex(0x0F6A52), hex(0xF2B84B), hex(0x62C6CF)],
            key: .white, keyLip: ink.opacity(0.26), keyLine: ink.opacity(0.13),
            lit: hex(0x18A67E), litInk: .white, wash: 0.5)
    }

    func tile(_ index: Int) -> Color { tiles[((index % tiles.count) + tiles.count) % tiles.count] }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = TourPalette.make(.light)
}

extension EnvironmentValues {
    var tourPalette: TourPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// The whole tour, filling the screen.
struct TourView: View {
    @ObservedObject var model: TourModel
    /// Room for the camera housing at the top of the screen.
    var safeTop: CGFloat = 0
    /// Where the tour shrinks to when it ends: the menu bar item.
    var irisPoint: CGPoint?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = TourPalette.make(scheme)
        GeometryReader { geometry in
            let size = geometry.size
            let k = min(max(size.height / 956, 0.78), 1.3)
            ZStack {
            // The desktop stays in sight behind the tour, softened. It is outside the mask below
            // because the system's blur cannot be cut to a shape; it fades instead.
            WindowBackdrop(material: .fullScreenUI)
                .opacity(model.closing ? 0 : 1)
            ZStack {
                Backdrop(still: reduceMotion)

                Group {
                    switch model.step {
                    case .hello:
                        HelloScene(model: model, size: size, k: k)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    case .permission:
                        PermissionScene(model: model, k: k)
                            .transition(.opacity.combined(with: .offset(y: 16)))
                    case .done:
                        DoneScene(model: model, size: size, k: k)
                            .transition(.opacity.combined(with: .offset(y: 16)))
                    default:
                        LessonScene(model: model, size: size, k: k, safeTop: safeTop)
                            .transition(.opacity)
                    }
                }

                TourLogo()
                    .frame(width: logoFrame(size, k).width, height: logoFrame(size, k).width)
                    .position(x: logoFrame(size, k).midX, y: logoFrame(size, k).midY)
                    .shadow(color: .black.opacity(model.step == .hello ? 0.16 : 0.08), radius: model.step == .hello ? 26 : 8, y: model.step == .hello ? 14 : 3)

                TopBar(model: model)
                    .padding(.top, safeTop + 22)
                    .padding(.horizontal, 30)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: size.width, height: size.height)
            .opacity(reduceMotion && model.closing ? 0 : 1)
            .mask {
                // The tour ends by drawing itself into the menu bar item, where Iguana lives.
                let reach = hypot(size.width, size.height)
                let centre = irisPoint ?? CGPoint(x: size.width - 120, y: 12)
                let diameter = reduceMotion ? reach * 2.4 : (model.closing ? 0 : reach * 2.4)
                Circle()
                    .frame(width: diameter, height: diameter)
                    .position(model.closing && !reduceMotion ? centre : CGPoint(x: size.width / 2, y: size.height / 2))
            }
            }
        }
        .environment(\.tourPalette, palette)
        .foregroundStyle(palette.ink)
        .ignoresSafeArea()
    }

    /// The mark is large at the greeting, then keeps a corner of the screen.
    private func logoFrame(_ size: CGSize, _ k: CGFloat) -> CGRect {
        switch model.step {
        case .hello:
            let side = 172 * k
            return CGRect(x: size.width / 2 - side / 2, y: size.height * 0.33 - side / 2, width: side, height: side)
        case .done:
            let side = 96 * k
            return CGRect(x: size.width / 2 - side / 2, y: size.height * 0.225 - side / 2, width: side, height: side)
        default:
            return CGRect(x: 34, y: safeTop + 18, width: 42, height: 42)
        }
    }
}

// MARK: Backdrop

/// Daylight through leaves: a pale ground with a few slow patches of green light.
private struct Backdrop: View {
    let still: Bool
    @Environment(\.tourPalette) private var palette
    @State private var drift = false

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                LinearGradient(colors: [palette.top.opacity(palette.wash), palette.bottom.opacity(palette.wash)], startPoint: .top, endPoint: .bottom)
                patch(palette.glowA, side: w * 0.95)
                    .position(x: w * (drift ? 0.20 : 0.10), y: h * (drift ? 0.96 : 0.82))
                patch(palette.glowB, side: w * 0.80)
                    .position(x: w * (drift ? 0.84 : 0.94), y: h * (drift ? 0.10 : 0.26))
                patch(palette.glowA.opacity(0.55), side: w * 0.55)
                    .position(x: w * (drift ? 0.70 : 0.58), y: h * (drift ? 1.02 : 0.92))
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .onAppear {
            guard !still else { return }
            withAnimation(.easeInOut(duration: 13).repeatForever(autoreverses: true)) { drift = true }
        }
        .accessibilityHidden(true)
    }

    private func patch(_ color: Color, side: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: side / 2))
            .frame(width: side, height: side)
            .scaleEffect(x: 1, y: 0.82)
    }
}

/// The logo from the app bundle, or the drawn mark when running outside one.
private struct TourLogo: View {
    private static let image: NSImage? = Bundle.main.image(forResource: "logo-large") ?? Bundle.main.image(forResource: "logo")

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                IguanaMark().padding(4)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Chrome

private struct TopBar: View {
    @ObservedObject var model: TourModel
    @Environment(\.tourPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            if !model.closing {
                Button(action: model.toggleMute) {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 38, height: 32)
                        .glass(Capsule(), interactive: true)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.soft)
                .help(model.muted ? "Turn sound on" : "Turn sound off")
                .accessibilityLabel(model.muted ? "Turn sound on" : "Turn sound off")

                Button(action: model.escape) {
                    HStack(spacing: 7) {
                        MiniCap(text: "esc")
                        Text(model.skipArmed ? "Press again to leave the tour" : "Skip")
                            .font(Theme.rounded(13, .medium))
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(palette.lit).opacity(model.skipArmed ? 0.4 : 0))
                    .glass(Capsule(), interactive: true)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.skipArmed ? palette.ink : palette.soft)
                .animation(.snappy(duration: 0.2), value: model.skipArmed)
            }
        }
    }
}

/// A small key, for naming a key inside a line of text or a button.
private struct MiniCap: View {
    let text: String
    var inverted = false
    @Environment(\.tourPalette) private var palette

    var body: some View {
        Text(text)
            .font(Theme.rounded(11.5, .semibold))
            .foregroundStyle(inverted ? palette.top : palette.ink.opacity(0.8))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(inverted ? palette.top.opacity(0.18) : palette.ink.opacity(0.08)))
    }
}

/// The one thing Return does on a scene, as a button that says so.
private struct Prompt: View {
    let label: String
    var enabled = true
    let action: () -> Void
    @Environment(\.tourPalette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Text(label).font(Theme.rounded(16, .semibold))
                MiniCap(text: "↩", inverted: true)
            }
            .foregroundStyle(palette.top)
            .padding(.leading, 24)
            .padding(.trailing, 14)
            .frame(height: 48)
            .background(Capsule().fill(palette.ink).opacity(0.9))
            .glass(Capsule(), interactive: true)
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
    }
}

private struct Headline: View {
    let title: String
    let detail: String
    let k: CGFloat
    @Environment(\.tourPalette) private var palette

    var body: some View {
        VStack(spacing: 9 * k) {
            Text(title)
                .font(Theme.rounded(44 * k, .bold))
                .tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.system(size: 17.5 * k, weight: .regular, design: .rounded))
                .foregroundStyle(palette.soft)
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: 720)
    }
}

// MARK: Hello

private struct HelloScene: View {
    @ObservedObject var model: TourModel
    let size: CGSize
    let k: CGFloat
    @Environment(\.tourPalette) private var palette
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: size.height * 0.33 + 86 * k + 38 * k)
            RisingText(text: "Meet Iguana", font: Theme.rounded(66 * k, .bold), shown: shown)
            Text("It keeps your windows in order, so you never arrange them again.")
                .font(.system(size: 19 * k, weight: .regular, design: .rounded))
                .foregroundStyle(palette.soft)
                .padding(.top, 12 * k)
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(0.75), value: shown)
            Prompt(label: "Take the tour", action: model.primary)
                .padding(.top, 44 * k)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 10)
                .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(1.15), value: shown)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { shown = true }
    }
}

/// A line whose letters come up one after another.
private struct RisingText: View {
    let text: String
    let font: Font
    let shown: Bool

    var body: some View {
        HStack(spacing: -0.5) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, letter in
                Text(String(letter))
                    .font(font)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 26)
                    .animation(.spring(response: 0.62, dampingFraction: 0.74).delay(0.25 + Double(index) * 0.04), value: shown)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Lessons

private struct LessonScene: View {
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

/// The play desktop: its windows, the outline that shows where one should go, and the mark that
/// calls for the focus. Everything is placed in the model's units and scaled here.
private struct StageView: View {
    @ObservedObject var model: TourModel
    let height: CGFloat
    @Environment(\.tourPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hop = false

    var body: some View {
        GeometryReader { geometry in
            let scale = height / TourModel.stage.height
            let left = (geometry.size.width - TourModel.stage.width * scale) / 2
            let compact = model.overview
            let place: (CGRect) -> CGRect = { r in
                CGRect(x: left + r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
            }
            let tiles = model.tiles

            ZStack(alignment: .topLeading) {
                ForEach(0..<TourModel.desktopCount, id: \.self) { index in
                    let frame = place(model.panel(index))
                    let isCurrent = index == model.current
                    let visible = model.overview || isCurrent
                    // The desktop is a slab of glass; the windows on it are the content.
                    Color.clear
                        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                        .glass(RoundedRectangle(cornerRadius: compact ? 15 : 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: compact ? 15 : 24, style: .continuous)
                            .strokeBorder(palette.ink, lineWidth: 2.5).opacity(compact && isCurrent ? 1 : 0))
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(visible ? 1 : 0)

                    if model.desktopBeacon == index {
                        Beacon()
                            .position(x: frame.midX, y: frame.midY)
                            .zIndex(4)
                            .transition(.scale.combined(with: .opacity))
                    }

                    DesktopNumber(number: index + 1, current: isCurrent, calling: model.desktopBeacon == index)
                        .position(x: frame.midX, y: frame.maxY + 30)
                        .opacity(model.overview ? 1 : 0)
                }

                if model.step == .open, tiles.isEmpty {
                    let frame = place(model.panel(0))
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(palette.faint)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity)
                }

                ForEach(Array(tiles.enumerated()), id: \.element.id) { order, tile in
                    let frame = place(tile.rect)
                    TileView(color: palette.tile(tile.color), focused: tile.focused, compact: compact, size: frame.size)
                        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                        .scaleEffect(hop ? 1.035 : 1)
                        .animation(.spring(response: 0.28, dampingFraction: 0.5).delay(Double(order) * 0.05), value: hop)
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(model.overview || tile.desktop == model.current ? 1 : 0)
                        // Between 1 and 2, in the order the windows lie in. It shows in a stack.
                        .zIndex(tile.focused ? 2 : 1 + Double(tile.layer) / Double(tiles.count + 1))
                        .transition(.scale(scale: 0.82).combined(with: .opacity))
                }

                // The call for the focus is drawn over the windows, on the part of its window
                // that shows: in a stack that is a strip, and a mark inside the window would be
                // cut off by the window in front.
                if let spot = model.beaconSpot {
                    Beacon()
                        .position(x: left + spot.x * scale, y: spot.y * scale)
                        .zIndex(4)
                        .id(model.beacon)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                if let ghost = model.ghost {
                    let frame = place(ghost.rect)
                    GhostView(color: palette.tile(model.colors[ghost.window] ?? 0), compact: compact, still: reduceMotion)
                        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                        .position(x: frame.midX, y: frame.midY)
                        .zIndex(3)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: model.celebrations) { _, _ in
            guard !reduceMotion else { return }
            hop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { hop = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Practice desktop with \(model.tiles.count) windows")
    }
}

private struct DesktopNumber: View {
    let number: Int
    let current: Bool
    let calling: Bool
    @Environment(\.tourPalette) private var palette

    var body: some View {
        Text("\(number)")
            .font(Theme.rounded(14, .bold))
            .foregroundStyle(current ? palette.top : palette.soft)
            .frame(width: 28, height: 28)
            .background(Circle().fill(current ? palette.ink : palette.ink.opacity(0.08)))
            .background { if calling { Pulse(color: palette.ink).frame(width: 28, height: 28) } }
    }
}

/// A ring that spreads and fades, over and over: "here".
private struct Pulse: View {
    let color: Color
    @State private var spread = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: 2)
            .scaleEffect(spread ? 2.5 : 1)
            .opacity(spread ? 0 : 0.85)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) { spread = true }
            }
    }
}

/// The mark that calls for attention: go here.
private struct Beacon: View {
    var body: some View {
        ZStack {
            Pulse(color: .white).frame(width: 30, height: 30)
            Circle().fill(.white).frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .accessibilityHidden(true)
    }
}

private struct TileView: View {
    let color: Color
    let focused: Bool
    let compact: Bool
    let size: CGSize
    @Environment(\.tourPalette) private var palette

    var body: some View {
        let radius: CGFloat = compact ? 8 : 15
        let mark = Color.black.opacity(0.17)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color)
            .overlay(alignment: .topLeading) {
                // Enough of a window to read as one: its three buttons and a few lines.
                VStack(alignment: .leading, spacing: compact ? 5 : 11) {
                    HStack(spacing: compact ? 3 : 6) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(mark).frame(width: compact ? 4.5 : 9, height: compact ? 4.5 : 9) }
                    }
                    if !compact, size.height > 120, size.width > 120 {
                        VStack(alignment: .leading, spacing: 8) {
                            Capsule().fill(mark).frame(width: size.width * 0.34, height: 8)
                            Capsule().fill(mark.opacity(0.6)).frame(width: size.width * 0.52, height: 8)
                            Capsule().fill(mark.opacity(0.6)).frame(width: size.width * 0.26, height: 8)
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(compact ? 7 : 15)
            }
            .overlay {
                // The outline of the animal itself, with a pale line inside it so that it also
                // shows on the darkest window.
                let line: CGFloat = compact ? 3 : 5
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.ink, lineWidth: line)
                    RoundedRectangle(cornerRadius: max(radius - line, 2), style: .continuous)
                        .strokeBorder(palette.top.opacity(0.85), lineWidth: compact ? 1 : 1.5)
                        .padding(line)
                }
                .opacity(focused ? 1 : 0)
            }
            .shadow(color: .black.opacity(focused ? 0.20 : 0.10), radius: focused ? 14 : 6, y: focused ? 7 : 3)
    }
}

private struct GhostView: View {
    let color: Color
    let compact: Bool
    let still: Bool
    @Environment(\.tourPalette) private var palette
    @State private var phase: CGFloat = 0

    var body: some View {
        let radius: CGFloat = compact ? 8 : 15
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color.opacity(0.42))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(palette.ink.opacity(0.75), style: StrokeStyle(lineWidth: compact ? 2 : 2.5, lineCap: .round, dash: [2, 9], dashPhase: phase)))
            .onAppear {
                guard !still else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = -11 }
            }
    }
}

// MARK: Keys

/// The keys of a lesson, laid out as they are under the hands: the ones to hold, then the ones to
/// press. Held keys go down as they go down on the keyboard.
private struct KeyDeck: View {
    @ObservedObject var model: TourModel
    let keys: LessonKeys
    @Environment(\.tourPalette) private var palette

    private static let names: [Modifier: (symbol: String, name: String)] = [
        .ctrl: ("⌃", "control"), .option: ("⌥", "option"), .shift: ("⇧", "shift"), .cmd: ("⌘", "command"),
    ]

    var body: some View {
        let holding = keys.modifiers.allSatisfy(model.held.contains)
        let next = model.suggested
        HStack(spacing: 12) {
            ForEach(keys.modifiers, id: \.self) { modifier in
                let down = model.held.contains(modifier)
                KeyFace(down: down, calling: !down, width: 92) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.names[modifier]?.symbol ?? "")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Spacer(minLength: 0)
                        Text(Self.names[modifier]?.name ?? "")
                            .font(Theme.rounded(12.5, .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            if !keys.modifiers.isEmpty {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.faint)
                    .padding(.horizontal, 2)
            }
            HStack(spacing: 8) {
                ForEach(keys.keys) { key in
                    let wide = key.label.count > 2
                    KeyFace(down: model.lit.contains(key.id), calling: holding && key.command == next, width: wide ? nil : 58) {
                        VStack(spacing: 3) {
                            if let symbol = key.symbol {
                                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).opacity(0.5)
                            }
                            Text(key.label).font(Theme.rounded(wide ? 15 : 19, .semibold))
                        }
                        .padding(.horizontal, wide ? 14 : 0)
                    }
                }
            }
        }
        .modifier(Shake(times: CGFloat(model.refusals)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.keys.map(\.label).joined(separator: ", "))
    }
}

/// A small sideways shake, once for each time `times` goes up: "not that one".
private struct Shake: GeometryEffect {
    var times: CGFloat

    var animatableData: CGFloat {
        get { times }
        set { times = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(times * .pi * 4) * 5, y: 0))
    }
}

private struct KeyFace<Content: View>: View {
    let down: Bool
    let calling: Bool
    var width: CGFloat?
    @ViewBuilder var content: Content
    @Environment(\.tourPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        content
            .foregroundStyle(down ? palette.litInk : palette.ink)
            .frame(width: width, height: 58)
            // The colour of a pressed key is painted on the glass rather than left to its tint,
            // which the system drops while another app is in front.
            .background(shape.fill(palette.lit).opacity(down ? 0.92 : 0))
            .glass(shape, interactive: true)
            .overlay(shape.strokeBorder(palette.lit, lineWidth: 2.5).opacity(calling && !down ? (breathe ? 1 : 0.25) : 0))
            .scaleEffect(down ? 0.93 : 1)
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: down)
            .onAppear {
                guard !reduceMotion else {
                    breathe = true
                    return
                }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { breathe = true }
            }
    }
}

// MARK: Permission

private struct PermissionScene: View {
    @ObservedObject var model: TourModel
    let k: CGFloat
    @Environment(\.tourPalette) private var palette

    var body: some View {
        let granted = model.permission == .granted
        VStack(spacing: 0) {
            Spacer()
            SwitchCard(on: granted, demonstrate: !granted)
            Spacer().frame(height: 46 * k)
            ZStack {
                Headline(title: granted ? "That was it" : "One switch to flip",
                         detail: granted ? "Iguana can arrange your windows now."
                             : "macOS asks you before an app may move windows. Turn Iguana on\nunder Accessibility, and the tour carries on by itself.",
                         k: k)
                    .id(granted)
                    .transition(.opacity)
            }
            Spacer().frame(height: 36 * k)
            ZStack {
                switch model.permission {
                case .idle:
                    Prompt(label: "Open System Settings", action: model.primary)
                case .waiting:
                    VStack(spacing: 14) {
                        HStack(spacing: 9) {
                            WaitingDots()
                            Text("Waiting for the switch").font(Theme.rounded(15, .medium)).foregroundStyle(palette.soft)
                        }
                        .frame(height: 48)
                        Button("Open Accessibility settings again", action: model.openAccessibilitySettings)
                            .buttonStyle(.plain)
                            .font(Theme.rounded(13, .medium))
                            .foregroundStyle(palette.soft)
                            .underline()
                    }
                case .granted:
                    Color.clear.frame(height: 48)
                }
            }
            .frame(height: 90, alignment: .top)
            Spacer()
            Spacer().frame(height: 30 * k)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The row to look for in System Settings, flipping its switch to show what to do.
private struct SwitchCard: View {
    let on: Bool
    let demonstrate: Bool
    @Environment(\.tourPalette) private var palette
    @State private var shown = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let isOn = on || shown
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Text("Privacy & Security")
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                Text("Accessibility")
            }
            .font(Theme.rounded(12.5, .medium))
            .foregroundStyle(palette.soft)
            .padding(.leading, 4)

            HStack(spacing: 14) {
                TourLogo().frame(width: 38, height: 38)
                Text("Iguana").font(Theme.rounded(19, .semibold))
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? palette.lit : palette.ink.opacity(0.16)).frame(width: 58, height: 34)
                    Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isOn)
                .overlay {
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(palette.lit)
                            .offset(x: 12)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(width: 430, height: 76)
            .glass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .onReceive(timer) { _ in
            guard demonstrate else { return }
            shown.toggle()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In System Settings, under Privacy and Security, Accessibility, turn on Iguana")
    }
}

private struct WaitingDots: View {
    @Environment(\.tourPalette) private var palette
    @State private var on = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(palette.soft).frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(index) * 0.2), value: on)
            }
        }
        .onAppear { on = true }
        .accessibilityHidden(true)
    }
}

// MARK: Done

private struct DoneScene: View {
    @ObservedObject var model: TourModel
    let size: CGSize
    let k: CGFloat
    @Environment(\.tourPalette) private var palette

    private struct Line: Identifiable {
        let id: Int
        let modifiers: [Modifier]
        let keys: [String]
        let text: String
        /// For a line about the mouse, which has no keys: a picture in their place.
        var symbol: String?
    }

    private var lines: [Line] {
        var out: [Line] = []
        func add(_ step: TourStep, _ text: String, keys override: [String]? = nil) {
            guard let keys = model.keys(for: step), !keys.modifiers.isEmpty else { return }
            out.append(Line(id: out.count, modifiers: keys.modifiers, keys: override ?? keys.keys.map(\.label), text: text))
        }
        add(.focus, "Move between windows")
        add(.move, "Take a window along")
        add(.resize, "Make it smaller or larger")
        add(.stack, "Stack a row or column")
        if let jump = model.bindings.first(where: { $0.command == .space(.index(1)) }) {
            let order: [Modifier] = [.ctrl, .option, .shift, .cmd]
            out.append(Line(id: out.count, modifiers: order.filter(jump.combo.modifiers.contains), keys: ["1", "…", "9"],
                            text: "Jump to a desktop. Add shift to bring the window."))
        }
        out.append(Line(id: out.count, modifiers: [], keys: [], text: "Drag a window. An outline shows where it lands.",
                        symbol: "cursorarrow"))
        return out
    }

    private static let symbols: [Modifier: String] = [.ctrl: "⌃", .option: "⌥", .shift: "⇧", .cmd: "⌘"]

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: size.height * 0.225 + 48 * k + 30 * k)
            Headline(title: "You know your way around", detail: "Iguana sits in the menu bar. Every key can be changed in its settings.", k: k)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(spacing: 14) {
                        HStack(spacing: 4) {
                            if let symbol = line.symbol {
                                Image(systemName: symbol)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(palette.ink.opacity(0.8))
                                    .frame(minWidth: 22, minHeight: 20)
                                    .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(palette.ink.opacity(0.08)))
                                    .accessibilityHidden(true)
                            }
                            ForEach(line.modifiers, id: \.self) { MiniCap(text: Self.symbols[$0] ?? "") }
                            ForEach(Array(line.keys.enumerated()), id: \.offset) { _, key in
                                if key == "…" {
                                    Text("…").font(Theme.rounded(12, .medium)).foregroundStyle(palette.faint)
                                } else {
                                    MiniCap(text: key)
                                }
                            }
                        }
                        .frame(width: 178, alignment: .leading)
                        Text(line.text).font(.system(size: 15, design: .rounded))
                        Spacer(minLength: 0)
                    }
                    // On the lowest screens six lines at full height push the button off the bottom.
                    .frame(height: size.height < 720 ? 38 : 44)
                    .overlay(alignment: .bottom) {
                        if line.id != lines.count - 1 { Rectangle().fill(palette.panelLine).frame(height: 1) }
                    }
                }
            }
            .frame(width: 590)
            .padding(.horizontal, 22)
            .padding(.vertical, 4)
            .glass(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.top, 30 * k)

            Button {
                model.setLaunchAtLogin(!model.launchAtLogin)
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(model.launchAtLogin ? palette.lit : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .strokeBorder(model.launchAtLogin ? .clear : palette.faint, lineWidth: 1.5))
                        if model.launchAtLogin {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(palette.litInk)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(model.launchAtLoginError ?? "Open Iguana when I log in")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(palette.soft)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 30 * k)
            .accessibilityAddTraits(model.launchAtLogin ? .isSelected : [])

            Prompt(label: "Start tiling", action: model.primary)
                .padding(.top, 26 * k)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
