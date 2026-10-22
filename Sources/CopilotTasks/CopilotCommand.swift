import Foundation

/// How BriefBar runs the Copilot CLI for a task.
public enum CopilotCommand {
    /// A run that works on its own: the prompt, in autopilot until Copilot calls the task done, with every tool allowed
    /// and no questions, since nobody is there to answer them. Its session gets the ID BriefBar chose, to follow it by.
    /// - Parameter trustFolder: loads the worktree's own skills, MCP servers and hooks, for a repository you trust.
    public static func arguments(
        prompt: String, options: CopilotRunOptions, sessionId: String, name: String, directory: URL, trustFolder: Bool
    ) -> [String] {
        var arguments = ["-p", prompt, "--model", options.model]
        if let effort = options.effort {
            arguments += ["--reasoning-effort", effort]
        }
        arguments += ["--autopilot", "--allow-all-tools", "--no-ask-user"]
        if trustFolder {
            arguments.append("--trust-folder")
        }
        arguments += ["--session-id", sessionId, "--name", name, "-C", directory.path, "--silent"]
        return arguments
    }

    /// A session's name, as the CLI lists it: the work item, kept short.
    public static func sessionName(for item: TaskWorkItem) -> String {
        let name = "\(item.type) \(item.id): \(item.title)"
        return name.count > 80 ? String(name.prefix(79)) + "…" : name
    }

    /// A script for Terminal that goes on with a run's session, interactively, in its worktree.
    public static func resumeScript(copilot: URL, sessionId: String, directory: URL, workItem: Int) -> String {
        """
        #!/bin/zsh -l
        # Opened by BriefBar: Copilot's session for work item \(workItem), to go on with it.
        cd \(quoted(directory.path)) && exec \(quoted(copilot.path)) --resume \(quoted(sessionId))
        """
    }

    /// A word for the shell, in single quotes.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
