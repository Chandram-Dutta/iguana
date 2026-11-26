import Foundation

/// Putting a newer Iguana in the place of the one that is running. Everything that is a
/// decision lives here and touches neither the network nor the disk: where a version is
/// downloaded from, whether this copy of Iguana may replace itself, what the answer to the
/// download means, and the words for each stage. The app does the work (`UpdateInstaller`) and
/// hands what it found to these functions.
///
/// Nothing here says a download can be trusted. That is decided by the signature of the app
/// that was unpacked, which the app checks with macOS before anything is replaced.
public enum UpdateInstall {
    /// The app's identity to macOS. The Accessibility permission hangs on it, so a download
    /// that calls itself anything else is not Iguana.
    public static let bundleIdentifier = "xyz.onlychan.iguana"
    /// The one item a release's zip holds.
    public static let bundleName = "Iguana.app"
    /// Far more than any real release. A longer download is stopped and thrown away.
    public static let largestDownload: Int64 = 200 * 1024 * 1024
    /// How long the server may stay silent before the download is given up.
    public static let silenceTimeout: TimeInterval = 30
    /// How long the whole download may take.
    public static let downloadTimeout: TimeInterval = 10 * 60

    // MARK: The address

    /// The name of the zip a release of this version publishes. Nil when `version` is not one.
    public static func assetName(version: String) -> String? {
        UpdateCheck.Version(version).map { "Iguana-\($0).zip" }
    }

    /// Where the zip of a version is downloaded from. The address is made here from the
    /// version's numbers and from nothing else, so no answer from a server can point the
    /// download anywhere but at this repository's releases.
    public static func assetURL(version: String) -> URL? {
        guard let number = UpdateCheck.Version(version), let name = assetName(version: version) else { return nil }
        return URL(string: "https://github.com/\(UpdateCheck.repository)/releases/download/v\(number)/\(name)")
    }

    /// GitHub keeps release files on another host and answers with "look over there". The
    /// download follows, but never off `https`. Where it leads is not what makes the file
    /// trusted: the signature of what was unpacked is.
    public static func allowsRedirect(to url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    /// Why the answer to the download is not a file to keep, or nil when it is. `expectedLength`
    /// is what the server says is coming, and negative when it does not say.
    public static func downloadProblem(status: Int, expectedLength: Int64, limit: Int64 = largestDownload) -> String? {
        switch status {
        case 200: break
        case 404: return "this release has no download for Iguana to install"
        default: return "the download was answered with status \(status)"
        }
        return expectedLength > limit ? tooLarge(limit: limit) : nil
    }

    /// Said when more arrives than any release holds, whatever the server claimed.
    public static func tooLarge(limit: Int64 = largestDownload) -> String {
        "the download is larger than \(limit / (1024 * 1024)) MB, which no release of Iguana is"
    }

    // MARK: May it?

    /// What is known about the copy of Iguana that is running, gathered by the app.
    public struct Facts: Equatable {
        /// The folder the process runs from: `/Applications/Iguana.app` for an installed copy.
        public var bundlePath: String
        /// The developer team that signed the running app. Nil when it is not signed by one.
        public var teamIdentifier: String?
        /// Signed without an identity, as a build made on one's own Mac is.
        public var adHoc: Bool
        /// The current user may put something in the folder that holds the app.
        public var folderWritable: Bool
        /// The current user may change the app itself.
        public var bundleWritable: Bool
        /// The version that is running.
        public var running: String

        public init(bundlePath: String, teamIdentifier: String?, adHoc: Bool, folderWritable: Bool, bundleWritable: Bool, running: String) {
            self.bundlePath = bundlePath
            self.teamIdentifier = teamIdentifier
            self.adHoc = adHoc
            self.folderWritable = folderWritable
            self.bundleWritable = bundleWritable
            self.running = running
        }
    }

    /// Why this copy of Iguana does not replace itself.
    public enum Refusal: Equatable {
        /// Not running from an app: a build run from its build folder.
        case notAnApp
        /// macOS runs a downloaded app that was never moved from a hidden, read-only copy.
        case translocated
        /// Not signed by a developer team. Only a released build has a signature that a
        /// download can be checked against.
        case notSigned
        /// The current user cannot replace the app. Iguana never asks for more rights.
        case notWritable(String)
        case notAVersion(String)
        /// The same version or an older one. Iguana never goes back.
        case notNewer(version: String, running: String)

        /// The sentence for the log and for `status`.
        public var sentence: String {
            switch self {
            case .notAnApp: return "this Iguana is not running from an app, so there is nothing to replace"
            case .translocated:
                return "macOS is running Iguana from a temporary copy; move Iguana.app to the Applications folder and open it again"
            case .notSigned: return "this Iguana is a development build, which does not update itself"
            case .notWritable(let path): return "Iguana may not replace \(path) as this user, and never asks for an administrator's rights"
            case .notAVersion(let text): return "\"\(text)\" is not a version"
            case .notNewer(let version, let running): return "Iguana \(version) is not newer than \(running), which is running"
            }
        }
    }

    public enum Verdict: Equatable {
        case allowed
        case refused(Refusal)
    }

    /// Whether the running Iguana may replace itself with `version`. Asked before anything is
    /// downloaded, so a refusal costs nothing.
    public static func verdict(installing version: String, facts: Facts) -> Verdict {
        guard facts.bundlePath.hasSuffix(".app") else { return .refused(.notAnApp) }
        guard !facts.bundlePath.contains("/AppTranslocation/") else { return .refused(.translocated) }
        guard let team = facts.teamIdentifier, !team.isEmpty, !facts.adHoc else { return .refused(.notSigned) }
        guard facts.folderWritable, facts.bundleWritable else { return .refused(.notWritable(facts.bundlePath)) }
        guard let wanted = UpdateCheck.Version(version) else { return .refused(.notAVersion(version)) }
        guard let running = UpdateCheck.Version(facts.running), wanted > running else {
            return .refused(.notNewer(version: wanted.description, running: facts.running))
        }
        return .allowed
    }

    /// Whether the version an unpacked app says it is, is the one that was asked for. A release
    /// that holds another version is refused, so an old release can never stand in for a new one.
    public static func isVersion(_ found: String?, _ asked: String) -> Bool {
        guard let found, let a = UpdateCheck.Version(found), let b = UpdateCheck.Version(asked) else { return false }
        return a == b
    }

    // MARK: Progress

    /// What an install is doing, in the order it does it.
    public enum Stage: String, Equatable, CaseIterable {
        case downloading
        /// Unpacking the download and checking its signature.
        case checking
        /// Putting the new app in the place of the old one.
        case installing
        case restarting

        /// The title of the menu item while this is going on.
        public func menuTitle(version: String) -> String {
            switch self {
            case .downloading: return "Downloading Iguana \(version)…"
            case .checking: return "Checking Iguana \(version)…"
            case .installing: return "Installing Iguana \(version)…"
            case .restarting: return "Restarting into Iguana \(version)…"
            }
        }
    }

    /// Where the installer is.
    public enum State: Equatable {
        /// Nothing was asked for since Iguana started.
        case idle
        case working(version: String, stage: Stage)
        /// The last install stopped, and why. Nothing was replaced.
        case failed(version: String, reason: String)
        /// The new app is in place, and what is left for the user to do. Iguana could not
        /// restart itself, so the old one is still the one that is running.
        case installed(version: String, reason: String)

        /// The stage of an install that is under way.
        public var stage: Stage? {
            if case .working(_, let stage) = self { return stage }
            return nil
        }

        /// The version this is about.
        public var version: String? {
            switch self {
            case .idle: return nil
            case .working(let version, _), .failed(let version, _), .installed(let version, _): return version
            }
        }

        /// Why the last install stopped, when it did.
        public var stopped: String? {
            switch self {
            case .idle, .working: return nil
            case .failed(_, let reason), .installed(_, let reason): return reason
            }
        }

        /// The title of the menu item while an install is under way.
        public var menuTitle: String? {
            if case .working(let version, let stage) = self { return stage.menuTitle(version: version) }
            return nil
        }

        /// The line `iguana status` adds.
        public var statusLine: String? {
            switch self {
            case .idle: return nil
            case .working(let version, let stage): return "update: installing Iguana \(version) (\(stage.rawValue))"
            case .failed(let version, let reason): return "update: Iguana \(version) was not installed: \(reason)"
            case .installed(let version, let reason): return "update: Iguana \(version) is installed: \(reason)"
            }
        }
    }

    // MARK: By itself

    /// Whether Iguana should start installing `version` now without being asked. Only when the
    /// user switched that on, and never under their hands: not while the welcome tour is on
    /// screen and not while a window is being dragged. `lastTry` is the last time it started by
    /// itself. A version that could not be installed is tried again a day later, not every hour.
    public static func startsByItself(switchedOn: Bool, tourShowing: Bool, dragging: Bool, version: String,
                                      lastTry: (version: String, at: Date)?, now: Date) -> Bool {
        guard switchedOn, !tourShowing, !dragging else { return false }
        guard let lastTry, lastTry.version == version else { return true }
        let since = now.timeIntervalSince(lastTry.at)
        // A last try in the future means the clock was set back.
        return since >= UpdateCheck.interval || since < 0
    }
}
