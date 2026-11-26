import AppKit
import XCTest
import IguanaCore
@testable import iguana

/// The menu bar item for a given state of the window manager: what its menu holds and what
/// its picture stands for. The item itself is never put in the menu bar.
final class StatusItemControllerTests: ScenarioTestCase {
    var trusted = true
    var shortcutProblems: [String] = []
    var update: UpdateCheck.Update?
    var install = UpdateInstall.State.idle
    var installsAsked: [UpdateCheck.Update] = []
    var ran: [Command] = []
    var iconsAsked: [pid_t] = []
    var controller: StatusItemController!
    var menu: NSMenu!

    override func setUp() {
        super.setUp()
        trusted = true
        shortcutProblems = []
        update = nil
        install = .idle
        installsAsked = []
        ran = []
        iconsAsked = []
        menu = NSMenu()
        makeController()
    }

    override func tearDown() {
        menu.removeAllItems()
        menu = nil
        controller = nil
        super.tearDown()
    }

    func makeController() {
        let wm = mac.wm!
        let icons = AppIcons { [unowned self] pid in
            iconsAsked.append(pid)
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        controller = StatusItemController(wm: wm, icons: icons, trusted: { [unowned self] in trusted },
                                          shortcutProblems: { [unowned self] in shortcutProblems },
                                          knownUpdate: { [unowned self] in update }, installState: { [unowned self] in install },
                                          installUpdate: { [unowned self] in installsAsked.append($0) }) { [unowned self] command in
            ran.append(command)
            return wm.run(command)
        }
    }

    /// Start again on a Mac with this config and this many desktops.
    func restart(config: String? = nil, desktops: Int = 1) {
        let scenario = Scenario(display: false, config: config)
        scenario.system.addDisplay(desktops: desktops)
        scenario.settle()
        replaceScenario(scenario)
        makeController()
    }

    /// The menu as it opens: `-` for a line, `(desktops)` for the drawing at the top.
    func titles() -> [String] {
        controller.menuNeedsUpdate(menu)
        return menu.items.map { $0.isSeparatorItem ? "-" : ($0.view != nil ? "(desktops)" : $0.title) }
    }

    func item(_ title: String) throws -> NSMenuItem {
        controller.menuNeedsUpdate(menu)
        return try XCTUnwrap(menu.items.first { $0.title == title }, "no item called \(title)")
    }

    func choose(_ title: String) throws {
        let item = try item(title)
        _ = item.target?.perform(try XCTUnwrap(item.action))
        mac.settle()
    }

    // MARK: The menu

    func testTheMenuWhileTiling() {
        XCTAssertEqual(titles(), [
            "(desktops)", "-", "Pause Tiling", "Balance Windows", "-",
            "Settings…", "Edit Config File", "Welcome Tour…", "Show Log", "-", "Quit Iguana",
        ])
    }

    func testTheMenuIsBuiltAfreshEachTimeItOpens() {
        let first = titles()
        XCTAssertEqual(titles(), first)
        XCTAssertEqual(menu.items.filter { $0.view != nil }.count, 1)
    }

    func testTheMenuWithoutThePermission() {
        trusted = false
        XCTAssertEqual(Array(titles().prefix(4)), ["(desktops)", "-", "Open Accessibility Settings…", "-"])
        XCTAssertFalse(titles().contains("Pause Tiling"))
        XCTAssertFalse(titles().contains("Balance Windows"))
    }

    func testPauseBecomesResume() throws {
        try choose("Pause Tiling")
        XCTAssertTrue(mac.wm.paused)
        XCTAssertTrue(titles().contains("Resume Tiling"))
        XCTAssertFalse(titles().contains("Pause Tiling"))
        try choose("Resume Tiling")
        XCTAssertFalse(mac.wm.paused)
        XCTAssertTrue(ran.isEmpty, "the pause is the real windows' own, even with the tour on screen")
    }

    func testProblemsOfTheConfigAndOfTheShortcutsAreCountedTogether() {
        shortcutProblems = ["binding 'option-f': the system refused it (another app may own this shortcut)"]
        XCTAssertEqual(Array(titles()[4...6]), ["-", "1 config problem (see log)", "Settings…"])

        mac.writeConfig("no-such-key = 1\n[gaps]\nno-such-gap = 2\n")
        XCTAssertEqual(mac.wm.configWarnings.count, 2)
        XCTAssertTrue(titles().contains("3 config problems (see log)"))
    }

    func testANewerReleaseIsOfferedAboveSettings() {
        update = ShellFakes.update("9.9.9")
        XCTAssertEqual(Array(titles()[4...6]), ["-", "Update to Iguana 9.9.9…", "Settings…"])
    }

    func testChoosingTheUpdateInstallsItAndOpensNoPage() throws {
        update = ShellFakes.update("9.9.9")
        try choose("Update to Iguana 9.9.9…")
        XCTAssertEqual(installsAsked, [ShellFakes.update("9.9.9")], "the installer is asked, once, for the release that is known")
    }

    func testWhileAnInstallRunsTheItemSaysSoAndCannotBeChosen() throws {
        update = ShellFakes.update("9.9.9")
        for stage in UpdateInstall.Stage.allCases {
            install = .working(version: "9.9.9", stage: stage)
            let title = stage.menuTitle(version: "9.9.9")
            XCTAssertEqual(Array(titles()[4...6]), ["-", title, "Settings…"])
            let item = try item(title)
            XCTAssertNil(item.action, "an item without an action cannot be chosen")
            menu.update()
            XCTAssertFalse(item.isEnabled, title)
            XCTAssertFalse(titles().contains("Update to Iguana 9.9.9…"))
        }
        XCTAssertEqual(installsAsked, [])

        // It says so even if the release is no longer told about, as when the check was switched off meanwhile.
        update = nil
        install = .working(version: "9.9.9", stage: .downloading)
        XCTAssertTrue(titles().contains("Downloading Iguana 9.9.9…"))
    }

    func testTheItemFollowsTheInstallWhileTheMenuIsOpen() throws {
        update = ShellFakes.update("9.9.9")
        let item = try item("Update to Iguana 9.9.9…")
        menu.update()
        XCTAssertTrue(item.isEnabled)

        install = .working(version: "9.9.9", stage: .downloading)
        controller.showInstall()
        XCTAssertEqual(item.title, "Downloading Iguana 9.9.9…")
        XCTAssertFalse(item.isEnabled)
        install = .working(version: "9.9.9", stage: .checking)
        controller.showInstall()
        XCTAssertEqual(item.title, "Checking Iguana 9.9.9…")

        // It failed: the item is the offer again, and can be chosen again.
        install = .failed(version: "9.9.9", reason: "the download failed (offline)")
        controller.showInstall()
        XCTAssertEqual(item.title, "Update to Iguana 9.9.9…")
        XCTAssertTrue(item.isEnabled)
        _ = item.target?.perform(try XCTUnwrap(item.action))
        XCTAssertEqual(installsAsked.count, 1)
    }

    func testAnInstallThatRunsIsNotStartedASecondTimeFromTheMenu() throws {
        update = ShellFakes.update("9.9.9")
        let item = try item("Update to Iguana 9.9.9…")
        let action = try XCTUnwrap(item.action)
        // The menu was open when the install started by itself, and the click came just after.
        install = .working(version: "9.9.9", stage: .downloading)
        _ = item.target?.perform(action)
        XCTAssertEqual(installsAsked, [])
    }

    func testWithoutAMenuThereIsNoItemToChange() {
        install = .working(version: "9.9.9", stage: .downloading)
        controller.showInstall()
        XCTAssertEqual(installsAsked, [])
    }

    func testSettingsAndTheTourAreHandedToTheApp() throws {
        var opened: [String] = []
        controller.onSettings = { opened.append("settings") }
        controller.onTour = { opened.append("tour") }
        try choose("Settings…")
        try choose("Welcome Tour…")
        XCTAssertEqual(opened, ["settings", "tour"])
    }

    func testTheKeysAndTheTargetOfTheItems() throws {
        XCTAssertEqual(try item("Settings…").keyEquivalent, ",")
        XCTAssertEqual(try item("Quit Iguana").keyEquivalent, "q")
        controller.menuNeedsUpdate(menu)
        for item in menu.items where !item.isSeparatorItem && item.view == nil {
            XCTAssertTrue(item.target === controller, item.title)
            XCTAssertNotNil(item.action, item.title)
        }
    }

    func testTheIconsOfTheDrawingAreAskedForOncePerApp() {
        let app = mac.system.launch("Terminal")
        mac.system.open(app)
        mac.settle()
        mac.system.open(app)
        mac.settle()
        _ = titles()
        XCTAssertEqual(iconsAsked, [app.processIdentifier])
        _ = titles()
        XCTAssertEqual(iconsAsked, [app.processIdentifier])
    }

    // MARK: The picture

    func testThePictureOfOneDesktop() {
        let face = controller.face()
        XCTAssertEqual(face.accessibilityTitle, "Iguana, desktop 1")
        XCTAssertEqual(face.activeDesk, 1)
        XCTAssertEqual(face.slots, [], "one desktop is not a row to click in")
        XCTAssertEqual(face.image.size.height, StatusIcon.height)
    }

    func testThePictureSaysTheMode() {
        restart(config: ShellFakes.modes)
        let plain = controller.face()
        mac.run("mode resize")
        let moded = controller.face()
        XCTAssertEqual(moded.accessibilityTitle, "Iguana, desktop 1, resize mode")
        XCTAssertGreaterThan(moded.image.size.width, plain.image.size.width, "the mode is written beside the number")
    }

    func testThePictureWithoutThePermission() {
        trusted = false
        let face = controller.face()
        XCTAssertEqual(face.accessibilityTitle, "Iguana needs permission")
        XCTAssertNil(face.activeDesk)
        XCTAssertEqual(face.slots, [])
    }

    func testEveryDesktopIsDrawnWhenAskedFor() {
        restart(config: "[menu-bar]\ndesktops = \"all\"\n", desktops: 3)
        let face = controller.face()
        XCTAssertEqual(face.slots.map(\.number), [1, 2, 3])
        XCTAssertEqual(face.activeDesk, 1)
        XCTAssertEqual(face.accessibilityTitle, "Iguana, desktop 1")

        mac.system.showDesktop(2)
        mac.settle()
        XCTAssertEqual(controller.face().activeDesk, 2)
        XCTAssertEqual(controller.face().accessibilityTitle, "Iguana, desktop 2")
    }

    func testARowIsNotDrawnWhilePaused() {
        restart(config: "[menu-bar]\ndesktops = \"all\"\n", desktops: 2)
        mac.run("pause")
        XCTAssertEqual(controller.face().slots, [])
    }

    func testOnlyDesktopsInUseAreDrawnWhenAskedFor() {
        restart(config: "[menu-bar]\ndesktops = \"occupied\"\n", desktops: 3)
        let app = mac.system.launch("Terminal")
        mac.system.open(app)
        mac.settle()
        XCTAssertEqual(controller.face().slots, [], "the others are empty, and one desktop is not a row")

        mac.system.showDesktop(3)
        mac.settle()
        mac.system.open(app)
        mac.settle()
        XCTAssertEqual(controller.face().slots.map(\.number), [1, 3])
        XCTAssertEqual(controller.face().activeDesk, 3)
    }

    func testAnItemThatIsNotInTheMenuBarIsLeftAlone() {
        controller.update()
        XCTAssertNil(controller.frameOnScreen)
    }
}
