import AppKit
import BriefBarCore
import BriefBarUI
import CopilotCore
import CopilotTasks

/// Opening a session on a Mac without the GitHub Copilot app, as with only the Copilot CLI, where nothing opens the app's
/// `ghapp://` links. A session a CLI still has open (`SessionLock`) is in the terminal that CLI runs in, which comes to the
/// front: going on with it in a second one would fork its history. Any other goes on in Terminal with `copilot --resume`,
/// in the folder it works in, as **Continue in Terminal** does for a task BriefBar sent. While it starts there, before its
/// CLI holds it, another click opens nothing more (`Starting`).
@MainActor
enum CLISession {
    /// How a session opens.
    enum Way: Equatable {
        /// In the terminal of the CLI that has it open, by that CLI's process ID.
        case show(pid_t)
        /// In a new Terminal window.
        case resume
    }

    /// The sessions being opened in Terminal now.
    private static var starting = Starting()

    nonisolated static func way(
        for id: String, paths: CopilotPaths, holder: (URL) -> pid_t? = { SessionLock.holder(sessionFolder: $0) }
    ) -> Way {
        holder(paths.sessionDirectory(id)).map(Way.show) ?? .resume
    }

    static func open(_ id: String, paths: CopilotPaths) {
        // A session's ID is a UUID, which names its folder in lowercase.
        guard let id = ItemRef.session(id)?.id else { return }
        switch way(for: id, paths: paths) {
        case .show(let pid):
            starting.end(id)
            show(pid)
        case .resume:
            // Its CLI may not hold it yet: a second one would fork its history.
            guard starting.begin(id) else { return }
            let round = starting.round
            Task { await resume(id, paths: paths, round: round) }
        }
    }

    /// Stops opening sessions in Terminal, when Copilot is turned off or BriefBar quits: one that's still finding
    /// `copilot` reads nothing more of its session, and opens nothing.
    static func stop() {
        starting.stopAll()
    }

    /// Brings the app the CLI runs in to the front, such as Terminal: the one macOS holds responsible for it.
    private static func show(_ pid: pid_t) {
        guard let responsible = Responsibility.responsible(for: pid), responsible.pid != pid,
              let app = NSRunningApplication(processIdentifier: responsible.pid), let url = app.bundleURL
        else {
            return say(
                "The session is open in another terminal",
                "The Copilot CLI has it open where BriefBar can't bring it up, such as in tmux or over SSH. Go on with it there: opening it in a second terminal would fork its history."
            )
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Goes on with it in a new Terminal window: `copilot`, as your login shell finds it, resumes it in its folder, from
    /// the Copilot folder BriefBar found it in. Only while opening hasn't stopped since `round` (`stop()`).
    private static func resume(_ id: String, paths: CopilotPaths, round: Int) async {
        let environment = await LoginEnvironment.load()
        // Copilot was turned off meanwhile.
        guard starting.round == round else { return }
        // A CLI may have opened it meanwhile.
        if case .show(let pid) = way(for: id, paths: paths) {
            starting.end(id)
            return show(pid)
        }
        let command = "copilot --resume \(id)"
        guard let copilot = CopilotCLI.locate(environment: environment) else {
            starting.end(id)
            return say("BriefBar couldn't find the Copilot CLI", "Open the session in Terminal yourself with \(command).")
        }
        guard let folder = AppSessions.folder(of: id, home: paths.root) else {
            starting.end(id)
            return say(
                "The session's folder isn't there anymore",
                "Copilot worked on it in a folder that's gone, such as a worktree that was removed. To go on with it anyway, run \(command) in Terminal."
            )
        }
        let file = script(for: id)
        let contents = CopilotCommand.resumeScript(copilot: copilot, sessionId: id, directory: folder, home: paths.root, file: file)
        do {
            try FileManager.default.createDirectory(at: scriptsFolder, withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            starting.end(id)
            // Not its description, which names the file, and so the session.
            let error = error as NSError
            Log.app.error("Couldn't open a Copilot CLI session in Terminal: \(error.domain, privacy: .public) \(error.code)")
        }
    }

    /// Where the scripts that open sessions in Terminal go: BriefBar's caches, as for **Continue in Terminal**.
    nonisolated static var scriptsFolder: URL {
        UserHome.url.appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
    }

    nonisolated static let scriptPrefix = "Copilot session "

    /// The script that opens a session in Terminal, by its whole ID, so that no two sessions' scripts are the same file.
    nonisolated static func script(for id: String, in folder: URL = scriptsFolder) -> URL {
        folder.appendingPathComponent("\(scriptPrefix)\(id).command")
    }

    /// Removes the scripts that would have opened sessions in Terminal but never ran: each removes itself as it starts,
    /// and names a session and its folder. When you turn Copilot off (`CopilotSource.deleteSavedData()`).
    nonisolated static func forgetScripts(in folder: URL = scriptsFolder) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(scriptPrefix) && name.hasSuffix(".command") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func say(_ message: String, _ information: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        NSApp.activate()
        alert.runModal()
    }

    /// The sessions being opened in Terminal, since when. A new Terminal window takes a moment to start a login shell and
    /// the CLI, which holds the session only once it starts: a second click meanwhile would start a second CLI on it, and
    /// fork its history. So for a while, opening it again opens nothing more.
    struct Starting {
        /// Long enough for Terminal to start a login shell and the CLI.
        static let window: TimeInterval = 30
        private var since: [String: Date] = [:]
        /// How many times opening stopped (`stopAll()`): a session that began opening before then opens nothing.
        private(set) var round = 0

        /// Starts opening the session, unless it's being opened already: false then.
        mutating func begin(_ id: String, now: Date = Date()) -> Bool {
            if let started = since[id], now.timeIntervalSince(started) < Self.window { return false }
            since[id] = now
            return true
        }

        /// It's open, or couldn't be opened: the next click opens it again.
        mutating func end(_ id: String) {
            since[id] = nil
        }

        /// Stops opening every session, as when Copilot is turned off.
        mutating func stopAll() {
            since = [:]
            round += 1
        }
    }
}
