import BriefBarCore
import Foundation

/// The prompt a task is sent with. It names the work item and leaves the rest to Copilot, which reads the work item
/// with your own Azure DevOps tools. You can change it in Settings, and before each send.
///
/// Placeholders: `{id}`, `{type}`, `{title}`, `{url}`, `{organization}`, `{project}` and `{baseBranch}`, the branch
/// the worktree starts from. Others are left as they are. Each value stays on its placeholder's line, whatever a work
/// item's title holds (`QuotedText.oneLine`), since Copilot runs the prompt with every tool. The base branch, which the
/// repository names, is written as it's named but for what's unseen (`QuotedText.inLine`), so a template of yours can
/// quote it as its commands need. Only a work item's prompt is filled in: a pull request's has no placeholders, and
/// quotes code that may look like one (`CopilotLauncher`).
public enum PromptTemplate {
    public static let standard = """
        Fix Azure DevOps {type} {id}: {title}
        {url}

        1. Read the work item with your Azure DevOps tools: its description, acceptance criteria, comments and \
        attachments, and its parent's.
        2. You're in a new git worktree of this repository, detached at origin/{baseBranch}. Create a branch for this \
        work, named the way this repository names its branches.
        3. Make the change, following the repository's instructions and conventions. Build, and run the tests that \
        cover what you changed.
        4. Commit, push the branch, and open a pull request into {baseBranch} in Azure DevOps that's published, ready \
        for review, and linked to work item {id}.

        Work on your own, without asking questions. If something stops you, say what and why. End with the pull \
        request's link.
        """

    /// For a session that's there already, such as one of the Copilot app's: it works where that session does, which
    /// may be another repository or hold other work, so it checks first, and asks rather than mixing work up.
    public static let existingSession = """
        Work on Azure DevOps {type} {id}: {title}
        {url}

        1. Read the work item with your Azure DevOps tools: its description, acceptance criteria, comments and \
        attachments, and its parent's.
        2. Before you change anything, make sure you're in a clone of the repository this work goes in, and that it \
        has no changes of its own that aren't for this work item (git status). If it isn't, or you're not sure, stop \
        and ask me where to work.
        3. Unless you're on this work item's branch already, create one for it from the latest default branch of \
        origin, named the way this repository names its branches.
        4. Make the change, following the repository's instructions and conventions. Build, and run the tests that \
        cover what you changed.
        5. Commit only what you changed for this work item, and push the branch. Open a pull request into the default \
        branch in Azure DevOps that's published, ready for review, and linked to work item {id}, or push to the one it \
        has already.

        If something stops you, say what and why. End with the pull request's link.
        """

    /// The last line of BriefBar's prompts that change code, Send Work to Copilot's and a pull request's fixes', while Pull
    /// Request Order is on: for the session to tell BriefBar the pull request's stage itself once it pushed, with `--mcp`'s
    /// `pull_request_stage`, which it has only while Pull Request Order and agents are on.
    public static let stageLine = """
        When you've pushed, tell BriefBar the pull request is ready for my review with pull_request_stage, if that tool \
        is there.
        """

    /// A prompt, ending with `stageLine` when it asks for the stage: once, and never alone.
    public static func ending(_ prompt: String, asksForStage: Bool) -> String {
        let trimmed = prompt.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard asksForStage, !trimmed.isEmpty, !trimmed.hasSuffix(stageLine) else { return prompt }
        return trimmed + "\n\n" + stageLine
    }

    /// Fills in the placeholders. Without a base branch yet, `{baseBranch}` stays, to be filled in once the
    /// repository says which it is.
    public static func render(_ template: String, item: TaskWorkItem, baseBranch: String? = nil) -> String {
        var values: [String: String] = [
            "id": String(item.id),
            "type": QuotedText.oneLine(item.type),
            "title": QuotedText.oneLine(item.title),
            "url": item.url.absoluteString,
            "organization": QuotedText.oneLine(item.organization),
            "project": QuotedText.oneLine(item.project),
        ]
        if let baseBranch { values["baseBranch"] = QuotedText.inLine(baseBranch) }
        return fill(template, values)
    }

    /// Fills in only the base branch, once the repository says which it is: in a prompt you may have edited.
    public static func render(_ prompt: String, baseBranch: String) -> String {
        fill(prompt, ["baseBranch": QuotedText.inLine(baseBranch)])
    }

    /// One pass over the text, so a value that looks like a placeholder, such as a title with braces, stays as it is.
    static func fill(_ text: String, _ values: [String: String]) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}"), let value = values[String(rest[afterOpen..<close])] {
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                result += "{"
                rest = rest[afterOpen...]
            }
        }
        return result + rest
    }
}
