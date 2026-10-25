import AppKit
import Foundation

private let runClaudeDefaultsKey = "runClaudeOnOpen"
private let maxRecentProjects = 30

private let scottyAppPath = "/Applications/Scotty.app"
private let scottyCLIPath = "\(scottyAppPath)/Contents/Helpers/scotty"

struct Project: Equatable {
    let path: String
    let name: String?
    let lastOpenedAt: Date?

    var displayName: String {
        if let name = name, !name.isEmpty {
            return name
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var projects: [Project] = []
    private var moreProjects: [Project] = []
    private var activeProjectPaths = Set<String>()
    private var shouldRunClaudeOnOpen: Bool {
        UserDefaults.standard.bool(forKey: runClaudeDefaultsKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.title = "● 0"
        }

        menu.delegate = self
        statusItem.menu = menu
        refreshProjects()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshProjects()
    }

    @objc private func refreshProjects() {
        let recent = mergeProjects(
            loadRecentProjects(limit: maxRecentProjects) + loadRecentClaudeProjects(),
            limit: maxRecentProjects
        )
        projects = Array(recent.prefix(10))
        moreProjects = Array(recent.dropFirst(10))
        activeProjectPaths = loadScottyShellWorkingDirectories()
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func openProject(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project else { return }
        logEvent("menu selected path=\(project.path)")
        openScottyTerminal(for: project, runClaude: shouldRunClaudeOnOpen)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if projects.isEmpty {
            let item = NSMenuItem(title: "No Projects", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for project in projects {
                menu.addItem(makeProjectItem(for: project))
            }

            if !moreProjects.isEmpty {
                let moreItem = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
                moreItem.submenu = makeProjectMenu(for: moreProjects)
                menu.addItem(moreItem)
            }
        }

        menu.addItem(.separator())
        let runClaudeItem = NSMenuItem(title: "Run claude on Open", action: #selector(toggleRunClaudeOnOpen), keyEquivalent: "")
        runClaudeItem.target = self
        runClaudeItem.state = shouldRunClaudeOnOpen ? .on : .off
        menu.addItem(runClaudeItem)
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshProjects), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleRunClaudeOnOpen(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!shouldRunClaudeOnOpen, forKey: runClaudeDefaultsKey)
        rebuildMenu()
    }

    private func isScottyActive(for project: Project) -> Bool {
        activeProjectPaths.contains(project.path)
    }

    private func makeProjectItem(for project: Project) -> NSMenuItem {
        let isActive = isScottyActive(for: project)
        let timeSuffix = project.lastOpenedAt.map { " – \(relativeTimeString(from: $0))" } ?? ""
        let item = NSMenuItem(title: "\(isActive ? "● " : "")\(project.displayName)\(timeSuffix)", action: #selector(openProject(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = project
        item.toolTip = project.path
        return item
    }

    private func makeProjectMenu(for projects: [Project]) -> NSMenu {
        let submenu = NSMenu()
        for project in projects {
            submenu.addItem(makeProjectItem(for: project))
        }
        return submenu
    }

    private func updateStatusTitle() {
        let activeCount = projects.filter(isScottyActive).count
        statusItem.button?.title = "● \(activeCount)"
    }
}

private func loadRecentProjects(limit: Int) -> [Project] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let databasePath = "\(home)/.local/share/opencode/opencode.db"
    let query = """
    SELECT
      s.directory,
      p.name,
      s.time_updated
    FROM (
      SELECT
        directory,
        time_updated,
        ROW_NUMBER() OVER (PARTITION BY directory ORDER BY time_updated DESC) AS row_number
      FROM session_v2
      WHERE directory IS NOT NULL AND directory != ''
    ) s
    LEFT JOIN project p ON p.id = (
      SELECT project_id FROM session_v2 WHERE directory = s.directory ORDER BY time_updated DESC LIMIT 1
    )
    WHERE s.row_number = 1
    ORDER BY s.time_updated DESC
    LIMIT \(limit);
    """

    let output = runProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
        arguments: [databasePath, query]
    )

    return output
        .split(separator: "\n")
        .compactMap { line -> Project? in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let path = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { return nil }
            let nameVector = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = nameVector.isEmpty ? nil : nameVector
            let lastOpenedAt = Double(parts[2].trimmingCharacters(in: .whitespacesAndNewlines))
                .map { Date(timeIntervalSince1970: $0 / 1000) }
            return Project(path: path, name: name, lastOpenedAt: lastOpenedAt)
        }
}

private func mergeProjects(_ projects: [Project], limit: Int) -> [Project] {
    var byPath: [String: Project] = [:]
    for project in projects {
        guard let existing = byPath[project.path] else {
            byPath[project.path] = project
            continue
        }
        let existingDate = existing.lastOpenedAt ?? .distantPast
        let projectDate = project.lastOpenedAt ?? .distantPast
        byPath[project.path] = Project(
            path: project.path,
            name: existing.name ?? project.name,
            lastOpenedAt: max(existingDate, projectDate)
        )
    }
    return Array(
        byPath.values
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .prefix(limit)
    )
}

/// Claude Code stores transcripts in `~/.claude/projects/<encoded-cwd>/<session>.jsonl`, where the
/// encoded name replaces every non-alphanumeric character of the cwd with `-`. The encoding is
/// lossy, so the real path is recovered from a `"cwd"` field whose encoding matches the folder name.
private func loadRecentClaudeProjects() -> [Project] {
    let fileManager = FileManager.default
    let projectsURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    guard let directories = try? fileManager.contentsOfDirectory(
        at: projectsURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    return directories.compactMap { directoryURL -> Project? in
        guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let files = try? fileManager.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return nil
        }

        let transcripts = files
            .filter { $0.pathExtension == "jsonl" }
            .map { url in
                (url: url, modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        guard let latest = transcripts.first else { return nil }

        let encodedName = directoryURL.lastPathComponent
        guard let path = transcripts.lazy.compactMap({ claudeWorkingDirectory(in: $0.url, matching: encodedName) }).first else {
            logEvent("claude project skipped: no matching cwd for \(encodedName)")
            return nil
        }
        return Project(path: path, name: nil, lastOpenedAt: latest.modifiedAt)
    }
}

private func claudeWorkingDirectory(in transcriptURL: URL, matching encodedName: String) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: transcriptURL) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }

    for line in data.split(separator: UInt8(ascii: "\n")) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let cwd = object["cwd"] as? String,
              cwd.hasPrefix("/"),
              encodeClaudeProjectName(cwd) == encodedName
        else {
            continue
        }
        return cwd
    }
    return nil
}

private func encodeClaudeProjectName(_ path: String) -> String {
    String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
}

private func loadScottyShellWorkingDirectories() -> Set<String> {
    let rows = loadProcessRows()
    let scottyPIDs = Set(
        rows
            .filter { $0.command.hasPrefix("\(scottyAppPath)/Contents/MacOS/ScottyApp") }
            .map(\.pid)
    )

    guard !scottyPIDs.isEmpty else { return [] }

    var childPIDsByParent: [Int: [Int]] = [:]
    for row in rows {
        childPIDsByParent[row.parentPID, default: []].append(row.pid)
    }

    var descendantPIDs = scottyPIDs
    var frontier = Array(scottyPIDs)
    while let currentPID = frontier.popLast() {
        for childPID in childPIDsByParent[currentPID, default: []] where !descendantPIDs.contains(childPID) {
            descendantPIDs.insert(childPID)
            frontier.append(childPID)
        }
    }

    let pidList = descendantPIDs.map(String.init).sorted().joined(separator: ",")
    let output = runProcess(
        executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
        arguments: ["-Fn", "-a", "-d", "cwd", "-p", pidList]
    )

    return Set(
        output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.hasPrefix("n") else { return nil }
                return String(value.dropFirst())
            }
            .filter { !$0.isEmpty }
    )
}

private struct ProcessRow {
    let pid: Int
    let parentPID: Int
    let tty: String
    let command: String
}

private func loadProcessRows() -> [ProcessRow] {
    let output = runProcess(
        executableURL: URL(fileURLWithPath: "/bin/ps"),
        arguments: ["-axo", "pid=,ppid=,tty=,command="]
    )

    return output.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4,
              let pid = Int(parts[0]),
              let parentPID = Int(parts[1])
        else {
            return nil
        }

        return ProcessRow(pid: pid, parentPID: parentPID, tty: String(parts[2]), command: String(parts[3]))
    }
}

/// Focuses the project's terminal in its Scotty workspace, or creates it, via the bundled `scotty` CLI.
/// The terminal is named after the project path, so projects sharing a display name (and therefore a
/// workspace) stay distinct. A focused terminal keeps its directory and command, so `claude` only
/// runs when the terminal is created. The CLI can wait up to 30 seconds for Scotty to reply, so it
/// runs off the main thread.
@MainActor
private func openScottyTerminal(for project: Project, runClaude: Bool) {
    let workspace = project.displayName.isEmpty ? project.path : project.displayName
    var arguments = [
        "terminal",
        "--name", project.path,
        "--if-existing", "focus",
        "--workspace", workspace,
        "--working-directory", project.path,
    ]
    if runClaude {
        // A login shell resolves `claude` from the user's PATH rather than Scotty's child environment.
        arguments += ["--", "/bin/zsh", "-lc", "exec claude"]
    }
    logEvent("scotty launch arguments=\(arguments)")

    Task.detached {
        let result = runProcessWithStatus(executableURL: URL(fileURLWithPath: scottyCLIPath), arguments: arguments)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorOutput = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        logEvent("scotty exited status=\(result.status) output=\(output) error=\(errorOutput) path=\(project.path)")

        guard result.status == EXIT_SUCCESS else {
            await MainActor.run {
                showError(errorOutput.isEmpty ? "Failed to open \(project.path) in Scotty (exit \(result.status))." : errorOutput)
            }
            return
        }
    }
}

private func relativeTimeString(from date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date).rounded())
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 7 { return "\(days)d" }
    return "\(days / 7)w"
}

@MainActor
private func showError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "ProjectsBar Error"
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.runModal()
}

private func logEvent(_ message: String) {
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ProjectsBar.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"

    guard let data = line.data(using: .utf8) else { return }

    if FileManager.default.fileExists(atPath: logURL.path),
       let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

@discardableResult
private func runProcess(executableURL: URL, arguments: [String]) -> String {
    runProcessWithStatus(executableURL: executableURL, arguments: arguments).output
}

private func runProcessWithStatus(executableURL: URL, arguments: [String]) -> (output: String, errorOutput: String, status: Int32) {
    let process = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()

    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = errorPipe

    do {
        try process.run()
    } catch {
        return ("", "Failed to run \(executableURL.path): \(error.localizedDescription)", EXIT_FAILURE)
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", String(data: errorData, encoding: .utf8) ?? "", process.terminationStatus)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
