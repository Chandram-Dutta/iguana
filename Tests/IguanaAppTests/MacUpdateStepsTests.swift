import XCTest
import IguanaCore
@testable import iguana

/// Stands in for the server a release is downloaded from: answers inside the process, so no
/// test touches the network, and keeps what it was asked.
final class StubDownloads: URLProtocol {
    struct Answer {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        /// Where to send the download on to.
        var location: String?
    }

    static var seen: [URLRequest] = []
    /// What to answer, by address. An address that is not here is a Mac that is offline.
    static var answers: [String: Answer] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.seen.append(request)
        guard let url = request.url, let answer = Self.answers[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var headers = answer.headers
        headers["Set-Cookie"] = "session=abc; Path=/"
        if let location = answer.location { headers["Location"] = location }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if let location = answer.location, let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, as a real download arrives.
        var rest = answer.body[...]
        while !rest.isEmpty {
            client?.urlProtocol(self, didLoad: Data(rest.prefix(4096)))
            rest = rest.dropFirst(4096)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Throwaway apps for the tests of the updater, in a temporary folder of the test's own.
/// Nothing here is ever outside that folder, and nothing is ever opened.
enum ThrowawayApp {
    /// A folder for one test, on the volume the temporary folder is on.
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iguana-update-steps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }

    /// A tiny app: an Info.plist, a program that does nothing, and one resource.
    @discardableResult
    static func make(in folder: URL, name: String = "Iguana.app", identifier: String = UpdateInstall.bundleIdentifier,
                     version: String = "9.9.9", marker: String = "new") throws -> URL {
        let files = FileManager.default
        let app = folder.appendingPathComponent(name)
        try files.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try files.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleName": "Iguana", "CFBundleExecutable": "iguana",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        // A real program, so that the app can be signed as one. It is never run.
        try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/iguana"))
        try Data(marker.utf8).write(to: app.appendingPathComponent("Contents/Resources/marker.txt"))
        return app
    }

    static func marker(of app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
    }

    /// Runs a tool and waits for it. Nil when it could not be started.
    static func run(_ tool: String, _ arguments: [String]) -> Int32? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Signs an app without an identity, as a build on one's own Mac is signed. A test that
    /// needs this is skipped where `codesign` is not there to do it.
    static func signAdHoc(_ app: URL, identifier: String = UpdateInstall.bundleIdentifier) throws {
        let status = run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, app.path])
        guard status == 0 else {
            throw XCTSkip("codesign is not available to sign a throwaway app (\(status.map(String.init) ?? "not found"))")
        }
    }

    /// Takes the signature off an app's program. The program is a copy of one of the system's,
    /// which arrives signed by Apple.
    static func removeSignature(_ app: URL) throws {
        let status = run("/usr/bin/codesign", ["--remove-signature", app.appendingPathComponent("Contents/MacOS/iguana").path])
        guard status == 0 else {
            throw XCTSkip("codesign is not available to take a signature off (\(status.map(String.init) ?? "not found"))")
        }
    }

    /// Zips an app as `scripts/release.sh` does.
    static func zip(_ app: URL, to zip: URL) throws {
        let status = run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        guard status == 0 else { throw XCTSkip("ditto is not available to make a zip (\(status.map(String.init) ?? "not found"))") }
    }

    /// Zips what is in a folder, without the folder itself.
    static func zip(contentsOf folder: URL, to zip: URL) throws {
        let status = run("/usr/bin/ditto", ["-c", "-k", folder.path, zip.path])
        guard status == 0 else { throw XCTSkip("ditto is not available to make a zip (\(status.map(String.init) ?? "not found"))") }
    }
}

/// The steps of an install, for real, on throwaway apps in a temporary folder. Nothing is
/// downloaded from the network, no app in /Applications is looked at, and nothing is restarted.
final class MacUpdateStepsTests: XCTestCase {
    var folder: URL!
    var steps: MacUpdateSteps!
    /// Passes for any app that is signed as Iguana, whoever signed it. A throwaway app can
    /// satisfy this, which a test of what comes after the signature needs.
    static let anyIguana = "identifier \"\(UpdateInstall.bundleIdentifier)\""
    /// What the designated requirement of a released Iguana comes to.
    static let releasedIguana = """
    identifier "\(UpdateInstall.bundleIdentifier)" and anchor apple generic \
    and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] \
    and certificate leaf[subject.OU] = DR99P625RR
    """

    override func setUpWithError() throws {
        folder = try ThrowawayApp.folder()
        steps = MacUpdateSteps(bundle: folder.appendingPathComponent("installed/Iguana.app"), version: "0.1.0",
                               trust: { try UpdateTrust(sameApp: Self.anyIguana, notarized: Self.anyIguana) },
                               protocols: [StubDownloads.self])
        StubDownloads.seen = []
        StubDownloads.answers = [:]
    }

    override func tearDown() {
        // A test may have locked a folder to see a step fail.
        if let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let url as URL in all { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    func sub(_ name: String) throws -> URL {
        let made = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }

    func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    func reason(_ work: @autoclosure () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            try work()
            XCTFail("this must be refused", file: file, line: line)
            return ""
        } catch {
            return UpdateFailure.reason(error)
        }
    }

    // MARK: The facts

    func testTheTestRunnerIsNeverAnAppThatUpdatesItself() {
        // The process these tests run in is no released Iguana, whatever signed it.
        let facts = MacUpdateSteps().facts()
        XCTAssertEqual(facts.running, Iguana.version)
        XCTAssertFalse(facts.bundlePath.hasPrefix("/Applications/Iguana.app"))
        guard case .refused = UpdateInstall.verdict(installing: "999.0.0", facts: facts) else {
            return XCTFail("a test run must not be able to replace itself: \(facts)")
        }
        let signature = MacUpdateSteps.runningSignature()
        XCTAssertEqual(facts.teamIdentifier, signature.team)
        XCTAssertEqual(facts.adHoc, signature.adHoc)
    }

    func testTheFactsSayWhatTheUserMayReplace() throws {
        let home = try sub("installed")
        let app = try ThrowawayApp.make(in: home, version: "0.1.0", marker: "old")
        XCTAssertEqual(steps.facts().bundlePath, app.path)
        XCTAssertEqual(steps.facts().running, "0.1.0")
        XCTAssertTrue(steps.facts().folderWritable)
        XCTAssertTrue(steps.facts().bundleWritable)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        XCTAssertFalse(steps.facts().folderWritable)
        XCTAssertTrue(steps.facts().bundleWritable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: app.path)
        XCTAssertFalse(steps.facts().bundleWritable)
    }

    func testAnAppReachedThroughALinkIsNamedByItsRealPlace() throws {
        let app = try ThrowawayApp.make(in: try sub("real"), version: "0.1.0")
        let link = folder.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        XCTAssertEqual(MacUpdateSteps(bundle: link, version: "0.1.0").facts().bundlePath, app.path)
    }

    // MARK: The workspace

    func testTheWorkspaceIsNewPrivateAndOnTheVolumeOfTheApp() throws {
        let app = try ThrowawayApp.make(in: try sub("installed"), version: "0.1.0")
        let first = try steps.makeWorkspace(for: app)
        let second = try steps.makeWorkspace(for: app)
        defer {
            steps.remove(first)
            steps.remove(second)
        }
        XCTAssertNotEqual(first, second, "a new one each time")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.path), [])
        XCTAssertEqual(try permissions(first), 0o700, "readable by this user only")
        XCTAssertFalse(first.path.hasPrefix("/Applications"))
        let here = try XCTUnwrap(first.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier)
        let there = try XCTUnwrap(app.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier)
        XCTAssertTrue(here.isEqual(there), "the swap is one move only on one volume")

        try Data("x".utf8).write(to: first.appendingPathComponent("Iguana-9.9.9.zip"))
        steps.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "and it goes with all that is in it")
    }

    // MARK: Download

    static let address = UpdateInstall.assetURL(version: "9.9.9")!

    func download(_ url: URL = MacUpdateStepsTests.address, limit: Int64 = UpdateInstall.largestDownload) throws -> (Result<Void, Error>, URL) {
        let target = folder.appendingPathComponent("download-\(UUID().uuidString).zip")
        let steps = MacUpdateSteps(version: "0.1.0", protocols: [StubDownloads.self], limit: limit)
        var result: Result<Void, Error>?
        let done = expectation(description: "downloaded")
        steps.download(url, to: target) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return (try XCTUnwrap(result), target)
    }

    func refusedDownload(_ url: URL = MacUpdateStepsTests.address, limit: Int64 = UpdateInstall.largestDownload) throws -> String {
        let (result, target) = try download(url, limit: limit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "what is refused is not kept")
        guard case .failure(let error) = result else {
            XCTFail("this download must be refused")
            return ""
        }
        return UpdateFailure.reason(error)
    }

    func testTheDownloadIsKeptWhereItWasAskedFor() throws {
        let body = Data((0..<20_000).map { UInt8($0 % 251) })
        StubDownloads.answers[Self.address.absoluteString] = .init(body: body, headers: ["Content-Length": "\(body.count)"])
        let (result, target) = try download()
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(try Data(contentsOf: target), body)
    }

    func testTheDownloadSaysNothingAboutTheUser() throws {
        StubDownloads.answers[Self.address.absoluteString] = .init(body: Data("zip".utf8))
        _ = try download()
        _ = try download()
        XCTAssertEqual(StubDownloads.seen.count, 2)
        for sent in StubDownloads.seen {
            XCTAssertEqual(sent.url, Self.address)
            XCTAssertEqual(sent.httpMethod, "GET")
            XCTAssertEqual(sent.value(forHTTPHeaderField: "User-Agent"), "Iguana/0.1.0")
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept-Language"), "en")
            XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie"), "the cookie the server set the first time is not sent back")
            XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        }

        let request = MacUpdateSteps.request(Self.address, version: "0.1.0")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.allHTTPHeaderFields, ["User-Agent": "Iguana/0.1.0", "Accept": "application/octet-stream", "Accept-Language": "en"])

        // Set up as the update check is, with more time.
        let configuration = UpdateChecker.configuration(silence: UpdateInstall.silenceTimeout, whole: UpdateInstall.downloadTimeout)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.timeoutIntervalForResource, UpdateInstall.downloadTimeout)
    }

    func testARedirectIsFollowedOverHTTPSAndNotOtherwise() throws {
        let stored = "https://objects.githubusercontent.com/github-production-release-asset/1/2"
        StubDownloads.answers[Self.address.absoluteString] = .init(status: 302, location: stored)
        StubDownloads.answers[stored] = .init(body: Data("the zip".utf8))
        let (result, target) = try download()
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(try Data(contentsOf: target), Data("the zip".utf8))
        XCTAssertEqual(StubDownloads.seen.compactMap { $0.url?.absoluteString }, [Self.address.absoluteString, stored])

        StubDownloads.seen = []
        let plain = "http://objects.githubusercontent.com/github-production-release-asset/1/2"
        StubDownloads.answers[Self.address.absoluteString] = .init(status: 302, location: plain)
        StubDownloads.answers[plain] = .init(body: Data("not the zip".utf8))
        XCTAssertEqual(try refusedDownload(), "the download was sent on to an address that is not https")
        XCTAssertEqual(StubDownloads.seen.compactMap { $0.url?.absoluteString }, [Self.address.absoluteString], "the other address is never asked")
    }

    func testAnAnswerThatIsNotTheFileIsRefused() throws {
        // Nothing answers: offline.
        XCTAssertFalse(try refusedDownload().isEmpty)

        StubDownloads.answers[Self.address.absoluteString] = .init(status: 404, body: Data("Not Found".utf8))
        XCTAssertEqual(try refusedDownload(), "this release has no download for Iguana to install")
        StubDownloads.answers[Self.address.absoluteString] = .init(status: 404)
        XCTAssertEqual(try refusedDownload(), "this release has no download for Iguana to install")
        StubDownloads.answers[Self.address.absoluteString] = .init(status: 503, body: Data("<html>".utf8))
        XCTAssertEqual(try refusedDownload(), "the download was answered with status 503")
    }

    func testADownloadThatIsTooLargeIsStoppedAndThrownAway() throws {
        let body = Data(repeating: 7, count: 50_000)
        // The server says so.
        StubDownloads.answers[Self.address.absoluteString] = .init(body: body, headers: ["Content-Length": "\(body.count)"])
        XCTAssertEqual(try refusedDownload(limit: 10_000), UpdateInstall.tooLarge(limit: 10_000))
        // The server does not say, and it is too large all the same.
        StubDownloads.answers[Self.address.absoluteString] = .init(body: body)
        XCTAssertEqual(try refusedDownload(limit: 10_000), UpdateInstall.tooLarge(limit: 10_000))
        // Just under the limit is a download like any other.
        let (result, _) = try download(limit: 50_000)
        XCTAssertNoThrow(try result.get())
    }

    func testWithoutAStandInATestDownloadsNothing() throws {
        let done = expectation(description: "refused")
        var result: Result<Void, Error>?
        MacUpdateSteps().download(Self.address, to: folder.appendingPathComponent("never.zip")) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        guard case .failure(let error) = try XCTUnwrap(result) else { return XCTFail("the network is not a test's to use") }
        XCTAssertEqual(UpdateFailure.reason(error), "a test may not download from the network")
        XCTAssertEqual(StubDownloads.seen.count, 0)
    }

    // MARK: Unpack

    func testAReleasesZipUnpacksToTheApp() throws {
        let made = try ThrowawayApp.make(in: try sub("release"))
        let zip = folder.appendingPathComponent("Iguana-9.9.9.zip")
        try ThrowawayApp.zip(made, to: zip)

        let target = folder.appendingPathComponent("unpacked")
        let app = try steps.unpack(zip, into: target)
        XCTAssertEqual(app, target.appendingPathComponent("Iguana.app"))
        XCTAssertEqual(ThrowawayApp.marker(of: app), "new")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/iguana").path))
        XCTAssertEqual(try permissions(target), 0o700, "readable by this user only")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["Iguana.app"])

        // A folder that is there already is not unpacked into.
        XCTAssertThrowsError(try steps.unpack(zip, into: target))
    }

    func testAZipWithoutTheAppIsRefused() throws {
        let made = try ThrowawayApp.make(in: try sub("release"), name: "Other.app")
        let zip = folder.appendingPathComponent("other.zip")
        try ThrowawayApp.zip(made, to: zip)
        XCTAssertEqual(reason(_ = try steps.unpack(zip, into: folder.appendingPathComponent("unpacked"))),
                       "the download holds Other.app, where a release holds Iguana.app and nothing else")

        let empty = try sub("empty")
        XCTAssertEqual(reason(_ = try MacUpdateSteps.bundle(in: empty)),
                       "the download holds nothing, where a release holds Iguana.app and nothing else")
    }

    func testAZipWithMoreThanTheAppIsRefused() throws {
        let release = try sub("release")
        try ThrowawayApp.make(in: release)
        try Data("run me".utf8).write(to: release.appendingPathComponent("install.command"))
        let zip = folder.appendingPathComponent("more.zip")
        try ThrowawayApp.zip(contentsOf: release, to: zip)
        XCTAssertEqual(reason(_ = try steps.unpack(zip, into: folder.appendingPathComponent("unpacked"))),
                       "the download holds Iguana.app, install.command, where a release holds Iguana.app and nothing else")

        // A file that hides is one too many as well.
        let hidden = try sub("hidden")
        try ThrowawayApp.make(in: hidden)
        try Data().write(to: hidden.appendingPathComponent(".extra"))
        XCTAssertTrue(reason(_ = try MacUpdateSteps.bundle(in: hidden)).hasPrefix("the download holds .extra, Iguana.app"))
    }

    func testALinkInTheAppsPlaceIsRefused() throws {
        // The link points at a real app elsewhere. Followed, it would pass for one.
        let elsewhere = try ThrowawayApp.make(in: try sub("elsewhere"))
        let release = try sub("release")
        try FileManager.default.createSymbolicLink(at: release.appendingPathComponent("Iguana.app"), withDestinationURL: elsewhere)
        XCTAssertEqual(reason(_ = try MacUpdateSteps.bundle(in: release)), "Iguana.app in the download is not a folder")

        // And the same through a zip that holds the link.
        let zip = folder.appendingPathComponent("link.zip")
        try ThrowawayApp.zip(contentsOf: release, to: zip)
        XCTAssertEqual(reason(_ = try steps.unpack(zip, into: folder.appendingPathComponent("unpacked"))),
                       "Iguana.app in the download is not a folder")

        // A plain file by that name is no app either.
        let file = try sub("file")
        try Data("not an app".utf8).write(to: file.appendingPathComponent("Iguana.app"))
        XCTAssertEqual(reason(_ = try MacUpdateSteps.bundle(in: file)), "Iguana.app in the download is not a folder")
    }

    func testWhatIsNotAZipIsRefused() throws {
        let zip = folder.appendingPathComponent("page.zip")
        try Data("<html>Not Found</html>".utf8).write(to: zip)
        XCTAssertTrue(reason(_ = try steps.unpack(zip, into: folder.appendingPathComponent("unpacked")))
            .hasPrefix("the download could not be unpacked"))
        XCTAssertTrue(reason(_ = try steps.unpack(folder.appendingPathComponent("missing.zip"), into: folder.appendingPathComponent("again")))
            .hasPrefix("the download could not be unpacked"))
    }

    // MARK: Verify

    /// A throwaway app that went the way a release goes: signed, zipped, unpacked.
    func unpackedApp(identifier: String = UpdateInstall.bundleIdentifier, version: String = "9.9.9", sign: Bool = true,
                     strip: Bool = false) throws -> URL {
        let made = try ThrowawayApp.make(in: try sub("release-\(UUID().uuidString)"), identifier: identifier, version: version)
        if strip { try ThrowawayApp.removeSignature(made) }
        if sign { try ThrowawayApp.signAdHoc(made) }
        let zip = folder.appendingPathComponent("\(UUID().uuidString).zip")
        try ThrowawayApp.zip(made, to: zip)
        return try steps.unpack(zip, into: folder.appendingPathComponent("unpacked-\(UUID().uuidString)"))
    }

    func lenient() throws -> UpdateTrust { try UpdateTrust(sameApp: Self.anyIguana, notarized: Self.anyIguana) }

    func testAnAppThatSatisfiesBothRequirementsAndIsTheVersionAskedForPasses() throws {
        // The requirements are the test's own: no throwaway app is signed as a release is.
        // What this shows is that an app that went through a zip passes the strict checks.
        let app = try unpackedApp()
        XCTAssertNoThrow(try MacUpdateSteps.verify(app, version: "9.9.9", trust: try lenient()))
        XCTAssertNoThrow(try steps.verify(app, version: "9.9.9"), "and the step asks for the trust it was made with")
        XCTAssertNoThrow(try MacUpdateSteps.verify(app, version: "v9.9.9", trust: try lenient()))
    }

    func testAnUnsignedAppIsRefused() throws {
        let app = try unpackedApp(sign: false, strip: true)
        let why = reason(try MacUpdateSteps.verify(app, version: "9.9.9", trust: try lenient()))
        XCTAssertEqual(why, "the download is not signed as the Iguana that is running (code object is not signed at all)")
        // Not with the real requirements either.
        let real = reason(try MacUpdateSteps.verify(app, version: "9.9.9", trust: try UpdateTrust(sameApp: Self.releasedIguana)))
        XCTAssertTrue(real.hasPrefix("the download is not signed as the Iguana that is running"), real)
    }

    func testAnAppWhoseProgramIsSignedByAnotherIsRefused() throws {
        // The program is Apple's own, with Apple's signature on it, in an app nobody signed.
        // A good signature is not enough: it has to be Iguana's.
        let app = try unpackedApp(sign: false)
        for trust in [try lenient(), try UpdateTrust(sameApp: Self.releasedIguana), try UpdateTrust(sameApp: "anchor apple generic")] {
            let why = reason(try MacUpdateSteps.verify(app, version: "9.9.9", trust: trust))
            XCTAssertTrue(why.hasPrefix("the download is not"), why)
        }
    }

    func testAnAdHocSignedAppIsRefused() throws {
        let app = try unpackedApp()
        // It is not signed by Iguana's team, which is what a released Iguana asks of its successor.
        let released = reason(try MacUpdateSteps.verify(app, version: "9.9.9", trust: try UpdateTrust(sameApp: Self.releasedIguana)))
        XCTAssertTrue(released.hasPrefix("the download is not signed as the Iguana that is running"), released)
        // And were it signed as Iguana, it would still not be notarized.
        let notarized = reason(try MacUpdateSteps.verify(app, version: "9.9.9", trust: try UpdateTrust(sameApp: Self.anyIguana)))
        XCTAssertTrue(notarized.hasPrefix("the download is not notarized by Apple"), notarized)
    }

    func testAnAppIsCheckedAgainstTheProcessThatIsRunning() throws {
        // Under test the running process is the test runner. A throwaway app is not that.
        let trust: UpdateTrust
        do { trust = try UpdateTrust.ofRunningApp() } catch {
            throw XCTSkip("the test runner has no signature to compare with: \(UpdateFailure.reason(error))")
        }
        let app = try unpackedApp()
        let why = reason(try MacUpdateSteps.verify(app, version: "9.9.9", trust: trust))
        XCTAssertTrue(why.hasPrefix("the download is not signed as the Iguana that is running"), why)
        // That is the trust the step uses unless a test hands it another.
        let unlikeTheRunner = reason(try MacUpdateSteps(version: "0.1.0").verify(app, version: "9.9.9"))
        XCTAssertTrue(unlikeTheRunner.hasPrefix("the download is not signed as the Iguana that is running"), unlikeTheRunner)
    }

    func testAnAppWithAnotherBundleIdentifierIsRefused() throws {
        // Signed under Iguana's name, so the signature passes, but the app says it is another.
        let app = try unpackedApp(identifier: "com.example.imposter")
        XCTAssertEqual(reason(try MacUpdateSteps.verify(app, version: "9.9.9", trust: try lenient())),
                       "the download is not Iguana: it calls itself com.example.imposter")
    }

    func testAnAppOfAnotherVersionIsRefused() throws {
        let older = try unpackedApp(version: "0.0.9")
        XCTAssertEqual(reason(try MacUpdateSteps.verify(older, version: "9.9.9", trust: try lenient())),
                       "the download is Iguana 0.0.9, not Iguana 9.9.9")
        let odd = try unpackedApp(version: "9.9.9-beta")
        XCTAssertEqual(reason(try MacUpdateSteps.verify(odd, version: "9.9.9", trust: try lenient())),
                       "the download is Iguana 9.9.9-beta, not Iguana 9.9.9")
    }

    func testAnAppChangedAfterItWasSignedIsRefused() throws {
        // A resource, the Info.plist, the program, and a file that was not there.
        let changes: [(String, (URL) throws -> Void)] = [
            ("a resource", { try Data("changed".utf8).write(to: $0.appendingPathComponent("Contents/Resources/marker.txt")) }),
            ("the Info.plist", { app in
                let url = app.appendingPathComponent("Contents/Info.plist")
                let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "9.9.9", with: "99.9.9")
                try Data(text.utf8).write(to: url)
            }),
            ("the program", { app in
                let url = app.appendingPathComponent("Contents/MacOS/iguana")
                var bytes = try Data(contentsOf: url)
                bytes[bytes.count / 2] ^= 0xFF
                try bytes.write(to: url)
            }),
            ("an added file", { try Data("extra".utf8).write(to: $0.appendingPathComponent("Contents/Resources/added.txt")) }),
        ]
        for (name, change) in changes {
            let app = try unpackedApp()
            XCTAssertNoThrow(try MacUpdateSteps.verify(app, version: "9.9.9", trust: try lenient()), name)
            try change(app)
            let why = reason(try MacUpdateSteps.verify(app, version: "9.9.9", trust: try lenient()))
            XCTAssertTrue(why.hasPrefix("the download is not signed as the Iguana that is running"), "\(name): \(why)")
        }
    }

    func testWhatIsNotThereIsRefused() throws {
        XCTAssertFalse(reason(try MacUpdateSteps.verify(folder.appendingPathComponent("Missing.app"), version: "9.9.9", trust: try lenient())).isEmpty)
        XCTAssertThrowsError(try UpdateTrust(sameApp: "this is not a requirement"))
        XCTAssertNoThrow(try UpdateTrust.requirement("notarized"), "the requirement the real check uses is one macOS reads")
        XCTAssertNoThrow(try UpdateTrust.requirement(Self.releasedIguana))
    }

    // MARK: Swap

    func testTheNewAppTakesThePlaceOfTheOldOne() throws {
        let home = try sub("installed")
        let installed = try ThrowawayApp.make(in: home, version: "0.1.0", marker: "old")
        let fresh = try ThrowawayApp.make(in: try sub("unpacked"), marker: "new")
        try MacUpdateSteps.swap(installed, with: fresh)

        XCTAssertEqual(ThrowawayApp.marker(of: installed), "new", "the same path now holds the new app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "it was moved, not copied")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["Iguana.app"], "and nothing is left beside it")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.appendingPathComponent("Contents/MacOS/iguana").path))
    }

    func testASignedAppIsStillValidWhereItWasPutInPlace() throws {
        let installed = try ThrowawayApp.make(in: try sub("installed"), version: "0.1.0", marker: "old")
        let fresh = try unpackedApp()
        try steps.swap(installed, with: fresh)
        XCTAssertNoThrow(try MacUpdateSteps.verify(installed, version: "9.9.9", trust: try lenient()), "the move changed nothing in it")
    }

    func testASwapThatCannotBeMadeLeavesTheOldApp() throws {
        let home = try sub("installed")
        let installed = try ThrowawayApp.make(in: home, version: "0.1.0", marker: "old")
        let unpacked = try sub("unpacked")

        // Nothing to put in its place.
        XCTAssertTrue(reason(try MacUpdateSteps.swap(installed, with: unpacked.appendingPathComponent("Iguana.app"))).hasPrefix("the new app is not a folder"))
        XCTAssertEqual(ThrowawayApp.marker(of: installed), "old")

        // A link where the new app should be.
        let elsewhere = try ThrowawayApp.make(in: try sub("elsewhere"), marker: "elsewhere")
        let link = unpacked.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        XCTAssertTrue(reason(try MacUpdateSteps.swap(installed, with: link)).hasPrefix("the new app is not a folder"))
        XCTAssertEqual(ThrowawayApp.marker(of: installed), "old")

        // Nothing to replace.
        let fresh = try ThrowawayApp.make(in: unpacked, marker: "new")
        XCTAssertTrue(reason(try MacUpdateSteps.swap(home.appendingPathComponent("Gone.app"), with: fresh)).hasPrefix("the app to replace is not a folder"))
        XCTAssertEqual(ThrowawayApp.marker(of: fresh), "new", "the new app was not moved anywhere")

        // A folder the user may not change, as /Applications is for some.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        XCTAssertTrue(reason(try MacUpdateSteps.swap(installed, with: fresh)).hasPrefix("the new app could not be put in the place of the old one"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        XCTAssertEqual(ThrowawayApp.marker(of: installed), "old", "the old app is whole and where it was")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["Iguana.app"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.appendingPathComponent("Contents/MacOS/iguana").path))
    }

    func testATestNeverReplacesAnAppInApplications() throws {
        let fresh = try ThrowawayApp.make(in: try sub("unpacked"))
        XCTAssertEqual(reason(try MacUpdateSteps.swap(URL(fileURLWithPath: "/Applications/Iguana.app"), with: fresh)),
                       "a test may not replace an app in /Applications")
        XCTAssertEqual(reason(try MacUpdateSteps.swap(URL(fileURLWithPath: "/Applications/../Applications/Iguana.app"), with: fresh)),
                       "a test may not replace an app in /Applications")
        XCTAssertEqual(ThrowawayApp.marker(of: fresh), "new")
    }

    // MARK: Restart

    func testTheRestartHandsThePathOverAsAnArgument() throws {
        // A path that would do harm if a shell ever read it as text.
        let path = "/tmp/it's \"$(touch /tmp/pwned)\"; `id` & rm -rf ~ #/Iguana $HOME.app"
        let shell = try MacUpdateSteps.relaunchProcess(bundle: URL(fileURLWithPath: path), pid: 4242)
        XCTAssertFalse(shell.isRunning, "made, and never started")
        XCTAssertEqual(shell.executableURL?.path, "/bin/sh")
        XCTAssertEqual(shell.arguments, ["-c", MacUpdateSteps.relaunchScript, "iguana-relaunch", "4242", path])
        XCTAssertEqual(shell.arguments?.last, path, "exactly as it is, and as one argument")

        // The text the shell reads is the same for every path and every process.
        let script = MacUpdateSteps.relaunchScript
        XCTAssertFalse(script.contains(path))
        XCTAssertFalse(script.contains("4242"))
        XCTAssertFalse(script.contains("pwned"))
        XCTAssertTrue(script.contains("kill -0 \"$1\""), "it waits for the old Iguana by its process number")
        XCTAssertTrue(script.contains("exec /usr/bin/open \"$2\""), "and opens the app by its path, in quotes")
        XCTAssertFalse(script.contains("sudo"))
        XCTAssertEqual(try MacUpdateSteps.relaunchProcess(bundle: URL(fileURLWithPath: "/Applications/Iguana.app"), pid: 7).arguments?[1], script)

        // The shell reads it as a script. It is only read here, with -n, and never run.
        XCTAssertEqual(ThrowawayApp.run("/bin/sh", ["-n", "-c", script]), 0)
    }

    func testOnlyAnAppIsOpenedAgain() {
        XCTAssertFalse(reason(_ = try MacUpdateSteps.relaunchProcess(bundle: URL(fileURLWithPath: "/usr/bin/true"), pid: 4242)).isEmpty)
        XCTAssertFalse(reason(_ = try MacUpdateSteps.relaunchProcess(bundle: URL(fileURLWithPath: "/Applications/Iguana.app"), pid: 0)).isEmpty)
        XCTAssertFalse(reason(_ = try MacUpdateSteps.relaunchProcess(bundle: URL(fileURLWithPath: "/Applications/Iguana.app"), pid: 1)).isEmpty)
        XCTAssertFalse(reason(_ = try MacUpdateSteps.relaunchProcess(bundle: URL(fileURLWithPath: "/Applications/Iguana.app"), pid: -1)).isEmpty,
                       "kill -0 -1 would ask about every process")
    }

    func testATestNeverRestartsAnything() throws {
        let app = try ThrowawayApp.make(in: try sub("installed"))
        XCTAssertEqual(reason(try steps.relaunch(app)), "a test may not restart anything")
    }
}

/// A whole install with the real steps: a throwaway "installed" app in a temporary folder, a
/// release served by the test, and everything between done for real. Two things are the
/// test's own: the facts about the running app, which would refuse a test runner at once, and
/// the restart, which is written down instead of made.
final class UpdateInstallRehearsalTests: XCTestCase {
    final class Rehearsal: UpdateSteps {
        let real: MacUpdateSteps
        var team: String? = "DR99P625RR"
        private(set) var workspaces: [URL] = []
        private(set) var relaunched: URL?

        init(_ real: MacUpdateSteps) { self.real = real }

        func facts() -> UpdateInstall.Facts {
            var facts = real.facts()
            facts.teamIdentifier = team
            facts.adHoc = false
            return facts
        }

        func makeWorkspace(for bundle: URL) throws -> URL {
            let made = try real.makeWorkspace(for: bundle)
            workspaces.append(made)
            return made
        }

        func download(_ url: URL, to file: URL, completion: @escaping (Result<Void, Error>) -> Void) {
            real.download(url, to: file, completion: completion)
        }

        func unpack(_ zip: URL, into folder: URL) throws -> URL { try real.unpack(zip, into: folder) }
        func verify(_ bundle: URL, version: String) throws { try real.verify(bundle, version: version) }
        func swap(_ installed: URL, with fresh: URL) throws { try real.swap(installed, with: fresh) }
        func relaunch(_ bundle: URL) throws { relaunched = bundle }
        func remove(_ workspace: URL) { real.remove(workspace) }
    }

    var folder: URL!
    var installed: URL!
    var suite: String!
    var defaults: UserDefaults!
    var steps: Rehearsal!
    var installer: UpdateInstaller!
    var logged: [String] = []
    var opened: [URL] = []
    let update = ShellFakes.update("9.9.9")

    override func setUpWithError() throws {
        folder = try ThrowawayApp.folder()
        let home = folder.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        installed = try ThrowawayApp.make(in: home, version: "0.1.0", marker: "old")
        suite = "iguana-rehearsal-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        logged = []
        opened = []
        StubDownloads.seen = []
        StubDownloads.answers = [:]
        steps = Rehearsal(MacUpdateSteps(bundle: installed, version: "0.1.0",
                                         trust: { try UpdateTrust(sameApp: MacUpdateStepsTests.anyIguana, notarized: MacUpdateStepsTests.anyIguana) },
                                         protocols: [StubDownloads.self]))
        installer = UpdateInstaller(steps: steps, defaults: defaults, log: { [unowned self] in logged.append($0) },
                                    openPage: { [unowned self] in opened.append($0) })
    }

    override func tearDown() {
        steps.workspaces.forEach { try? FileManager.default.removeItem(at: $0) }
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suite)
        installer = nil
        steps = nil
    }

    /// Publish a throwaway app as the release the installer will ask for.
    func publish(version: String = "9.9.9", identifier: String = UpdateInstall.bundleIdentifier, sign: Bool = true,
                 change: (URL) throws -> Void = { _ in }) throws {
        let made = try ThrowawayApp.make(in: folder.appendingPathComponent("release"), identifier: identifier, version: version, marker: "new")
        if sign { try ThrowawayApp.signAdHoc(made) }
        try change(made)
        let zip = folder.appendingPathComponent("release.zip")
        try ThrowawayApp.zip(made, to: zip)
        StubDownloads.answers[UpdateInstall.assetURL(version: "9.9.9")!.absoluteString] = .init(body: try Data(contentsOf: zip))
    }

    /// The installer works off the main thread and reports back on it.
    func waitUntilDone() {
        let deadline = Date().addingTimeInterval(30)
        while installer.isWorking, installer.state.stage != .restarting, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        // Let what was sent to the main thread last arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func assertNothingChanged(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(ThrowawayApp.marker(of: installed), "old", "the installed app is as it was", file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["Iguana.app"],
                       file: file, line: line)
        XCTAssertNil(steps.relaunched, "nothing was restarted", file: file, line: line)
        for workspace in steps.workspaces {
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path), "the temporary files are gone", file: file, line: line)
        }
        XCTAssertEqual(opened, [update.page], "the user is sent to the release's page", file: file, line: line)
    }

    func testAReleaseIsDownloadedCheckedAndPutInPlace() throws {
        try publish()
        XCTAssertTrue(installer.install(update))
        waitUntilDone()

        XCTAssertEqual(installer.state, .working(version: "9.9.9", stage: .restarting), logged.joined(separator: "\n"))
        XCTAssertEqual(ThrowawayApp.marker(of: installed), "new", "the new app is where the old one was")
        XCTAssertEqual(steps.relaunched?.path, installed.path, "and that is the app to open again")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["Iguana.app"])
        XCTAssertEqual(steps.workspaces.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: steps.workspaces[0].path), "nothing temporary is left behind")
        XCTAssertEqual(opened, [])
        XCTAssertEqual(StubDownloads.seen.map { $0.url?.absoluteString }, [UpdateInstall.assetURL(version: "9.9.9")?.absoluteString])
        XCTAssertNoThrow(try steps.real.verify(installed, version: "9.9.9"), "what is installed is what was verified")
    }

    func testAReleaseThatDoesNotVerifyChangesNothing() throws {
        // Unsigned, changed after signing, another app, another version: none is put in place.
        let releases: [(String, () throws -> Void)] = [
            ("unsigned", { try self.publish(sign: false) }),
            ("changed", { try self.publish { try Data("changed".utf8).write(to: $0.appendingPathComponent("Contents/Resources/marker.txt")) } }),
            ("another app", { try self.publish(identifier: "com.example.imposter") }),
            ("an older version", { try self.publish(version: "0.0.9") }),
        ]
        for (name, publish) in releases {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("release"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("release.zip"))
            opened = []
            try publish()
            XCTAssertTrue(installer.install(update), name)
            waitUntilDone()
            guard case .failed(_, let reason) = installer.state else {
                XCTFail("\(name): \(installer.state)")
                continue
            }
            XCTAssertTrue(reason.hasPrefix("the download is"), "\(name): \(reason)")
            try assertNothingChanged()
        }
    }

    func testADownloadThatFailsChangesNothing() throws {
        // No release answers: offline.
        XCTAssertTrue(installer.install(update))
        waitUntilDone()
        XCTAssertTrue(installer.state.stopped?.hasPrefix("the download failed") == true, "\(installer.state)")
        try assertNothingChanged()

        // A page in the place of the zip.
        opened = []
        StubDownloads.answers[UpdateInstall.assetURL(version: "9.9.9")!.absoluteString] = .init(body: Data("<html>Not Found</html>".utf8))
        XCTAssertTrue(installer.install(update))
        waitUntilDone()
        XCTAssertTrue(installer.state.stopped?.hasPrefix("the download could not be unpacked") == true, "\(installer.state)")
        try assertNothingChanged()
    }

    func testAnAppTheUserMayNotReplaceIsRefusedBeforeAnythingIsDownloaded() throws {
        try publish()
        let home = installed.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path) }
        XCTAssertTrue(installer.install(update))
        XCTAssertEqual(installer.state, .failed(version: "9.9.9", reason: UpdateInstall.Refusal.notWritable(installed.path).sentence))
        XCTAssertEqual(StubDownloads.seen.count, 0)
        XCTAssertEqual(steps.workspaces, [])
        XCTAssertEqual(opened, [update.page])
    }

    func testADevelopmentBuildIsRefusedBeforeAnythingIsDownloaded() throws {
        try publish()
        steps.team = nil
        XCTAssertTrue(installer.install(update))
        XCTAssertEqual(installer.state, .failed(version: "9.9.9", reason: UpdateInstall.Refusal.notSigned.sentence))
        XCTAssertEqual(StubDownloads.seen.count, 0)
        XCTAssertEqual(ThrowawayApp.marker(of: installed), "old")
    }
}
