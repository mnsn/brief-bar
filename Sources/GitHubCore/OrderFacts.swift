import BriefBarCore
import Foundation

// What GitHub's pull requests tell an order, once the order's query read them (`PullRequestQuery.orderText`), while Pull
// Request Order is on.

extension GitHubPullRequest {
    /// What an order needs of a pull request: the branch it merges into, whether its branch is a fork's, its repository's
    /// default branch, and its GitHub stack.
    public struct OrderFields: Sendable, Codable, Equatable {
        public var baseBranch: String
        /// Whether its branch is in another repository than the one it merges into; nil when GitHub doesn't say.
        public var isFork: Bool?
        public var defaultBranch: String?
        /// The GitHub stack it's in, with where each of its pull requests stands; nil when it's in none.
        public var stack: GitHubStack?

        public init(baseBranch: String, isFork: Bool? = nil, defaultBranch: String? = nil, stack: GitHubStack? = nil) {
            self.baseBranch = baseBranch
            self.isFork = isFork
            self.defaultBranch = defaultBranch
            self.stack = stack
        }

        /// From the order's query; nil from the usual one, which doesn't read the branch it merges into.
        init?(_ api: APIPullRequest) {
            guard let base = api.baseRefName, !base.isEmpty else { return nil }
            self.init(
                baseBranch: base, isFork: api.isCrossRepository, defaultBranch: api.repository.defaultBranchRef?.name,
                stack: api.stackEntry.flatMap { GitHubStack($0, in: api.repository.nameWithOwner) }
            )
        }
    }

    /// The pull request as an order sees it. Every pull request the list reads is open: a draft or not. Without what the
    /// order's query reads, such as when GitHub can't answer it and BriefBar reads the usual one, the branch it merges
    /// into isn't known (empty), so it goes after nothing BriefBar sees; an order that names it still sees it listed.
    /// - Parameter attention: what it means for you now, as its group counts it.
    public func orderPullRequest(attention: ItemState?) -> OrderPullRequest {
        OrderPullRequest(
            ref: .gitHubPullRequest(repository: repository, number: number), repository: repository, sourceBranch: branch ?? "",
            targetBranch: order?.baseBranch ?? "", isFork: order?.isFork, defaultBranch: order?.defaultBranch, author: author,
            state: isDraft ? .draft : .open, attention: attention, createdAt: createdAt, stack: order?.stack
        )
    }
}

extension GitHubPRSnapshot {
    /// The pull request as an order sees it, with what it means for you, as its group counts it.
    public var orderPullRequest: OrderPullRequest {
        pullRequest.orderPullRequest(attention: group.state)
    }
}

extension GitHubStack {
    /// A pull request's GitHub stack, as the order's query reads it: its pull requests by their place in it, those it
    /// can't read left out. Nil without the stack.
    /// - Parameter repository: the pull request's, for a member whose repository GitHub doesn't say.
    init?(_ entry: APIPullRequest.StackEntry, in repository: String) {
        guard let stack = entry.stack else { return nil }
        let members = (stack.entries?.nodes ?? []).compactMap { node -> Member? in
            guard let member = node.pullRequest else { return nil }
            return Member(
                position: node.position,
                ref: .gitHubPullRequest(repository: member.repository?.nameWithOwner ?? repository, number: member.number),
                state: PullRequestState(gitHub: member.state)
            )
        }
        self.init(repository: repository, number: stack.number, baseBranch: stack.baseRefName, members: members)
    }
}

extension PullRequestState {
    /// GitHub's `PullRequestState`: OPEN, CLOSED or MERGED. Nil for anything else.
    init?(gitHub state: String?) {
        switch state {
        case "OPEN": self = .open
        case "CLOSED": self = .closed
        case "MERGED": self = .merged
        default: return nil
        }
    }
}
