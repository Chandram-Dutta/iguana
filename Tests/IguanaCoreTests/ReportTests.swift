import XCTest
@testable import IguanaCore

/// The JSON documents of `list-windows --json`, `list-spaces --json`, `tree --json` and
/// `status --json`, built from fixed facts. The documents here are the examples in the docs
/// (reference/commands.mdx): when one changes, change the other.
final class ReportTests: XCTestCase {
    static let builtIn = "Built-in Retina Display"

    static let windows = Report.Windows(windows: [
        Report.Window(id: 1187, app: "Terminal", bundleId: "com.apple.Terminal", title: "zsh", state: .tiled, focused: true,
                      desktop: 1, display: builtIn, frame: Report.Frame(CGRect(x: 8, y: 41, width: 748, height: 933))),
        Report.Window(id: 1320, app: "Notes", bundleId: "com.apple.Notes", title: "Notes", state: .notOnScreen, focused: false,
                      desktop: 2, display: builtIn, frame: nil),
    ])

    static let spaces = Report.Spaces(
        desktops: [
            Report.Desktop(number: 1, display: builtIn, showing: true, active: true, windows: [1187, 1203]),
            Report.Desktop(number: 2, display: builtIn, showing: false, active: false, windows: [1320]),
            Report.Desktop(number: 3, display: "Studio Display", showing: true, active: false, windows: []),
        ],
        displays: [
            Report.Display(name: builtIn, desktop: 1, desktopCount: 2, main: true),
            Report.Display(name: "Studio Display", desktop: 3, desktopCount: 1, main: false),
        ])

    static var trees: Report.Trees {
        // Safari beside a column of Terminal over Notes, with Notes minimised.
        let tree = Tree()
        tree.insert(1203)
        tree.insert(1187, after: 1203)
        tree.insert(1320, after: 1187, split: .vertical)
        let known: [WindowID: (app: String, title: String, onScreen: Bool)] = [
            1203: ("Safari", "Start Page", true), 1187: ("Terminal", "zsh", true), 1320: ("Notes", "Notes", false),
        ]
        return Report.Trees(displays: [Report.Layout(display: builtIn, desktop: 1, layout: Report.Node(tree.snapshot) { known[$0] })],
                            otherLayouts: 1)
    }

    static let status = Report.Status(
        version: "0.1.2", permission: true, paused: false, configPath: "/Users/you/.config/iguana/iguana.toml", configExists: true,
        configWarnings: [], windows: Report.WindowCounts(tiled: 3, known: 7, apps: 5),
        stageManager: Report.StageManager(on: false, reserved: 0),
        displays: [Report.Display(name: builtIn, desktop: 1, desktopCount: 3, main: true)],
        shortcuts: Report.Shortcuts(active: 40, warnings: []), tourShowing: false,
        lastShortcut: Report.LastShortcut(keys: "option-l", secondsAgo: 4, reply: "ok"))

    func testWindowsDocument() {
        XCTAssertEqual(Report.encode(Self.windows), """
        {
          "windows" : [
            {
              "app" : "Terminal",
              "bundleId" : "com.apple.Terminal",
              "desktop" : 1,
              "display" : "Built-in Retina Display",
              "focused" : true,
              "frame" : {
                "height" : 933,
                "width" : 748,
                "x" : 8,
                "y" : 41
              },
              "id" : 1187,
              "state" : "tiled",
              "title" : "zsh"
            },
            {
              "app" : "Notes",
              "bundleId" : "com.apple.Notes",
              "desktop" : 2,
              "display" : "Built-in Retina Display",
              "focused" : false,
              "frame" : null,
              "id" : 1320,
              "state" : "notOnScreen",
              "title" : "Notes"
            }
          ]
        }
        """)
    }

    func testSpacesDocument() {
        XCTAssertEqual(Report.encode(Self.spaces), """
        {
          "desktops" : [
            {
              "active" : true,
              "display" : "Built-in Retina Display",
              "number" : 1,
              "showing" : true,
              "windows" : [
                1187,
                1203
              ]
            },
            {
              "active" : false,
              "display" : "Built-in Retina Display",
              "number" : 2,
              "showing" : false,
              "windows" : [
                1320
              ]
            },
            {
              "active" : false,
              "display" : "Studio Display",
              "number" : 3,
              "showing" : true,
              "windows" : [

              ]
            }
          ],
          "displays" : [
            {
              "desktop" : 1,
              "desktopCount" : 2,
              "main" : true,
              "name" : "Built-in Retina Display"
            },
            {
              "desktop" : 3,
              "desktopCount" : 1,
              "main" : false,
              "name" : "Studio Display"
            }
          ]
        }
        """)
    }

    func testTreeDocumentNestsContainersAndWindows() throws {
        XCTAssertEqual(Report.encode(Self.trees), """
        {
          "displays" : [
            {
              "desktop" : 1,
              "display" : "Built-in Retina Display",
              "layout" : {
                "children" : [
                  {
                    "app" : "Safari",
                    "id" : 1203,
                    "onScreen" : true,
                    "title" : "Start Page",
                    "type" : "window",
                    "weight" : 1
                  },
                  {
                    "children" : [
                      {
                        "app" : "Terminal",
                        "id" : 1187,
                        "onScreen" : true,
                        "title" : "zsh",
                        "type" : "window",
                        "weight" : 1
                      },
                      {
                        "app" : "Notes",
                        "id" : 1320,
                        "onScreen" : false,
                        "title" : "Notes",
                        "type" : "window",
                        "weight" : 1
                      }
                    ],
                    "orientation" : "vertical",
                    "type" : "container",
                    "weight" : 1
                  }
                ],
                "orientation" : "horizontal",
                "type" : "container",
                "weight" : 1
              }
            }
          ],
          "otherLayouts" : 1
        }
        """)

        // A window that is in a saved layout but has not been looked at yet still has its id.
        let tree = Tree()
        tree.insert(7)
        let node = try XCTUnwrap(Report.Node(tree.snapshot) { _ in nil }.children?.first)
        XCTAssertEqual(node.type, .window)
        XCTAssertEqual(node.id, 7)
        XCTAssertNil(node.app)
        XCTAssertEqual(node.onScreen, false)
    }

    func testStatusDocument() {
        XCTAssertEqual(Report.encode(Self.status), """
        {
          "configExists" : true,
          "configPath" : "/Users/you/.config/iguana/iguana.toml",
          "configWarnings" : [

          ],
          "displays" : [
            {
              "desktop" : 1,
              "desktopCount" : 3,
              "main" : true,
              "name" : "Built-in Retina Display"
            }
          ],
          "lastShortcut" : {
            "keys" : "option-l",
            "reply" : "ok",
            "secondsAgo" : 4
          },
          "paused" : false,
          "permission" : true,
          "shortcuts" : {
            "active" : 40,
            "warnings" : [

            ]
          },
          "stageManager" : {
            "on" : false,
            "reserved" : 0
          },
          "tourShowing" : false,
          "version" : "0.1.2",
          "windows" : {
            "apps" : 5,
            "known" : 7,
            "tiled" : 3
          }
        }
        """)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testWhatIsNotKnownIsNullAndItsKeyStays() throws {
        let unknown = Report.Window(id: 9, app: "pid 77", bundleId: nil, title: "", state: .unmanaged, focused: false,
                                    desktop: nil, display: nil, frame: nil)
        let window = try XCTUnwrap((try object(Report.encode(Report.Windows(windows: [unknown])))["windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(window.keys), ["id", "app", "bundleId", "title", "state", "focused", "desktop", "display", "frame"])
        for key in ["bundleId", "desktop", "display", "frame"] { XCTAssertTrue(window[key] is NSNull, key) }

        // A display on a fullscreen Space, a desktop with no display of its own, an empty desktop.
        let spaces = try object(Report.encode(Report.Spaces(
            desktops: [Report.Desktop(number: 1, display: nil, showing: false, active: false, windows: [])],
            displays: [Report.Display(name: "Studio Display", desktop: nil, desktopCount: 1, main: true)])))
        XCTAssertTrue((spaces["desktops"] as? [[String: Any]])?.first?["display"] is NSNull)
        XCTAssertTrue((spaces["displays"] as? [[String: Any]])?.first?["desktop"] is NSNull)

        let trees = try object(Report.encode(Report.Trees(displays: [Report.Layout(display: "Studio Display", desktop: nil, layout: nil)], otherLayouts: 0)))
        let layout = try XCTUnwrap((trees["displays"] as? [[String: Any]])?.first)
        XCTAssertTrue(layout["desktop"] is NSNull)
        XCTAssertTrue(layout["layout"] is NSNull)

        var status = Self.status
        status.lastShortcut = nil
        XCTAssertTrue(try object(Report.encode(status))["lastShortcut"] is NSNull)
    }

    func testDocumentsReadBackAsWhatWasWritten() throws {
        func roundTrip<T: Codable & Equatable>(_ value: T, line: UInt = #line) throws {
            XCTAssertEqual(try JSONDecoder().decode(T.self, from: Data(Report.encode(value).utf8)), value, line: line)
        }
        try roundTrip(Self.windows)
        try roundTrip(Self.spaces)
        try roundTrip(Self.trees)
        try roundTrip(Self.status)
    }

    func testEveryKeyIsLowerCamelCase() throws {
        var keys = Set<String>()
        func collect(_ value: Any) {
            if let table = value as? [String: Any] {
                for (key, inner) in table {
                    keys.insert(key)
                    collect(inner)
                }
            } else if let list = value as? [Any] {
                list.forEach(collect)
            }
        }
        for text in [Report.encode(Self.windows), Report.encode(Self.spaces), Report.encode(Self.trees), Report.encode(Self.status)] {
            collect(try object(text))
        }
        XCTAssertGreaterThan(keys.count, 30)
        for key in keys {
            XCTAssertNotNil(key.range(of: "^[a-z][a-zA-Z0-9]*$", options: .regularExpression), "'\(key)' is not lower camel case")
        }
    }

    func testOutputIsStableAndKeepsTextAsItIs() throws {
        XCTAssertEqual(Report.encode(Self.status), Report.encode(Self.status))
        // A title is data: quotes, slashes, line breaks and other alphabets survive the trip.
        let title = "a \"quoted\" /path\n$(rm -rf ~) — 東京 🦎"
        let odd = Report.Windows(windows: [Report.Window(id: 1, app: "Safari", bundleId: nil, title: title, state: .floating,
                                                         focused: false, desktop: nil, display: nil, frame: nil)])
        let text = Report.encode(odd)
        XCTAssertTrue(text.contains("/path"), "slashes are not escaped")
        XCTAssertEqual(try JSONDecoder().decode(Report.Windows.self, from: Data(text.utf8)).windows.first?.title, title)
    }

    func testStateIsTheOneListWindowsPrints() {
        XCTAssertEqual(Report.State.of(inLayout: true, onScreen: true, floating: false, tileable: true), .tiled)
        XCTAssertEqual(Report.State.of(inLayout: false, onScreen: false, floating: true, tileable: true), .notOnScreen)
        XCTAssertEqual(Report.State.of(inLayout: false, onScreen: true, floating: true, tileable: true), .floating)
        // On screen and about to be given a tile.
        XCTAssertEqual(Report.State.of(inLayout: false, onScreen: true, floating: false, tileable: true), .tiled)
        XCTAssertEqual(Report.State.of(inLayout: false, onScreen: true, floating: false, tileable: false), .unmanaged)
        XCTAssertEqual(Report.State.notOnScreen.rawValue, "notOnScreen")
    }

    func testJSONIsAskedForOnTheCommandLine() throws {
        for (line, command) in [("list-windows", Command.listWindows), ("list-spaces", .listSpaces), ("tree", .tree), ("status", .status)] {
            XCTAssertEqual(try Command.parseRequest(line).command, command)
            XCTAssertFalse(try Command.parseRequest(line).json, "\(line): text unless asked")
            XCTAssertEqual(try Command.parseRequest("\(line) --json").command, command)
            XCTAssertTrue(try Command.parseRequest("\(line) --json").json)
        }
        XCTAssertTrue(try Command.parseRequest("--json  Status").json)
        XCTAssertTrue(try Command.parseRequest("TREE --JSON").json)

        // Everything else is the command it always was.
        XCTAssertEqual(try Command.parseRequest("move-to-space 2 --stay").command, .moveToSpace(.index(2), follow: false))
        XCTAssertFalse(try Command.parseRequest("focus left").json)
        for bad in ["focus left --json", "reload --json", "--json", "status --json now", "status --jsonx", ""] {
            XCTAssertThrowsError(try Command.parseRequest(bad), bad)
        }
        // A shortcut has nowhere to print a document.
        XCTAssertThrowsError(try Command.parse("status --json"))
        XCTAssertTrue(Command.usage.contains("--json"))
    }
}
