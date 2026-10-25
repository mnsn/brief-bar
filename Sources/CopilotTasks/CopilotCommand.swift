import Foundation

/// How BriefBar runs the Copilot CLI for a task.
public enum CopilotCommand {
    /// A run that works on its own: the prompt, in autopilot until Copilot calls the task done, with every tool allowed
    /// and no questions, since nobody is there to answer them. Its session gets the ID BriefBar chose, to follow it by.
    /// - Parameter trustFolder: loads the worktree's own skills, MCP servers and hooks, for a repository you trust.
    /// - Parameter name: the new session's name; nil to go on with an existing session, under its own.
    public static func arguments(
        prompt: String, options: CopilotRunOptions, sessionId: String, name: String?, directory: URL, trustFolder: Bool
    ) -> [String] {
        var arguments = ["-p", prompt, "--model", options.model]
        if let effort = options.effort {
            arguments += ["--reasoning-effort", effort]
        }
        arguments += ["--autopilot", "--allow-all-tools", "--no-ask-user"]
        if trustFolder {
            arguments.append("--trust-folder")
        }
        arguments += ["--session-id", sessionId]
        if let name { arguments += ["--name", name] }
        arguments += ["-C", directory.path, "--silent"]
        return arguments
    }

    /// A session's name, as the CLI lists it: the work item, kept short.
    public static func sessionName(for item: TaskWorkItem) -> String {
        short("\(item.type) \(item.id): \(item.title)")
    }

    /// A pull request's session's name: what it's for, and the pull request, kept short.
    public static func sessionName(for pullRequest: TaskPullRequest, action: PullRequestAction) -> String {
        short("\(action.title): !\(pullRequest.id) \(pullRequest.title)")
    }

    /// The new session's name for a subject.
    static func sessionName(for subject: TaskSubject) -> String {
        switch subject {
        case .workItem(let item): return sessionName(for: item)
        case .pullRequest(let pullRequest, let action): return sessionName(for: pullRequest, action: action)
        }
    }

    private static func short(_ name: String) -> String {
        name.count > 80 ? String(name.prefix(79)) + "…" : name
    }

    /// A script for Terminal that goes on with a run's session, interactively, in its worktree.
    public static func resumeScript(copilot: URL, sessionId: String, directory: URL, workItem: Int) -> String {
        resumeScript(copilot: copilot, sessionId: sessionId, directory: directory, subject: "work item \(workItem)")
    }

    /// The same, for a session about `subject`, such as "pull request 4071".
    public static func resumeScript(copilot: URL, sessionId: String, directory: URL, subject: String) -> String {
        """
        #!/bin/zsh -l
        # Opened by BriefBar: Copilot's session for \(subject), to go on with it.
        cd \(quoted(directory.path)) && exec \(quoted(copilot.path)) --resume \(quoted(sessionId))
        """
    }

    /// A word for the shell, in single quotes.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
