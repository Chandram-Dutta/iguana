import XCTest
@testable import IguanaCore

/// The JSON Schema of the config file: it is valid JSON and has every section and key of the default config.
final class SchemaTests: XCTestCase {
    func testSchemaIsValidJSONAndCoversEveryKey() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Config.jsonSchema.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let doc = try TOML.parse(Config.defaultText)
        // [[display]] and [mode.NAME] are in the default config only as commented-out examples.
        XCTAssertEqual(Set(properties.keys), Set(doc.keys).union(["display", "mode"]), "every top-level section of the default config is in the schema")
        for (section, value) in doc {
            guard section != "bindings", let table = value.tableValue else { continue }
            let described = try XCTUnwrap((properties[section] as? [String: Any])?["properties"] as? [String: Any], section)
            XCTAssertEqual(Set(described.keys), Set(table.keys), "keys of [\(section)]")
        }
        // The shortcut pattern accepts every built-in shortcut.
        let bindings = try XCTUnwrap(properties["bindings"] as? [String: Any])
        let pattern = try XCTUnwrap((bindings["patternProperties"] as? [String: Any])?.keys.first)
        let regex = try NSRegularExpression(pattern: pattern)
        for b in Config.default.bindings {
            XCTAssertNotNil(regex.firstMatch(in: b.source, range: NSRange(b.source.startIndex..., in: b.source)), b.source)
        }
    }
}
