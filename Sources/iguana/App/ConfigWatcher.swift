import Foundation

/// Notices that the config file was saved, whatever saved it: an editor, a script, or a
/// dotfiles tool that swaps the file for another.
final class ConfigWatcher {
    private let url: () -> URL
    private var signature = ""
    private var timer: Timer?

    init(url: @escaping () -> URL = { Iguana.configURL }) {
        self.url = url
    }

    deinit { timer?.invalidate() }

    /// What tells one saved file from the next: when it was written, its size and which file
    /// it is. Reading the whole file twice a second would cost more and tell no more.
    static func signature(of url: URL) -> String {
        // The file itself, not a link to it: a config kept in a dotfiles folder is a link.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path) else { return "missing" }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(modified) \(attributes[.size] ?? 0) \(attributes[.systemFileNumber] ?? 0)"
    }

    /// The file as it is now has been read already, so it does not count as a change. The
    /// settings window saves the file and reloads it itself.
    func mark() {
        signature = Self.signature(of: url())
    }

    /// Whether the file changed since it was last looked at. A change is reported once.
    func changed() -> Bool {
        let now = Self.signature(of: url())
        guard now != signature else { return false }
        signature = now
        return true
    }

    /// Look every half second, and call `onChange` when the file is another one.
    func start(every interval: TimeInterval = 0.5, _ onChange: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            if self?.changed() == true { onChange() }
        }
    }
}
