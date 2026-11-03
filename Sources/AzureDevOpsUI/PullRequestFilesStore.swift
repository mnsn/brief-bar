import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// A pull request's whole change, for its details' Files: the files it touched, read as its Files come on screen; each
/// file's diff, as its page shows it; and how many lines each adds and removes, counted as its row comes on screen, one
/// file at a time. It reads through the reader `PullRequestCodeStore` reads threads' code with, so a file is read once for
/// both, and only as that store allows: while something shows the pull request, and a window shows, on screen, a page
/// where its details can show. What's read stays in memory only, until nothing shows the pull request: a few files' diffs,
/// and every file's count. It never reads by itself: the files again only after a push, as they show, and what couldn't be
/// read because Azure DevOps couldn't be reached, at most every half minute, or when you ask.
@MainActor
final class PullRequestFilesStore: ObservableObject {
    /// What's read of something, as far as it's read.
    enum State<Value: Equatable>: Equatable {
        case reading
        case read(Value)
        /// It can't be shown, for this reason.
        case failed(ThreadExcerpt.Problem)
    }

    /// A file's change, as its diff and its count are kept: the file, and the versions it compares, by their object IDs, or,
    /// without them, by the updates compared. The same file changed the same way, in the whole change and since an update,
    /// is counted once.
    struct Version: Hashable {
        var file: FileChange.ID
        var objectId: String?
        var originalObjectId: String?
        var comparison: ReviewThread.Comparison?

        init(_ file: FileChange, in files: ChangedFiles) {
            self.file = file.id
            objectId = file.objectId
            originalObjectId = file.originalObjectId
            let missing = (!file.kind.contains(.delete) && (file.objectId ?? "").isEmpty)
                || (!file.kind.contains(.add) && (file.originalObjectId ?? "").isEmpty)
            comparison = missing ? files.comparison : nil
        }
    }

    /// The files each change touched, by pull request.
    @Published private(set) var lists: [PRKey: [ChangeScope: State<ChangedFiles>]] = [:]
    /// The diffs read, of the files whose pages show and the last few before them.
    @Published private(set) var diffs: [PRKey: [Version: State<FileDiff>]] = [:]
    /// How many lines each file counted adds and removes, or why it can't be counted, such as a picture.
    @Published private(set) var counts: [PRKey: [Version: Result<LineCounts, ThreadExcerpt.Problem>]] = [:]

    /// How many diffs it keeps, besides those that show.
    static let keptDiffs = 3

    /// The pull request as each list was last asked for: its head and target, which a push or another target changes.
    /// Its branch is compared by its bytes, as Git tells branches apart.
    struct Head: Equatable {
        var source: String?
        var targetBranch: String
        var target: String?

        init(_ pullRequest: PullRequest) {
            source = pullRequest.sourceCommit
            targetBranch = pullRequest.targetBranch
            target = pullRequest.targetCommit
        }

        static func == (lhs: Head, rhs: Head) -> Bool {
            lhs.source == rhs.source && lhs.target == rhs.target && lhs.targetBranch.utf8.elementsEqual(rhs.targetBranch.utf8)
        }
    }

    /// A file to count, with what it takes to read it.
    private struct Count {
        var version: Version
        var file: FileChange
        var files: ChangedFiles
        var pullRequest: PullRequest
    }

    /// What's being read of a pull request.
    private struct Reads {
        var listAsked: [ChangeScope: Head] = [:]
        var listTasks: [ChangeScope: Task<Void, Never>] = [:]
        var listFailedAt: [ChangeScope: Date] = [:]
        var diffTasks: [Version: Task<Void, Never>] = [:]
        /// The views on screen that show each diff: a read is called off only once none does.
        var diffViewers: [Version: Set<UUID>] = [:]
        var diffFailedAt: [Version: Date] = [:]
        /// The diffs read, the latest last.
        var diffOrder: [Version] = []
        /// The files whose rows are on screen, to count in the order they came, and the views that show each.
        var countQueue: [Count] = []
        var countViewers: [Version: Set<UUID>] = [:]
        var counting: (version: Version, task: Task<Void, Never>)?
        var countFailedAt: [Version: Date] = [:]
    }

    private let code: PullRequestCodeStore
    private let now: () -> Date
    private var reads: [PRKey: Reads] = [:]
    private var subscription: AnyCancellable?

    /// Reads through `code`'s readers, while it lets them read.
    init(code: PullRequestCodeStore, now: @escaping () -> Date = Date.init) {
        self.code = code
        self.now = now
        code.forgot = { [weak self] in self?.forgetWhatNothingShows() }
        // Nothing is read while no window shows a page where the details can show: each view asks again once one does.
        subscription = code.$isVisible.removeDuplicates().sink { [weak self] isVisible in
            MainActor.assumeIsolated {
                if !isVisible { self?.callOffEverything() }
            }
        }
    }

    // MARK: The files

    func list(of key: PRKey, _ scope: ChangeScope) -> State<ChangedFiles>? {
        lists[key]?[scope]
    }

    /// The pull request's Files came on screen: the files the change touched are read, unless they're read for this
    /// version of the pull request already, or being read. Read again after a push, the files read before show meanwhile.
    /// - Parameter again: read them again even if they failed less than half a minute ago, as when you ask.
    func showList(of pullRequest: PullRequest, scope: ChangeScope, again: Bool = false) {
        let key = pullRequest.key
        guard code.isVisible, let reader = code.reader(for: pullRequest) else { return }
        let head = Head(pullRequest)
        var pullRequestReads = reads[key] ?? Reads()
        if pullRequestReads.listAsked[scope] == head {
            if pullRequestReads.listTasks[scope] != nil { return }
            switch lists[key]?[scope] {
            case .read?:
                return
            case .failed(let problem)?:
                guard ThreadCode.mayPass(problem), again || isDue(pullRequestReads.listFailedAt[scope]) else { return }
            case .reading?, nil:
                break
            }
        }
        pullRequestReads.listTasks[scope]?.cancel()
        pullRequestReads.listAsked[scope] = head
        pullRequestReads.listTasks[scope] = Task { [weak self] in
            let result = await reader.changedFiles(of: pullRequest, scope: scope)
            guard !Task.isCancelled else { return }
            self?.finishList(scope, of: key, head, result)
        }
        reads[key] = pullRequestReads
        if case .read? = lists[key]?[scope] {} else { lists[key, default: [:]][scope] = .reading }
    }

    private func finishList(_ scope: ChangeScope, of key: PRKey, _ head: Head, _ result: Result<ChangedFiles, ThreadExcerpt.Problem>) {
        // Unless it was asked for again since, or its pull request forgotten.
        guard reads[key]?.listAsked[scope] == head else { return }
        reads[key]?.listTasks[scope] = nil
        switch result {
        case .success(let files):
            reads[key]?.listFailedAt[scope] = nil
            lists[key, default: [:]][scope] = .read(files)
        case .failure(let problem):
            reads[key]?.listFailedAt[scope] = now()
            // What showed stays, rather than a failure to read it again after a push.
            if case .read? = lists[key]?[scope], ThreadCode.mayPass(problem) { return }
            lists[key, default: [:]][scope] = .failed(problem)
        }
    }

    // MARK: A file's diff

    func diff(of version: Version, in key: PRKey) -> State<FileDiff>? {
        diffs[key]?[version]
    }

    /// A file's page came on screen: its diff is read, unless it's read or being read.
    /// - Parameters:
    ///   - viewer: the view that shows it, which says so again with `hideDiff` once it goes.
    ///   - again: read it again even if it failed less than half a minute ago, as when you ask.
    func showDiff(of file: FileChange, in files: ChangedFiles, of pullRequest: PullRequest, by viewer: UUID, again: Bool = false) {
        let key = pullRequest.key
        guard code.isVisible, let reader = code.reader(for: pullRequest) else { return }
        let version = Version(file, in: files)
        reads[key, default: Reads()].diffViewers[version, default: []].insert(viewer)
        guard reads[key]?.diffTasks[version] == nil else { return }
        switch diffs[key]?[version] {
        case .read?:
            return
        case .failed(let problem)?:
            guard ThreadCode.mayPass(problem), again || isDue(reads[key]?.diffFailedAt[version]) else { return }
        case .reading?, nil:
            break
        }
        reads[key]?.diffTasks[version] = Task { [weak self] in
            let result = await reader.diff(of: file, in: files, of: pullRequest)
            guard !Task.isCancelled else { return }
            self?.finishDiff(version, of: key, result)
        }
        diffs[key, default: [:]][version] = .reading
    }

    /// The view that showed a file's diff doesn't anymore: once none does, what's being read of it is called off.
    func hideDiff(_ version: Version, of key: PRKey, by viewer: UUID) {
        guard reads[key] != nil else { return }
        reads[key]?.diffViewers[version]?.remove(viewer)
        guard reads[key]?.diffViewers[version]?.isEmpty ?? true else { return }
        reads[key]?.diffViewers[version] = nil
        if let task = reads[key]?.diffTasks.removeValue(forKey: version) {
            task.cancel()
            if diffs[key]?[version] == .reading { diffs[key]?[version] = nil }
        }
        trimDiffs(of: key)
    }

    private func finishDiff(_ version: Version, of key: PRKey, _ result: Result<FileDiff, ThreadExcerpt.Problem>) {
        guard reads[key]?.diffTasks.removeValue(forKey: version) != nil else { return }
        switch result {
        case .success(let diff):
            reads[key]?.diffFailedAt[version] = nil
            diffs[key, default: [:]][version] = .read(diff)
            reads[key]?.diffOrder.removeAll { $0 == version }
            reads[key]?.diffOrder.append(version)
            // Counted with it.
            counted(version, of: key, .success(diff.counts))
        case .failure(let problem):
            reads[key]?.diffFailedAt[version] = now()
            diffs[key, default: [:]][version] = .failed(problem)
            if !ThreadCode.mayPass(problem) { counted(version, of: key, .failure(problem)) }
        }
        trimDiffs(of: key)
    }

    /// Forgets the diffs read first, past the few it keeps, unless a view shows them.
    private func trimDiffs(of key: PRKey) {
        guard var pullRequestReads = reads[key] else { return }
        let shown = Set(pullRequestReads.diffViewers.keys)
        var kept = 0
        for version in pullRequestReads.diffOrder.reversed() where !shown.contains(version) {
            kept += 1
            if kept > Self.keptDiffs {
                pullRequestReads.diffOrder.removeAll { $0 == version }
                diffs[key]?[version] = nil
            }
        }
        reads[key] = pullRequestReads
    }

    // MARK: Counting lines

    func counts(of version: Version, in key: PRKey) -> Result<LineCounts, ThreadExcerpt.Problem>? {
        counts[key]?[version]
    }

    /// A file's row came on screen: how many lines it adds and removes is counted, unless it is, after the files whose rows
    /// came before it, one file at a time, by reading its two versions.
    /// - Parameter viewer: the view that shows it, which says so again with `stopCounting` once it leaves the screen.
    func count(_ file: FileChange, in files: ChangedFiles, of pullRequest: PullRequest, by viewer: UUID) {
        let key = pullRequest.key
        guard code.isVisible, code.shows(key) else { return }
        let version = Version(file, in: files)
        reads[key, default: Reads()].countViewers[version, default: []].insert(viewer)
        switch counts[key]?[version] {
        case .success?:
            return
        case .failure(let problem)?:
            guard ThreadCode.mayPass(problem), isDue(reads[key]?.countFailedAt[version]) else { return }
        case nil:
            break
        }
        guard reads[key]?.counting?.version != version, reads[key]?.countQueue.contains(where: { $0.version == version }) == false
        else { return }
        reads[key]?.countQueue.append(Count(version: version, file: file, files: files, pullRequest: pullRequest))
        countNext(of: key)
    }

    /// The view that showed a file's row doesn't anymore: once none does, it isn't counted, or, while it is, that's called
    /// off.
    func stopCounting(_ version: Version, of key: PRKey, by viewer: UUID) {
        guard reads[key] != nil else { return }
        reads[key]?.countViewers[version]?.remove(viewer)
        guard reads[key]?.countViewers[version]?.isEmpty ?? true else { return }
        reads[key]?.countViewers[version] = nil
        reads[key]?.countQueue.removeAll { $0.version == version }
        if let counting = reads[key]?.counting, counting.version == version {
            counting.task.cancel()
            reads[key]?.counting = nil
            countNext(of: key)
        }
    }

    /// Counts the next file waiting, unless one is being counted.
    private func countNext(of key: PRKey) {
        guard code.isVisible, reads[key]?.counting == nil, let next = reads[key]?.countQueue.first else { return }
        reads[key]?.countQueue.removeFirst()
        guard let reader = code.reader(for: next.pullRequest) else { return }
        let task = Task { [weak self] in
            let result = await reader.diff(of: next.file, in: next.files, of: next.pullRequest)
            guard !Task.isCancelled else { return }
            self?.finishCount(next.version, of: key, result)
        }
        reads[key]?.counting = (next.version, task)
    }

    private func finishCount(_ version: Version, of key: PRKey, _ result: Result<FileDiff, ThreadExcerpt.Problem>) {
        guard let counting = reads[key]?.counting, counting.version == version else { return }
        reads[key]?.counting = nil
        counted(version, of: key, result.map(\.counts))
        countNext(of: key)
    }

    /// Notes a file's count, or why it can't be counted, and takes it off what's to count.
    private func counted(_ version: Version, of key: PRKey, _ result: Result<LineCounts, ThreadExcerpt.Problem>) {
        guard reads[key] != nil else { return }
        reads[key]?.countQueue.removeAll { $0.version == version }
        if case .failure = result {
            reads[key]?.countFailedAt[version] = now()
        } else {
            reads[key]?.countFailedAt[version] = nil
        }
        if counts[key]?[version] != result { counts[key, default: [:]][version] = result }
    }

    // MARK: Forgetting

    /// Whether what failed in a way that may pass is read again: half a minute after it failed.
    private func isDue(_ failed: Date?) -> Bool {
        guard let failed else { return true }
        return now().timeIntervalSince(failed) >= PullRequestCodeStore.retryInterval
    }

    /// No window shows a page where the details can show: what's being read is called off, to be read once one does again,
    /// as the views showing it ask.
    private func callOffEverything() {
        for key in reads.keys {
            for (scope, task) in reads[key]?.listTasks ?? [:] {
                task.cancel()
                reads[key]?.listAsked[scope] = nil
                if lists[key]?[scope] == .reading { lists[key]?[scope] = nil }
            }
            reads[key]?.listTasks = [:]
            for (version, task) in reads[key]?.diffTasks ?? [:] {
                task.cancel()
                if diffs[key]?[version] == .reading { diffs[key]?[version] = nil }
            }
            reads[key]?.diffTasks = [:]
            reads[key]?.diffViewers = [:]
            reads[key]?.counting?.task.cancel()
            reads[key]?.counting = nil
            reads[key]?.countQueue = []
            reads[key]?.countViewers = [:]
        }
    }

    /// Forgets what's read of the pull requests nothing shows anymore, and calls off what's being read of them.
    private func forgetWhatNothingShows() {
        for key in Set(reads.keys).union(lists.keys).union(diffs.keys).union(counts.keys) where !code.shows(key) {
            if let pullRequestReads = reads[key] {
                pullRequestReads.listTasks.values.forEach { $0.cancel() }
                pullRequestReads.diffTasks.values.forEach { $0.cancel() }
                pullRequestReads.counting?.task.cancel()
            }
            reads[key] = nil
            if lists[key] != nil { lists[key] = nil }
            if diffs[key] != nil { diffs[key] = nil }
            if counts[key] != nil { counts[key] = nil }
        }
    }
}
