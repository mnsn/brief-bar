import Foundation

/// One of a pull request's iterations: what a push made it, with the commits its diff compares.
public struct PRIteration: Sendable, Equatable, Hashable {
    /// From 1, in the order they were pushed.
    public var id: Int
    /// The head of the pull request's branch.
    public var sourceCommit: String?
    /// The head of its target branch.
    public var targetCommit: String?
    /// The commit where the branch left its target: the base its diff compares with.
    public var commonCommit: String?
    public var createdAt: Date?

    public init(id: Int, sourceCommit: String?, targetCommit: String? = nil, commonCommit: String?, createdAt: Date? = nil) {
        self.id = id
        self.sourceCommit = sourceCommit
        self.targetCommit = targetCommit
        self.commonCommit = commonCommit
        self.createdAt = createdAt
    }

    /// Nil for an iteration numbered below 1.
    init?(_ dto: ADOPullRequestIteration) {
        guard dto.id >= 1 else { return nil }
        self.init(
            id: dto.id, sourceCommit: dto.sourceRefCommit?.commitId, targetCommit: dto.targetRefCommit?.commitId,
            commonCommit: dto.commonRefCommit?.commitId, createdAt: dto.createdDate
        )
    }
}

/// A file that a diff of a pull request changed.
public struct FileChange: Sendable, Equatable, Hashable {
    /// What happened to it: several at once, as when it was renamed and edited.
    public struct Kind: OptionSet, Sendable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let add = Kind(rawValue: 1 << 0)
        public static let edit = Kind(rawValue: 1 << 1)
        public static let rename = Kind(rawValue: 1 << 2)
        public static let delete = Kind(rawValue: 1 << 3)

        /// From Azure DevOps' `changeType`, such as "edit" or "edit, rename". An undeleted file was added again, and one
        /// whose encoding changed was edited; the rest aren't about the file's content.
        public init(_ changeType: String?) {
            var kind: Kind = []
            for part in (changeType ?? "").split(separator: ",") {
                switch part.trimmingCharacters(in: .whitespaces).lowercased() {
                case "add", "undelete": kind.insert(.add)
                case "edit", "encoding": kind.insert(.edit)
                case "rename", "sourcerename", "targetrename": kind.insert(.rename)
                case "delete": kind.insert(.delete)
                default: break
                }
            }
            self = kind
        }
    }

    /// Such as "/src/PaymentsClient.cs": the path after a rename, or the deleted file's.
    public var path: String
    /// Its path before, when it was renamed.
    public var originalPath: String?
    public var kind: Kind
    /// The file's blob after the change: nil when it was deleted.
    public var objectId: String?
    /// The file's blob before the change: nil when it was added.
    public var originalObjectId: String?
    /// The file across the pull request's iterations, as threads say which file they're on.
    public var changeTrackingId: Int?

    public init(
        path: String, originalPath: String? = nil, kind: Kind, objectId: String?, originalObjectId: String? = nil,
        changeTrackingId: Int? = nil
    ) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.objectId = objectId
        self.originalObjectId = originalObjectId
        self.changeTrackingId = changeTrackingId
    }

    /// Nil for one that isn't a file, such as a folder, or that doesn't say which.
    init?(_ dto: ADOIterationChanges.Change) {
        guard let item = dto.item, let path = item.path, !path.isEmpty, (item.gitObjectType ?? "blob") == "blob" else { return nil }
        let original = dto.originalPath.flatMap { $0.isEmpty || $0 == path ? nil : $0 }
        var kind = Kind(dto.changeType)
        if original != nil { kind.insert(.rename) }
        self.init(
            path: path, originalPath: original, kind: kind, objectId: item.objectId, originalObjectId: item.originalObjectId,
            changeTrackingId: dto.changeTrackingId.flatMap { $0 > 0 ? $0 : nil }
        )
    }

}

/// The files a diff changed: all of them, or as many as BriefBar reads of a diff that changed more.
struct FileChanges: Sendable, Equatable {
    var files: [FileChange]
    /// False when the diff changed more files than were read, and the rest aren't here.
    var isComplete = true

    /// The change to a thread's file: the one Azure DevOps tracks as `trackingId`, or else the one at `path` after the
    /// change, or else before it, so that a file renamed from that path doesn't stand for one added there.
    func change(to path: String, trackingId: Int?) -> FileChange? {
        if let trackingId, let tracked = files.first(where: { $0.changeTrackingId == trackingId }) { return tracked }
        return files.first { $0.path == path } ?? files.first { $0.originalPath == path }
    }
}

/// A version of a file, as BriefBar reads it to show: its text, or why there's none to show.
public enum FileText: Sendable, Equatable {
    case text(String)
    /// Not text, such as an image.
    case binary
    /// Longer than BriefBar reads.
    case tooLarge

    /// The most of a file BriefBar reads: 1 MB.
    public static let limit = 1 << 20

    /// From a file's bytes, as many as were read: text in UTF-8, or UTF-16 with its byte order mark, or else in Windows'
    /// Latin alphabet. A NUL byte in its first 8,000, as Git tells, makes it binary.
    init(_ bytes: Data, isComplete: Bool) {
        guard isComplete else {
            self = .tooLarge
            return
        }
        let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
        if bytes.starts(with: utf8BOM) {
            self = String(data: bytes.dropFirst(utf8BOM.count), encoding: .utf8).map(FileText.text) ?? .binary
        } else if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            self = String(data: bytes, encoding: .utf16).map(FileText.text) ?? .binary
        } else if bytes.prefix(8_000).contains(0) {
            self = .binary
        } else {
            let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252)
                ?? String(data: bytes, encoding: .isoLatin1)
            self = text.map(FileText.text) ?? .binary
        }
    }

    /// How much memory it takes, about: its text's bytes in UTF-8.
    var size: Int {
        if case .text(let text) = self { return text.utf8.count }
        return 0
    }
}

// MARK: - Where the code comes from

/// A pull request's iterations, the files each changed and their contents: Azure DevOps', or the demo's made-up ones.
protocol CodeSource: Sendable {
    /// Oldest first.
    func iterations(of pullRequest: PullRequest) async throws -> [PRIteration]
    /// The files `iteration` changed since the base when `comparedTo` is 0, or since that iteration.
    func changes(of pullRequest: PullRequest, iteration: Int, comparedTo: Int) async throws -> FileChanges
    func file(of pullRequest: PullRequest, objectId: String, limit: Int) async throws -> FileText
    func file(of pullRequest: PullRequest, path: String, commit: String, limit: Int) async throws -> FileText
}

/// The code as Azure DevOps has it, read through `ADOClient`, with GETs.
struct AzureDevOpsCode: CodeSource {
    let client: ADOClient
    /// How many pages of an iteration's changes it reads: 10,000 files.
    var maxPages = 5

    func iterations(of pullRequest: PullRequest) async throws -> [PRIteration] {
        let address = ADOEndpoint.pullRequestIterations(
            organization: pullRequest.key.organization, projectId: pullRequest.projectId, repositoryId: pullRequest.repositoryId,
            pullRequestId: pullRequest.key.number
        )
        return try await client.get(address, as: ADOList<ADOPullRequestIteration>.self).value.compactMap(PRIteration.init).sorted { $0.id < $1.id }
    }

    func changes(of pullRequest: PullRequest, iteration: Int, comparedTo: Int) async throws -> FileChanges {
        var changes = FileChanges(files: [])
        var skip = 0
        for page in 0..<max(1, maxPages) {
            let address = ADOEndpoint.iterationChanges(
                organization: pullRequest.key.organization, projectId: pullRequest.projectId,
                repositoryId: pullRequest.repositoryId, pullRequestId: pullRequest.key.number, iteration: iteration,
                comparedTo: comparedTo, skip: skip
            )
            let read = try await client.get(address, as: ADOIterationChanges.self)
            changes.files += read.changeEntries.compactMap(FileChange.init)
            guard let next = read.nextSkip, next > skip, !read.changeEntries.isEmpty else { break }
            // More than it reads: the rest are left out, and it says so.
            if page == max(1, maxPages) - 1 { changes.isComplete = false }
            skip = next
        }
        return changes
    }

    func file(of pullRequest: PullRequest, objectId: String, limit: Int) async throws -> FileText {
        let address = ADOEndpoint.blob(
            organization: pullRequest.key.organization, projectId: pullRequest.projectId, repositoryId: pullRequest.repositoryId,
            objectId: objectId
        )
        let bytes = try await client.file(address, limit: limit)
        return FileText(bytes.data, isComplete: bytes.isComplete)
    }

    func file(of pullRequest: PullRequest, path: String, commit: String, limit: Int) async throws -> FileText {
        let address = ADOEndpoint.file(
            organization: pullRequest.key.organization, projectId: pullRequest.projectId, repositoryId: pullRequest.repositoryId,
            path: path, commit: commit
        )
        let bytes = try await client.file(address, limit: limit)
        return FileText(bytes.data, isComplete: bytes.isComplete)
    }
}

/// Lets a few requests go out at a time. The rest wait their turn, in order; one whose task is cancelled while it waits
/// never goes out.
actor RequestLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [(id: Int, turn: CheckedContinuation<Void, Error>)] = []
    private var nextId = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await start()
        defer { finish() }
        try Task.checkCancellation()
        return try await body()
    }

    private func start() async throws {
        guard running >= limit else {
            running += 1
            return
        }
        nextId += 1
        let id = nextId
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { turn in
                waiting.append((id, turn))
            }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }

    private func stopWaiting(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).turn.resume(throwing: CancellationError())
    }

    /// Hands its place to the next request waiting, or gives it up.
    private func finish() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().turn.resume()
        }
    }
}

// MARK: - The reader

/// Reads the code a pull request's comment threads are on, for its panel: a thread's when asked for it, and only what
/// that needs, a few requests at a time. What it reads is read once, however many threads need it: files by their
/// object IDs, or their paths at commits, which never change. It never reads by itself, or again on a schedule: the
/// pull request's iterations are read again only for a push it hadn't seen, or a thread made on an iteration it hadn't.
/// A read that every thread waiting on it gave up on is called off. One reader for the pull request a panel shows:
/// given another, it starts over.
public actor PullRequestCode {
    private let source: any CodeSource
    private let requests: RequestLimiter
    private let fileLimit: Int
    /// How many bytes of files it keeps: past that, it forgets those it read first.
    private let memoryLimit: Int

    private var pullRequest: PullRequest
    /// What's read, or being read.
    private var reads: [ReadKey: Task<Read, Error>] = [:]
    /// Who waits on each read, by the number each ask got.
    private var asks: [ReadKey: Set<Int>] = [:]
    private var lastAsk = 0
    /// The files it keeps, first read first, and how big they are.
    private var files: [(key: ReadKey, size: Int)] = []
    private var excerpts: [ExcerptKey: ThreadExcerpt] = [:]
    /// Counts the pull requests it's read for, so that what was read for another isn't kept.
    private var generation = 0

    /// Reads Azure DevOps through `client`, `concurrency` requests at a time.
    public init(_ pullRequest: PullRequest, client: ADOClient, concurrency: Int = 4) {
        self.init(pullRequest, source: AzureDevOpsCode(client: client), concurrency: concurrency)
    }

    init(
        _ pullRequest: PullRequest, source: any CodeSource, concurrency: Int = 4, fileLimit: Int = FileText.limit,
        memoryLimit: Int = 32 << 20
    ) {
        self.pullRequest = pullRequest
        self.source = source
        requests = RequestLimiter(limit: concurrency)
        self.fileLimit = fileLimit
        self.memoryLimit = memoryLimit
    }

    /// The demo's: made-up code for its pull requests' threads, without a network.
    public static func demo(_ pullRequest: PullRequest) -> PullRequestCode {
        PullRequestCode(pullRequest, source: DemoCode())
    }

    deinit {
        for task in reads.values { task.cancel() }
    }

    /// The code a thread on lines of a file is on, as its reviewer saw it: in the diff it was made on, before Azure DevOps
    /// followed it to later ones. A thread that doesn't say which diff is on the latest iteration's diff with the base.
    /// - Parameters:
    ///   - pullRequest: as it was last read, so that a push it doesn't know of yet makes it read the iterations again.
    ///   - context: how many lines it shows before and after the thread's.
    public func excerpt(
        of thread: ReviewThread, in pullRequest: PullRequest, context: Int = ThreadExcerpt.context
    ) async -> Result<ThreadExcerpt, ThreadExcerpt.Problem> {
        follow(pullRequest)
        guard let anchor = Anchor(thread) else { return .failure(.notOnLines) }
        do {
            return .success(try await excerpt(of: thread.id, at: anchor, context: context))
        } catch let problem as ThreadExcerpt.Problem {
            return .failure(problem)
        } catch let error as ADOError {
            return .failure(.unreadable(error))
        } catch {
            return .failure(.unreadable(.network(error.localizedDescription)))
        }
    }

    /// The code of each of these threads that's on lines of a file, by the thread's ID, read together.
    public func excerpts(
        of threads: [ReviewThread], in pullRequest: PullRequest, context: Int = ThreadExcerpt.context
    ) async -> [Int: Result<ThreadExcerpt, ThreadExcerpt.Problem>] {
        follow(pullRequest)
        return await withTaskGroup(of: (Int, Result<ThreadExcerpt, ThreadExcerpt.Problem>).self) { group in
            for thread in threads where Anchor(thread) != nil {
                group.addTask { (thread.id, await self.excerpt(of: thread, in: pullRequest, context: context)) }
            }
            var results: [Int: Result<ThreadExcerpt, ThreadExcerpt.Problem>] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }
    }

    // MARK: Reading

    private func excerpt(of threadId: Int, at anchor: Anchor, context: Int) async throws -> ThreadExcerpt {
        let generation = generation
        let iterations = try await iterations(including: anchor.comparison?.second, for: generation)
        guard let latest = iterations.last else { throw ThreadExcerpt.Problem.noIterations }
        let key = ExcerptKey(threadId: threadId, anchor: anchor, latest: latest.id, context: context)
        if let kept = excerpts[key] { return kept }
        let comparison = anchor.comparison ?? ReviewThread.Comparison(base: latest.id)
        guard let right = iterations.first(where: { $0.id == comparison.second }) else { throw ThreadExcerpt.Problem.noIterations }
        let leftCommit = comparison.isWithBase ? right.commonCommit : iterations.first { $0.id == comparison.first }?.sourceCommit

        let changes = try await changes(iteration: right.id, comparedTo: comparison.isWithBase ? 0 : comparison.first, for: generation)
        let change = changes.change(to: anchor.path, trackingId: anchor.changeTrackingId)
        // Among the files left out of a diff that changed more than it reads, it can't tell whether this one changed.
        if change == nil, !changes.isComplete { throw ThreadExcerpt.Problem.tooManyFiles }
        // The file after the change, then before it: a file the diff didn't change is the same on both sides.
        let newText: String
        let oldText: String
        if let change {
            newText = change.kind.contains(.delete)
                ? "" : try Self.text(await file(change.objectId, change.path, at: right.sourceCommit, for: generation))
            oldText = change.kind.contains(.add)
                ? "" : try Self.text(await file(change.originalObjectId, change.originalPath ?? change.path, at: leftCommit, for: generation))
        } else {
            newText = try Self.text(await file(nil, anchor.path, at: right.sourceCommit, for: generation))
            oldText = newText
        }
        let diff = await Self.compare(oldText, newText)
        guard let window = ThreadExcerpt.window(of: diff, side: anchor.side, lines: anchor.lines, context: context) else {
            throw ThreadExcerpt.Problem.linesNotFound
        }

        // Whether it changed since: whether the diff from that iteration to the latest has it. Unknown when that can't be
        // read, or when it changed more files than were read and this one isn't among them.
        var changedSince: Bool? = false
        if latest.id > right.id {
            let later = try? await self.changes(iteration: latest.id, comparedTo: right.id, for: generation)
            if let later, later.change(to: change?.path ?? anchor.path, trackingId: change?.changeTrackingId ?? anchor.changeTrackingId) != nil {
                changedSince = true
            } else {
                changedSince = later?.isComplete == true ? false : nil
            }
        }
        let excerpt = ThreadExcerpt(
            threadId: threadId, path: change?.path ?? anchor.path, originalPath: change?.originalPath, change: change?.kind,
            side: anchor.side, lines: window.lines, reachesStart: window.reachesStart, reachesEnd: window.reachesEnd,
            hiddenCommentedLines: window.hiddenCommentedLines, iteration: right.id, latestIteration: latest.id,
            changedSince: changedSince
        )
        // Kept unless whether it changed since is still to be read, or it was for another pull request.
        if changedSince != nil, generation == self.generation { excerpts[key] = excerpt }
        return excerpt
    }

    /// A file's text, or why there's none to show.
    private static func text(_ file: FileText) throws -> String {
        switch file {
        case .text(let text): return text
        case .binary: throw ThreadExcerpt.Problem.binary
        case .tooLarge: throw ThreadExcerpt.Problem.tooLarge
        }
    }

    /// Diffs off the actor, so that other threads' reads go on meanwhile.
    private static func compare(_ old: String, _ new: String) async -> [DiffLine] {
        LineDiff.compare(old, new)
    }

    /// The pull request's iterations, oldest first: read again for a push it hadn't seen, or for an iteration it
    /// doesn't have.
    private func iterations(including id: Int?, for generation: Int) async throws -> [PRIteration] {
        let key = ReadKey.iterations(pullRequest.sourceCommit)
        let kept = reads[key]
        guard case .iterations(let iterations) = try await read(key, for: generation) else { return [] }
        guard let id, !iterations.contains(where: { $0.id == id }), kept != nil else { return iterations }
        // A thread made on an iteration after the ones read before: once, they're read again.
        if reads[key] == kept { forget(key) }
        guard case .iterations(let again) = try await read(key, for: generation) else { return [] }
        return again
    }

    private func changes(iteration: Int, comparedTo: Int, for generation: Int) async throws -> FileChanges {
        let key = ReadKey.changes(iteration: iteration, comparedTo: comparedTo)
        guard case .changes(let changes) = try await read(key, for: generation) else { return FileChanges(files: []) }
        return changes
    }

    /// A file by its object ID, or else by its path at a commit.
    private func file(_ objectId: String?, _ path: String, at commit: String?, for generation: Int) async throws -> FileText {
        let key: ReadKey
        if let objectId, !objectId.isEmpty {
            key = .object(objectId)
        } else if let commit, !commit.isEmpty {
            key = .file(path, commit: commit)
        } else {
            throw ThreadExcerpt.Problem.noIterations
        }
        guard case .file(let text) = try await read(key, for: generation) else { return .binary }
        return text
    }

    /// What's read under a key: read once, and kept, unless it failed in a way that asking again might not. Nothing is
    /// read for a pull request it no longer reads for (`generation` is the one the ask began with), or for an ask that
    /// stopped waiting, which a read that others still wait on doesn't stop: it goes no further.
    private func read(_ key: ReadKey, for generation: Int) async throws -> Read {
        guard generation == self.generation else { throw CancellationError() }
        try Task.checkCancellation()
        let task: Task<Read, Error>
        if let kept = reads[key] {
            task = kept
        } else {
            let (source, requests, pullRequest, limit) = (source, requests, pullRequest, fileLimit)
            task = Task {
                try await requests.run {
                    switch key {
                    case .iterations: return .iterations(try await source.iterations(of: pullRequest))
                    case .changes(let iteration, let comparedTo):
                        return .changes(try await source.changes(of: pullRequest, iteration: iteration, comparedTo: comparedTo))
                    case .object(let objectId): return .file(try await source.file(of: pullRequest, objectId: objectId, limit: limit))
                    case .file(let path, let commit):
                        return .file(try await source.file(of: pullRequest, path: path, commit: commit, limit: limit))
                    }
                }
            }
            reads[key] = task
        }
        lastAsk += 1
        let ask = lastAsk
        asks[key, default: []].insert(ask)
        defer { stopAsking(ask, on: key) }
        let read: Read
        do {
            read = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.giveUp(ask, on: key, task) }
            }
        } catch {
            if !Self.lasts(error), reads[key] == task { forget(key) }
            throw error
        }
        keep(read, under: key, task)
        try Task.checkCancellation()
        return read
    }

    /// How many asks wait on a read, for tests.
    func waiting(_ key: ReadKey) -> Int {
        asks[key]?.count ?? 0
    }

    /// Notes that an ask doesn't wait on a read anymore: it's done, or it stopped waiting. False when that was noted
    /// already.
    @discardableResult
    private func stopAsking(_ ask: Int, on key: ReadKey) -> Bool {
        guard asks[key]?.remove(ask) != nil else { return false }
        if asks[key]?.isEmpty == true { asks[key] = nil }
        return true
    }

    /// An ask stopped waiting on a read before it was done: when it was the last one, the read is called off.
    private func giveUp(_ ask: Int, on key: ReadKey, _ task: Task<Read, Error>) {
        guard stopAsking(ask, on: key), asks[key] == nil, reads[key] == task else { return }
        task.cancel()
        forget(key)
    }

    /// Notes a file's size, and forgets the files read first past the memory it may use.
    private func keep(_ read: Read, under key: ReadKey, _ task: Task<Read, Error>) {
        guard case .file(let text) = read, reads[key] == task, !files.contains(where: { $0.key == key }) else { return }
        files.append((key, text.size))
        var total = files.reduce(0) { $0 + $1.size }
        while total > memoryLimit, files.count > 1 {
            let oldest = files.removeFirst()
            total -= oldest.size
            reads[oldest.key] = nil
        }
    }

    private func forget(_ key: ReadKey) {
        reads[key] = nil
        files.removeAll { $0.key == key }
    }

    /// Starts over for another pull request, and forgets the iterations read before a push.
    private func follow(_ pullRequest: PullRequest) {
        guard pullRequest.key == self.pullRequest.key else {
            for task in reads.values { task.cancel() }
            reads = [:]
            asks = [:]
            files = []
            excerpts = [:]
            generation += 1
            self.pullRequest = pullRequest
            return
        }
        if pullRequest.sourceCommit != self.pullRequest.sourceCommit {
            // The iterations as of the head before, which another push replaced.
            reads = reads.filter { if case .iterations = $0.key { false } else { true } }
        }
        self.pullRequest = pullRequest
    }

    /// A failure that asking again won't change: what isn't there or you may not read, or what BriefBar can't understand.
    static func lasts(_ error: Error) -> Bool {
        switch error as? ADOError {
        case .notFound?, .forbidden?, .decoding?: return true
        default: return false
        }
    }

    // MARK: Keys

    enum ReadKey: Hashable, Sendable {
        /// The iterations, as of the pull request's head.
        case iterations(String?)
        case changes(iteration: Int, comparedTo: Int)
        case object(String)
        case file(String, commit: String)
    }

    enum Read: Sendable {
        case iterations([PRIteration])
        case changes(FileChanges)
        case file(FileText)
    }

    struct ExcerptKey: Hashable {
        var threadId: Int
        var anchor: Anchor
        var latest: Int
        var context: Int
    }
}

/// Where a thread was made, as its reviewer saw it: which diff, which file, and its lines, on which side.
struct Anchor: Hashable, Sendable {
    /// Nil for the latest iteration's diff with the base.
    var comparison: ReviewThread.Comparison?
    var path: String
    var side: ThreadExcerpt.Side
    var lines: ClosedRange<Int>
    var changeTrackingId: Int?

    /// Nil for a thread that isn't on lines of a file.
    init?(_ thread: ReviewThread) {
        guard let location = thread.location else {
            // Without its location, as the demo's threads: its line, after the change, in the latest diff.
            guard let path = thread.filePath, !path.isEmpty, let line = thread.line, line >= 1 else { return nil }
            self.init(comparison: nil, path: path, side: .right, lines: line...line, changeTrackingId: nil)
            return
        }
        var comparison = location.madeOn
        var path = location.path
        var spans = (left: location.left, right: location.right)
        if let tracking = location.tracking {
            if location.madeOn != nil, tracking.originalLeft != nil || tracking.originalRight != nil {
                // Where it was made, before Azure DevOps followed it.
                path = tracking.originalPath ?? location.path
                spans = (tracking.originalLeft, tracking.originalRight)
            } else {
                comparison = tracking.to
            }
        }
        if let right = spans.right {
            self.init(comparison: comparison, path: path, side: .right, lines: right.lines, changeTrackingId: location.changeTrackingId)
        } else if let left = spans.left {
            self.init(comparison: comparison, path: path, side: .left, lines: left.lines, changeTrackingId: location.changeTrackingId)
        } else {
            return nil
        }
    }

    init(comparison: ReviewThread.Comparison?, path: String, side: ThreadExcerpt.Side, lines: ClosedRange<Int>, changeTrackingId: Int?) {
        self.comparison = comparison
        self.path = path
        self.side = side
        self.lines = lines
        self.changeTrackingId = changeTrackingId
    }
}
