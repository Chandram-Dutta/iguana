import XCTest
import IguanaCore
@testable import iguana

/// Stands in for the Mac during an install: downloads nothing, unpacks nothing, checks no
/// signature, replaces no app and restarts nothing. It writes down what it was asked, in
/// order, and fails at the step a test names.
final class FakeUpdateSteps: UpdateSteps {
    enum Step: String, CaseIterable {
        case workspace, download, unpack, verify, swap, relaunch
    }

    var theFacts = UpdateInstall.Facts(bundlePath: "/Fake/Applications/Iguana.app", teamIdentifier: "DR99P625RR", adHoc: false,
                                       folderWritable: true, bundleWritable: true, running: "0.1.0")
    /// The step that fails, and what it says.
    var failing: Step?
    var reason = "the fake said no"
    /// Every step asked for, oldest first.
    private(set) var asked: [String] = []
    /// Downloads that are held back until the test lets them go.
    var held: [(Result<Void, Error>) -> Void]?
    private(set) var workspaces: [URL] = []
    private(set) var removed: [URL] = []
    private(set) var downloads: [(from: URL, to: URL)] = []
    /// The app that was put in place, if one was. Nil means the installed app is as it was.
    private(set) var swappedIn: URL?
    private(set) var relaunched: URL?

    private func step(_ step: Step, _ detail: String = "") throws {
        asked.append(detail.isEmpty ? step.rawValue : "\(step.rawValue) \(detail)")
        if failing == step { throw UpdateFailure(reason) }
    }

    func facts() -> UpdateInstall.Facts {
        asked.append("facts")
        return theFacts
    }

    func makeWorkspace(for bundle: URL) throws -> URL {
        try step(.workspace, bundle.path)
        let folder = URL(fileURLWithPath: "/Fake/Temporary/install-\(workspaces.count + 1)")
        workspaces.append(folder)
        return folder
    }

    func download(_ url: URL, to file: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        asked.append("download")
        downloads.append((url, file))
        if held != nil { return held!.append(completion) }
        completion(failing == .download ? .failure(UpdateFailure(reason)) : .success(()))
    }

    func unpack(_ zip: URL, into folder: URL) throws -> URL {
        try step(.unpack, "\(zip.lastPathComponent) into \(folder.lastPathComponent)")
        return folder.appendingPathComponent("Iguana.app")
    }

    func verify(_ bundle: URL, version: String) throws {
        try step(.verify, version)
    }

    func swap(_ installed: URL, with fresh: URL) throws {
        try step(.swap, installed.path)
        swappedIn = fresh
    }

    func relaunch(_ bundle: URL) throws {
        try step(.relaunch, bundle.path)
        relaunched = bundle
    }

    func remove(_ workspace: URL) {
        asked.append("remove")
        removed.append(workspace)
    }
}

/// The order of an install, with every step played by the test.
final class UpdateInstallerTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var steps: FakeUpdateSteps!
    var logged: [String] = []
    var opened: [URL] = []
    var states: [UpdateInstall.State] = []
    var installer: UpdateInstaller!
    let update = ShellFakes.update("9.9.9")

    override func setUp() {
        // What is remembered between runs goes to a throwaway place, not to the user's own.
        suite = "iguana-installer-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        steps = FakeUpdateSteps()
        logged = []
        opened = []
        states = []
        installer = makeInstaller()
    }

    override func tearDown() {
        installer = nil
        steps = nil
        defaults.removePersistentDomain(forName: suite)
    }

    /// A new installer on a new fake Mac, for a test that goes through several cases.
    func startAgain() {
        tearDown()
        setUp()
    }

    /// Everything runs where it is called, so a whole install is over when `install` returns.
    func makeInstaller() -> UpdateInstaller {
        let made = UpdateInstaller(steps: steps, defaults: defaults, now: { [unowned self] in clock },
                                   log: { [unowned self] in logged.append($0) }, openPage: { [unowned self] in opened.append($0) },
                                   background: { $0() }, main: { $0() })
        made.onChange = { [unowned self, unowned made] in states.append(made.state) }
        return made
    }

    static let wholeInstall = [
        "facts", "workspace /Fake/Applications/Iguana.app", "download", "unpack Iguana-9.9.9.zip into unpacked",
        "verify 9.9.9", "swap /Fake/Applications/Iguana.app", "remove", "relaunch /Fake/Applications/Iguana.app",
    ]

    // MARK: The order

    func testAnInstallGoesThroughEveryStepInOrder() {
        XCTAssertEqual(installer.state, .idle)
        XCTAssertTrue(installer.install(update))
        XCTAssertEqual(steps.asked, Self.wholeInstall)
        XCTAssertEqual(steps.swappedIn?.path, "/Fake/Temporary/install-1/unpacked/Iguana.app", "what was verified is what was put in place")
        XCTAssertEqual(steps.relaunched?.path, "/Fake/Applications/Iguana.app")
        XCTAssertEqual(steps.removed, steps.workspaces, "nothing temporary is left behind")
        XCTAssertEqual(opened, [], "no browser when it worked")
    }

    func testTheDownloadIsMadeFromTheVersionAndGoesIntoTheWorkspace() throws {
        installer.install(update)
        let download = try XCTUnwrap(steps.downloads.first)
        XCTAssertEqual(download.from, UpdateInstall.assetURL(version: "9.9.9"))
        XCTAssertEqual(download.from.absoluteString, "https://github.com/Chandram-Dutta/iguana/releases/download/v9.9.9/Iguana-9.9.9.zip")
        XCTAssertNotEqual(download.from, update.page, "the page a server named is never what is downloaded")
        XCTAssertEqual(download.to.path, "/Fake/Temporary/install-1/Iguana-9.9.9.zip")
        XCTAssertEqual(steps.downloads.count, 1)
    }

    func testProgressIsReportedStageByStage() {
        installer.install(update)
        XCTAssertEqual(states, UpdateInstall.Stage.allCases.map { UpdateInstall.State.working(version: "9.9.9", stage: $0) })
        XCTAssertEqual(installer.state.menuTitle, "Restarting into Iguana 9.9.9…")
        XCTAssertEqual(logged, [
            "update: installing Iguana 9.9.9, chosen in the menu",
            "update: downloading https://github.com/Chandram-Dutta/iguana/releases/download/v9.9.9/Iguana-9.9.9.zip",
            "update: unpacking Iguana 9.9.9 and checking its signature",
            "update: the download is Iguana 9.9.9; replacing /Fake/Applications/Iguana.app",
            "update: Iguana 9.9.9 is in place; restarting",
        ])
    }

    // MARK: Refusals

    func testARefusalDownloadsNothing() {
        let refusals: [(String, (inout UpdateInstall.Facts) -> Void, UpdateInstall.Refusal)] = [
            ("a build folder", { $0.bundlePath = "/Fake/iguana/.build/debug" }, .notAnApp),
            ("translocated", { $0.bundlePath = "/private/var/folders/x/AppTranslocation/y/d/Iguana.app" }, .translocated),
            ("no team", { $0.teamIdentifier = nil }, .notSigned),
            ("ad hoc", { $0.adHoc = true }, .notSigned),
            ("the folder", { $0.folderWritable = false }, .notWritable("/Fake/Applications/Iguana.app")),
            ("the app", { $0.bundleWritable = false }, .notWritable("/Fake/Applications/Iguana.app")),
            ("not newer", { $0.running = "9.9.9" }, .notNewer(version: "9.9.9", running: "9.9.9")),
            ("a downgrade", { $0.running = "10.0.0" }, .notNewer(version: "9.9.9", running: "10.0.0")),
        ]
        for (name, change, refusal) in refusals {
            startAgain()
            change(&steps.theFacts)
            XCTAssertTrue(installer.install(update), name)
            XCTAssertEqual(steps.asked, ["facts"], "\(name): asked, refused, and nothing else was done")
            XCTAssertEqual(installer.state, .failed(version: "9.9.9", reason: refusal.sentence), name)
            XCTAssertEqual(states, [installer.state], name)
            XCTAssertEqual(logged.last, "update: opening \(update.page.absoluteString) instead", name)
            XCTAssertTrue(logged.contains("update: Iguana 9.9.9 was not installed: \(refusal.sentence)"), name)
            XCTAssertEqual(opened, [update.page], "\(name): the user is sent to the release's page instead")
        }
    }

    func testAFailureAtAnyStepStopsThereAndClearsUp() {
        // What had been asked for when each step failed.
        let stops: [(FakeUpdateSteps.Step, asked: Int)] = [(.workspace, 2), (.download, 3), (.unpack, 4), (.verify, 5), (.swap, 6)]
        for (step, count) in stops {
            startAgain()
            steps.failing = step
            steps.reason = "no \(step.rawValue) today"
            XCTAssertTrue(installer.install(update), step.rawValue)

            // It stopped there: the steps before it ran, the ones after it did not.
            let cleared = step == .workspace ? [] : ["remove"]
            XCTAssertEqual(steps.asked, Array(Self.wholeInstall.prefix(count)) + cleared, step.rawValue)
            XCTAssertNil(steps.swappedIn, "\(step.rawValue): the installed app is as it was")
            XCTAssertNil(steps.relaunched, "\(step.rawValue): nothing was restarted")
            XCTAssertEqual(steps.removed, steps.workspaces, "\(step.rawValue): the temporary files are gone")

            // It says why, goes back to where an install can be chosen, and opens the page.
            guard case .failed(let version, let reason) = installer.state else {
                XCTFail("\(step.rawValue): \(installer.state)")
                continue
            }
            XCTAssertEqual(version, "9.9.9")
            XCTAssertTrue(reason.contains("no \(step.rawValue) today"), reason)
            XCTAssertNil(installer.state.menuTitle, step.rawValue)
            XCTAssertFalse(installer.isWorking, step.rawValue)
            XCTAssertEqual(states.last, installer.state, step.rawValue)
            XCTAssertTrue(logged.contains("update: Iguana 9.9.9 was not installed: \(reason)"), step.rawValue)
            XCTAssertEqual(opened, [update.page], step.rawValue)
        }
    }

    func testAnAppThatDoesNotVerifyIsNeverPutInPlace() {
        steps.failing = .verify
        steps.reason = "the download is not signed as the Iguana that is running"
        installer.install(update)
        XCTAssertFalse(steps.asked.contains { $0.hasPrefix("swap") })
        XCTAssertFalse(steps.asked.contains { $0.hasPrefix("relaunch") })
        XCTAssertEqual(installer.state, .failed(version: "9.9.9", reason: "the download is not signed as the Iguana that is running"))
        XCTAssertEqual(states.map(\.stage), [.downloading, .checking, nil], "it never got as far as installing")
    }

    func testARestartThatFailsLeavesTheNewAppInPlaceAndSaysSo() {
        steps.failing = .relaunch
        steps.reason = "no shell"
        installer.install(update)
        XCTAssertEqual(steps.asked, Self.wholeInstall)
        XCTAssertNotNil(steps.swappedIn)
        XCTAssertEqual(installer.state, .installed(version: "9.9.9",
                                                   reason: "Iguana could not restart itself (no shell); quit Iguana and open it again"))
        XCTAssertEqual(opened, [], "the new version is installed, so there is nothing to download by hand")
        XCTAssertEqual(logged.last, "update: Iguana 9.9.9 is installed, but Iguana could not restart itself (no shell); quit Iguana and open it again")
        XCTAssertFalse(installer.isWorking)
    }

    func testAnErrorOfTheSystemIsSaidInItsOwnWords() {
        XCTAssertEqual(UpdateFailure.reason(UpdateFailure("plain words")), "plain words")
        XCTAssertEqual(UpdateFailure("plain words").localizedDescription, "plain words")
        XCTAssertEqual(UpdateFailure.reason(URLError(.notConnectedToInternet)), URLError(.notConnectedToInternet).localizedDescription)
    }

    // MARK: One at a time

    func testASecondInstallCannotStartWhileOneRuns() {
        steps.held = []
        XCTAssertTrue(installer.install(update))
        XCTAssertTrue(installer.isWorking)
        XCTAssertEqual(installer.state, .working(version: "9.9.9", stage: .downloading))
        let before = steps.asked

        XCTAssertFalse(installer.install(update), "the menu item was chosen again")
        XCTAssertFalse(installer.install(ShellFakes.update("10.0.0")), "nor another version")
        installer.look(update, switchedOn: true, tourShowing: false, dragging: false)
        XCTAssertEqual(steps.asked, before, "nothing was asked a second time")
        XCTAssertEqual(steps.workspaces.count, 1)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(logged.filter { $0.hasPrefix("update: installing") }.count, 1)

        // The download ends on some thread of its own; the rest follows.
        let waiting = steps.held ?? []
        steps.held = nil
        waiting.forEach { $0(.success(())) }
        XCTAssertEqual(steps.asked, Self.wholeInstall)
    }

    func testAfterAFailureAnInstallCanBeChosenAgain() {
        steps.failing = .download
        installer.install(update)
        XCTAssertFalse(installer.isWorking)
        steps.failing = nil
        XCTAssertTrue(installer.install(update))
        XCTAssertEqual(installer.state, .working(version: "9.9.9", stage: .restarting))
        XCTAssertEqual(steps.workspaces.count, 2, "a fresh folder each time")
        XCTAssertEqual(steps.removed, steps.workspaces)
    }

    func testADownloadThatFailsLaterIsClearedUpThen() {
        steps.held = []
        installer.install(update)
        XCTAssertEqual(steps.removed, [])
        let waiting = steps.held ?? []
        steps.held = nil
        waiting.forEach { $0(.failure(URLError(.networkConnectionLost))) }
        XCTAssertEqual(steps.removed, steps.workspaces)
        XCTAssertEqual(installer.state.stopped, "the download failed (\(URLError(.networkConnectionLost).localizedDescription))")
        XCTAssertNil(steps.swappedIn)
    }

    // MARK: By itself

    func look(_ update: UpdateCheck.Update? = ShellFakes.update("9.9.9"), on: Bool = true, tour: Bool = false, dragging: Bool = false) {
        installer.look(update, switchedOn: on, tourShowing: tour, dragging: dragging)
    }

    func testNothingInstallsByItselfUnlessSwitchedOn() {
        look(on: false)
        XCTAssertEqual(steps.asked, [])
        XCTAssertEqual(installer.state, .idle)
        XCTAssertEqual(logged, [])
    }

    func testWithNothingKnownThereIsNothingToInstall() {
        // No newer release, or the check switched off: the app hands over nil either way.
        look(nil)
        XCTAssertEqual(steps.asked, [])
        XCTAssertEqual(installer.state, .idle)
    }

    func testSwitchedOnTheUpdateInstallsByItself() {
        look()
        XCTAssertEqual(steps.asked, Self.wholeInstall)
        XCTAssertEqual(logged.first, "update: installing Iguana 9.9.9, by itself")
        XCTAssertEqual(opened, [])
    }

    func testItWaitsForTheNextLookWhileTheTourShowsOrAWindowIsDragged() {
        look(tour: true)
        look(dragging: true)
        XCTAssertEqual(steps.asked, [], "not under the user's hands")
        XCTAssertEqual(installer.state, .idle)

        // An hour later the tour is over and the window is down. Waiting did not count as a try.
        clock += 3600
        look()
        XCTAssertEqual(steps.asked, Self.wholeInstall)
    }

    func testAnInstallByItselfThatFailsOpensNoBrowserAndWaitsADay() {
        steps.failing = .verify
        look()
        XCTAssertEqual(installer.state.stopped, "the fake said no")
        XCTAssertEqual(opened, [], "Iguana does not open a browser unasked")
        XCTAssertEqual(steps.downloads.count, 1)

        // Looked at every hour, tried once a day.
        for _ in 1...23 {
            clock += 3600
            look()
        }
        XCTAssertEqual(steps.downloads.count, 1)
        // Restarting Iguana does not start the day again.
        installer = makeInstaller()
        look()
        XCTAssertEqual(steps.downloads.count, 1)

        clock += 3600
        look()
        XCTAssertEqual(steps.downloads.count, 2)

        // A newer release still is news at once, and the menu item works whenever it is chosen.
        look(ShellFakes.update("10.0.0"))
        XCTAssertEqual(steps.downloads.count, 3)
        XCTAssertTrue(installer.install(update))
        XCTAssertEqual(steps.downloads.count, 4)
        XCTAssertEqual(opened, [update.page], "chosen in the menu, a failure opens the page")
    }

    func testARefusalByItselfIsSaidOnceADayToo() {
        steps.theFacts.teamIdentifier = nil
        look()
        clock += 3600
        look()
        XCTAssertEqual(steps.asked, ["facts"])
        XCTAssertEqual(installer.state, .failed(version: "9.9.9", reason: UpdateInstall.Refusal.notSigned.sentence))
        XCTAssertEqual(logged.filter { $0.contains("was not installed") }.count, 1)
        XCTAssertEqual(opened, [])
    }
}
