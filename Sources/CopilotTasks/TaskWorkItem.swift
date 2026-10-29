import Foundation

/// The work item a task is for: enough to name it in a prompt and to find it again. It holds no Azure DevOps types, so
/// this module doesn't depend on the source that lists work items.
public struct TaskWorkItem: Sendable, Codable, Equatable, Hashable {
    public var organization: String
    public var project: String
    public var id: Int
    /// Such as `Task`, `Bug` or `User Story`.
    public var type: String
    public var title: String
    public var url: URL

    public init(organization: String, project: String, id: Int, type: String, title: String, url: URL) {
        self.organization = organization
        self.project = project
        self.id = id
        self.type = type
        self.title = title
        self.url = url
    }

    public var reference: WorkItemReference {
        WorkItemReference(organization: organization, project: project, id: id)
    }
}

/// Which work item, without its title: what BriefBar keeps about a run.
public struct WorkItemReference: Sendable, Codable, Equatable, Hashable {
    public var organization: String
    public var project: String
    public var id: Int

    public init(organization: String, project: String, id: Int) {
        self.organization = organization
        self.project = project
        self.id = id
    }

    /// The same work item, whatever case its organization is written in.
    public func matches(_ other: WorkItemReference) -> Bool {
        id == other.id && organization.caseInsensitiveCompare(other.organization) == .orderedSame
    }

    /// Its project, to remember which repository its work goes in, such as `contoso/storefront`.
    public var projectKey: String {
        "\(organization.lowercased())/\(project.lowercased())"
    }
}

/// The pull request a task works on: enough to name it in a prompt, to find it again and to check out its branch. Like
/// `TaskWorkItem`, it holds no Azure DevOps types.
public struct TaskPullRequest: Sendable, Codable, Equatable, Hashable {
    public var organization: String
    public var project: String
    public var repository: String
    /// Git remotes can use these IDs instead of the project's and repository's names.
    public var projectId: String?
    public var repositoryId: String?
    public var id: Int
    public var title: String
    public var url: URL
    /// The branch it merges, such as `users/robin/fix-total`.
    public var sourceBranch: String
    /// The branch it merges into, such as `main`.
    public var targetBranch: String

    public init(
        organization: String, project: String, repository: String, id: Int, title: String, url: URL, sourceBranch: String,
        targetBranch: String, projectId: String? = nil, repositoryId: String? = nil
    ) {
        self.organization = organization
        self.project = project
        self.repository = repository
        self.projectId = projectId
        self.repositoryId = repositoryId
        self.id = id
        self.title = title
        self.url = url
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
    }

    public var reference: PullRequestReference {
        PullRequestReference(organization: organization, project: project, repository: repository, id: id, sourceBranch: sourceBranch)
    }

    /// Matches Azure DevOps' HTTPS and SSH clone URLs, not a local folder's name.
    public func matches(remote: String) -> Bool {
        var address = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://"), let colon = address.firstIndex(of: ":") {
            address = "ssh://" + address[..<colon] + "/" + address[address.index(after: colon)...]
        }
        guard let url = URLComponents(string: address), let host = url.host?.lowercased(),
              let scheme = url.scheme?.lowercased(), url.query == nil, url.fragment == nil else { return false }
        let encodedParts = url.percentEncodedPath.split(separator: "/")
        var parts = encodedParts.compactMap { String($0).removingPercentEncoding }
        guard parts.count == encodedParts.count else { return false }
        let remoteOrganization: String
        if scheme == "ssh", host == "ssh.dev.azure.com" || host == "vs-ssh.visualstudio.com" {
            guard parts.count == 4, parts.removeFirst().lowercased() == "v3" else { return false }
            remoteOrganization = parts.removeFirst()
        } else if scheme == "https" {
            if host == "dev.azure.com" {
                guard parts.count == 4 else { return false }
                remoteOrganization = parts.removeFirst()
            } else if host.hasSuffix(".visualstudio.com") {
                remoteOrganization = String(host.dropLast(".visualstudio.com".count))
                if parts.first?.lowercased() == "defaultcollection" { parts.removeFirst() }
            } else {
                return false
            }
            guard parts.count == 3, parts[1].lowercased() == "_git" else { return false }
            parts.remove(at: 1)
        } else {
            return false
        }
        guard parts.count == 2, remoteOrganization.caseInsensitiveCompare(organization) == .orderedSame else { return false }
        let projects = [project, projectId].compactMap { $0 }
        let repositories = [repository, repositoryId].compactMap { $0 }
        return projects.contains { $0.caseInsensitiveCompare(parts[0]) == .orderedSame }
            && repositories.contains { $0.caseInsensitiveCompare(parts[1]) == .orderedSame }
    }
}

/// Which pull request, without its title: what BriefBar keeps about a run.
public struct PullRequestReference: Sendable, Codable, Equatable, Hashable {
    public var organization: String
    public var project: String
    public var repository: String
    public var id: Int
    /// The branch the run's worktree started from.
    public var sourceBranch: String

    public init(organization: String, project: String, repository: String, id: Int, sourceBranch: String) {
        self.organization = organization
        self.project = project
        self.repository = repository
        self.id = id
        self.sourceBranch = sourceBranch
    }

    /// The same pull request, whatever case its organization is written in.
    public func matches(_ other: PullRequestReference) -> Bool {
        matches(organization: other.organization, id: other.id)
    }

    public func matches(organization: String, id: Int) -> Bool {
        self.id == id && self.organization.caseInsensitiveCompare(organization) == .orderedSame
    }

    /// Its repository, to remember which local repository it is, such as `contoso/storefront/shop-web`.
    public var repositoryKey: String {
        "\(organization.lowercased())/\(project.lowercased())/\(repository.lowercased())"
    }
}

/// What a task asks Copilot to do with a pull request.
public enum PullRequestAction: String, Sendable, Codable, CaseIterable {
    /// Address the comment threads that wait on you, without pushing.
    case fixComments
    /// Reproduce and fix a failed build, without pushing.
    case fixBuild
    /// Merge the target branch in, resolving the conflicts, without pushing.
    case resolveConflicts
    /// Read someone else's change and draft review comments, changing nothing.
    case review
    /// Commit and push what an earlier task changed, and reply on the threads it addressed.
    case pushAndReply

    /// "Fix Comments", for menus and the composer.
    public var title: String {
        switch self {
        case .fixComments: return "Fix Comments"
        case .fixBuild: return "Fix the Build"
        case .resolveConflicts: return "Resolve Conflicts"
        case .review: return "Pre-review"
        case .pushAndReply: return "Push & Reply"
        }
    }

    /// The tools the Copilot CLI refuses on this task, whatever the prompt says (`--deny-tool`, which wins over
    /// `--allow-all-tools`): a review writes nothing, and only Push & Reply pushes. Merging a target branch in needs a
    /// commit, so resolving conflicts may commit, but not push.
    public var deniedTools: [String] {
        switch self {
        case .review: return ["write", "shell(git commit)", "shell(git push)"]
        case .fixComments, .fixBuild: return ["shell(git commit)", "shell(git push)"]
        case .resolveConflicts: return ["shell(git push)"]
        case .pushAndReply: return []
        }
    }

    /// Whether it changes code that a later Push & Reply ships.
    public var changesCode: Bool {
        switch self {
        case .fixComments, .fixBuild, .resolveConflicts: return true
        case .review, .pushAndReply: return false
        }
    }
}

/// What a task is about.
public enum TaskSubject: Sendable, Equatable {
    case workItem(TaskWorkItem)
    case pullRequest(TaskPullRequest, PullRequestAction)

    /// What the Copilot CLI refuses on it: a work item's task pushes and opens a pull request, so nothing.
    var deniedTools: [String] {
        if case .pullRequest(_, let action) = self { return action.deniedTools }
        return []
    }

    /// The worktree's folder name: `wi-<id>` or `pr-<id>`.
    var worktreeName: String {
        switch self {
        case .workItem(let item): return "wi-\(item.id)"
        case .pullRequest(let pullRequest, _): return "pr-\(pullRequest.id)"
        }
    }
}

/// Which model works on a task, and how hard it thinks.
public struct CopilotRunOptions: Sendable, Codable, Equatable, Hashable {
    /// Such as `claude-opus-5.5`, or `auto`.
    public var model: String
    /// Such as `max`; nil for the model's own default.
    public var effort: String?

    public init(model: String, effort: String?) {
        self.model = model
        self.effort = effort
    }

    /// "Claude Opus 5.5 · Max".
    public var title: String {
        [CopilotModel.name(of: model), effort.map(CopilotModel.effortName)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Models and reasoning efforts to choose from. The Copilot CLI takes any model your plan offers, so a model's ID can
/// also be typed in.
public enum CopilotModel {
    public struct Choice: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
    }

    public static let suggestions: [Choice] = [
        Choice(id: "claude-opus-5.5", name: "Claude Opus 5.5"),
        Choice(id: "claude-sonnet-5.5", name: "Claude Sonnet 5.5"),
        Choice(id: "claude-haiku-5.5", name: "Claude Haiku 5.5"),
        Choice(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
        Choice(id: "gemini-4-argon", name: "Gemini 4 Argon"),
        Choice(id: "auto", name: "Auto"),
    ]

    /// From least to most thinking. Not every model takes every one.
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// For a summary, which needs little thinking: without Opus, which costs more than a summary is worth, or Auto, which
    /// may choose it.
    public static let forSummaries: [Choice] = suggestions.filter { !$0.id.contains("opus") && $0.id != "auto" }

    /// What a task is sent with unless you choose otherwise.
    public static let standard = CopilotRunOptions(model: "claude-opus-5.5", effort: "max")
    /// For easy tasks: quicker, and cheaper.
    public static let quick = CopilotRunOptions(model: "claude-sonnet-5.5", effort: "medium")

    public static func name(of model: String) -> String {
        suggestions.first { $0.id == model }?.name ?? model
    }

    public static func effortName(_ effort: String) -> String {
        switch effort {
        case "xhigh": return "Extra High"
        default: return effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}
