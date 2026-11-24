import Foundation

/// Noticing that a newer Iguana has been released. Everything that is a decision lives here and
/// touches neither the network nor the clock: what a version is, which answer from GitHub is
/// news, which address may be opened, and when it is time to ask again. The app does the asking
/// (`UpdateChecker`) and hands what it got to these functions.
///
/// Iguana only ever says that a newer version exists. It downloads and installs nothing.
public enum UpdateCheck {
    /// The GitHub repository Iguana's releases are published to, as `owner/name`. This is the
    /// one place that names it: the address that is asked and every address that may be opened
    /// are made from it.
    public static let repository = "Chandram-Dutta/iguana"

    /// GitHub's "get the latest release": the newest release that is not a draft or a prerelease.
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Where to send someone when a release's own page cannot be trusted.
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    /// How long to leave between two checks Iguana makes by itself.
    public static let interval: TimeInterval = 24 * 60 * 60
    /// How long after starting Iguana first looks whether a check is due, so that starting up
    /// is not held up by it.
    public static let startDelay: TimeInterval = 20
    /// How long the request may take. A check that cannot be made quickly is not made.
    public static let timeout: TimeInterval = 10
    /// More than any real answer. A longer one is not read as a release.
    public static let longestAnswer = 1 << 20

    /// All that the request says about who is asking: the name and the version of Iguana.
    public static func userAgent(version: String) -> String { "Iguana/\(version)" }

    // MARK: Versions

    /// A version such as `0.1.3`: numbers separated by dots, compared number by number.
    public struct Version: Comparable, CustomStringConvertible {
        public let components: [Int]

        /// Reads `0.1.3`, or a release tag such as `v0.1.3`. Anything else is not a version:
        /// `0.2.0-beta`, `nightly` and `1..2` all give nil, and a tag that gives nil is ignored.
        public init?(_ text: String) {
            var text = Substring(text)
            if text.first == "v" || text.first == "V" { text = text.dropFirst() }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(parts.count) else { return nil }
            var numbers: [Int] = []
            for part in parts {
                // Plain digits, and few enough of them to be a number.
                guard !part.isEmpty, part.utf8.count <= 9, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(part) else {
                    return nil
                }
                numbers.append(n)
            }
            components = numbers
        }

        public var description: String { components.map(String.init).joined(separator: ".") }

        /// The numbers with the ones that are left out counted as zero, so `0.2` is `0.2.0`.
        private func padded(to count: Int) -> [Int] {
            components + Array(repeating: 0, count: max(0, count - components.count))
        }

        public static func == (a: Version, b: Version) -> Bool {
            let count = max(a.components.count, b.components.count)
            return a.padded(to: count) == b.padded(to: count)
        }

        /// By number, not by text: `0.1.10` comes after `0.1.9`.
        public static func < (a: Version, b: Version) -> Bool {
            let count = max(a.components.count, b.components.count)
            return a.padded(to: count).lexicographicallyPrecedes(b.padded(to: count))
        }
    }

    // MARK: GitHub's answer

    /// The four fields Iguana reads from GitHub's description of a release. Everything else in
    /// the answer (the notes, the files, who published it) is not looked at.
    public struct Release: Equatable {
        public var tag: String
        /// The address of the release's page, as GitHub gave it. Not checked yet.
        public var page: String?
        public var draft: Bool
        public var prerelease: Bool

        public init(tag: String, page: String?, draft: Bool, prerelease: Bool) {
            self.tag = tag
            self.page = page
            self.draft = draft
            self.prerelease = prerelease
        }
    }

    private struct Payload: Decodable {
        let tag: String
        let page: String?
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
            case draft, prerelease
        }
    }

    /// Reads a release from the body of GitHub's answer. Nil when the body is not a release:
    /// not JSON, or without a tag, or without saying whether it is a draft or a prerelease.
    public static func release(from body: Data) -> Release? {
        guard body.count <= longestAnswer, let payload = try? JSONDecoder().decode(Payload.self, from: body) else { return nil }
        return Release(tag: payload.tag, page: payload.page, draft: payload.draft, prerelease: payload.prerelease)
    }

    /// A newer version, and the page to read about it and download it from.
    public struct Update: Equatable {
        /// Digits and dots only, whatever the tag looked like: this text is shown in a menu.
        public let version: String
        /// An address that passed `page(_:)`.
        public let page: URL

        fileprivate init(version: Version, page: String?) {
            self.version = version.description
            self.page = UpdateCheck.page(page)
        }
    }

    /// Whether a release is news to someone running `running`: it is a full release, its tag
    /// is a version, and that version is greater. A tag that is not a version is ignored.
    public static func news(_ release: Release, running: String) -> Update? {
        guard !release.draft, !release.prerelease, let found = Version(release.tag), let mine = Version(running), found > mine else {
            return nil
        }
        return Update(version: found, page: release.page)
    }

    /// What was found on an earlier run and kept, looked at again with the version running
    /// now: after an upgrade it is no longer news, and the address is checked afresh.
    public static func remembered(version: String?, page: String?, running: String) -> Update? {
        guard let version else { return nil }
        return news(Release(tag: version, page: page, draft: false, prerelease: false), running: running)
    }

    // MARK: The address that is opened

    /// The address to open for a release. Iguana hands this to the browser, so it only ever
    /// opens one that is `https`, on `github.com`, and inside this repository; for anything
    /// else it opens the repository's list of releases.
    ///
    /// The address is taken apart, checked and put together again from the checked parts, so
    /// what is opened is what was checked. The path may hold letters, digits, `.`, `_`, `-` and
    /// `/` and nothing else: no `..` that would climb out of the repository, no backslash that a
    /// browser reads as a slash, no query and no fragment.
    public static func page(_ text: String?) -> URL {
        guard let text, text.utf8.count <= 512, let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil
        else { return releasesPage }
        // `path` is the path with every %XX already turned back into its character.
        let path = parts.path
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/".unicodeScalars)
        guard path.unicodeScalars.allSatisfy(allowed.contains) else { return releasesPage }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let home = repository.split(separator: "/").map { $0.lowercased() }
        // "/owner/name/…": an empty piece before the first slash, then the repository, then more.
        guard segments.count > home.count + 1, segments[0].isEmpty,
              segments[1...home.count].map({ $0.lowercased() }) == home,
              !segments.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return releasesPage }
        return URL(string: "https://github.com" + path) ?? releasesPage
    }

    /// GitHub may answer the request with "look over there" (a renamed repository does).
    /// Iguana follows only to GitHub's own API over `https`, and treats anything else as a
    /// check that failed.
    public static func allowsRedirect(to url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == latestReleaseURL.host && url.user == nil && url.port == nil
    }

    // MARK: The outcome of a check

    public enum Outcome: Equatable {
        /// Nothing newer has been released.
        case latest
        case newer(Update)
        /// The check could not be made, and why.
        case failed(String)

        /// The one line `iguana update` answers with.
        public func reply(running: String) -> String {
            switch self {
            case .latest: return "ok: Iguana \(running) is the latest version"
            case .newer(let update): return "ok: Iguana \(update.version) is available at \(update.page.absoluteString)"
            case .failed(let why): return "error: could not check for a newer version: \(why)"
            }
        }

        /// The same, as the settings window says it beside its button.
        public func summary(running: String) -> String {
            switch self {
            case .latest: return "Iguana \(running) is the latest version."
            case .newer(let update): return "Iguana \(update.version) is available."
            case .failed(let why): return "Could not check: \(why)"
            }
        }
    }

    /// What an answer from GitHub means. `status` is the HTTP status of the answer.
    public static func outcome(status: Int, body: Data, running: String) -> Outcome {
        switch status {
        case 200: break
        // Without an account GitHub answers a limited number of questions an hour from one address.
        case 403, 429: return .failed("GitHub is answering no more requests from this network for now")
        case 404: return .failed("GitHub lists no release")
        default: return .failed("GitHub answered with status \(status)")
        }
        guard let release = release(from: body) else { return .failed("GitHub's answer was not a release") }
        return news(release, running: running).map(Outcome.newer) ?? .latest
    }

    // MARK: When to ask

    /// Whether Iguana should ask now, by itself. `lastCheck` is when it last asked, on this run
    /// or an earlier one, whether or not it got an answer: a check that failed is tried again
    /// after the same wait, not sooner.
    public static func isDue(enabled: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        let since = now.timeIntervalSince(lastCheck)
        // A last check in the future means the clock was set back. Asking once more is better
        // than waiting for the clock to catch up.
        return since >= interval || since < 0
    }

    // MARK: Words

    /// The title of the item in the menu of the menu bar item.
    public static func menuTitle(_ update: Update) -> String { "Update to Iguana \(update.version)…" }

    /// The line `iguana status` adds.
    public static func statusLine(_ update: Update) -> String {
        "update: Iguana \(update.version) is available (\(update.page.absoluteString))"
    }
}
