import CoreGraphics
import XCTest
@testable import IguanaCore

/// How a window's move is paced: the easing curves, and the frame part-way between two.
final class AnimationTests: XCTestCase {
    func testEasingAndInterpolation() {
        for e in Easing.allCases {
            XCTAssertEqual(e.apply(0), 0, accuracy: 1e-9)
            XCTAssertEqual(e.apply(1), 1, accuracy: 1e-9)
            XCTAssertEqual(e.apply(-3), 0, accuracy: 1e-9)
            XCTAssertEqual(e.apply(7), 1, accuracy: 1e-9)
            var last = 0.0
            for i in 1...20 {
                let v = e.apply(Double(i) / 20)
                XCTAssertGreaterThanOrEqual(v, last, "\(e) never goes backwards")
                last = v
            }
        }
        XCTAssertGreaterThan(Easing.easeOut.apply(0.5), 0.5)
        let a = CGRect(x: 0, y: 0, width: 100, height: 100), b = CGRect(x: 100, y: 50, width: 300, height: 200)
        XCTAssertEqual(interpolate(a, b, 0), a)
        XCTAssertEqual(interpolate(a, b, 1), b)
        XCTAssertEqual(interpolate(a, b, 0.5), CGRect(x: 50, y: 25, width: 200, height: 150))
    }
}
