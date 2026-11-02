import Foundation

// The Azure DevOps REST API (7.1) shapes and endpoints for the code a pull request changed: its iterations, the files each
// changed, and those files' contents. As elsewhere, fields the API may omit are optional, a value of an unexpected type
// counts as missing, and a list skips an element it can't decode.

/// One of a pull request's iterations: what a push made it, with the commits its diff compares.
public struct ADOPullRequestIteration: Decodable, Sendable {
    public var id: Int
    public var createdDate: Date?
    /// `create`, `push`, `forcePush`, `rebase`, `retarget`, `resolveConflicts` or `unknown`.
    public var reason: String?
    /// The head of the pull request's branch.
    public var sourceRefCommit: ADOCommitRef?
    /// The head of its target branch.
    public var targetRefCommit: ADOCommitRef?
    /// The commit where the branch left its target: the base its diff compares with.
    public var commonRefCommit: ADOCommitRef?

    private enum CodingKeys: String, CodingKey {
        case id, createdDate, reason, sourceRefCommit, targetRefCommit, commonRefCommit
    }

    public init(
        id: Int, createdDate: Date? = nil, reason: String? = nil, sourceRefCommit: ADOCommitRef? = nil,
        targetRefCommit: ADOCommitRef? = nil, commonRefCommit: ADOCommitRef? = nil
    ) {
        self.id = id
        self.createdDate = createdDate
        self.reason = reason
        self.sourceRefCommit = sourceRefCommit
        self.targetRefCommit = targetRefCommit
        self.commonRefCommit = commonRefCommit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        createdDate = container.lenient(Date.self, forKey: .createdDate)
        reason = container.lenient(String.self, forKey: .reason)
        sourceRefCommit = container.lenient(ADOCommitRef.self, forKey: .sourceRefCommit)
        targetRefCommit = container.lenient(ADOCommitRef.self, forKey: .targetRefCommit)
        commonRefCommit = container.lenient(ADOCommitRef.self, forKey: .commonRefCommit)
    }
}

/// The files an iteration changed, a page of them: `{"changeEntries": [...], "nextSkip": n, "nextTop": n}`.
public struct ADOIterationChanges: Decodable, Sendable {
    public var changeEntries: [Change]
    /// Where the next page starts: 0, or missing, after the last.
    public var nextSkip: Int?
    public var nextTop: Int?

    /// One file it changed.
    public struct Change: Decodable, Sendable {
        /// The file across the pull request's iterations, as threads say which file they're on.
        public var changeTrackingId: Int?
        public var changeId: Int?
        /// `add`, `edit`, `delete`, `rename` and others, several separated by commas, as in "edit, rename".
        public var changeType: String?
        public var item: Item?
        /// Its path before, when it was renamed.
        public var originalPath: String?

        public struct Item: Decodable, Sendable {
            public var path: String?
            /// The file's blob after the change.
            public var objectId: String?
            /// The file's blob before the change.
            public var originalObjectId: String?
            /// `blob` for a file.
            public var gitObjectType: String?

            private enum CodingKeys: String, CodingKey { case path, objectId, originalObjectId, gitObjectType }

            public init(path: String?, objectId: String? = nil, originalObjectId: String? = nil, gitObjectType: String? = nil) {
                self.path = path
                self.objectId = objectId
                self.originalObjectId = originalObjectId
                self.gitObjectType = gitObjectType
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                path = container.lenient(String.self, forKey: .path)
                objectId = container.lenient(String.self, forKey: .objectId)
                originalObjectId = container.lenient(String.self, forKey: .originalObjectId)
                gitObjectType = container.lenient(String.self, forKey: .gitObjectType)
            }
        }

        private enum CodingKeys: String, CodingKey { case changeTrackingId, changeId, changeType, item, originalPath }

        public init(
            changeTrackingId: Int? = nil, changeId: Int? = nil, changeType: String?, item: Item?, originalPath: String? = nil
        ) {
            self.changeTrackingId = changeTrackingId
            self.changeId = changeId
            self.changeType = changeType
            self.item = item
            self.originalPath = originalPath
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            changeTrackingId = container.lenient(Int.self, forKey: .changeTrackingId)
            changeId = container.lenient(Int.self, forKey: .changeId)
            changeType = container.lenient(String.self, forKey: .changeType)
            item = container.lenient(Item.self, forKey: .item)
            originalPath = container.lenient(String.self, forKey: .originalPath)
        }
    }

    private enum CodingKeys: String, CodingKey { case changeEntries, nextSkip, nextTop }

    public init(changeEntries: [Change], nextSkip: Int? = nil, nextTop: Int? = nil) {
        self.changeEntries = changeEntries
        self.nextSkip = nextSkip
        self.nextTop = nextTop
    }

    /// Consumes one element of any shape, to step over one that failed to decode.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var entries: [Change] = []
        if var items = try? container.nestedUnkeyedContainer(forKey: .changeEntries) {
            while !items.isAtEnd {
                if let entry = try? items.decode(Change.self) {
                    entries.append(entry)
                } else {
                    _ = try items.decode(Skip.self)
                }
            }
        }
        changeEntries = entries
        nextSkip = container.lenient(Int.self, forKey: .nextSkip)
        nextTop = container.lenient(Int.self, forKey: .nextTop)
    }
}

/// A file's bytes, as Azure DevOps sent them: all of them, or as many as BriefBar reads.
struct FileBytes: Sendable, Equatable {
    var data: Data
    /// False when the file is longer than what was read.
    var isComplete: Bool
}

extension ADOEndpoint {
    // MARK: Code

    /// A pull request's iterations, oldest first, with the commits each one's diff compares, but not the lists of their
    /// commits.
    public static func pullRequestIterations(
        organization: String, projectId: String, repositoryId: String, pullRequestId: Int
    ) -> URL {
        url("https://dev.azure.com",
            [organization, projectId, "_apis", "git", "repositories", repositoryId, "pullRequests", String(pullRequestId), "iterations"],
            [("includeCommits", "false"), ("api-version", apiVersion)])
    }

    /// The files an iteration changed since the base when `comparedTo` is 0, or since that iteration: `top` of them at
    /// most, after the first `skip`. Azure DevOps answers with up to 2,000.
    public static func iterationChanges(
        organization: String, projectId: String, repositoryId: String, pullRequestId: Int, iteration: Int, comparedTo: Int = 0,
        top: Int = 2_000, skip: Int = 0
    ) -> URL {
        url("https://dev.azure.com",
            [organization, projectId, "_apis", "git", "repositories", repositoryId, "pullRequests", String(pullRequestId),
             "iterations", String(iteration), "changes"],
            [("$top", String(top)), ("$skip", String(skip)), ("$compareTo", String(comparedTo)), ("api-version", apiVersion)])
    }

    /// A file at a commit, which answers with its bytes when asked for `application/octet-stream`.
    public static func file(organization: String, projectId: String, repositoryId: String, path: String, commit: String) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "git", "repositories", repositoryId, "items"], [
            ("path", path), ("versionDescriptor.version", commit), ("versionDescriptor.versionType", "commit"),
            ("api-version", apiVersion),
        ])
    }

    /// A file by its object ID, its blob's bytes.
    public static func blob(organization: String, projectId: String, repositoryId: String, objectId: String) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "git", "repositories", repositoryId, "blobs", objectId],
            [("$format", "octetstream"), ("api-version", apiVersion)])
    }
}
