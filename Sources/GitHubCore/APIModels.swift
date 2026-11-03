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

    /// The same query, sent instead only while Pull Request Order is on: also the branch each pull request merges into,
    /// whether its branch is a fork's, its repository's default branch, and its place in a GitHub stack, with where each
    /// of the stack's pull requests stands. Fixed text too, with the same variables, and it only reads.
    public static let orderText = """
        query BriefBarPullRequestOrder($reviewing: String!, $authored: String!, $count: Int!) {
          viewer { login }
          reviewing: search(query: $reviewing, type: ISSUE, first: $count) { issueCount nodes { ...BriefBarPullRequest } }
          authored: search(query: $authored, type: ISSUE, first: $count) { issueCount nodes { ...BriefBarPullRequest } }
          rateLimit { remaining resetAt }
        }
        fragment BriefBarPullRequest on PullRequest {
          id number title url isDraft createdAt updatedAt headRefName baseRefName isCrossRepository
          author { login }
          repository { nameWithOwner defaultBranchRef { name } }
          reviewDecision
          mergeable
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          latestOpinionatedReviews(first: 20) { nodes { state author { login } } }
          stackEntry {
            position
            stack {
              number baseRefName
              entries(first: 50) { nodes { position pullRequest { number state repository { nameWithOwner } } } }
            }
          }
        }
        """

    /// The fields only the order's query reads.
    static let orderFields: Set<String> = ["baseRefName", "isCrossRepository", "defaultBranchRef", "stackEntry"]

    struct Body: Encodable {
        struct Variables: Encodable {
            var reviewing: String
            var authored: String
            var count: Int
        }

        var query: String
        var variables: Variables
    }

    /// The usual query's, or the order's while Pull Request Order is on.
    static func body(order: Bool = false) -> Data {
        let body = Body(
            query: order ? orderText : text, variables: .init(reviewing: reviewingSearch, authored: authoredSearch, count: count)
        )
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
    /// Where in the answer it happened, such as `authored`, `nodes`, `3`, `stackEntry`, when GitHub says.
    public var path: [String]?

    public init(type: String? = nil, message: String, path: [String]? = nil) {
        self.type = type
        self.message = message
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case type, message, path
    }

    /// A place in a path: a field's name, or a list's index.
    private struct PathElement: Decodable {
        var text: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let index = try? container.decode(Int.self) {
                text = String(index)
            } else {
                text = try container.decode(String.self)
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        message = try container.decode(String.self, forKey: .message)
        path = (try? container.decodeIfPresent([PathElement].self, forKey: .path))?.map(\.text)
    }

    /// Whether it's about a field only the order's query reads: that leaves the field out of the order, and every pull
    /// request is still read.
    var isAboutAnOrderField: Bool {
        path?.contains { PullRequestQuery.orderFields.contains($0) } ?? false
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
        /// Only in the order's query (`PullRequestQuery.orderText`).
        public var defaultBranchRef: Ref?
    }

    public struct Ref: Decodable, Sendable, Equatable {
        public var name: String
    }

    /// A pull request's place in a GitHub stack, in the order's query: its position, from 1 at the bottom, and the stack,
    /// with its pull requests and where each stands.
    public struct StackEntry: Decodable, Sendable, Equatable {
        public struct Stack: Decodable, Sendable, Equatable {
            public var number: Int
            /// The branch its bottom pull request merges into.
            public var baseRefName: String?
            public var entries: Nodes<Entry>?
        }

        public struct Entry: Decodable, Sendable, Equatable {
            public struct Member: Decodable, Sendable, Equatable {
                public var number: Int
                /// OPEN, CLOSED or MERGED.
                public var state: String?
                public var repository: Repository?
            }

            public var position: Int
            public var pullRequest: Member?
        }

        public var position: Int
        public var stack: Stack?
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
    /// The branch it merges into: only in the order's query, as the fields after it.
    public var baseRefName: String?
    /// Whether its branch is in another repository than the one it merges into, as a fork's is.
    public var isCrossRepository: Bool?
    /// Its place in a GitHub stack; nil when it's in none.
    public var stackEntry: StackEntry?
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
