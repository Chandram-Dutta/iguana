import Foundation
import IguanaCore

/// The steps of an install, as the installer asks for them. `MacUpdateSteps` does them on the
/// Mac. A test hands over steps of its own, so the order, the stops and the clearing up can be
/// tested without a network, a signature or a restart.
protocol UpdateSteps {
    /// What is known about the copy of Iguana that is running.
    func facts() -> UpdateInstall.Facts
    /// A new folder for the temporary files of one install, on the volume `bundle` is on.
    func makeWorkspace(for bundle: URL) throws -> URL
    /// Downloads `url` into `file`. `completion` may run on any thread.
    func download(_ url: URL, to file: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// Unpacks `zip` into `folder`, which does not exist yet, and returns the app found there.
    func unpack(_ zip: URL, into folder: URL) throws -> URL
    /// Throws unless `bundle` is Iguana `version`, signed as the running app is and notarized.
    func verify(_ bundle: URL, version: String) throws
    /// Puts `fresh` in the place of `installed` in one move, or throws and leaves `installed` as it was.
    func swap(_ installed: URL, with fresh: URL) throws
    /// Starts the app at `bundle` once this process has ended, and ends this process.
    func relaunch(_ bundle: URL) throws
    /// Throws a workspace away, with all that is in it.
    func remove(_ workspace: URL)
}

/// Why a step stopped, in words for the log and for `status`.
struct UpdateFailure: LocalizedError, Equatable {
    let reason: String

    init(_ reason: String) { self.reason = reason }

    var errorDescription: String? { reason }

    static func reason(_ error: Error) -> String { (error as? UpdateFailure)?.reason ?? error.localizedDescription }
}

/// Replaces the running Iguana with a newer release: may it, download, unpack, verify, swap,
/// restart. Each step can refuse, and after a refusal nothing on disk has changed but the
/// workspace, which is removed.
///
/// What may be installed is not decided here. `UpdateInstall` says whether this copy of Iguana
/// replaces itself at all and where a version is downloaded from, and the `verify` step says
/// whether what arrived is Iguana. This file keeps the order and never skips a step.
final class UpdateInstaller {
    /// Who started an install. A failure opens the release's page only for the user, who is
    /// waiting for something to happen. Iguana does not open a browser by itself.
    enum Origin {
        case user
        case itself
    }

    /// Runs work somewhere: on the main thread, or off it.
    typealias Hop = (@escaping () -> Void) -> Void

    private enum Key {
        static let triedVersion = "updateInstallTriedVersion"
        static let triedAt = "updateInstallTriedAt"
    }

    /// One install from start to end.
    private struct Run {
        let update: UpdateCheck.Update
        let origin: Origin
        /// The app that is running, which is to be replaced.
        let installed: URL
        var workspace: URL?

        var version: String { update.version }
    }

    private let steps: UpdateSteps
    private let defaults: UserDefaults
    private let now: () -> Date
    private let log: (String) -> Void
    private let openPage: (URL) -> Void
    /// Unpacking and checking a signature take a moment, and the window manager must not wait for them.
    private let background: Hop
    private let main: Hop

    /// Where the install is. Read and changed on the main thread only.
    private(set) var state: UpdateInstall.State = .idle
    /// Called on the main thread when `state` changed.
    var onChange: (() -> Void)?

    init(steps: UpdateSteps, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = Log.write, openPage: @escaping (URL) -> Void,
         background: @escaping Hop = { work in DispatchQueue.global(qos: .utility).async(execute: work) },
         main: @escaping Hop = { work in DispatchQueue.main.async(execute: work) }) {
        self.steps = steps
        self.defaults = defaults
        self.now = now
        self.log = log
        self.openPage = openPage
        self.background = background
        self.main = main
    }

    /// An install is under way. A second one does not start beside it.
    var isWorking: Bool { state.stage != nil }

    // MARK: By itself

    /// A look Iguana takes by itself: after its check found something, and every hour. Starts
    /// an install only where `UpdateInstall.startsByItself` says so. `update` is nil when no
    /// newer release is known or the check is switched off, and then there is nothing to do.
    func look(_ update: UpdateCheck.Update?, switchedOn: Bool, tourShowing: Bool, dragging: Bool) {
        guard let update, !isWorking else { return }
        var lastTry: (version: String, at: Date)?
        if let version = defaults.string(forKey: Key.triedVersion), let at = defaults.object(forKey: Key.triedAt) as? Date {
            lastTry = (version, at)
        }
        guard UpdateInstall.startsByItself(switchedOn: switchedOn, tourShowing: tourShowing, dragging: dragging,
                                           version: update.version, lastTry: lastTry, now: now()) else { return }
        // Written down before the outcome, so that an install that fails also waits a day.
        defaults.set(update.version, forKey: Key.triedVersion)
        defaults.set(now(), forKey: Key.triedAt)
        install(update, origin: .itself)
    }

    // MARK: The steps

    /// Start installing `update`. Call on the main thread. False when an install is already
    /// under way, and then nothing was started.
    @discardableResult
    func install(_ update: UpdateCheck.Update, origin: Origin = .user) -> Bool {
        guard !isWorking else { return false }
        let version = update.version
        log("update: installing Iguana \(version), \(origin == .user ? "chosen in the menu" : "by itself")")

        // 1. May it? Asked first, so that a refusal has downloaded nothing.
        let facts = steps.facts()
        var run = Run(update: update, origin: origin, installed: URL(fileURLWithPath: facts.bundlePath), workspace: nil)
        if case .refused(let refusal) = UpdateInstall.verdict(installing: version, facts: facts) {
            fail(run, refusal.sentence)
            return true
        }
        // The address is made from the version. No address from a server's answer is ever used.
        guard let address = UpdateInstall.assetURL(version: version), let name = UpdateInstall.assetName(version: version) else {
            fail(run, UpdateInstall.Refusal.notAVersion(version).sentence)
            return true
        }
        let zip: URL
        do {
            let workspace = try steps.makeWorkspace(for: run.installed)
            run.workspace = workspace
            zip = workspace.appendingPathComponent(name)
        } catch {
            fail(run, "no temporary folder could be made beside the app (\(UpdateFailure.reason(error)))")
            return true
        }

        // 2. Download.
        enter(.downloading, run, "downloading \(address.absoluteString)")
        let finished = run
        steps.download(address, to: zip) { result in
            self.main { self.downloaded(result, finished, zip) }
        }
        return true
    }

    private func downloaded(_ result: Result<Void, Error>, _ run: Run, _ zip: URL) {
        if case .failure(let error) = result { return fail(run, "the download failed (\(UpdateFailure.reason(error)))") }
        guard let workspace = run.workspace else { return fail(run, "the temporary folder is gone") }
        enter(.checking, run, "unpacking Iguana \(run.version) and checking its signature")
        background {
            do {
                // 3. Unpack, 4. verify. Nothing below runs for an app that did not pass.
                let fresh = try self.steps.unpack(zip, into: workspace.appendingPathComponent("unpacked"))
                try self.steps.verify(fresh, version: run.version)
                self.main { self.enter(.installing, run, "the download is Iguana \(run.version); replacing \(run.installed.path)") }
                // 5. Swap.
                try self.steps.swap(run.installed, with: fresh)
                self.main { self.swapped(run) }
            } catch {
                self.main { self.fail(run, UpdateFailure.reason(error)) }
            }
        }
    }

    private func swapped(_ run: Run) {
        if let workspace = run.workspace { steps.remove(workspace) }
        // 6. Restart.
        enter(.restarting, run, "Iguana \(run.version) is in place; restarting")
        do {
            try steps.relaunch(run.installed)
        } catch {
            // The new app is where the old one was. Only the restart is left, and that is the user's now.
            let reason = "Iguana could not restart itself (\(UpdateFailure.reason(error))); quit Iguana and open it again"
            log("update: Iguana \(run.version) is installed, but \(reason)")
            state = .installed(version: run.version, reason: reason)
            onChange?()
        }
    }

    private func enter(_ stage: UpdateInstall.Stage, _ run: Run, _ line: String) {
        log("update: \(line)")
        state = .working(version: run.version, stage: stage)
        onChange?()
    }

    /// Stop. Whatever was downloaded or unpacked goes; the installed app was not touched.
    private func fail(_ run: Run, _ reason: String) {
        if let workspace = run.workspace { steps.remove(workspace) }
        log("update: Iguana \(run.version) was not installed: \(reason)")
        state = .failed(version: run.version, reason: reason)
        onChange?()
        guard run.origin == .user else { return }
        // The user asked for a newer Iguana and is not left without a way to it.
        log("update: opening \(run.update.page.absoluteString) instead")
        openPage(run.update.page)
    }
}
