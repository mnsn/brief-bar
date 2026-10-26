import Foundation

/// The one query BriefBar sends to GitHub: who you are, the open pull requests that request your review by name,
/// and your own open pull requests, with what decides where each one goes. It reads, and changes nothing.
public enum PullRequestQuery {
    /// Fixed text: only the search strings and the count are variables.
    public static let text = """
        query BriefBarPullRequests($reviewing: String!, $authored: String!, $count: Int!) {
          viewer { login }
          reviewing: search(query: $reviewing, type: ISSUE, first: $count) { issueCount nodes { ...BriefBarPullRequest } }
          authored: search(query: $authored, type: ISSUE, first: $count) { issueCount nodes { ...BriefBarPullRequest } }
          rateLimit { remaining resetAt }
        }
        fragment BriefBarPullRequest on PullRequest {
          id number title url isDraft createdAt updatedAt headRefName
          author { login }
          repository { nameWithOwner }
          reviewDecision
          mergeable
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          latestOpinionatedReviews(first: 20) { nodes { state author { login } } }
        }
        """

    /// Review requests for you by name. A request for one of your teams alone isn't in it.
    public static let reviewingSearch = "is:pr is:open archived:false user-review-requested:@me sort:updated-desc"
    public static let authoredSearch = "is:pr is:open archived:false author:@me sort:updated-desc"
    /// Each search's most recently updated; more than this is unusual, and the list says so.
    public static let count = 50

    struct Body: Encodable {
        struct Variables: Encodable {
            var reviewing: String
            var authored: String
            var count: Int
        }

        var query: String
        var variables: Variables
    }

    static func body() -> Data {
        let body = Body(query: text, variables: .init(reviewing: reviewingSearch, authored: authoredSearch, count: count))
        // Encoding fixed strings and a number can't fail.
        return (try? JSONEncoder().encode(body)) ?? Data()
    }
}

/// A GraphQL answer: what could be read, and errors about what couldn't. Both can come together.
struct GraphQLResponse<Payload: Decodable>: Decodable {
    var data: Payload?
    var errors: [GraphQLError]?
}

public struct GraphQLError: Decodable, Sendable, Equatable {
    /// Such as `RATE_LIMITED`, `FORBIDDEN` or `NOT_FOUND`, when GitHub says.
    public var type: String?
    public var message: String

    public init(type: String? = nil, message: String) {
        self.type = type
        self.message = message
    }
}

/// What `PullRequestQuery` reads.
public struct PullRequestQueryData: Decodable, Sendable, Equatable {
    public struct Viewer: Decodable, Sendable, Equatable {
        public var login: String
    }

    public struct Search: Decodable, Sendable, Equatable {
        /// How many match, of which `nodes` holds the first `PullRequestQuery.count`.
        public var issueCount: Int
        /// Those it could read: a node that's null, or that it can't read, is left out.
        public var nodes: [APIPullRequest]

        enum CodingKeys: String, CodingKey { case issueCount, nodes }

        public init(issueCount: Int, nodes: [APIPullRequest]) {
            self.issueCount = issueCount
            self.nodes = nodes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            issueCount = try container.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
            nodes = (try container.decodeIfPresent([Lossy<APIPullRequest>].self, forKey: .nodes) ?? []).compactMap(\.value)
        }
    }

    public struct RateLimit: Decodable, Sendable, Equatable {
        public var remaining: Int
        public var resetAt: Date
    }

    public var viewer: Viewer
    public var reviewing: Search
    public var authored: Search
    public var rateLimit: RateLimit?
}

/// A pull request as the query reads it.
public struct APIPullRequest: Decodable, Sendable, Equatable {
    public struct Login: Decodable, Sendable, Equatable {
        public var login: String
    }

    public struct Repository: Decodable, Sendable, Equatable {
        public var nameWithOwner: String
    }

    public struct Nodes<Node: Decodable & Sendable & Equatable>: Decodable, Sendable, Equatable {
        public var nodes: [Node]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nodes = (try container.decodeIfPresent([Lossy<Node>].self, forKey: .nodes) ?? []).compactMap(\.value)
        }

        enum CodingKeys: String, CodingKey { case nodes }
    }

    public struct CommitNode: Decodable, Sendable, Equatable {
        public struct Commit: Decodable, Sendable, Equatable {
            public struct Rollup: Decodable, Sendable, Equatable {
                public var state: String
            }

            /// Nil when nothing checks the commit.
            public var statusCheckRollup: Rollup?
        }

        public var commit: Commit
    }

    public struct Review: Decodable, Sendable, Equatable {
        public var state: String
        public var author: Login?
    }

    public var id: String
    public var number: Int
    public var title: String
    public var url: URL
    public var isDraft: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Nil for a deleted account.
    public var author: Login?
    public var repository: Repository
    /// The branch it merges.
    public var headRefName: String?
    /// Nil when the repository doesn't require reviews.
    public var reviewDecision: String?
    public var mergeable: String?
    public var commits: Nodes<CommitNode>?
    public var latestOpinionatedReviews: Nodes<Review>?
}

/// A value that decodes to nil instead of failing, so one odd element doesn't lose a whole list.
struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

enum GitHubJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
