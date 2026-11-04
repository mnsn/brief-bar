import Foundation

// A pull request's merge conflicts with its target branch: which files conflict, and how, as Azure DevOps lists them for the
// merge it tried last (`/pullRequests/{id}/conflicts`, a preview API). As elsewhere, fields the API may omit are optional, a
// value of an unexpected type counts as missing, and a list skips an element it can't decode.

/// One conflict, as Azure DevOps lists it: `{"conflictId": 1, "conflictPath": "/src/Orders/OrderService.cs",
/// "conflictType": "editEdit", "resolutionStatus": "unresolved"}`, with the other paths a rename gives it, as each type of
/// conflict names them. Its type and status are names, or, from some servers, their numbers.
public struct ADOConflict: Decodable, Sendable {
    public var conflictId: Int?
    public var conflictPath: String?
    /// `editEdit`, `addAdd`, `deleteEdit`, `editDelete`, `renameDelete`, `deleteRename`, `rename1to2`, `rename2to1`,
    /// `renameAdd`, `addRename`, `renameRename`, `directoryFile`, `fileDirectory`, `directoryChild` or `none`.
    public var conflictType: String?
    /// `unresolved`, `partiallyResolved` or `resolved`.
    public var resolutionStatus: String?
    /// Where the pull request's branch renamed the file to, and the target branch, for `rename1to2`, `renameDelete` and
    /// `deleteRename`.
    public var sourceNewPath: String?
    public var targetNewPath: String?
    /// Where each renamed a file from, to the conflict's path, for `rename2to1`, `renameAdd` and `addRename`.
    public var sourceOriginalPath: String?
    public var targetOriginalPath: String?
    /// Where both renamed it from, for `renameRename`.
    public var originalPath: String?

    /// The types of conflict, in the order Azure DevOps numbers them (`GitConflictType`).
    static let types = [
        "none", "addAdd", "addRename", "deleteEdit", "deleteRename", "directoryFile", "directoryChild", "editDelete", "editEdit",
        "fileDirectory", "rename1to2", "rename2to1", "renameAdd", "renameDelete", "renameRename",
    ]
    /// Its resolution's statuses, in the order Azure DevOps numbers them (`GitResolutionStatus`).
    static let statuses = ["unresolved", "partiallyResolved", "resolved"]

    private enum CodingKeys: String, CodingKey {
        case conflictId, conflictPath, conflictType, resolutionStatus, sourceNewPath, targetNewPath, sourceOriginalPath,
             targetOriginalPath, originalPath
    }

    public init(
        conflictId: Int?, conflictPath: String?, conflictType: String?, resolutionStatus: String? = "unresolved",
        sourceNewPath: String? = nil, targetNewPath: String? = nil, sourceOriginalPath: String? = nil,
        targetOriginalPath: String? = nil, originalPath: String? = nil
    ) {
        self.conflictId = conflictId
        self.conflictPath = conflictPath
        self.conflictType = conflictType
        self.resolutionStatus = resolutionStatus
        self.sourceNewPath = sourceNewPath
        self.targetNewPath = targetNewPath
        self.sourceOriginalPath = sourceOriginalPath
        self.targetOriginalPath = targetOriginalPath
        self.originalPath = originalPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conflictId = container.lenient(Int.self, forKey: .conflictId)
        conflictPath = container.lenient(String.self, forKey: .conflictPath)
        conflictType = Self.name(in: container, forKey: .conflictType, among: Self.types)
        resolutionStatus = Self.name(in: container, forKey: .resolutionStatus, among: Self.statuses)
        sourceNewPath = container.lenient(String.self, forKey: .sourceNewPath)
        targetNewPath = container.lenient(String.self, forKey: .targetNewPath)
        sourceOriginalPath = container.lenient(String.self, forKey: .sourceOriginalPath)
        targetOriginalPath = container.lenient(String.self, forKey: .targetOriginalPath)
        originalPath = container.lenient(String.self, forKey: .originalPath)
    }

    /// An enumeration's value: its name, or the name its number stands for.
    private static func name(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys, among names: [String]) -> String? {
        if let name = container.lenient(String.self, forKey: key) { return name }
        guard let number = container.lenient(Int.self, forKey: key), names.indices.contains(number) else { return nil }
        return names[number]
    }
}

extension ADOEndpoint {
    /// A pull request's merge conflicts with its target branch, those of the merge Azure DevOps tried last, resolved in Azure
    /// DevOps or not: `top` of them at most, after the first `skip`. A preview API.
    public static func pullRequestConflicts(
        organization: String, projectId: String, repositoryId: String, pullRequestId: Int, top: Int, skip: Int = 0
    ) -> URL {
        url("https://dev.azure.com",
            [organization, projectId, "_apis", "git", "repositories", repositoryId, "pullRequests", String(pullRequestId), "conflicts"],
            [("$top", String(top)), ("$skip", String(skip)), ("api-version", "7.1-preview.1")])
    }
}

/// A file that conflicts with a pull request's target branch, and how: what each branch did to it since they parted, which
/// Git can't put together by itself.
public struct MergeConflict: Sendable, Equatable, Identifiable {
    /// What each branch did to the file, as Azure DevOps names it: the pull request's branch is the source, the branch it
    /// merges into the target.
    public enum Kind: String, Sendable, CaseIterable {
        /// Both changed it, in the same places.
        case editEdit
        /// Both added a file at its path, with different contents.
        case addAdd
        /// The source deleted it, and the target changed it.
        case deleteEdit
        /// The source changed it, and the target deleted it.
        case editDelete
        /// The source renamed it (`sourcePath`), and the target deleted it.
        case renameDelete
        /// The source deleted it, and the target renamed it (`targetPath`).
        case deleteRename
        /// Both renamed it, each to another path (`sourcePath`, `targetPath`).
        case rename1to2
        /// Each renamed another file to its path (from `sourcePath` and `targetPath`).
        case rename2to1
        /// The source renamed a file to its path (from `sourcePath`), and the target added one there.
        case renameAdd
        /// The source added a file at its path, and the target renamed one to it (from `targetPath`).
        case addRename
        /// Both renamed it to its path, from `originalPath`, with different contents.
        case renameRename
        /// A folder on the source, a file on the target.
        case directoryFile
        /// A file on the source, a folder on the target.
        case fileDirectory
        /// In a folder that's a file on one branch.
        case directoryChild
        /// Azure DevOps doesn't say how, or says it in a way BriefBar doesn't know.
        case other
    }

    /// Its number among the pull request's conflicts.
    public var id: Int
    /// Such as "/src/Orders/OrderService.cs".
    public var path: String
    public var kind: Kind
    /// The other path the pull request's branch has the file at: where it renamed it to, or from.
    public var sourcePath: String?
    /// The same on the target branch.
    public var targetPath: String?
    /// Where both branches renamed it from.
    public var originalPath: String?
    /// Someone resolved it in Azure DevOps, which hasn't committed the merge yet: until it does, it still conflicts.
    public var isResolved: Bool

    public init(
        id: Int, path: String, kind: Kind, sourcePath: String? = nil, targetPath: String? = nil, originalPath: String? = nil,
        isResolved: Bool = false
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.originalPath = originalPath
        self.isResolved = isResolved
    }

    /// Nil for one without a path, which can't be shown.
    /// - Parameter index: where it is in the list, for its number when Azure DevOps gives none.
    init?(_ dto: ADOConflict, index: Int) {
        guard let path = dto.conflictPath.flatMap(Self.path), !path.isEmpty else { return nil }
        let kind = dto.conflictType.flatMap(Kind.init(rawValue:)) ?? .other
        self.init(
            id: dto.conflictId ?? -(index + 1), path: path, kind: kind,
            sourcePath: (dto.sourceNewPath ?? dto.sourceOriginalPath).flatMap(Self.path),
            targetPath: (dto.targetNewPath ?? dto.targetOriginalPath).flatMap(Self.path),
            originalPath: dto.originalPath.flatMap(Self.path),
            isResolved: dto.resolutionStatus == "resolved"
        )
    }

    /// A path from the top of the repository, as the change's files have theirs: "/src/a.cs". Nil for none.
    private static func path(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        return text.hasPrefix("/") ? text : "/" + text
    }

    /// "OrderService.cs".
    public var name: String {
        (path as NSString).lastPathComponent
    }

    /// The folder it's in, without the slashes around it: "src/Orders"; nil at the top of the repository.
    public var folder: String? {
        FileChange.folder(of: path)
    }

    /// Where the pull request's change has the file, to show it: where it renamed it to, or its path.
    public var pathInPullRequest: String {
        switch kind {
        case .rename1to2, .renameDelete: sourcePath ?? path
        default: path
        }
    }

    /// How it conflicts, in a few words, naming the branches: "Changed on both branches", "Changed on rename-order-status,
    /// deleted on main", "Renamed to OrderStatuses.md on rename-order-status, and to docs/orders/states.md on main".
    /// - Parameters:
    ///   - source: the pull request's branch.
    ///   - target: the branch it merges into.
    public func how(source: String, target: String) -> String {
        let source = source.isEmpty ? "its branch" : source
        let target = target.isEmpty ? "the target branch" : target
        func named(_ other: String?) -> String? { other.map { Self.named($0, beside: path) } }
        switch kind {
        case .editEdit:
            return "Changed on both branches"
        case .addAdd:
            return "Added on both branches"
        case .deleteEdit:
            return "Deleted on \(source), changed on \(target)"
        case .editDelete:
            return "Changed on \(source), deleted on \(target)"
        case .renameDelete:
            return named(sourcePath).map { "Renamed to \($0) on \(source), deleted on \(target)" }
                ?? "Renamed on \(source), deleted on \(target)"
        case .deleteRename:
            return named(targetPath).map { "Deleted on \(source), renamed to \($0) on \(target)" }
                ?? "Deleted on \(source), renamed on \(target)"
        case .rename1to2:
            if let ours = named(sourcePath), let theirs = named(targetPath) {
                return "Renamed to \(ours) on \(source), and to \(theirs) on \(target)"
            }
            return "Renamed differently on each branch"
        case .rename2to1:
            if let ours = named(sourcePath), let theirs = named(targetPath) {
                return "Both branches renamed a file to it: \(ours) on \(source), \(theirs) on \(target)"
            }
            return "Both branches renamed a file to it"
        case .renameAdd:
            return named(sourcePath).map { "Renamed from \($0) on \(source), added on \(target)" }
                ?? "Renamed to it on \(source), added on \(target)"
        case .addRename:
            return named(targetPath).map { "Added on \(source), renamed from \($0) on \(target)" }
                ?? "Added on \(source), renamed to it on \(target)"
        case .renameRename:
            return named(originalPath).map { "Renamed from \($0) on both branches, with different changes" }
                ?? "Renamed to it on both branches, with different changes"
        case .directoryFile:
            return "A folder on \(source), a file on \(target)"
        case .fileDirectory:
            return "A file on \(source), a folder on \(target)"
        case .directoryChild:
            return "In a folder that's a file on one branch"
        case .other:
            return "Conflicts with \(target)"
        }
    }

    /// Another path a rename involves, as short as it can be said beside `path`: its name when it's in the same folder,
    /// else from the top of the repository.
    static func named(_ other: String, beside path: String) -> String {
        let folder = FileChange.folder(of: other)
        guard folder != FileChange.folder(of: path) else { return (other as NSString).lastPathComponent }
        return other.hasPrefix("/") ? String(other.dropFirst()) : other
    }
}

/// The files that conflict with a pull request's target branch, as Azure DevOps listed them for the merge it tried last: in
/// the order a change lists its files (`PullRequestPanel.listsFirst`).
public struct MergeConflicts: Sendable, Equatable {
    public var files: [MergeConflict]
    /// False when there may be more than BriefBar read: past the pages it reads, or from a server that answers each page
    /// with the first.
    public var isComplete: Bool
    /// What the pull request was as they were read: its head, its target branch and that branch's head, which the merge
    /// Azure DevOps tries changes with.
    public var sourceCommit: String?
    public var targetBranch: String
    public var targetCommit: String?

    public init(files: [MergeConflict], isComplete: Bool = true, sourceCommit: String?, targetBranch: String, targetCommit: String?) {
        self.files = files.sorted { PullRequestPanel.listsFirst($0.path, $1.path) }
        self.isComplete = isComplete
        self.sourceCommit = sourceCommit
        self.targetBranch = targetBranch
        self.targetCommit = targetCommit
    }

    /// As read for `pullRequest` as it is now.
    public init(files: [MergeConflict], isComplete: Bool = true, of pullRequest: PullRequest) {
        self.init(
            files: files, isComplete: isComplete, sourceCommit: pullRequest.sourceCommit, targetBranch: pullRequest.targetBranch,
            targetCommit: pullRequest.targetCommit
        )
    }

    /// Whether they were read for the pull request as it is now: neither branch moved since, and it merges into the same
    /// branch. Branches are compared by their bytes, as Git tells them apart.
    public func isCurrent(for pullRequest: PullRequest) -> Bool {
        sourceCommit == pullRequest.sourceCommit && targetCommit == pullRequest.targetCommit
            && targetBranch.utf8.elementsEqual(pullRequest.targetBranch.utf8)
    }

    /// Those nobody resolved in Azure DevOps.
    public var unresolved: [MergeConflict] { files.filter { !$0.isResolved } }

    /// How many conflicts BriefBar asks for in each page: one GET reads them all, but for a pull request with more.
    public static let pageSize = 100
    /// How many pages it reads at most: past that, the rest are left out, and it says so.
    public static let maxPages = 10

    /// Reads a pull request's conflicts from Azure DevOps, with GETs: one, or one for each hundred. They're complete unless
    /// there may be more than it read: past the pages it reads, or from a server that answers each page with the first.
    public static func read(
        _ pullRequest: PullRequest, with client: ADOClient, pageSize: Int = pageSize, maxPages: Int = maxPages
    ) async throws -> MergeConflicts {
        var read: [ADOConflict] = []
        var seen: Set<Seen> = []
        var isComplete = true
        var skip = 0
        for page in 0..<max(1, maxPages) {
            let address = ADOEndpoint.pullRequestConflicts(
                organization: pullRequest.key.organization, projectId: pullRequest.projectId, repositoryId: pullRequest.repositoryId,
                pullRequestId: pullRequest.key.number, top: pageSize, skip: skip
            )
            let list = try await client.get(address, as: ADOList<ADOConflict>.self)
            // Those it hadn't read: one without a number or a path can't show, and brings nothing.
            let new = list.value.filter { (conflict: ADOConflict) -> Bool in
                guard let key = Seen(conflict) else { return false }
                return seen.insert(key).inserted
            }
            read += new
            let answered = list.value.count + list.skipped
            // A page that isn't full is the last; so is one longer than asked for, from a server that answers with all of
            // them at once.
            guard answered == pageSize else { break }
            // A full one that brings nothing new is from a server that ignores where a page starts, and answers with the
            // same page again: it may have more, which it won't give.
            guard !new.isEmpty else {
                isComplete = false
                break
            }
            if page == max(1, maxPages) - 1 { isComplete = false }
            skip += answered
        }
        let files = read.enumerated().compactMap { MergeConflict($1, index: $0) }
        return MergeConflicts(files: files, isComplete: isComplete, of: pullRequest)
    }

    /// What tells a conflict from the others as pages repeat them: its number, else its path.
    private enum Seen: Hashable {
        case id(Int)
        case path(String)

        init?(_ conflict: ADOConflict) {
            if let id = conflict.conflictId {
                self = .id(id)
            } else if let path = conflict.conflictPath, !path.isEmpty {
                self = .path(path)
            } else {
                return nil
            }
        }
    }
}
