import XCTest
import IguanaCore
@testable import iguana

/// Stands in for GitHub: answers the request inside the process, so no test touches the
/// network, and keeps the request it was asked so a test can look at it.
final class StubGitHub: URLProtocol {
    static var seen: [URLRequest] = []
    /// What to answer for a request, by its address: a status and a body, or where to redirect to.
    static var answers: [String: (status: Int, body: Data, location: String?)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.seen.append(request)
        guard let url = request.url, let answer = Self.answers[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var headers = ["Content-Type": "application/json", "Set-Cookie": "session=abc; Path=/"]
        if let location = answer.location { headers["Location"] = location }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if let location = answer.location, let target = URL(string: location) {
            // The session asks its delegate whether to follow. When it does not, the redirect
            // itself is the answer, so that is delivered as well.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The part of the update check that asks and remembers, with GitHub played by the test.
final class UpdateCheckerTests: XCTestCase {
    static let page = "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3"
    static func release(_ tag: String = "v0.1.3") -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/Chandram-Dutta/iguana/releases/tag/\#(tag)","draft":false,"prerelease":false}"#.utf8)
    }

    var suite: String!
    var defaults: UserDefaults!
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var logged: [String] = []
    /// What GitHub answers next, and how often it was asked.
    var next: UpdateChecker.Answer = .success((200, UpdateCheckerTests.release()))
    var asked = 0
    /// Answers that are held back until the test lets them go.
    var held: [(UpdateChecker.Answer) -> Void]?

    override func setUp() {
        // What is remembered between runs goes to a throwaway place, not to the user's own.
        suite = "iguana-update-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        logged = []
        asked = 0
        held = nil
        next = .success((200, Self.release()))
        StubGitHub.seen = []
        StubGitHub.answers = [:]
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func makeChecker(running: String = "0.1.2") -> UpdateChecker {
        UpdateChecker(defaults: defaults, running: running, now: { [unowned self] in self.clock },
                      log: { [unowned self] in self.logged.append($0) },
                      ask: { [unowned self] completion in
                          self.asked += 1
                          if self.held != nil { self.held?.append(completion) } else { completion(self.next) }
                      })
    }

    /// The checker reports back on the main queue, so waiting means letting the main run loop turn.
    @discardableResult
    func wait(_ seconds: TimeInterval = 5, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return done()
    }

    func check(_ checker: UpdateChecker) -> UpdateCheck.Outcome? {
        var outcome: UpdateCheck.Outcome?
        checker.checkNow { outcome = $0 }
        wait { outcome != nil }
        return outcome
    }

    func testANewerReleaseIsFoundAndRemembered() throws {
        let first = makeChecker()
        var changes = 0
        first.onChange = { changes += 1 }
        XCTAssertNil(first.available)
        XCTAssertNil(first.lastCheck)

        guard case .newer(let update) = check(first) else { return XCTFail("0.1.3 is newer than 0.1.2") }
        XCTAssertEqual(update.version, "0.1.3")
        XCTAssertEqual(first.available, update)
        XCTAssertEqual(first.lastCheck, clock)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(logged, ["update check: Iguana 0.1.3 is available"])

        // Finding the same thing again is not a change, and is not written to the log again.
        XCTAssertEqual(check(first), .newer(update))
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(logged.count, 1)

        // The next run of Iguana still knows, without asking.
        let second = makeChecker()
        XCTAssertEqual(second.available, update)
        XCTAssertEqual(second.lastCheck, clock)
        XCTAssertEqual(asked, 2)

        // And the run after the upgrade has nothing left to say.
        XCTAssertNil(makeChecker(running: "0.1.3").available)
        XCTAssertNil(makeChecker().available, "what was remembered is gone, not only hidden")
    }

    func testTheLatestVersionClearsWhatWasKnown() {
        let checker = makeChecker()
        XCTAssertNotNil(check(checker))
        XCTAssertNotNil(checker.available)
        var changes = 0
        checker.onChange = { changes += 1 }
        // The release was withdrawn, and the one before it is the latest again.
        next = .success((200, Self.release("v0.1.2")))
        XCTAssertEqual(check(checker), .latest)
        XCTAssertNil(checker.available)
        XCTAssertEqual(changes, 1)
        XCTAssertNil(makeChecker().available)
    }

    func testIguanaAsksOnceADayAndOnlyWhenSwitchedOn() {
        var enabled = false
        let checker = makeChecker()
        checker.start { enabled }
        checker.checkIfDue()
        XCTAssertEqual(asked, 0, "switched off")

        enabled = true
        checker.checkIfDue()
        XCTAssertEqual(asked, 1)
        wait { checker.available != nil }

        // Looked at every hour, asked once a day.
        for _ in 1...23 {
            clock += 3600
            checker.checkIfDue()
        }
        XCTAssertEqual(asked, 1)
        // Restarting does not start the day again.
        let restarted = makeChecker()
        restarted.start { true }
        restarted.checkIfDue()
        XCTAssertEqual(asked, 1)

        clock += 3600
        restarted.checkIfDue()
        XCTAssertEqual(asked, 2)

        // Asking by hand works with the check switched off, and counts as the day's check.
        enabled = false
        clock += 86400
        XCTAssertNotNil(check(checker))
        XCTAssertEqual(asked, 3)
        enabled = true
        checker.checkIfDue()
        XCTAssertEqual(asked, 3)
    }

    func testAFailedCheckIsQuietKeepsWhatWasKnownAndWaitsADay() {
        let checker = makeChecker()
        checker.start { true }
        XCTAssertNotNil(check(checker))
        let known = checker.available
        XCTAssertNotNil(known)
        logged = []
        var changes = 0
        checker.onChange = { changes += 1 }

        clock += 86400
        next = .failure(URLError(.notConnectedToInternet))
        guard case .failed(let why) = check(checker) else { return XCTFail("offline") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertEqual(checker.available, known, "what was found before is still true")
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].hasPrefix("update check: "), logged[0])

        // Not tried again before the day is over.
        clock += 3600
        checker.checkIfDue()
        XCTAssertEqual(asked, 2)

        // Every other kind of trouble, and one line in the log for the whole run.
        for answer in [UpdateChecker.Answer.success((403, Data())), .success((429, Data())), .success((500, Data())),
                       .success((200, Data("<html>".utf8))), .failure(URLError(.timedOut))] {
            next = answer
            guard case .failed = check(checker) else { return XCTFail("not an answer") }
        }
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(checker.available, known)
    }

    func testTwoQuestionsAtOnceAreOneRequest() {
        held = []
        let checker = makeChecker()
        var outcomes: [UpdateCheck.Outcome] = []
        checker.checkNow { outcomes.append($0) }
        checker.checkNow { outcomes.append($0) }
        checker.checkNow()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(outcomes, [])

        // The answer arrives on some other thread, as the real one does.
        let answer = next
        let waiting = held ?? []
        held = nil
        DispatchQueue.global().async { waiting.forEach { $0(answer) } }
        wait { outcomes.count == 2 }
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes.first, outcomes.last)

        // And the next question is a new request.
        XCTAssertNotNil(check(checker))
        XCTAssertEqual(asked, 2)
    }

    // MARK: The request

    func testTheRequestSaysNothingAboutTheUser() throws {
        let request = UpdateChecker.request(version: "0.1.2")
        XCTAssertEqual(request.url, UpdateCheck.latestReleaseURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, UpdateCheck.timeout)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.allHTTPHeaderFields, [
            "User-Agent": "Iguana/0.1.2", "Accept": "application/vnd.github+json", "Accept-Language": "en",
        ])

        let configuration = UpdateChecker.session().configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpAdditionalHeaders)
        XCTAssertEqual(configuration.timeoutIntervalForResource, UpdateCheck.timeout)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func ask(_ request: URLRequest = UpdateChecker.request(version: "0.1.2")) -> UpdateChecker.Answer? {
        var answer: UpdateChecker.Answer?
        let done = expectation(description: "answered")
        UpdateChecker.askGitHub(request: request, protocols: [StubGitHub.self]) {
            answer = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return answer
    }

    func testAskingGoesThroughTheSessionAndComesBackAsAnOutcome() throws {
        StubGitHub.answers[UpdateCheck.latestReleaseURL.absoluteString] = (200, Self.release(), nil)
        let got = try XCTUnwrap(try ask()?.get())
        XCTAssertEqual(got.status, 200)
        guard case .newer(let update) = UpdateCheck.outcome(status: got.status, body: got.body, running: "0.1.2") else {
            return XCTFail("0.1.3 is newer than 0.1.2")
        }
        XCTAssertEqual(update.page.absoluteString, Self.page)

        // What left for GitHub: one request, with these headers and no cookie.
        XCTAssertEqual(StubGitHub.seen.count, 1)
        let sent = try XCTUnwrap(StubGitHub.seen.first)
        XCTAssertEqual(sent.url, UpdateCheck.latestReleaseURL)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "User-Agent"), "Iguana/0.1.2")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept-Language"), "en")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))

        // The cookie GitHub's stand-in tried to set is not sent the next time.
        _ = ask()
        XCTAssertEqual(StubGitHub.seen.count, 2)
        XCTAssertNil(StubGitHub.seen.last?.value(forHTTPHeaderField: "Cookie"))
    }

    func testTroubleComesBackAsAFailedCheck() throws {
        // Nothing answers: offline.
        guard case .failure = try XCTUnwrap(ask()) else { return XCTFail("nothing was there to answer") }

        StubGitHub.answers[UpdateCheck.latestReleaseURL.absoluteString] = (403, Data(#"{"message":"API rate limit exceeded"}"#.utf8), nil)
        let limited = try XCTUnwrap(try ask()?.get())
        guard case .failed = UpdateCheck.outcome(status: limited.status, body: limited.body, running: "0.1.2") else {
            return XCTFail("rate-limited")
        }
    }

    func testARedirectIsFollowedToGitHubsAPIAndNowhereElse() throws {
        let moved = "https://api.github.com/repositories/123456/releases/latest"
        StubGitHub.answers[UpdateCheck.latestReleaseURL.absoluteString] = (301, Data(), moved)
        StubGitHub.answers[moved] = (200, Self.release(), nil)
        XCTAssertEqual(try XCTUnwrap(try ask()?.get()).status, 200, "a renamed repository is still found")
        XCTAssertEqual(StubGitHub.seen.compactMap { $0.url?.absoluteString }, [UpdateCheck.latestReleaseURL.absoluteString, moved])

        StubGitHub.seen = []
        let elsewhere = "https://example.com/releases/latest"
        StubGitHub.answers[UpdateCheck.latestReleaseURL.absoluteString] = (302, Data(), elsewhere)
        StubGitHub.answers[elsewhere] = (200, Self.release("v9.9.9"), nil)
        let answer = try XCTUnwrap(ask())
        XCTAssertEqual(StubGitHub.seen.compactMap { $0.url?.absoluteString }, [UpdateCheck.latestReleaseURL.absoluteString],
                       "the other address is never asked")
        if case .success(let got) = answer {
            guard case .failed = UpdateCheck.outcome(status: got.status, body: got.body, running: "0.1.2") else {
                return XCTFail("a redirect that is not followed is a failed check")
            }
        }
    }
}

/// The Updates section of the settings window, against a throwaway config file.
final class UpdateSettingsTests: XCTestCase {
    final class Backend: SettingsBackend {
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("iguana-update-settings-\(UUID().uuidString)/iguana.toml")
        var config = Config.default
        var problems: [String] = []
        var isPaused = false
        var availableUpdate: UpdateCheck.Update?
        /// Checks that were asked for and have not been answered yet.
        var asked: [(UpdateCheck.Outcome) -> Void] = []

        func reloadConfig() {
            if let text = try? String(contentsOf: configURL, encoding: .utf8), let loaded = try? Config.load(text) { (config, problems) = loaded }
        }

        func setPaused(_ paused: Bool) { isPaused = paused }
        func suspendShortcuts(_ suspended: Bool) {}
        func checkForUpdate(_ completion: @escaping (UpdateCheck.Outcome) -> Void) { asked.append(completion) }
    }

    var backend: Backend!
    var model: SettingsModel!

    override func setUp() {
        backend = Backend()
        model = SettingsModel(backend: backend)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: backend.configURL.deletingLastPathComponent())
    }

    func testTheToggleWritesTheSetting() throws {
        XCTAssertTrue(model.config.checkForUpdates)
        model.set(["updates", "check"], .bool(false))
        XCTAssertFalse(model.config.checkForUpdates)
        let text = try String(contentsOf: backend.configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[updates]"))
        XCTAssertTrue(text.contains("check = false"))
        XCTAssertEqual(model.problems, [])
        model.set(["updates", "check"], .bool(true))
        XCTAssertTrue(model.config.checkForUpdates)
    }

    func testCheckNowShowsWhatItFound() throws {
        XCTAssertEqual(model.updateSummary(running: "0.1.2"), "You have Iguana 0.1.2.")
        XCTAssertNil(model.updateOffered)

        model.checkForUpdate()
        model.checkForUpdate()
        XCTAssertEqual(backend.asked.count, 1, "pressed twice, asked once")
        XCTAssertTrue(model.checkingForUpdate)
        XCTAssertEqual(model.updateSummary(running: "0.1.2"), "Asking GitHub…")

        backend.asked.removeFirst()(.latest)
        XCTAssertFalse(model.checkingForUpdate)
        XCTAssertEqual(model.updateSummary(running: "0.1.2"), "Iguana 0.1.2 is the latest version.")
        XCTAssertNil(model.updateOffered)

        let update = try XCTUnwrap(UpdateCheck.remembered(version: "0.1.3", page: UpdateCheckerTests.page, running: "0.1.2"))
        model.checkForUpdate()
        backend.availableUpdate = update
        backend.asked.removeFirst()(.newer(update))
        XCTAssertEqual(model.updateSummary(running: "0.1.2"), "Iguana 0.1.3 is available.")
        XCTAssertEqual(model.updateOffered, update)

        // A check that fails says so, and what was found before is still on offer.
        model.checkForUpdate()
        backend.asked.removeFirst()(.failed("offline"))
        XCTAssertEqual(model.updateSummary(running: "0.1.2"), "Could not check: offline")
        XCTAssertEqual(model.updateOffered, update)
    }

    func testWhatTheDailyCheckFoundIsShownWithoutPressingAnything() throws {
        backend.availableUpdate = try XCTUnwrap(UpdateCheck.remembered(version: "0.1.3", page: UpdateCheckerTests.page, running: "0.1.2"))
        model.refresh()
        XCTAssertEqual(model.updateSummary(running: "0.1.2"), "Iguana 0.1.3 is available.")
        XCTAssertEqual(model.updateOffered?.page.absoluteString, UpdateCheckerTests.page)
    }
}

/// The command socket, on a socket of the test's own. `update` is the one command that answers
/// later, when GitHub has answered; here a stand-in command does.
final class DeferredReplyTests: XCTestCase {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ig-ipc-\(getpid())")

    override func setUp() {
        // Set for the rest of the test run and never taken back, so that nothing in this
        // process can reach the socket of the Iguana that is running on this Mac.
        IPC.socketPathOverride = Self.folder.appendingPathComponent("test.sock").path
    }

    override func tearDown() {
        IPC.stop()
        try? FileManager.default.removeItem(at: Self.folder)
    }

    func testAnAnswerGivenLaterReachesTheThreadThatWaitsForIt() {
        let answer = IPC.Answer()
        let done = expectation(description: "answered")
        var got = ""
        DispatchQueue.global().async {
            got = answer.wait()
            done.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            answer.give("later")
            answer.give("a second time")
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(got, "later", "only the first reply counts")
    }

    func testACommandMayAnswerLaterWithoutHoldingUpTheOthers() throws {
        XCTAssertTrue(IPC.socketPath.hasPrefix(Self.folder.path))
        var handledOnMain = true
        XCTAssertTrue(IPC.listen { line, reply in
            handledOnMain = handledOnMain && Thread.isMainThread
            if line == "slow" {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { reply("ok: slow") }
            } else {
                reply("ok: \(line)")
            }
        })

        var order: [String] = []
        var replies: [String: String] = [:]
        let slow = expectation(description: "slow"), fast = expectation(description: "fast")
        func send(_ line: String, _ done: XCTestExpectation, after delay: TimeInterval) {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                let reply = IPC.send(line)
                DispatchQueue.main.async {
                    order.append(line)
                    replies[line] = reply
                    done.fulfill()
                }
            }
        }
        send("slow", slow, after: 0)
        send("fast", fast, after: 0.1)
        wait(for: [slow, fast], timeout: 10)

        XCTAssertEqual(replies, ["slow": "ok: slow\n", "fast": "ok: fast\n"])
        XCTAssertEqual(order, ["fast", "slow"], "the command sent second was answered while the first was still waiting")
        XCTAssertTrue(handledOnMain)
    }
}
