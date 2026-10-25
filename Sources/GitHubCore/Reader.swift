import Foundation

/// What one read of GitHub found.
public struct GitHubLoad: Sendable, Equatable {
    /// Who the GitHub CLI is signed in as.
    public var login: String
    public var items: [GitHubPRSnapshot]
    /// What GitHub couldn't read, such as an organization's pull requests that need single sign-on.
    public var notice: String?
    /// More pull requests matched than BriefBar reads (`PullRequestQuery.count` of each kind).
    public var moreThanShown: Bool

    public init(login: String, items: [GitHubPRSnapshot], notice: String? = nil, moreThanShown: Bool = false) {
        self.login = login
        self.items = items
        self.notice = notice
        self.moreThanShown = moreThanShown
    }

    public var counts: GitHubGroupCounts { GitHubGroupCounts(items) }
}

public enum GitHubReader {
    /// Reads your pull requests from GitHub, in one request.
    public static func load(client: GitHubClient) async throws -> GitHubLoad {
        let result = try await client.pullRequests()
        return load(from: result.data, errors: result.errors)
    }

    /// What a query's answer means for the list.
    public static func load(from data: PullRequestQueryData, errors: [GraphQLError] = []) -> GitHubLoad {
        let items = GitHubClassifier.snapshots(
            reviewing: data.reviewing.nodes.map(GitHubPullRequest.init),
            authored: data.authored.nodes.map(GitHubPullRequest.init)
        )
        let moreThanShown = data.reviewing.issueCount > data.reviewing.nodes.count
            || data.authored.issueCount > data.authored.nodes.count
        return GitHubLoad(login: data.viewer.login, items: items, notice: notice(for: errors), moreThanShown: moreThanShown)
    }

    /// Errors GitHub answered with alongside what it could read.
    static func notice(for errors: [GraphQLError]) -> String? {
        guard let first = errors.first else { return nil }
        if errors.contains(where: { $0.message.localizedCaseInsensitiveContains("SAML") }) {
            return "Some organizations use single sign-on: authorize the GitHub CLI for them to see their pull requests."
        }
        return "Some pull requests couldn't be read: \(first.message.prefix(200))"
    }
}
