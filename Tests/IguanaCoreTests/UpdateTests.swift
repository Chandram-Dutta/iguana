import XCTest
@testable import IguanaCore

/// Noticing a newer release: versions, GitHub's answer, the address that may be opened, and
/// when to ask. Nothing here touches the network. The answers are written by hand from the
/// documented shape of GitHub's "get the latest release".
final class UpdateTests: XCTestCase {
    typealias Version = UpdateCheck.Version

    /// GitHub's answer for a release, with the fields a real one has. Iguana reads four of them.
    static func answer(tag: String = "v0.1.3", page: String? = "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3",
                       draft: Bool = false, prerelease: Bool = false) -> Data {
        let htmlURL = page.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {
          "url": "https://api.github.com/repos/Chandram-Dutta/iguana/releases/100000001",
          "assets_url": "https://api.github.com/repos/Chandram-Dutta/iguana/releases/100000001/assets",
          "upload_url": "https://uploads.github.com/repos/Chandram-Dutta/iguana/releases/100000001/assets{?name,label}",
          "html_url": \(htmlURL),
          "id": 100000001,
          "author": {
            "login": "octocat",
            "id": 1,
            "node_id": "MDQ6VXNlcjE=",
            "avatar_url": "https://github.com/images/error/octocat_happy.gif",
            "html_url": "https://github.com/octocat",
            "type": "User",
            "site_admin": false
          },
          "node_id": "RE_kwDOexample",
          "tag_name": "\(tag)",
          "target_commitish": "main",
          "name": "Iguana 0.1.3",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "created_at": "2026-11-20T10:00:00Z",
          "published_at": "2026-11-20T10:05:00Z",
          "assets": [
            {
              "url": "https://api.github.com/repos/Chandram-Dutta/iguana/releases/assets/200000001",
              "id": 200000001,
              "name": "Iguana.dmg",
              "content_type": "application/x-apple-diskimage",
              "state": "uploaded",
              "size": 4194304,
              "download_count": 42,
              "browser_download_url": "https://github.com/Chandram-Dutta/iguana/releases/download/v0.1.3/Iguana.dmg"
            }
          ],
          "tarball_url": "https://api.github.com/repos/Chandram-Dutta/iguana/tarball/v0.1.3",
          "zipball_url": "https://api.github.com/repos/Chandram-Dutta/iguana/zipball/v0.1.3",
          "body": "## What's Changed\\n* A fix by @octocat in https://github.com/Chandram-Dutta/iguana/pull/1"
        }
        """.utf8)
    }

    // MARK: Versions

    func testAVersionIsNumbersAndDots() throws {
        XCTAssertEqual(Version("0.1.3")?.components, [0, 1, 3])
        XCTAssertEqual(Version("v0.1.3")?.components, [0, 1, 3], "a release tag")
        XCTAssertEqual(Version("V2")?.components, [2])
        XCTAssertEqual(Version("1.2.3.4")?.components, [1, 2, 3, 4])
        XCTAssertEqual(Version("v0.10.0")?.description, "0.10.0", "shown without the v, and with its zeros")
        for bad in ["", "v", "nightly", "0.2.0-beta", "0.2.0-rc.1", "1..2", ".1", "1.", "1.2.3.4.5", "v v1", "vv1", "1.2 ", " 1.2",
                    "1.-2", "+1.2", "1.2a", "0x10", "١.٢", "1.99999999999999999999", "latest/../../x"] {
            XCTAssertNil(Version(bad), "'\(bad)' is not a version")
        }
    }

    func testVersionsCompareByNumberNotByText() throws {
        func v(_ text: String) throws -> Version { try XCTUnwrap(Version(text), text) }
        XCTAssertGreaterThan(try v("0.1.10"), try v("0.1.9"))
        XCTAssertGreaterThan(try v("0.2.0"), try v("0.1.99"))
        XCTAssertGreaterThan(try v("1.0"), try v("0.99.99"))
        XCTAssertGreaterThan(try v("0.1.2.1"), try v("0.1.2"))
        XCTAssertLessThan(try v("0.1.2"), try v("v0.1.3"))
        XCTAssertEqual(try v("0.2"), try v("0.2.0"), "what is left out counts as zero")
        XCTAssertFalse(try v("0.2") < v("0.2.0"))
        XCTAssertFalse(try v("0.2.0") < v("0.2"))
        XCTAssertEqual(try v("v1.2.3"), try v("1.2.3"))
    }

    // MARK: GitHub's answer

    func testReadsTheFourFieldsOfARelease() throws {
        let release = try XCTUnwrap(UpdateCheck.release(from: Self.answer()))
        XCTAssertEqual(release, UpdateCheck.Release(tag: "v0.1.3", page: "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3",
                                                    draft: false, prerelease: false))
        XCTAssertEqual(UpdateCheck.release(from: Self.answer(draft: true))?.draft, true)
        XCTAssertEqual(UpdateCheck.release(from: Self.answer(prerelease: true))?.prerelease, true)
        XCTAssertNil(try XCTUnwrap(UpdateCheck.release(from: Self.answer(page: nil))).page, "a release without a page is still a release")
    }

    func testAnAnswerThatIsNotAReleaseIsNotRead() {
        for body in ["", "not json", "[]", "null", "{}", "<html>Sign in</html>",
                     #"{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}"#,
                     #"{"tag_name":"v0.1.3","html_url":"https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3"}"#,
                     #"{"tag_name":"v0.1.3","draft":false}"#,
                     #"{"tag_name":13,"draft":false,"prerelease":false}"#,
                     #"{"tag_name":"v0.1.3","draft":"no","prerelease":false}"#,
                     #"{"tag_name":"v0.1.3","html_url":7,"draft":false,"prerelease":false}"#] {
            XCTAssertNil(UpdateCheck.release(from: Data(body.utf8)), body)
        }
        let long = Data(#"{"tag_name":"v0.1.3","draft":false,"prerelease":false,"body":""#.utf8)
            + Data(repeating: 0x61, count: UpdateCheck.longestAnswer) + Data("\"}".utf8)
        XCTAssertNil(UpdateCheck.release(from: long), "longer than any real answer")
    }

    func testAReleaseIsNewsOnlyWhenItIsAFullReleaseWithAGreaterVersion() throws {
        func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> UpdateCheck.Release {
            UpdateCheck.Release(tag: tag, page: "https://github.com/Chandram-Dutta/iguana/releases/tag/\(tag)", draft: draft, prerelease: prerelease)
        }
        let update = try XCTUnwrap(UpdateCheck.news(release("v0.1.3"), running: "0.1.2"))
        XCTAssertEqual(update.version, "0.1.3")
        XCTAssertEqual(update.page.absoluteString, "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3")
        XCTAssertEqual(UpdateCheck.news(release("v0.1.10"), running: "0.1.9")?.version, "0.1.10")
        XCTAssertEqual(UpdateCheck.news(release("1.0"), running: "0.9.9")?.version, "1.0")

        XCTAssertNil(UpdateCheck.news(release("v0.1.2"), running: "0.1.2"), "the version that is running")
        XCTAssertNil(UpdateCheck.news(release("v0.1.1"), running: "0.1.2"), "an older one")
        XCTAssertNil(UpdateCheck.news(release("v0.1.9"), running: "0.1.10"))
        XCTAssertNil(UpdateCheck.news(release("v0.2.0"), running: "0.2"))
        XCTAssertNil(UpdateCheck.news(release("v0.1.3", draft: true), running: "0.1.2"))
        XCTAssertNil(UpdateCheck.news(release("v0.1.3", prerelease: true), running: "0.1.2"))
        XCTAssertNil(UpdateCheck.news(release("v0.2.0-beta"), running: "0.1.2"), "a tag that is not a version is ignored")
        XCTAssertNil(UpdateCheck.news(release("nightly"), running: "0.1.2"))
        XCTAssertNil(UpdateCheck.news(release("v9.9.9"), running: "a development build"), "nothing is newer than a version that cannot be read")
    }

    func testTheVersionShownIsDigitsAndDotsWhateverTheTagSaid() throws {
        let update = try XCTUnwrap(UpdateCheck.news(UpdateCheck.Release(tag: "V0.1.3", page: nil, draft: false, prerelease: false), running: "0.1.2"))
        XCTAssertEqual(update.version, "0.1.3")
        XCTAssertEqual(UpdateCheck.menuTitle(update), "Update to Iguana 0.1.3…")
        XCTAssertEqual(update.page, UpdateCheck.releasesPage, "without a page of its own, the list of releases")
        XCTAssertEqual(UpdateCheck.statusLine(update), "update: Iguana 0.1.3 is available (https://github.com/Chandram-Dutta/iguana/releases)")
    }

    // MARK: The address that is opened

    func testOnlyAPageOfThisRepositoryOnGitHubIsOpened() {
        for good in ["https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3",
                     "https://github.com/Chandram-Dutta/iguana/releases",
                     "https://github.com/Chandram-Dutta/iguana/releases/latest",
                     "HTTPS://GitHub.com/chandram-dutta/Iguana/releases/tag/v1.0"] {
            XCTAssertEqual(UpdateCheck.page(good).absoluteString.lowercased(), good.lowercased(), good)
            XCTAssertEqual(UpdateCheck.page(good).scheme, "https")
            XCTAssertEqual(UpdateCheck.page(good).host, "github.com")
        }
        XCTAssertEqual(UpdateCheck.page("https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3").absoluteString,
                       "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3")
        XCTAssertEqual(UpdateCheck.page("https://github.com/Chandram-Dutta/iguana/releases/tag/%76%30.1.3").absoluteString,
                       "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3", "put together again from the checked parts")
    }

    func testAnyOtherAddressBecomesTheListOfReleases() {
        let bad = [
            nil, "", "v0.1.3", "/Chandram-Dutta/iguana/releases/tag/v0.1.3", "github.com/Chandram-Dutta/iguana/releases",
            // Not https.
            "http://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3",
            "file:///Applications/Calculator.app", "javascript:alert(1)", "x-apple.systempreferences:com.apple.preference.security",
            "ftp://github.com/Chandram-Dutta/iguana/releases",
            // Not github.com.
            "https://example.com/Chandram-Dutta/iguana/releases/tag/v0.1.3",
            "https://github.com.example.com/Chandram-Dutta/iguana/releases",
            "https://evilgithub.com/Chandram-Dutta/iguana/releases",
            "https://www.github.com/Chandram-Dutta/iguana/releases",
            "https://gist.github.com/Chandram-Dutta/iguana/releases",
            "https://github.com./Chandram-Dutta/iguana/releases",
            "https://github.com@example.com/Chandram-Dutta/iguana/releases",
            "https://github.com:pass@example.com/Chandram-Dutta/iguana/releases",
            "https://user@github.com/Chandram-Dutta/iguana/releases",
            "https://github.com:8443/Chandram-Dutta/iguana/releases",
            "https://example.com/https://github.com/Chandram-Dutta/iguana/releases",
            "https://gіthub.com/Chandram-Dutta/iguana/releases",
            // Not this repository.
            "https://github.com", "https://github.com/", "https://github.com/Chandram-Dutta", "https://github.com/Chandram-Dutta/iguana",
            "https://github.com/Chandram-Dutta/iguana/", "https://github.com/Chandram-Dutta/iguana-evil/releases",
            "https://github.com/Someone-Else/iguana/releases/tag/v0.1.3", "https://github.com/Chandram-Dutta/other/releases",
            "https://github.com//Chandram-Dutta/iguana/releases", "https://github.com/x/Chandram-Dutta/iguana/releases",
            // Climbing out of it.
            "https://github.com/Chandram-Dutta/iguana/../../evil/repo/releases",
            "https://github.com/Chandram-Dutta/iguana/releases/../../../evil",
            "https://github.com/Chandram-Dutta/iguana/%2e%2e/%2e%2e/evil/repo",
            "https://github.com/Chandram-Dutta/iguana/..%2f..%2fevil/repo",
            "https://github.com/Chandram-Dutta/iguana/..\\..\\evil\\repo",
            "https://github.com/Chandram-Dutta/iguana/%5c..%5c..%5cevil",
            "https://github.com/Chandram-Dutta/iguana/./releases",
            "https://github.com/Chandram-Dutta/iguana//releases",
            "https://github.com/Chandram-Dutta/iguana/releases/",
            // Anything a release's page does not have.
            "https://github.com/Chandram-Dutta/iguana/releases?tab=1", "https://github.com/Chandram-Dutta/iguana/releases#x",
            "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3 ", " https://github.com/Chandram-Dutta/iguana/releases",
            "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3\n", "https://github.com/Chandram-Dutta/iguana/releases/a%09b",
            "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3%00", "https://github.com/Chandram-Dutta/iguana/releases/tag/é",
            "https://github.com/Chandram-Dutta/iguana/releases/" + String(repeating: "a", count: 600),
        ]
        for text in bad {
            XCTAssertEqual(UpdateCheck.page(text), UpdateCheck.releasesPage, text ?? "nil")
        }
        XCTAssertEqual(UpdateCheck.releasesPage.absoluteString, "https://github.com/Chandram-Dutta/iguana/releases")
        XCTAssertEqual(UpdateCheck.page(UpdateCheck.releasesPage.absoluteString), UpdateCheck.releasesPage, "the fallback passes its own check")
    }

    func testTheRepositoryIsNamedOnce() {
        XCTAssertEqual(UpdateCheck.latestReleaseURL.absoluteString, "https://api.github.com/repos/\(UpdateCheck.repository)/releases/latest")
        XCTAssertEqual(UpdateCheck.releasesPage.absoluteString, "https://github.com/\(UpdateCheck.repository)/releases")
        XCTAssertEqual(UpdateCheck.userAgent(version: "0.1.2"), "Iguana/0.1.2")
    }

    func testARedirectIsFollowedOnlyToGitHubsAPI() throws {
        func allows(_ text: String) throws -> Bool { UpdateCheck.allowsRedirect(to: try XCTUnwrap(URL(string: text), text)) }
        XCTAssertTrue(try allows("https://api.github.com/repositories/123456/releases/latest"), "where a renamed repository sends you")
        for bad in ["http://api.github.com/repositories/1/releases/latest", "https://example.com/repos/Chandram-Dutta/iguana/releases/latest",
                    "https://github.com/login", "https://api.github.com.example.com/x", "https://user@api.github.com/x",
                    "https://api.github.com:8443/x", "file:///etc/passwd"] {
            XCTAssertFalse(try allows(bad), bad)
        }
    }

    // MARK: The outcome

    func testWhatAnAnswerMeans() throws {
        guard case .newer(let update) = UpdateCheck.outcome(status: 200, body: Self.answer(), running: "0.1.2") else {
            return XCTFail("0.1.3 is newer than 0.1.2")
        }
        XCTAssertEqual(update.version, "0.1.3")
        XCTAssertEqual(UpdateCheck.outcome(status: 200, body: Self.answer(), running: "0.1.3"), .latest)
        XCTAssertEqual(UpdateCheck.outcome(status: 200, body: Self.answer(), running: "0.2.0"), .latest, "a build ahead of the releases")
        XCTAssertEqual(UpdateCheck.outcome(status: 200, body: Self.answer(tag: "nightly"), running: "0.1.2"), .latest)
        XCTAssertEqual(UpdateCheck.outcome(status: 200, body: Self.answer(prerelease: true), running: "0.1.2"), .latest)

        // A page that is not this repository's is not opened: the list of releases is.
        guard case .newer(let odd) = UpdateCheck.outcome(status: 200, body: Self.answer(page: "https://example.com/get"), running: "0.1.2") else {
            return XCTFail("still a newer version")
        }
        XCTAssertEqual(odd.page, UpdateCheck.releasesPage)

        for (status, body) in [(200, Data("<html>".utf8)), (200, Data()), (301, Data()), (403, Self.answer()), (404, Self.answer()),
                               (429, Data()), (500, Data()), (503, Self.answer())] {
            guard case .failed(let why) = UpdateCheck.outcome(status: status, body: body, running: "0.1.2") else {
                XCTFail("status \(status) is not an answer")
                continue
            }
            XCTAssertFalse(why.isEmpty)
        }
    }

    func testTheOneLineOfTheCommand() throws {
        let update = try XCTUnwrap(UpdateCheck.release(from: Self.answer()).flatMap { UpdateCheck.news($0, running: "0.1.2") })
        XCTAssertEqual(UpdateCheck.Outcome.latest.reply(running: "0.1.2"), "ok: Iguana 0.1.2 is the latest version")
        XCTAssertEqual(UpdateCheck.Outcome.newer(update).reply(running: "0.1.2"),
                       "ok: Iguana 0.1.3 is available at https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3")
        XCTAssertEqual(UpdateCheck.Outcome.failed("offline").reply(running: "0.1.2"), "error: could not check for a newer version: offline")
        for outcome in [UpdateCheck.Outcome.latest, .newer(update), .failed("offline")] {
            XCTAssertFalse(outcome.reply(running: "0.1.2").contains("\n"), "one line")
            XCTAssertFalse(outcome.summary(running: "0.1.2").isEmpty)
        }
        // The command line exits with an error only when the check could not be made.
        XCTAssertTrue(UpdateCheck.Outcome.failed("offline").reply(running: "0.1.2").hasPrefix("error"))
    }

    // MARK: When to ask

    func testACheckIsDueOnceADayAndOnlyWhenSwitchedOn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func due(_ enabled: Bool, _ secondsAgo: TimeInterval?) -> Bool {
            UpdateCheck.isDue(enabled: enabled, lastCheck: secondsAgo.map { now.addingTimeInterval(-$0) }, now: now)
        }
        XCTAssertTrue(due(true, nil), "never asked before")
        XCTAssertFalse(due(true, 0))
        XCTAssertFalse(due(true, 60), "restarting often does not mean asking often")
        XCTAssertFalse(due(true, 23 * 3600 + 3599))
        XCTAssertTrue(due(true, 24 * 3600))
        XCTAssertTrue(due(true, 30 * 24 * 3600))
        XCTAssertTrue(due(true, -3600), "the clock was set back")
        for ago in [nil, 0, 60, 24 * 3600, 30 * 24 * 3600, -3600] as [TimeInterval?] {
            XCTAssertFalse(due(false, ago), "switched off")
        }
        XCTAssertEqual(UpdateCheck.interval, 86400)
        XCTAssertLessThanOrEqual(UpdateCheck.timeout, 15, "a short timeout")
    }

    func testWhatWasFoundBeforeIsLookedAtAgain() {
        let page = "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3"
        XCTAssertEqual(UpdateCheck.remembered(version: "0.1.3", page: page, running: "0.1.2")?.version, "0.1.3")
        XCTAssertEqual(UpdateCheck.remembered(version: "0.1.3", page: page, running: "0.1.2")?.page.absoluteString, page)
        XCTAssertNil(UpdateCheck.remembered(version: "0.1.3", page: page, running: "0.1.3"), "after the upgrade it is not news")
        XCTAssertNil(UpdateCheck.remembered(version: "0.1.3", page: page, running: "0.2.0"))
        XCTAssertNil(UpdateCheck.remembered(version: nil, page: page, running: "0.1.2"))
        XCTAssertNil(UpdateCheck.remembered(version: "rubbish", page: page, running: "0.1.2"))
        // What is kept between runs is a file anyone can edit, so the address is checked again.
        XCTAssertEqual(UpdateCheck.remembered(version: "0.1.3", page: "https://example.com/get", running: "0.1.2")?.page, UpdateCheck.releasesPage)
    }

    // MARK: The setting, the command and the report

    func testTheSetting() throws {
        XCTAssertTrue(Config.default.checkForUpdates, "on unless switched off")
        let (off, none) = try Config.load("[updates]\ncheck = false\n")
        XCTAssertFalse(off.checkForUpdates)
        XCTAssertEqual(none, [])
        let (wrong, warnings) = try Config.load("[updates]\ncheck = \"daily\"\nchannel = \"beta\"\n")
        XCTAssertTrue(wrong.checkForUpdates, "a value that is not true or false keeps the default")
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings.contains("updates.check must be true or false; keeping the default"))
        XCTAssertTrue(warnings.contains("unknown key 'channel' in [updates]"))
        XCTAssertEqual(try TOML.parse(Config.defaultText)["updates"]?.tableValue?["check"], .bool(true))
    }

    func testTheCommand() throws {
        XCTAssertEqual(try Command.parse("update"), .update)
        XCTAssertEqual(try Command.parseRequest(" Update ").command, .update)
        XCTAssertThrowsError(try Command.parse("update now"))
        XCTAssertThrowsError(try Command.parseRequest("update --json"), "one line, not a document")
        XCTAssertTrue(Command.usage.contains("\nupdate "))
        // A config that binds it is a valid config, so the schema lets it through.
        XCTAssertTrue(Config.jsonSchema.contains("\"update\""))
        XCTAssertEqual(try Config.load("[bindings]\noption-u = \"update\"\n").config.bindings.first { $0.commandText == "update" }?.command, .update)
    }

    func testStatusSaysWhichVersionIsNewer() throws {
        var status = ReportTests.status
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Report.encode(status).utf8)) as? [String: Any])
        XCTAssertTrue(none["update"] is NSNull, "the key is there when nothing newer is known")

        status.update = Report.Update(version: "0.1.3", url: "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3")
        let text = Report.encode(status)
        XCTAssertTrue(text.contains("""
          "update" : {
            "url" : "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.1.3",
            "version" : "0.1.3"
          },
        """), text)
        XCTAssertEqual(try JSONDecoder().decode(Report.Status.self, from: Data(text.utf8)), status)
    }
}
