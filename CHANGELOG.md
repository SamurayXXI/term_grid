# Changelog

All notable changes to TermGrid are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Menu-bar app that tiles windows into a grid with presets: two columns, three columns, two rows, 2x2, one plus two, 2x3.
- Draggable divider panels: drag a divider to resize the two neighbouring cells live.
- Resize a window by its inner edge; an outer grid edge snaps the window back to its cell.
- Gap between windows from 0 to 8 pt, default 4 pt.
- Assign windows to cells from the menu, and "Lay out automatically".
- Layout is saved automatically and restored with "Restore windows".
- Cell operations: split horizontally or vertically, close, return a detached window, retry.
- Resize cursor over a divider while TermGrid is not the active app.
- Menu warning while Stage Manager is on.
- Character-cell fitting for Terminal.app and iTerm2.
- Accessibility onboarding.
- Apache-2.0 license.
- English README with a Russian translation.
- `scripts/build-dmg.sh` builds a compressed DMG.
- `scripts/release.sh` publishes a version as a Git tag and a GitHub release.

### Fixed

- Divider hover highlight is drawn only while a managed app is frontmost, so it no longer shows over another active app.
- Review findings on restore, fit, lanes and persistence.

### Known issues

- Accessibility permission is lost after every rebuild, because the build is ad-hoc signed. See the README "Signing" section.
- The app is not signed with a Developer ID and not notarized. Users must open it through the context menu the first time.
- Stage Manager must be off for windows to stay where TermGrid puts them.
