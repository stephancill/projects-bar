# Implementation Notes

## 2026-07-18

- Scaffolded a Swift Package Manager executable for a macOS AppKit status bar app.
- The app reads recent OpenCode session directories from `~/.local/share/opencode/opencode.db` using the system `sqlite3` CLI.
- Recent directories are ordered by latest `session.time_updated` and displayed by the last path segment.
- OpenCode directory rows must be single absolute paths; malformed SQLite rows containing separators such as `|` are ignored.
- Selecting a project always opens a new Ghostty window at that directory. ProjectsBar no longer attempts to focus or reuse existing Ghostty windows.
- ProjectsBar does not use Accessibility APIs, AppleScript, or Ghostty window-title mutation.
- The menu includes a persisted `Run opencode on Open` toggle backed by `UserDefaults` key `runOpenCodeOnOpen`.
- When `Run opencode on Open` is enabled, ProjectsBar first checks whether the selected directory is already active in Ghostty. If it is already active, it opens a normal Ghostty window without running a command. If it is not active, it launches Ghostty via `open -na` with `-e /bin/zsh -lc 'cd <path> && exec opencode'`, because Ghostty's existing-instance Service does not expose a command parameter and direct `-e opencode` did not reliably preserve cwd.
- The build script ad-hoc signs the generated `.app` bundle so the bundle identifier and `Info.plist` are bound for macOS permissions.
- The menu shows `●` next to projects detected as active in Ghostty.
- The menu bar status item title is `● <N>`, where `N` is the number of listed recent projects detected as active in Ghostty.
- Active detection uses exact cwd paths from processes descended from Ghostty, with the descendant tree derived from `ps` and cwd paths read via `lsof`.
- `lsof -Fn` cwd results are parsed from `n<path>` records; non-path records are ignored.
- Active Ghostty state is refreshed at app launch and manual Refresh; the menu does not perform synchronous process scans while opening.
- Clicking a project opens a new Ghostty window using Ghostty's native macOS Service `New Ghostty Window Here` with a fresh named pasteboard containing a file URL inside the target directory.
- Ghostty's `New Ghostty Window Here` service opens the containing directory of the pasteboard item, so ProjectsBar passes a file inside the target directory rather than the directory itself. If no file exists, it creates `.projects-bar-open-here` in the target directory and passes that marker file.
- If the Ghostty Service cannot be invoked, the app shows an error and does not fall back. Silent fallback behavior was removed because it could open an incorrect directory.
- `scripts/build-app.sh` builds a release executable and packages `.build/ProjectsBar.app` with `LSUIElement` enabled so the app runs as a menu bar accessory.
- `scripts/install-login-item.sh` installs `~/Library/LaunchAgents/net.stupidtech.ProjectsBar.plist`, which opens the built app at login using LaunchAgent `RunAtLoad`.
- `scripts/uninstall-login-item.sh` unloads and removes that LaunchAgent.
- Process helpers drain stdout before waiting for exit to avoid deadlocking on commands with larger output, such as `ps`.
