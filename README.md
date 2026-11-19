# TermGrid

Russian version: [README.ru.md](README.ru.md)

TermGrid is a macOS menu-bar app that tiles windows of any applications, terminals first, into a grid and lets you resize cells by dragging dividers or window edges with the mouse instead of hotkeys.

## Status

TermGrid is an early MVP.

- Requires macOS 14 or later.
- Built and tested with Command Line Tools only. There is no Xcode project.
- Verified live only on TermGrid's own test windows and in one maintainer session. Terminal.app character-step fitting has not been measured.

## Features

- Grid presets (two columns, three columns, two rows, 2x2, one plus two, 2x3) on one screen.
- Assign windows to cells from the menu, or use "Lay out automatically".
- Drag a divider to resize the two neighbouring cells live, while the mouse moves.
- Resize a window by its inner edge: the adjacent divider moves and the neighbouring window takes the freed space. An outer edge of the grid snaps the window back to its cell size.
- Gap between windows: 0, 1, 2, 3, 4, 6 or 8 pt, default 4 pt. Dividers are at least 6 pt thick and centred on the gap.
- Character-cell fitting for Terminal.app and iTerm2 is on by design. It closes inner gaps between neighbouring terminal windows when the shortfall is under 40 pt.
- The layout is saved automatically and can be restored with the "Restore windows" menu button.
- The menu shows a warning while Stage Manager is on.

## Requirements

- macOS 14 or later.
- Command Line Tools for Xcode. Full Xcode is not needed: the build uses `swift build`.

Check the installation:

```bash
xcode-select -p
```

If the command prints nothing or fails, install the tools with `xcode-select --install`.

Turn Stage Manager off (see [Stage Manager](#stage-manager)).

## Build

Run from the repository root:

```bash
scripts/build-app.sh            # debug, default
scripts/build-app.sh release    # release
```

The script builds the `TermGrid` product, copies the binary and `Resources/Info.plist` into `build/TermGrid.app`, and signs the bundle. The last line it prints is the path to `build/TermGrid.app`.

## Tests

```bash
scripts/test.sh --filter DividerTests
```

`--filter` takes the name of a test suite from `Tests/GridCoreTests`. Use the name from the `struct` declaration, not the file name: the suite `DividerTests` is declared in `DividersTests.swift`. The script passes all arguments to `swift test`.

The script is needed because with only Command Line Tools, `swift test` cannot load Swift Testing (`no such module 'Testing'`). The script adds the `-F` and `-rpath` flags that point at the CLT framework directory. Do not call `swift test` directly.

The local workflow does not run the full suite without `--filter`. Run the suites that your change touches.

## Releases

The version is `CFBundleShortVersionString` in `Resources/Info.plist`. It is the only place to change it. Each release is tagged `v<version>` and published on GitHub with the DMG `TermGrid-<version>.dmg`.

To publish: bump the version in `Resources/Info.plist`, rename `[Unreleased]` in `CHANGELOG.md` to the new version with its date, commit both, and push `main`. Then run from a clean `main` that equals `origin/main`:

```bash
scripts/release.sh             # dry run: checks and builds the DMG, publishes nothing
scripts/release.sh --publish   # tags vX.Y.Z, pushes the tag, creates the GitHub release
```

The release is not signed or notarized. Users must right-click the app and choose Open the first time, or run `xattr -dr com.apple.quarantine /Applications/TermGrid.app`, and then grant Accessibility again.

## Run

```bash
open build/TermGrid.app
```

Launch the app only with `open`. Do not run the binary `build/TermGrid.app/Contents/MacOS/TermGrid` directly from a terminal: the Accessibility permission is checked for the process that started the binary, so the permission would have to be granted to the terminal instead of TermGrid.

The app appears in the menu bar. It has no Dock icon (`LSUIElement`).

## Permissions

TermGrid uses one permission: **Accessibility**. It does not need Screen Recording, because it never shows window contents.

1. Run `open build/TermGrid.app`.
2. macOS shows a system dialog. It only opens System Settings. You cannot switch the toggle inside the dialog.
3. In System Settings, open Privacy & Security → Accessibility and enable TermGrid.
4. If the menu still shows onboarding after you grant the permission, quit TermGrid and start it again with `open build/TermGrid.app`. In one test run, a running TermGrid did not notice a permission granted after it started, and logged "accessibility trusted" only after a restart.

With the `TermGrid Local Signing` certificate the permission survives rebuilds. If it is lost anyway (for example, the build fell back to ad-hoc), reset it:

1. Quit TermGrid.
2. Reset the permission: `tccutil reset Accessibility local.termgrid.TermGrid` (see [Signing](#signing)).
3. Run `open build/TermGrid.app` and grant the permission again.

While the permission is not granted, the menu shows an "Open Settings" button.

## Signing

`scripts/build-app.sh` signs the app with the certificate `TermGrid Local Signing` from your login keychain. The certificate is self-signed and is not trusted by macOS, but `codesign` uses it. The Accessibility permission is then bound to the certificate, not to the binary hash, so rebuilds keep the permission.

Create the certificate once (keys stay out of the repository):

```bash
d="$(mktemp -d)"; cd "$d"
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=TermGrid Local Signing" \
  -addext "extendedKeyUsage=critical,codeSigning" -addext "keyUsage=critical,digitalSignature"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:tgsign
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P tgsign -T /usr/bin/codesign
```

If the certificate is missing, the script falls back to ad-hoc signing and prints a warning. With ad-hoc signing the permission is lost after every rebuild.

The first build with the new certificate needs one new grant: run `tccutil reset Accessibility local.termgrid.TermGrid`, then `open build/TermGrid.app`, and grant the permission.

## Stage Manager

Turn Stage Manager off before you use TermGrid: System Settings → Desktop & Dock → Stage Manager.

While Stage Manager is on, macOS groups windows by application, lets you switch only between groups, and moves some windows into the side strip. TermGrid does not see windows in the side strip, so the layout breaks: windows can be minimised or disappear, and new cells look empty. The menu shows a warning while Stage Manager is on.

The project maintainer attributes this to Stage Manager. It matches the setting on the development machine: `defaults read com.apple.WindowManager GloballyEnabled` prints `1`. A re-test with Stage Manager off has not been done yet.

## Usage

The menu labels are in Russian. The English names below are translations.

- **Grid** (Сетка): choose a preset, the screen, and the gap, or hide the dividers. "Lay out automatically" arranges the windows you selected in the window list; it is enabled only when some are selected. "Reset" clears the grid. "Restore windows" restores the saved layout.
- **Cells** (Ячейки): for each cell, split it horizontally or vertically, close it, return a detached window to the grid, retry, or remove the window from the cell.
- **Windows** (Окна): assign a window to a cell.

Drag a divider with the mouse to resize the two cells on each side. Drag an inner window edge to move the adjacent divider. Drag an outer grid edge to snap the window back to its cell. Drag a window with the mouse onto another cell to swap it with that cell's window (the target cell is highlighted under the pointer). Released anywhere else, the window returns to its cell.

The resize cursor appears over a divider even when TermGrid is not the active app. See [Limitations and known issues](#limitations-and-known-issues) for how this works.

## Limitations and known issues

- Windows on other Spaces are not visible to Accessibility. TermGrid does not lay them out or move them between Spaces. Whether the divider panels follow Spaces has not been verified.
- Full-screen windows are skipped and do not appear in the window list.
- One grid on one screen. Multiple monitors are not supported in the MVP.
- Moving a window with the mouse is a drag: it swaps or returns. A window moved without the mouse button held (for example, by another app) detaches from its cell; use "Return to grid" to attach it again.
- Stage Manager must be off. See [Stage Manager](#stage-manager).
- A window whose minimum size is larger than its cell is clamped (log status `clamped`) and overlaps neighbouring cells, because the layout solver does not use minimum sizes when it lays out cells. Not verified on real applications.
- Not verified: after "Lay out automatically" with several real windows, a new cell can look empty. The project maintainer attributes this to Stage Manager; a re-test with it off has not been done.
- Not verified: a monitor change may detach windows before the layout is re-applied. Checking this needs a second display.
- Not verified: live runs of an application stopped with SIGSTOP (with the main-thread heartbeat), and of Chromium and Electron windows.
- Divider panels are at the `.floating` window level. Over unmanaged windows they can catch clicks in the gap strip.
- The resize cursor uses the private CoreGraphics connection property `SetsCursorInBackground`. The app resolves it with `dlsym` at runtime (`Sources/TermGrid/BackgroundCursor.swift`). Private APIs can disappear or change in a future macOS. If the symbol is missing, the cursor stays the system cursor, and the divider is highlighted on hover instead.
- The project maintainer confirmed the resize cursor by eye. The automated `tgprobe` cursor check reported `matchesResizeLeftRight=false`, so it does not confirm the cursor.
- Live-resize latency was measured on TermGrid's own test windows and on iTerm2. Terminal.app and browsers were not measured.
- The iTerm2 "Terminal windows resize smoothly" observation comes from one measurement without a recorded profile or font. Check the setting in your iTerm2 version.

## Project layout

- `Sources/GridCore`: pure layout logic (layout tree, frame solver, dividers, edge resize, echo filter, fit policy, layout snapshot). It imports only CoreGraphics and Foundation.
- `Sources/TermGrid`: the menu-bar app (window discovery and moving through Accessibility, divider panels, grid controller, menu).
- `Sources/ProbeKit`: Accessibility probes shared by the app and `tgprobe`. Debugging tool.
- `Sources/tgprobe`: command-line probe utility for checks that need Accessibility. It runs through the app bundle.
- `Tests/GridCoreTests`: Swift Testing suites for `GridCore`.
- `Resources/Info.plist`: bundle metadata.
- `scripts/`: build, tests, the no-comments check, and debugging helpers (`probe.sh`, `selftest.sh`; they need a debug build of `build/TermGrid.app`).

## Contributing

- Do not add comments to code. This is a project rule. Put rationale in the commit message. Check it with:

  ```bash
  scripts/check-no-comments.sh
  ```

  The script prints the lines that break the rule and exits with status 1.
- Run only the tests for the suites your change touches:

  ```bash
  scripts/test.sh --filter DividerTests
  ```

- Build the app before you check it by hand: `scripts/build-app.sh`.
- Use conventional commit messages, as in the existing history (for example `feat(grid): ...`, `docs: ...`).

## License

TermGrid is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
