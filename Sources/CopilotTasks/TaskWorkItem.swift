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
    public var id: Int
    public var title: String
    public var url: URL
    /// The branch it merges, such as `users/robin/fix-total`.
    public var sourceBranch: String
    /// The branch it merges into, such as `main`.
    public var targetBranch: String

    public init(
        organization: String, project: String, repository: String, id: Int, title: String, url: URL, sourceBranch: String,
        targetBranch: String
    ) {
        self.organization = organization
        self.project = project
        self.repository = repository
        self.id = id
        self.title = title
        self.url = url
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
    }

    public var reference: PullRequestReference {
        PullRequestReference(organization: organization, project: project, repository: repository, id: id, sourceBranch: sourceBranch)
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
