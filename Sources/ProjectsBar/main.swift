import AppKit
import Foundation

private let runOpenCodeDefaultsKey = "runOpenCodeOnOpen"

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--open-ghostty-window" {
    let path = CommandLine.arguments[2]
    let shouldRunOpenCode = CommandLine.arguments.dropFirst(3).contains("--run-opencode")
    logEvent("helper path=\(path)")
    let isAlreadyActive = loadGhosttyShellWorkingDirectories().contains(path)
    let didOpen: Bool
    if shouldRunOpenCode, !isAlreadyActive {
        didOpen = openGhosttyWindowRunningOpenCode(at: path)
    } else {
        didOpen = openGhosttyWindowUsingService(at: path)
    }
    logEvent("helper result=\(didOpen ? "success" : "failure") path=\(path) runOpenCode=\(shouldRunOpenCode) alreadyActive=\(isAlreadyActive)")
    exit(didOpen ? EXIT_SUCCESS : EXIT_FAILURE)
}

struct Project: Equatable {
    let path: String

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var projects: [Project] = []
    private var activeProjectPaths = Set<String>()
    private var shouldRunOpenCodeOnOpen: Bool {
        UserDefaults.standard.bool(forKey: runOpenCodeDefaultsKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.title = "● 0"
        }

        statusItem.menu = menu
        refreshProjects()
    }

    @objc private func refreshProjects() {
        projects = loadRecentProjects()
        activeProjectPaths = loadGhosttyShellWorkingDirectories()
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func openProject(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project else { return }
        logEvent("menu selected path=\(project.path)")
        openGhosttyWindow(at: project.path)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if projects.isEmpty {
            let item = NSMenuItem(title: "No OpenCode Projects", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for project in projects {
                let isActive = isGhosttyActive(for: project)
                let item = NSMenuItem(title: "\(isActive ? "● " : "")\(project.name)", action: #selector(openProject(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = project
                item.toolTip = project.path
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let runOpenCodeItem = NSMenuItem(title: "Run opencode on Open", action: #selector(toggleRunOpenCodeOnOpen), keyEquivalent: "")
        runOpenCodeItem.target = self
        runOpenCodeItem.state = shouldRunOpenCodeOnOpen ? .on : .off
        menu.addItem(runOpenCodeItem)
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshProjects), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleRunOpenCodeOnOpen(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!shouldRunOpenCodeOnOpen, forKey: runOpenCodeDefaultsKey)
        rebuildMenu()
    }

    private func isGhosttyActive(for project: Project) -> Bool {
        activeProjectPaths.contains(project.path)
    }

    private func updateStatusTitle() {
        let activeCount = projects.filter(isGhosttyActive).count
        statusItem.button?.title = "● \(activeCount)"
    }
}

private func loadRecentProjects() -> [Project] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let databasePath = "\(home)/.local/share/opencode/opencode.db"
    let query = """
    SELECT
      directory
    FROM (
      SELECT
        s.directory,
        s.time_updated,
        ROW_NUMBER() OVER (PARTITION BY s.directory ORDER BY s.time_updated DESC) AS row_number
      FROM session s
      WHERE s.directory IS NOT NULL AND s.directory != ''
    )
    WHERE row_number = 1
    ORDER BY time_updated DESC
    LIMIT 10;
    """

    let output = runProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
        arguments: [databasePath, query]
    )

    return output
        .split(separator: "\n")
        .compactMap { line in
            let path = String(line)
            guard path.hasPrefix("/"), !path.contains("|") else { return nil }
            return Project(path: path)
        }
}

private func loadGhosttyShellWorkingDirectories() -> Set<String> {
    let rows = loadProcessRows()
    let ghosttyPIDs = Set(
        rows
            .filter { $0.command.contains("/Applications/Ghostty.app/Contents/MacOS/ghostty") }
            .map(\.pid)
    )

    guard !ghosttyPIDs.isEmpty else { return [] }

    var childPIDsByParent: [Int: [Int]] = [:]
    for row in rows {
        childPIDsByParent[row.parentPID, default: []].append(row.pid)
    }

    var descendantPIDs = ghosttyPIDs
    var frontier = Array(ghosttyPIDs)
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

@MainActor
private func openGhosttyWindow(at path: String) {
    let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    logEvent("spawning helper executable=\(executablePath) path=\(path)")
    var arguments = ["--open-ghostty-window", path]
    if UserDefaults.standard.bool(forKey: runOpenCodeDefaultsKey) {
        arguments.append("--run-opencode")
    }

    let result = runProcessWithStatus(
        executableURL: URL(fileURLWithPath: executablePath),
        arguments: arguments
    )
    logEvent("helper exited status=\(result.status) output=\(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) path=\(path)")

    guard result.status == EXIT_SUCCESS else {
        showError(result.output.isEmpty ? "Failed to invoke Ghostty's New Ghostty Window Here service." : result.output)
        return
    }
}

private func openGhosttyWindowRunningOpenCode(at path: String) -> Bool {
    let command = "cd \(shellQuoted(path)) && exec opencode"
    let result = runProcessWithStatus(
        executableURL: URL(fileURLWithPath: "/usr/bin/open"),
        arguments: [
            "-na",
            "/Applications/Ghostty.app",
            "--args",
            "--working-directory=\(path)",
            "-e",
            "/bin/zsh",
            "-lc",
            command,
        ]
    )
    logEvent("open opencode status=\(result.status) output=\(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) path=\(path)")
    return result.status == EXIT_SUCCESS
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func openGhosttyWindowUsingService(at path: String) -> Bool {
    let servicePath = ghosttyServicePath(forDirectory: path)
    logEvent("service path=\(path) servicePath=\(servicePath)")
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("ProjectsBarGhosttyService.\(UUID().uuidString)"))
    pasteboard.clearContents()
    let didWrite = pasteboard.writeObjects([URL(fileURLWithPath: servicePath) as NSURL])
    logEvent("pasteboard didWrite=\(didWrite) types=\(pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "")")

    let didPerform = NSPerformService("New Ghostty Window Here", pasteboard)
    logEvent("service didPerform=\(didPerform) servicePath=\(servicePath)")
    return didPerform
}

@MainActor
private func showError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "ProjectsBar Error"
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.runModal()
}

private func ghosttyServicePath(forDirectory path: String) -> String {
    let fileManager = FileManager.default
    let directoryURL = URL(fileURLWithPath: path, isDirectory: true)

    if let contents = try? fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) {
        for url in contents {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues?.isDirectory == false {
                return url.path
            }
        }
    }

    let markerPath = directoryURL.appendingPathComponent(".projects-bar-open-here").path
    if !fileManager.fileExists(atPath: markerPath) {
        fileManager.createFile(atPath: markerPath, contents: nil)
    }

    return markerPath
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

private func runProcessWithStatus(executableURL: URL, arguments: [String]) -> (output: String, status: Int32) {
    let process = Process()
    let pipe = Pipe()

    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return ("", EXIT_FAILURE)
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
