<img src="assets/logo-rounded.png" width="96" alt="">

# Iguana

A tiling window manager for macOS. Open a window and the others make room; move, resize and
switch between them from the keyboard.

![Loose windows snap into tiles and make room as one opens and closes. A cramped column becomes a stack and the focus steps through it. A window is dragged, and an outline shows where it will land.](assets/demo.gif)

**[iguana.onlychan.xyz](https://iguana.onlychan.xyz)** has a desktop you can try in the browser
and the full documentation.

Most tiling window managers for macOS replace Spaces with workspaces of their own, and hide the
windows of inactive workspaces by parking them in a corner of the screen. Iguana does neither:

- **No workspaces of its own.** Iguana tiles each Space on each display separately.
  Switching goes through Mission Control's own shortcuts, so gestures, Mission Control and
  `ctrl-arrows` keep working and stay in sync.
- **It only touches windows that are on screen.** Nothing is ever hidden or parked. Minimised
  windows, hidden apps, other Stage Manager stages and background native tabs keep their slot and
  take no room until they come back.
- **Nothing to put back.** Quit Iguana (or let it crash) and every window is exactly where you see it.
- **No need to disable System Integrity Protection.**

## Install

Iguana needs macOS 14 or later, on Apple silicon or Intel. The app is signed and notarized.

### Homebrew

```sh
brew tap chandram-dutta/tap
brew trust chandram-dutta/tap     # newer versions of Homebrew ask for this; older ones have no such command
brew install --cask chandram-dutta/tap/iguana
```

This also puts the `iguana` command on your PATH. Update later with `brew upgrade --cask iguana`.

Iguana tells you when there is something to update to. About once a day it asks GitHub for the
latest release, and when that is newer than yours the menu gains one item, "Update to Iguana
0.2.2…", which opens the release's page. No alert, no notification, and nothing is downloaded
or installed. The request carries nothing about you or your Mac: no identifier, no cookie, no
stored credentials, only a `User-Agent` of `Iguana/<version>`. `iguana update` asks right now;
`check = false` under `[updates]`, or the switch in the settings window, turns the daily check off.

### Download

Download **[Iguana.dmg](https://github.com/Chandram-Dutta/iguana/releases/latest/download/Iguana.dmg)**,
open it and drag Iguana into Applications.

### From source

With Xcode 26 or later (or its Command Line Tools):

```sh
scripts/bundle.sh          # builds and signs build/Iguana.app
open build/Iguana.app      # shows the welcome tour the first time
```

`scripts/bundle.sh` signs with the project's own developer team. Pass your own with
`TEAM_ID=...` or `SIGN_IDENTITY="..."`, or the app is signed ad hoc and macOS asks for the
Accessibility permission again after every build.

The first start shows a full-screen tour: a practice desktop to try the shortcuts on (focus,
move, resize, stack, desktops), then the Accessibility permission (System Settings > Privacy &
Security > Accessibility). Tiling starts when the tour ends. `iguana tour`, or Welcome Tour…
in the menu, shows it again. The
menu bar icon is a live drawing of the current desktop's layout, with the desktop number beside
it. Click it for a menu that starts with the desktop in miniature (click a window to focus it) and
every other desktop with its layout (click one to go there), above Pause, Balance and Settings. With `desktops = "all"` or `"occupied"` under `[menu-bar]`, the icon draws every
desktop side by side; `click-to-switch = true` makes a click on one go there.

To use the command line after a download, put the binary on your `PATH` (Homebrew has already
done this):

```sh
ln -s /Applications/Iguana.app/Contents/MacOS/iguana /usr/local/bin/iguana
iguana help
```

For status bars such as SketchyBar and for scripts, `iguana list-windows --json` (and `list-spaces`, `tree`, `status`) answers with JSON. `iguana subscribe` keeps a connection open and prints a line of JSON for every change: the desktop, the focus, a window opening or closing, the layout, the pause. A `[hooks]` section in the config file (or the Hooks pane) runs a command of yours for the same events instead. Add `--window ID` to a command to act on a window other than the focused one.

## Default shortcuts

| Keys | Action |
| --- | --- |
| `option-h/j/k/l` | focus left / down / up / right |
| `option-tab` | back to the window that had the focus before |
| `option-w` | find a window by typing part of its title or app |
| `option-shift-h/j/k/l` | move the window (continues onto the next display at the edge) |
| `option-ctrl-h/j/k/l` | group the window with its neighbour |
| `option-minus`, `option-equal` | shrink, grow |
| `option-slash` | flip the container between side-by-side and top-to-bottom |
| `option-s` | stack the windows of the container so they overlap, or tile them again |
| `option-f` | zoom the window to fill the Space |
| `option-shift-space` | float or tile the window |
| `option-shift-b` | balance sizes |
| `option-z`, `option-shift-z` | undo, redo the last change to the layout |
| `option-1` … `option-9` | go to desktop N |
| `option-[`, `option-]` | go to the previous, next desktop |
| `option-shift-tab` | back to the desktop you were on before |
| `option-shift-1` … `option-shift-9` | take the window to desktop N and go with it |
| `option-shift-[`, `option-shift-]` | take the window to the previous, next desktop |
| `option-,`, `option-.` | focus the previous, next display |
| `option-shift-,`, `option-shift-.` | take the window to the previous, next display |

You can also drag a tiled window onto another: the middle swaps them, an edge takes that half of
the tile, and an outline shows where the window will land. Drag an edge to resize; the layout
keeps the new proportions. With `focus-follows-mouse = true` under `[layout]`, the window the
pointer comes to rest on gets the focus without a click.

More commands have no shortcut until you give them one:

- `focus-app safari` focuses an app's window, or opens the app. It is the answer to a
  scratchpad, since Iguana never hides a window.
- `arrange columns|rows|grid|main` lays the whole desktop out at once, and
  `split horizontal|vertical` chooses where the next window opens.
- `place center|left|right|top-left|…|full` puts a floating window in part of the screen.
- `"flip; balance"` runs several commands from one key, and `[mode.resize]` tables give you
  modes, such as plain `h/j/k/l` resizing until you press esc.

Layouts survive a restart of the Mac: as apps reopen their windows, each desktop takes its
saved shape again.

## Settings

There are two ways to change settings and they are the same thing underneath.

**The settings window** (menu bar item > Settings…, or `iguana settings`) has panes for layout
and gaps, animation, shortcuts, the rules that float an app's windows or send them to a
desktop or a display, and hooks, and the switch for the daily check for a newer version.
Changes apply to your real windows as you make them.

A `[[display]]` section in the config file gives one display its own gaps and a maximum layout
width, so the windows on an ultrawide monitor can stay in the middle.

A ring around the focused window, like the border other tiling window managers need a second
tool for, is built in and off until you switch it on: `enabled = true` under `[focus-ring]`, or
the Layout pane. It is drawn outside the window in your accent colour, or one you choose.

**The config file** is `~/.config/iguana/iguana.toml`. `iguana config init` writes it with every
setting explained in comments, plus a schema file that gives editors with TOML support completion
and validation. Iguana reloads the file the moment it is saved.

The window edits that same file: each change rewrites only the value you changed and keeps your
comments and formatting, and anything you change by hand shows up in the window. Every setting
is optional, and shortcuts are layered over the built-in ones (set one to `""` to switch it off).
A mistake never stops Iguana: `iguana config check` lists every problem (a syntax error comes
with its line number), and the previous settings stay in force until a broken file is fixed.

## Animation

Windows glide to their new place when the layout changes. Each app is driven on its own queue
and late frames are dropped rather than queued, so one slow app cannot hold up the rest. Set the
duration and pacing under `[animation]` or in the settings window, or turn it off. It is off
automatically while Reduce Motion is on.

## Limits you should know about

- **Sending a window to another Space relies on a newer system route.** On recent macOS (tested
  on 27.2) Iguana asks the system's own window-management bridge to move the window. It takes a
  few milliseconds and needs no SIP changes; Iguana then switches to that Space. Add `--stay` to a
  `move-to-space` binding to send the window away and stay where you are. On systems without that route Iguana falls
  back to holding the window by its title bar and switching Space, which is slower and always
  follows the window. A `[[rule]]` with `desktop = N` sends an app's new windows to a desktop
  through the quick route only, because a rule never takes you along.
- **Space switches are animated by macOS.** Turn on Reduce Motion (System Settings > Accessibility
  > Display) for a quick cross-fade.
- Reading which Space is showing uses undocumented system calls (read-only). They have been stable
  for many macOS releases but Apple makes no promise.

## Releasing

Pushing a tag such as `v0.2.0` runs `.github/workflows/release.yml`, which builds, signs,
notarizes and publishes the release. It needs the signing secrets described at the top of that
file. By hand, the same thing is two commands: `scripts/release.sh`, then `scripts/publish.sh`.

`scripts/release.sh` makes what is handed to other people, in `dist/`: a disk image, a zip of
the same app, the Homebrew cask filled in for that build, and checksums. The app is built for
Apple silicon and Intel and signed with the hardened runtime.

```sh
scripts/release.sh --check                 # is this Mac ready to make a build others can open?
scripts/release.sh                         # a trial run: packaged, but not accepted by other Macs
NOTARY_PROFILE=iguana scripts/release.sh   # the real thing
scripts/publish.sh                         # put it on GitHub as the release for its version
```

For macOS to open the app on someone else's Mac without a warning it has to be signed with a
Developer ID Application certificate and notarized by Apple. Both need the Apple Developer
Program. With the certificate in the keychain, store the notarization credentials once
(`xcrun notarytool store-credentials iguana ...`) and pass the profile name as `NOTARY_PROFILE`.
Without them the script still runs and says plainly that the build is not ready to hand out.

The version comes from `WindowManager.version`. The cask, `iguana.rb`, is published with every
release, and the [tap](https://github.com/Chandram-Dutta/homebrew-tap) fetches it from the
latest release by itself, once an hour.

## Development

```sh
swift test                 # layout engine, config and editor, settings window and tour logic
cd docs && npm install && npm run dev      # the documentation site (Astro Starlight)
tail -f ~/Library/Logs/Iguana.log
```

`Sources/IguanaCore` is pure logic with no system dependencies. `Sources/iguana` is the macOS
layer: Accessibility, Spaces, animation, shortcuts, the settings window, the menu bar item, the
command socket and the daily check for a newer version. `docs/` is the documentation site.

## Licence

Copyright (C) 2026 Chandram Dutta.

Iguana is free software: you can redistribute it and/or modify it under the terms of the
[GNU General Public License, version 3](LICENSE). Anyone who passes on a copy, changed or
not, has to keep the copyright notices and release it, with its source, under the same
licence. It comes with no warranty.
