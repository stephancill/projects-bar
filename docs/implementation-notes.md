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

## 2026-08-16

- The menu now loads up to 30 recent projects and shows the most recent 10 directly. Remaining projects appear in a `More` submenu that opens when highlighted; the `More` item is omitted when there are no extra projects.
- Each project row shows the relative time since its most recent session update (`time_updated`, stored in `Date` milliseconds), appended inline to the project name (e.g. `1m`, `2h`, `3d`, `1w`).

## 2026-08-28

- The project list is now read from the opencode2 `project` table instead of the legacy `session` table.
- The query selects `worktree`, `name`, and `time_updated`, ordered by `time_updated DESC`. `worktree` is used as the project path and `time_updated` as its last activity time.
- Projects with a non-empty `name` column are displayed using that name; otherwise the row falls back to the last path segment of `worktree`, matching previous behavior. The `global` project (worktree `/`) renders an empty label, consistent with the previous "keep everything" filtering (only non-absolute paths are skipped).
- Rows are still parsed from the sqlite3 CLI `|`-separated output; exactly three columns are required, and NULL/empty names become `nil`.

## 2026-08-28 (revision)

- Corrected the source of project recency: `project.time_updated` is not a reliable "last activity" timestamp (it can lag real session activity by days), so the list is now built from `session_v2` instead.
- The query groups `session_v2` rows by `directory`, taking the most recent `time_updated` per directory (`ROW_NUMBER() ... PARTITION BY directory`), and orders by that latest session time. `session_v2.directory` is used as the project path.
- The optional display name is still pulled from the `project` table by joining on the project that owns the directory's latest session. In practice no `project.name` values are currently set, so rows fall back to the last path segment; the `global`-mapped directories (sessions with no dedicated project) render by their real path segment.
- Rows are parsed from the sqlite3 CLI `|`-separated output; exactly three columns (`directory`, `name`, `time_updated`) are required.
- Net effect: the list's order and relative times now reflect actual session activity (e.g. a project last touched today orders high), instead of the sometimes-stale `project.time_updated`.
- The project list refreshes automatically every time the menu opens. `AppDelegate` now conforms to `NSMenuDelegate`, `menu.delegate` is set at launch, and `menuWillOpen(_:)` calls `refreshProjects()` so the shown list is always current without needing the manual `Refresh` item. The manual `Refresh` item remains available.

## 2026-10-16

- Claude Code projects are now listed alongside OpenCode projects. They are read from `~/.claude/projects/<encoded-cwd>/*.jsonl`.
- Claude encodes the project cwd in the folder name by replacing every non-alphanumeric character with `-`, which is lossy. The real path is recovered by scanning the first 256 KB of each transcript (newest first) for a JSON line whose `cwd` re-encodes to the folder name. Folders with no matching `cwd` are skipped and logged.
- A Claude project's last activity time is the newest transcript file modification date in its folder.
- OpenCode and Claude projects are merged by exact path (keeping the most recent time and any OpenCode `name`), sorted by recency, and capped at 30 as before.
- The empty-state label is now `No Projects`. The `Run opencode on Open` toggle still applies to every project, including Claude ones.
