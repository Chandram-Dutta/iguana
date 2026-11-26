import XCTest
@testable import IguanaCore

/// The decisions of an install: where a version is downloaded from, whether this copy of
/// Iguana may replace itself, what the answer to the download means, and the words for each
/// stage. Nothing here touches the network or the disk.
final class UpdateInstallTests: XCTestCase {
    /// An Iguana as a release leaves it in the Applications folder.
    static let released = UpdateInstall.Facts(bundlePath: "/Applications/Iguana.app", teamIdentifier: "DR99P625RR", adHoc: false,
                                              folderWritable: true, bundleWritable: true, running: "0.3.0")

    func verdict(_ version: String = "0.3.1", _ change: (inout UpdateInstall.Facts) -> Void = { _ in }) -> UpdateInstall.Verdict {
        var facts = Self.released
        change(&facts)
        return UpdateInstall.verdict(installing: version, facts: facts)
    }

    // MARK: The address

    func testTheAddressIsMadeFromTheVersionAndTheRepository() throws {
        XCTAssertEqual(UpdateInstall.assetURL(version: "0.3.1")?.absoluteString,
                       "https://github.com/Chandram-Dutta/iguana/releases/download/v0.3.1/Iguana-0.3.1.zip")
        XCTAssertEqual(UpdateInstall.assetName(version: "0.3.1"), "Iguana-0.3.1.zip")
        // A tag is read as its numbers, so the address is the same however it was written.
        XCTAssertEqual(UpdateInstall.assetURL(version: "v0.3.1"), UpdateInstall.assetURL(version: "0.3.1"))
        XCTAssertEqual(UpdateInstall.assetURL(version: "1.10")?.lastPathComponent, "Iguana-1.10.zip")
        let address = try XCTUnwrap(UpdateInstall.assetURL(version: "0.3.1"))
        XCTAssertTrue(address.path.hasPrefix("/" + UpdateCheck.repository + "/"), "the repository is named in one place")
        XCTAssertEqual(address.host, "github.com")
        XCTAssertEqual(address.scheme, "https")
    }

    func testNothingButAVersionMakesAnAddress() {
        for text in ["", "latest", "0.3.1-beta", "0.3.1/../../evil", "0.3.1?x=1", "0.3.1#x", "0.3 .1", "../0.3.1", "0.3.1%2F..", "1..2",
                     "https://example.com/Iguana-0.3.1.zip", "0.3.1\n", "٠.٣.١"] {
            XCTAssertNil(UpdateInstall.assetURL(version: text), text)
            XCTAssertNil(UpdateInstall.assetName(version: text), text)
        }
    }

    func testTheDownloadIsFollowedOnlyOverHTTPS() throws {
        func allows(_ text: String) throws -> Bool { UpdateInstall.allowsRedirect(to: try XCTUnwrap(URL(string: text))) }
        XCTAssertTrue(try allows("https://objects.githubusercontent.com/github-production-release-asset/1/2?sig=3"))
        XCTAssertTrue(try allows("HTTPS://release-assets.githubusercontent.com/x"))
        XCTAssertFalse(try allows("http://objects.githubusercontent.com/x"))
        XCTAssertFalse(try allows("file:///Applications/Iguana.app"))
        XCTAssertFalse(try allows("ftp://example.com/Iguana.zip"))
        XCTAssertFalse(try allows("https://user:secret@example.com/x"))
        XCTAssertFalse(try allows("https:///x"), "no host")
        XCTAssertFalse(try allows("/relative"))
    }

    func testWhatTheAnswerToTheDownloadMeans() {
        XCTAssertNil(UpdateInstall.downloadProblem(status: 200, expectedLength: 9_000_000))
        XCTAssertNil(UpdateInstall.downloadProblem(status: 200, expectedLength: -1), "a server need not say how much is coming")
        XCTAssertNil(UpdateInstall.downloadProblem(status: 200, expectedLength: UpdateInstall.largestDownload))
        XCTAssertEqual(UpdateInstall.downloadProblem(status: 200, expectedLength: UpdateInstall.largestDownload + 1),
                       "the download is larger than 200 MB, which no release of Iguana is")
        XCTAssertEqual(UpdateInstall.downloadProblem(status: 200, expectedLength: 11, limit: 10), UpdateInstall.tooLarge(limit: 10))
        XCTAssertEqual(UpdateInstall.downloadProblem(status: 404, expectedLength: 9), "this release has no download for Iguana to install")
        for status in [201, 206, 301, 302, 403, 429, 500, 503] {
            XCTAssertEqual(UpdateInstall.downloadProblem(status: status, expectedLength: 9), "the download was answered with status \(status)")
        }
        XCTAssertEqual(UpdateInstall.largestDownload, 200 * 1024 * 1024)
    }

    // MARK: May it?

    func testAReleasedIguanaInApplicationsMayReplaceItself() {
        XCTAssertEqual(verdict(), .allowed)
        XCTAssertEqual(verdict("v0.3.1"), .allowed)
        XCTAssertEqual(verdict { $0.bundlePath = "/Users/someone/Applications/Iguana.app" }, .allowed)
    }

    func testOnlyAnAppIsReplaced() {
        XCTAssertEqual(verdict { $0.bundlePath = "/Users/someone/iguana/.build/debug" }, .refused(.notAnApp))
        XCTAssertEqual(verdict { $0.bundlePath = "/Applications/Iguana.app/Contents/MacOS" }, .refused(.notAnApp))
        XCTAssertEqual(verdict { $0.bundlePath = "" }, .refused(.notAnApp))
    }

    func testATranslocatedAppIsNotReplaced() {
        let hidden = "/private/var/folders/ab/cd/T/AppTranslocation/0F0F0F0F-0000-0000-0000-000000000000/d/Iguana.app"
        XCTAssertEqual(verdict { $0.bundlePath = hidden }, .refused(.translocated))
    }

    func testADevelopmentBuildNeverUpdatesItself() {
        XCTAssertEqual(verdict { $0.teamIdentifier = nil }, .refused(.notSigned))
        XCTAssertEqual(verdict { $0.teamIdentifier = "" }, .refused(.notSigned))
        XCTAssertEqual(verdict { $0.adHoc = true }, .refused(.notSigned))
        XCTAssertEqual(verdict {
            $0.teamIdentifier = nil
            $0.adHoc = true
        }, .refused(.notSigned))
    }

    func testWhatTheUserMayNotReplaceIsRefused() {
        XCTAssertEqual(verdict { $0.folderWritable = false }, .refused(.notWritable("/Applications/Iguana.app")))
        XCTAssertEqual(verdict { $0.bundleWritable = false }, .refused(.notWritable("/Applications/Iguana.app")))
    }

    func testIguanaNeverGoesBack() {
        XCTAssertEqual(verdict("0.3.0"), .refused(.notNewer(version: "0.3.0", running: "0.3.0")))
        XCTAssertEqual(verdict("0.2.9"), .refused(.notNewer(version: "0.2.9", running: "0.3.0")))
        XCTAssertEqual(verdict("0.3"), .refused(.notNewer(version: "0.3", running: "0.3.0")), "0.3 is 0.3.0")
        XCTAssertEqual(verdict("0.3.0.1"), .allowed)
        XCTAssertEqual(verdict("0.10.0"), .allowed, "by number, not by text")
        XCTAssertEqual(verdict("nightly"), .refused(.notAVersion("nightly")))
        // A running version that cannot be read is not one anything is newer than.
        XCTAssertEqual(verdict { $0.running = "dev" }, .refused(.notNewer(version: "0.3.1", running: "dev")))
    }

    func testTheFirstReasonInTheOrderOfTheChecksIsTheOneGiven() {
        let everything: (inout UpdateInstall.Facts) -> Void = {
            $0.bundlePath = "/tmp/AppTranslocation/x/build"
            $0.teamIdentifier = nil
            $0.folderWritable = false
        }
        XCTAssertEqual(verdict("0.1.0", everything), .refused(.notAnApp))
        XCTAssertEqual(verdict("0.1.0") {
            everything(&$0)
            $0.bundlePath = "/tmp/AppTranslocation/x/Iguana.app"
        }, .refused(.translocated))
        XCTAssertEqual(verdict("0.1.0") {
            $0.teamIdentifier = nil
            $0.folderWritable = false
        }, .refused(.notSigned))
        XCTAssertEqual(verdict("0.1.0") { $0.folderWritable = false }, .refused(.notWritable("/Applications/Iguana.app")))
    }

    func testEveryRefusalHasASentence() {
        let refusals: [UpdateInstall.Refusal] = [.notAnApp, .translocated, .notSigned, .notWritable("/Applications/Iguana.app"),
                                                 .notAVersion("nightly"), .notNewer(version: "0.2.9", running: "0.3.0")]
        var seen = Set<String>()
        for refusal in refusals {
            XCTAssertFalse(refusal.sentence.isEmpty)
            XCTAssertFalse(refusal.sentence.contains("\n"), "one line, for the log and for status")
            seen.insert(refusal.sentence)
        }
        XCTAssertEqual(seen.count, refusals.count, "each says something of its own")
        XCTAssertTrue(UpdateInstall.Refusal.notWritable("/Applications/Iguana.app").sentence.contains("/Applications/Iguana.app"))
        XCTAssertTrue(UpdateInstall.Refusal.notWritable("/x").sentence.contains("never asks for an administrator's rights"))
        XCTAssertTrue(UpdateInstall.Refusal.notNewer(version: "0.2.9", running: "0.3.0").sentence.contains("0.2.9"))
        XCTAssertTrue(UpdateInstall.Refusal.notAVersion("nightly").sentence.contains("nightly"))
    }

    func testTheUnpackedAppMustBeTheVersionAskedFor() {
        XCTAssertTrue(UpdateInstall.isVersion("0.3.1", "0.3.1"))
        XCTAssertTrue(UpdateInstall.isVersion("0.3", "0.3.0"), "the same number written shorter")
        XCTAssertFalse(UpdateInstall.isVersion("0.3.0", "0.3.1"), "an older release in a newer one's place")
        XCTAssertFalse(UpdateInstall.isVersion("0.3.2", "0.3.1"))
        XCTAssertFalse(UpdateInstall.isVersion(nil, "0.3.1"))
        XCTAssertFalse(UpdateInstall.isVersion("", "0.3.1"))
        XCTAssertFalse(UpdateInstall.isVersion("0.3.1-beta", "0.3.1"))
        XCTAssertFalse(UpdateInstall.isVersion("0.3.1", "newest"))
    }

    func testTheIdentityOfTheApp() {
        XCTAssertEqual(UpdateInstall.bundleIdentifier, "xyz.onlychan.iguana")
        XCTAssertEqual(UpdateInstall.bundleName, "Iguana.app")
        XCTAssertGreaterThan(UpdateInstall.downloadTimeout, UpdateInstall.silenceTimeout)
    }

    // MARK: Progress

    func testTheMenuSaysWhatTheInstallIsDoing() {
        XCTAssertEqual(UpdateInstall.Stage.allCases, [.downloading, .checking, .installing, .restarting], "in the order they happen")
        XCTAssertEqual(UpdateInstall.Stage.allCases.map { $0.menuTitle(version: "0.3.1") }, [
            "Downloading Iguana 0.3.1…", "Checking Iguana 0.3.1…", "Installing Iguana 0.3.1…", "Restarting into Iguana 0.3.1…",
        ])
        XCTAssertEqual(UpdateInstall.State.working(version: "0.3.1", stage: .downloading).menuTitle, "Downloading Iguana 0.3.1…")
        XCTAssertNil(UpdateInstall.State.idle.menuTitle)
        XCTAssertNil(UpdateInstall.State.failed(version: "0.3.1", reason: "offline").menuTitle, "the item goes back to normal")
        XCTAssertNil(UpdateInstall.State.installed(version: "0.3.1", reason: "quit and open").menuTitle)
    }

    func testWhatStatusSaysOfAnInstall() {
        let working = UpdateInstall.State.working(version: "0.3.1", stage: .checking)
        let failed = UpdateInstall.State.failed(version: "0.3.1", reason: "the download failed (offline)")
        let installed = UpdateInstall.State.installed(version: "0.3.1", reason: "quit Iguana and open it again")
        XCTAssertNil(UpdateInstall.State.idle.statusLine)
        XCTAssertEqual(working.statusLine, "update: installing Iguana 0.3.1 (checking)")
        XCTAssertEqual(failed.statusLine, "update: Iguana 0.3.1 was not installed: the download failed (offline)")
        XCTAssertEqual(installed.statusLine, "update: Iguana 0.3.1 is installed: quit Iguana and open it again")

        XCTAssertEqual([UpdateInstall.State.idle, working, failed, installed].map(\.stage), [nil, .checking, nil, nil])
        XCTAssertEqual([UpdateInstall.State.idle, working, failed, installed].map(\.version), [nil, "0.3.1", "0.3.1", "0.3.1"])
        XCTAssertEqual([UpdateInstall.State.idle, working, failed, installed].map(\.stopped),
                       [nil, nil, "the download failed (offline)", "quit Iguana and open it again"])
    }

    // MARK: By itself

    func testAnInstallStartsByItselfOnlyWhenSwitchedOnAndNotUnderTheUsersHands() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func starts(on: Bool = true, tour: Bool = false, dragging: Bool = false, last: (String, TimeInterval)? = nil) -> Bool {
            UpdateInstall.startsByItself(switchedOn: on, tourShowing: tour, dragging: dragging, version: "0.3.1",
                                         lastTry: last.map { (version: $0.0, at: now.addingTimeInterval(-$0.1)) }, now: now)
        }
        XCTAssertTrue(starts())
        XCTAssertFalse(starts(on: false), "off unless the user switched it on")
        XCTAssertFalse(starts(tour: true), "not while the welcome tour is on screen")
        XCTAssertFalse(starts(dragging: true), "not while a window is in the hand")

        // What could not be installed is tried again a day later, not every hour.
        XCTAssertFalse(starts(last: ("0.3.1", 60)))
        XCTAssertFalse(starts(last: ("0.3.1", 23 * 3600)))
        XCTAssertTrue(starts(last: ("0.3.1", 24 * 3600)))
        XCTAssertTrue(starts(last: ("0.3.1", -60)), "the clock was set back")
        XCTAssertTrue(starts(last: ("0.3.0", 60)), "another version is news")
        XCTAssertFalse(starts(on: false, last: ("0.3.0", 60)))
        XCTAssertFalse(starts(tour: true, last: ("0.3.1", 48 * 3600)))
    }

    // MARK: The setting and the report

    func testTheSetting() throws {
        XCTAssertFalse(Config.default.installUpdates, "off unless switched on")
        let (on, none) = try Config.load("[updates]\ninstall = true\n")
        XCTAssertTrue(on.installUpdates)
        XCTAssertTrue(on.checkForUpdates)
        XCTAssertEqual(none, [])
        let (wrong, warnings) = try Config.load("[updates]\ninstall = \"always\"\n")
        XCTAssertFalse(wrong.installUpdates, "a value that is not true or false keeps the default")
        XCTAssertEqual(warnings, ["updates.install must be true or false; keeping the default"])
        XCTAssertEqual(try TOML.parse(Config.defaultText)["updates"]?.tableValue?["install"], .bool(false))
        XCTAssertFalse(try Config.load(Config.defaultText).config.installUpdates)
        XCTAssertTrue(Config.jsonSchema.contains("\"install\": { \"type\": \"boolean\", \"default\": false"))
    }

    func testStatusSaysWhatAnInstallIsDoing() throws {
        var status = ReportTests.status
        status.update = Report.Update(version: "0.3.1", url: "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.3.1",
                                      installing: "downloading")
        var text = Report.encode(status)
        XCTAssertTrue(text.contains("""
          "update" : {
            "installing" : "downloading",
            "url" : "https://github.com/Chandram-Dutta/iguana/releases/tag/v0.3.1",
            "version" : "0.3.1"
          },
        """), text)
        XCTAssertEqual(try JSONDecoder().decode(Report.Status.self, from: Data(text.utf8)), status)

        status.update = Report.Update(version: "0.3.1", url: "https://example.com", installStopped: "the download failed (offline)")
        text = Report.encode(status)
        XCTAssertTrue(text.contains("\"installStopped\" : \"the download failed (offline)\""), text)
        XCTAssertFalse(text.contains("\"installing\""), "left out when nothing is under way")
        XCTAssertEqual(try JSONDecoder().decode(Report.Status.self, from: Data(text.utf8)), status)
    }
}
