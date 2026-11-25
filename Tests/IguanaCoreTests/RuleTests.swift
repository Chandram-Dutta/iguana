import XCTest
@testable import IguanaCore

/// `[[rule]]`: which windows a rule matches, by app and by title.
final class RuleTests: XCTestCase {
    func testRules() {
        let byID = Rule(app: "com.apple.calculator", title: nil, float: true)
        XCTAssertTrue(byID.matches(bundleID: "com.apple.calculator", appName: "Calculator", title: ""))
        XCTAssertFalse(byID.matches(bundleID: "com.apple.Safari", appName: "Safari", title: ""))
        let byTitle = Rule(app: "safari", title: "^Settings", float: true)
        XCTAssertTrue(byTitle.matches(bundleID: "com.apple.Safari", appName: "Safari", title: "Settings — General"))
        XCTAssertFalse(byTitle.matches(bundleID: "com.apple.Safari", appName: "Safari", title: "Apple"))
    }
}
