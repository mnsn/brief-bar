import AppKit
import BriefBarCore
import BriefBarUI
import CopilotCore
import CopilotTasks

/// Opening a session on a Mac without the GitHub Copilot app, as with only the Copilot CLI, where nothing opens the app's
/// `ghapp://` links. A session a CLI still has open (`SessionLock`) is in the terminal that CLI runs in, which comes to the
/// front: going on with it in a second one would fork its history. Any other goes on in Terminal with `copilot --resume`,
/// in the folder it works in, as **Continue in Terminal** does for a task BriefBar sent.
@MainActor
enum CLISession {
    /// How a session opens.
    enum Way: Equatable {
        /// In the terminal of the CLI that has it open, by that CLI's process ID.
        case show(pid_t)
        /// In a new Terminal window.
        case resume
    }

    nonisolated static func way(
        for id: String, paths: CopilotPaths, holder: (URL) -> pid_t? = { SessionLock.holder(sessionFolder: $0) }
    ) -> Way {
        holder(paths.sessionDirectory(id)).map(Way.show) ?? .resume
    }

    static func open(_ id: String, paths: CopilotPaths) {
        // A session's ID is a UUID, which names its folder in lowercase.
        guard let id = ItemRef.session(id)?.id else { return }
        switch way(for: id, paths: paths) {
        case .show(let pid): show(pid)
        case .resume: Task { await resume(id, paths: paths) }
        }
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

    /// Goes on with it in a new Terminal window: `copilot`, as your login shell finds it, resumes it in its folder.
    private static func resume(_ id: String, paths: CopilotPaths) async {
        let environment = await LoginEnvironment.load()
        // A CLI may have opened it meanwhile.
        if case .show(let pid) = way(for: id, paths: paths) { return show(pid) }
        let command = "copilot --resume \(id)"
        guard let copilot = CopilotCLI.locate(environment: environment) else {
            return say("BriefBar couldn't find the Copilot CLI", "Open the session in Terminal yourself with \(command).")
        }
        guard let folder = AppSessions.folder(of: id, home: paths.root) else {
            return say(
                "The session's folder isn't there anymore",
                "Copilot worked on it in a folder that's gone, such as a worktree that was removed. To go on with it anyway, run \(command) in Terminal."
            )
        }
        let script = CopilotCommand.resumeScript(copilot: copilot, sessionId: id, directory: folder)
        do {
            let directory = UserHome.url.appendingPathComponent("Library/Caches", isDirectory: true)
                .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Copilot session \(id.prefix(8)).command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            // Not its description, which names the file, and so the session.
            let error = error as NSError
            Log.app.error("Couldn't open a Copilot CLI session in Terminal: \(error.domain, privacy: .public) \(error.code)")
        }
    }

    private static func say(_ message: String, _ information: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        NSApp.activate()
        alert.runModal()
    }
}
