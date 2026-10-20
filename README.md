# ProjectsBar

A macOS menu bar app that lists your recent [OpenCode](https://opencode.ai) and [Claude Code](https://claude.com/claude-code) projects and opens them in a new [Ghostty](https://ghostty.org) window.

Native Swift/AppKit, no dependencies.

## Features

- Lists recent projects from OpenCode (`~/.local/share/opencode/opencode.db`) and Claude Code (`~/.claude/projects`), merged and sorted by last activity.
- Shows the 10 most recent projects with relative times (`5m`, `2h`, `3d`), with up to 20 more under `More`.
- Marks projects that already have a Ghostty shell open with `●`, and shows the active count in the menu bar.
- Clicking a project opens a new Ghostty window in that directory.
- Optional `Run opencode on Open` toggle starts `opencode` in the new window, unless the project is already active.
- The list refreshes every time the menu opens.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode or Command Line Tools)
- Ghostty installed at `/Applications/Ghostty.app`

## Build and run

```sh
scripts/build-app.sh
open .build/ProjectsBar.app
```

The build script produces an ad-hoc signed `.build/ProjectsBar.app` that runs as a menu bar accessory (no Dock icon).

## Launch at login

```sh
scripts/install-login-item.sh    # installs a LaunchAgent that opens the app at login
scripts/uninstall-login-item.sh  # removes it
```

## How it works

See [docs/implementation-notes.md](docs/implementation-notes.md) for details on project discovery, active-shell detection, and how Ghostty windows are opened.
