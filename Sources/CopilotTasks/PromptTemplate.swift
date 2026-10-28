import Foundation

/// The prompt a task is sent with. It names the work item and leaves the rest to Copilot, which reads the work item
/// with your own Azure DevOps tools. You can change it in Settings, and before each send.
///
/// Placeholders: `{id}`, `{type}`, `{title}`, `{url}`, `{organization}`, `{project}` and `{baseBranch}`, the branch
/// the worktree starts from. Others are left as they are.
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

    /// Fills in the placeholders. Without a base branch yet, `{baseBranch}` stays, to be filled in once the
    /// repository says which it is.
    public static func render(_ template: String, item: TaskWorkItem, baseBranch: String? = nil) -> String {
        var values: [String: String] = [
            "id": String(item.id),
            "type": item.type,
            "title": item.title,
            "url": item.url.absoluteString,
            "organization": item.organization,
            "project": item.project,
        ]
        if let baseBranch { values["baseBranch"] = baseBranch }
        return fill(template, values)
    }

    /// Fills in only the base branch, once the repository says which it is: in a prompt you may have edited.
    public static func render(_ prompt: String, baseBranch: String) -> String {
        fill(prompt, ["baseBranch": baseBranch])
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
