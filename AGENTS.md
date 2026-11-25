# Iguana

A tiling window manager for macOS. Swift package; no Xcode project needed.

## Layout

- `Sources/IguanaCore` — pure logic: parsing, config, rules, the layout tree. No macOS APIs.
  Tested with XCTest in `Tests/IguanaCoreTests`.
- `Sources/iguana` — the macOS layer: the daemon, the window manager, the settings window.
  Tested in `Tests/IguanaAppTests`.
  - `Platform/` — the only code that talks to macOS about other apps' windows. `WindowSystem`
    and `UIElement` are the protocols; `MacWindowSystem` is the Mac. `Private.swift` holds the
    undocumented calls.
  - `Manager/` — the window manager. `WindowManager.swift` has its state and the refresh; each
    `WindowManager+….swift` is one concern (layout, commands, focus, Spaces, rules…).
    `AppTracker`, `SpaceCarrier`, `StateStore` and `Animator` are its helpers.
  - `App/` — the app shell. `Daemon.swift` is the app delegate: it makes the parts and wires
    them together. Each part has its own file: `StatusItemController` (the menu bar item),
    `HotkeyRegistrar`, `RequestHandler` (lines from the command socket), `ShellReport`,
    `ConfigWatcher`, `WelcomeTour`, `AppSettingsBackend`, `AppIcons`, `MainMenu`. A part is
    handed what it needs when it is made; it does not reach back into `Daemon`.
  - `IPC/` — the command socket, `subscribe`, and the `[hooks]` that fire on the same events.
  - `Overlays/` — what follows the windows from outside the manager: the focus ring, the drag
    outline, `focus-follows-mouse`.
  - `Tour/` — the welcome tour. `TourModel.swift` has its state; each `TourModel+….swift` is one
    concern (the practice desktop, keys, steps, commands). `Views/` has a file for each scene.
  - `Settings/` — the settings window: a file per pane in `Panes/`, shared rows in `Controls/`.
  - `main.swift`, `Iguana.swift` and `Hotkeys.swift` stay at the top level. The release
    workflow and `docs/scripts/check-coverage.mjs` read the last two by path.
- `docs/` — the documentation site (Astro Starlight). Its own notes are in `docs/AGENTS.md`.

## The window manager and macOS

- `Manager/` never calls Accessibility, the window server, `NSWorkspace` or `DispatchQueue`
  itself. It asks `system` (a `WindowSystem`) and waits with `scheduler` (a `Scheduler`). A
  call that goes round them cannot be tested and will write to the real desktop in a test.
- The rest of the app reads the window manager through `facts()` and
  `WindowManager+Shell.swift`. It does not change the manager's state.

## Tests

- `Tests/IguanaAppTests/Support` is a made-up Mac: `FakeWindowSystem` (displays, Spaces, apps,
  windows, the pointer), `FakeScheduler` (time that passes when the test says so) and
  `Scenario`, which runs the real `WindowManager` against them.
- A test of the window manager subclasses `ScenarioTestCase`, arranges the Mac through
  `mac.system`, calls `mac.settle()`, and looks at where the windows are. `mac.run("move left")`
  sends a command. `TilingLifecycleTests` shows the pattern.
- A test must never touch the real screen, config file, saved layouts or log. `Scenario` keeps
  each in a folder of its own.
- New behaviour in `Manager/` comes with a scenario test. New pure logic goes in `IguanaCore`
  with a unit test.

## Verify

- `swift build` and `swift test` after any change.
- `node docs/scripts/check-coverage.mjs` after changing commands, config keys, shortcuts or
  hooks — the docs must cover them all.
- `node docs/scripts/extract-schema.mjs` after changing `Schema.swift`; it rewrites
  `docs/public/schema/iguana.schema.json`.
- `cd docs && npm run build` builds the site and checks every internal link.

## Conventions

- Docs are plain British English, in short sentences.
- `///` comments explain why something is so, not what the code does.
- Commands reply `ok`, `ok: …` or `error: …`.
- The version is `Iguana.version` in `Sources/iguana/Iguana.swift`; the release workflow reads it there.
- The default-shortcut count is hard-coded in `ConfigTests`, `SettingsModelTests` and
  `reference/configuration.mdx` — update all three when a default shortcut is added.
- Every `[bindings]` pattern in `Schema.swift` must accept what `Command.parse` accepts;
  `SchemaCommandTests` checks it.

## Caution

- Never run `iguana daemon` or a built Iguana.app while another Iguana manages the windows.
- `iguana debug-snapshot|debug-desk|debug-tour|debug-switcher <folder>` render offscreen and
  are safe to run.
