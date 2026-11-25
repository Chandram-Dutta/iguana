import Foundation
import IguanaCore

/// Asks GitHub whether a newer Iguana has been released, about once a day, and remembers the
/// answer. It only ever finds out and says so: nothing is downloaded and nothing is installed.
///
/// What the answer means, which address may be opened and when a check is due are decided in
/// IguanaCore (`UpdateCheck`). This file does the asking and the remembering.
///
/// The request says nothing about the user or the Mac. It is one `GET` for a public address
/// with Iguana's name and version as its `User-Agent`; there are no cookies, no stored
/// credentials, no cache and no identifier, and the session it is made in is thrown away with
/// the answer. GitHub sees what any server sees: the internet address the request came from.
final class UpdateChecker {
    /// What came back: the HTTP status and the body, or why there was no answer.
    typealias Answer = Result<(status: Int, body: Data), Error>
    /// Something that asks and calls back, on any thread. The real one is `askGitHub`.
    typealias Ask = (@escaping (Answer) -> Void) -> Void

    private enum Key {
        static let lastCheck = "updateLastCheck"
        static let version = "updateVersion"
        static let page = "updatePage"
    }

    /// How often to look whether a check is due. A timer of a whole day would be thrown off by
    /// every sleep; looking at the time of the last check is not.
    private static let lookEvery: TimeInterval = 60 * 60

    private let defaults: UserDefaults
    private let ask: Ask
    private let running: String
    private let now: () -> Date
    private let log: (String) -> Void

    /// The newer release that is known of, from this run or an earlier one.
    private(set) var available: UpdateCheck.Update?
    /// Called when `available` changed.
    var onChange: (() -> Void)?

    private var enabled: () -> Bool = { false }
    private var timers: [Timer] = []
    /// A check is on its way, and these are waiting for what it finds.
    private var checking = false
    private var waiting: [(UpdateCheck.Outcome) -> Void] = []
    private var failureLogged = false

    init(defaults: UserDefaults = .standard, running: String = Iguana.version, now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = Log.write, ask: @escaping Ask = { UpdateChecker.askGitHub(completion: $0) }) {
        self.defaults = defaults
        self.running = running
        self.now = now
        self.log = log
        self.ask = ask
        // What an earlier run found is still worth showing, unless this is that version by now.
        available = UpdateCheck.remembered(version: defaults.string(forKey: Key.version), page: defaults.string(forKey: Key.page),
                                           running: running)
        if available == nil { forget() }
    }

    deinit { timers.forEach { $0.invalidate() } }

    /// When Iguana last asked, on this run or an earlier one.
    var lastCheck: Date? { defaults.object(forKey: Key.lastCheck) as? Date }

    /// Start checking by itself: a first look a little after starting, then one every hour.
    /// `enabled` is asked each time, so the setting can change while Iguana runs.
    func start(enabled: @escaping () -> Bool) {
        self.enabled = enabled
        timers.forEach { $0.invalidate() }
        let first = Timer.scheduledTimer(withTimeInterval: UpdateCheck.startDelay, repeats: false) { [weak self] _ in self?.checkIfDue() }
        let hourly = Timer.scheduledTimer(withTimeInterval: Self.lookEvery, repeats: true) { [weak self] _ in self?.checkIfDue() }
        hourly.tolerance = 5 * 60
        timers = [first, hourly]
    }

    /// Ask, if the setting is on and it has been a day.
    func checkIfDue() {
        guard UpdateCheck.isDue(enabled: enabled(), lastCheck: lastCheck, now: now()) else { return }
        checkNow()
    }

    /// Ask now, whatever the setting. Call on the main thread; `completion` runs there too.
    /// A check that is already on its way is not started twice: everyone gets its answer.
    func checkNow(_ completion: ((UpdateCheck.Outcome) -> Void)? = nil) {
        if let completion { waiting.append(completion) }
        guard !checking else { return }
        checking = true
        // Written down before the answer, so that a check that fails also waits a day.
        defaults.set(now(), forKey: Key.lastCheck)
        ask { [weak self] answer in
            DispatchQueue.main.async { self?.finish(answer) }
        }
    }

    private func finish(_ answer: Answer) {
        let outcome: UpdateCheck.Outcome
        switch answer {
        case .success(let got): outcome = UpdateCheck.outcome(status: got.status, body: got.body, running: running)
        case .failure(let error): outcome = .failed(error.localizedDescription)
        }
        checking = false
        switch outcome {
        case .latest: remember(nil)
        case .newer(let update): remember(update)
        case .failed(let why):
            // What was known before is still true. Being offline is ordinary, so it is said once.
            if !failureLogged {
                failureLogged = true
                log("update check: \(why) (logged once; Iguana tries again in about a day)")
            }
        }
        let callbacks = waiting
        waiting = []
        for callback in callbacks { callback(outcome) }
    }

    private func remember(_ update: UpdateCheck.Update?) {
        guard update != available else { return }
        available = update
        if let update {
            defaults.set(update.version, forKey: Key.version)
            defaults.set(update.page.absoluteString, forKey: Key.page)
            log("update check: Iguana \(update.version) is available")
        } else {
            forget()
        }
        onChange?()
    }

    private func forget() {
        defaults.removeObject(forKey: Key.version)
        defaults.removeObject(forKey: Key.page)
    }

    // MARK: The request

    /// The one request Iguana ever makes: GitHub's public "latest release" of this repository.
    static func request(url: URL = UpdateCheck.latestReleaseURL, version: String = Iguana.version) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: UpdateCheck.timeout)
        request.httpShouldHandleCookies = false
        request.setValue(UpdateCheck.userAgent(version: version), forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Left alone, the system fills this in with the languages chosen in System Settings,
        // which is something about the user.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// A session that starts with nothing and keeps nothing: no cookies, no credentials, no cache.
    /// `protocols` lets a test answer in GitHub's place, so that no test touches the network.
    static func session(protocols: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = UpdateCheck.timeout
        configuration.timeoutIntervalForResource = UpdateCheck.timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        if let protocols { configuration.protocolClasses = protocols }
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    static func askGitHub(request: URLRequest = UpdateChecker.request(), protocols: [AnyClass]? = nil,
                          completion: @escaping (Answer) -> Void) {
        // A session for this one request, so nothing carries over from one check to the next.
        let session = session(protocols: protocols)
        session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()
            if let error {
                completion(.failure(error))
            } else if let http = response as? HTTPURLResponse {
                completion(.success((http.statusCode, data ?? Data())))
            } else {
                completion(.failure(NoAnswer()))
            }
        }.resume()
    }

    private struct NoAnswer: LocalizedError {
        var errorDescription: String? { "GitHub gave no answer" }
    }

    /// Follows a redirect only where `UpdateCheck.allowsRedirect` says so. A redirect that is
    /// not followed comes back as the answer, and its status makes the check a failed one.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let allowed = request.url.map(UpdateCheck.allowsRedirect(to:)) ?? false
            completionHandler(allowed ? request : nil)
        }
    }
}
