import IguanaCore

extension TourModel {
    /// A tour stopped at one of its scenes, for looking at it without playing it through.
    static func preview(_ step: TourStep, config: Config = .default, variant: Int = 0) -> TourModel {
        let model = TourModel(config: config)
        model.isTrusted = { false }
        model.after = { _, _ in }
        switch step {
        case .hello:
            break
        case .open:
            model.go(to: .open)
            for _ in 0..<variant { model.primary() }
        case .permission:
            model.go(to: .permission)
            if variant == 1 { model.permission = .waiting }
            if variant == 2 { model.permission = .granted }
        case .stack:
            if variant == 3 {
                // As the tour comes to it: a window has been moved to one side and grown.
                model.go(to: .move)
                for _ in 0..<4 { if let next = model.suggested { _ = model.handle(next) } }
                model.go(to: .resize)
                for _ in 0..<3 { if let next = model.suggested { _ = model.handle(next) } }
            }
            model.go(to: .stack)
            if variant == 1 || variant == 2 { _ = model.handle(.stack) }
            if variant == 2, let next = model.suggested { _ = model.handle(next) }
        case .desktops:
            // The desktops as the stack lesson leaves them.
            if variant == 2 {
                model.go(to: .stack)
                _ = model.handle(.stack)
            }
            model.go(to: .desktops)
            if variant == 1 { _ = model.handle(.space(.index(2))) }
        default:
            model.go(to: step)
        }
        return model
    }
}
