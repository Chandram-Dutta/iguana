import XCTest
@testable import IguanaCore

/// Reading TOML: the values and tables a config file can hold, and errors that name the line.
final class TOMLTests: XCTestCase {
    func testTOMLBasics() throws {
        let doc = try TOML.parse("""
        # comment
        name = "a \\"b\\""   # trailing
        n = 1_000
        f = -0.5
        on = true
        list = [1, 2,
                3]
        point = { x = 1, y = 2 }
        a.b = 'lit'

        [t.sub]
        "quoted key" = 1

        [[item]]
        v = 1
        [[item]]
        v = 2
        """)
        XCTAssertEqual(doc["name"], .string("a \"b\""))
        XCTAssertEqual(doc["n"], .int(1000))
        XCTAssertEqual(doc["f"], .double(-0.5))
        XCTAssertEqual(doc["on"], .bool(true))
        XCTAssertEqual(doc["list"], .array([.int(1), .int(2), .int(3)]))
        XCTAssertEqual(doc["point"], .table(["x": .int(1), "y": .int(2)]))
        XCTAssertEqual(doc["a"], .table(["b": .string("lit")]))
        XCTAssertEqual(doc["t"], .table(["sub": .table(["quoted key": .int(1)])]))
        XCTAssertEqual(doc["item"], .array([.table(["v": .int(1)]), .table(["v": .int(2)])]))
    }

    func testTOMLErrorsCarryTheLine() {
        XCTAssertThrowsError(try TOML.parse("a = 1\nb = oops\n")) { e in
            XCTAssertEqual((e as? TOMLError)?.line, 2)
        }
        XCTAssertThrowsError(try TOML.parse("a = \"open\n"))
        XCTAssertThrowsError(try TOML.parse("a = 1 2\n"))
        XCTAssertThrowsError(try TOML.parse("a = 1\n[a]\n"))
        XCTAssertEqual(try TOML.parse("a = 1\r\nb = 2\r\n"), ["a": .int(1), "b": .int(2)], "Windows line endings")
    }
}
