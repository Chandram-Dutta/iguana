# Iguana

A tiling window manager for macOS. Swift package; no Xcode project needed.

## Layout

- `Sources/IguanaCore` — pure logic: parsing, config, rules, the layout tree. No macOS APIs.
  Tested with XCTest in `Tests/IguanaCoreTests`.
- `Sources/iguana` — the macOS layer: the daemon, the window manager, the settings window.
  Tested in `Tests/IguanaAppTests`.
- `docs/` — the documentation site (Astro Starlight). Its own notes are in `docs/AGENTS.md`.

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
- The default-shortcut count is hard-coded in `CoreTests`, `SettingsModelTests` and
  `reference/configuration.mdx` — update all three when a default shortcut is added.
- Every `[bindings]` pattern in `Schema.swift` must accept what `Command.parse` accepts;
  `SchemaCommandTests` checks it.

## Caution

- Never run `iguana daemon` or a built Iguana.app while another Iguana manages the windows.
- `iguana debug-snapshot|debug-desk|debug-tour|debug-switcher <folder>` render offscreen and
  are safe to run.
