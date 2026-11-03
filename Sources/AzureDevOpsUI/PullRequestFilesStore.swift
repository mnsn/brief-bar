import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// A pull request's whole change, for its details' Files: the files it touched, read as its Files come on screen; each
/// file's diff, as its page shows it; and how many lines each adds and removes, counted as its row comes on screen, one
/// file at a time. It reads through the reader `PullRequestCodeStore` reads threads' code with, so a file is read once for
/// both, and only as that store allows: while something shows the pull request, and only for a view in a window that
/// shows its page on screen (`PullRequestCodeStore.isVisible`); once none does, what only it asked for is called off.
/// What's read stays in memory only, until nothing shows the pull request: a few files' diffs, and every file's count. It
/// never reads by itself: the files again only after a push, as they show, and what couldn't be read because Azure DevOps
/// couldn't be reached, at most every half minute, or when you ask.
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
        /// The windows' pages that asked for each list being read: it's called off once no window shows any of them.
        var listPages: [ChangeScope: Set<String>] = [:]
        var listFailedAt: [ChangeScope: Date] = [:]
        var diffTasks: [Version: Task<Void, Never>] = [:]
        /// The views on screen that show each diff, by the token each has, with the page each is on: a read is called off
        /// once none does, or none whose window shows its page on screen.
        var diffViewers: [Version: [UUID: String]] = [:]
        var diffFailedAt: [Version: Date] = [:]
        /// The diffs read, the latest last.
        var diffOrder: [Version] = []
        /// The files whose rows are on screen, to count in the order they came, and the views that show each, with the
        /// page each is on.
        var countQueue: [Count] = []
        var countViewers: [Version: [UUID: String]] = [:]
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
        // What only views on a page that no window shows on screen anymore asked for is called off: each view asks again
        // once its window shows it.
        subscription = code.$visibilityChanges.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.callOffWhatNoWindowShows() }
        }
    }

    // MARK: The files

    func list(of key: PRKey, _ scope: ChangeScope) -> State<ChangedFiles>? {
        lists[key]?[scope]
    }

    /// The pull request's Files came on screen: the files the change touched are read, unless they're read for this
    /// version of the pull request already, or being read, or nothing shows the pull request, or its window doesn't show
    /// its page on screen. Read again after a push, the files read before show meanwhile.
    /// - Parameters:
    ///   - page: the window's page they're on (`PullRequestCodeStore.page`): nil outside one, where nothing is read.
    ///   - again: read them again even if they failed less than half a minute ago, as when you ask.
    func showList(of pullRequest: PullRequest, scope: ChangeScope, on page: String?, again: Bool = false) {
        let key = pullRequest.key
        guard let page, code.isVisible(page), let reader = code.reader(for: pullRequest) else { return }
        let head = Head(pullRequest)
        var pullRequestReads = reads[key] ?? Reads()
        if pullRequestReads.listAsked[scope] == head {
            if pullRequestReads.listTasks[scope] != nil {
                reads[key]?.listPages[scope, default: []].insert(page)
                return
            }
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
        pullRequestReads.listPages[scope] = [page]
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
        reads[key]?.listPages[scope] = nil
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

    /// A file's page came on screen: its diff is read, unless it's read or being read, or its window doesn't show its page
    /// on screen.
    /// - Parameters:
    ///   - viewer: the view that shows it, which says so again with `hideDiff` once it goes.
    ///   - page: the window's page it's on (`PullRequestCodeStore.page`): nil outside one, where nothing is read.
    ///   - again: read it again even if it failed less than half a minute ago, as when you ask.
    func showDiff(
        of file: FileChange, in files: ChangedFiles, of pullRequest: PullRequest, by viewer: UUID, on page: String?, again: Bool = false
    ) {
        let key = pullRequest.key
        guard let page, code.isVisible(page), let reader = code.reader(for: pullRequest) else { return }
        let version = Version(file, in: files)
        reads[key, default: Reads()].diffViewers[version, default: [:]][viewer] = page
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
        reads[key]?.diffViewers[version]?[viewer] = nil
        guard reads[key]?.diffViewers[version]?.isEmpty ?? true else { return }
        reads[key]?.diffViewers[version] = nil
        callOffDiff(version, of: key)
        trimDiffs(of: key)
    }

    /// Calls off what's being read of a diff, to be read when it's asked for again.
    private func callOffDiff(_ version: Version, of key: PRKey) {
        guard let task = reads[key]?.diffTasks.removeValue(forKey: version) else { return }
        task.cancel()
        if diffs[key]?[version] == .reading { diffs[key]?[version] = nil }
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
    /// - Parameters:
    ///   - viewer: the view that shows it, which says so again with `stopCounting` once it leaves the screen.
    ///   - page: the window's page it's on (`PullRequestCodeStore.page`): nil outside one, where nothing is read.
    func count(_ file: FileChange, in files: ChangedFiles, of pullRequest: PullRequest, by viewer: UUID, on page: String?) {
        let key = pullRequest.key
        guard let page, code.isVisible(page), code.shows(key) else { return }
        let version = Version(file, in: files)
        reads[key, default: Reads()].countViewers[version, default: [:]][viewer] = page
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
        reads[key]?.countViewers[version]?[viewer] = nil
        guard reads[key]?.countViewers[version]?.isEmpty ?? true else { return }
        reads[key]?.countViewers[version] = nil
        callOffCount(version, of: key)
    }

    /// Takes a file off what's to count, and calls off counting it, for the next one.
    private func callOffCount(_ version: Version, of key: PRKey) {
        reads[key]?.countQueue.removeAll { $0.version == version }
        if let counting = reads[key]?.counting, counting.version == version {
            counting.task.cancel()
            reads[key]?.counting = nil
            countNext(of: key)
        }
    }

    /// Counts the next file waiting, unless one is being counted: the next whose row is in a window that shows its page on
    /// screen.
    private func countNext(of key: PRKey) {
        guard reads[key]?.counting == nil else { return }
        while let next = reads[key]?.countQueue.first {
            reads[key]?.countQueue.removeFirst()
            guard (reads[key]?.countViewers[next.version] ?? [:]).values.contains(where: { code.isVisible($0) }),
                  let reader = code.reader(for: next.pullRequest)
            else { continue }
            let task = Task { [weak self] in
                let result = await reader.diff(of: next.file, in: next.files, of: next.pullRequest)
                guard !Task.isCancelled else { return }
                self?.finishCount(next.version, of: key, result)
            }
            reads[key]?.counting = (next.version, task)
            return
        }
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

    /// Reads a pull request's change, the counts of its first files, as many as `counting`, and the diffs of the files at
    /// `paths`, and returns once they're read: for `--render`, which draws them only then, for a pull request something
    /// holds, whether a window shows it or not.
    func readAll(of pullRequest: PullRequest, scopes: [ChangeScope] = [.whole], diffs paths: [String] = [], counting: Int = .max) async {
        let key = pullRequest.key
        guard let reader = code.reader(for: pullRequest) else { return }
        for scope in scopes {
            let head = Head(pullRequest)
            reads[key, default: Reads()].listAsked[scope] = head
            let result = await reader.changedFiles(of: pullRequest, scope: scope)
            finishList(scope, of: key, head, result)
            guard case .success(let changes) = result else { continue }
            for (index, file) in changes.files.enumerated() {
                let shows = paths.contains { FileChange.ID(path: $0) == file.id }
                guard index < counting || shows else { continue }
                let version = Version(file, in: changes)
                let diff = await reader.diff(of: file, in: changes, of: pullRequest)
                counted(version, of: key, diff.map(\.counts))
                guard shows else { continue }
                switch diff {
                case .success(let read):
                    diffs[key, default: [:]][version] = .read(read)
                    reads[key]?.diffOrder.append(version)
                case .failure(let problem):
                    diffs[key, default: [:]][version] = .failed(problem)
                }
            }
        }
    }

    /// Whether what failed in a way that may pass is read again: half a minute after it failed.
    private func isDue(_ failed: Date?) -> Bool {
        guard let failed else { return true }
        return now().timeIntervalSince(failed) >= PullRequestCodeStore.retryInterval
    }

    /// A window started or stopped showing a page on screen: what only views on pages that no window shows asked for is
    /// called off, to be read once a window shows them again, as they ask. What a view in a window on screen still asks for
    /// goes on.
    private func callOffWhatNoWindowShows() {
        for key in reads.keys {
            guard let pullRequestReads = reads[key] else { continue }
            for (scope, task) in pullRequestReads.listTasks
            where !(pullRequestReads.listPages[scope] ?? []).contains(where: { code.isVisible($0) }) {
                task.cancel()
                reads[key]?.listTasks[scope] = nil
                reads[key]?.listAsked[scope] = nil
                reads[key]?.listPages[scope] = nil
                if lists[key]?[scope] == .reading { lists[key]?[scope] = nil }
            }
            for (version, viewers) in pullRequestReads.diffViewers {
                let left = viewers.filter { code.isVisible($0.value) }
                guard left.count < viewers.count else { continue }
                reads[key]?.diffViewers[version] = left.isEmpty ? nil : left
                if left.isEmpty { callOffDiff(version, of: key) }
            }
            for (version, viewers) in pullRequestReads.countViewers {
                let left = viewers.filter { code.isVisible($0.value) }
                guard left.count < viewers.count else { continue }
                reads[key]?.countViewers[version] = left.isEmpty ? nil : left
                if left.isEmpty { callOffCount(version, of: key) }
            }
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
