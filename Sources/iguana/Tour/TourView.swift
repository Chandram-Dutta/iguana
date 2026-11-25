import AppKit
import SwiftUI

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
