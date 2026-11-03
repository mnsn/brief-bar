import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// The files that conflict with pull requests' target branches, and how, for their details' **Merge Conflicts**: read with
/// one GET (`MergeConflicts.read`), more only for more than a hundred, as the details of a pull request whose merge status
/// says it has conflicts show, and again once its branch or its target moves. It reads only as `PullRequestCodeStore`
/// allows the details' other reads: while something shows the pull request (`shows`), and for a view in a window that
/// shows its page on screen (`isVisible`); once that window is minimized, hidden or covered, a read under way that only it
/// asked for is called off, to be read as it shows them again. What's read stays in memory only, until nothing shows the
/// pull request. It never reads by itself: what couldn't be read because Azure DevOps couldn't be reached is read again at
/// most every half minute while it shows, or when you ask.
@MainActor
final class PullRequestConflictsStore: ObservableObject {
    /// What's read of a pull request's conflicts, as far as it's read.
    enum State: Equatable {
        case reading
        case read(MergeConflicts)
        /// They can't be read, for this reason.
        case failed(ADOError)
    }

    /// Reads a pull request's conflicts: from Azure DevOps, the demo's made-up ones, or, in tests, as they say.
    typealias Reader = @Sendable (PullRequest) async throws -> MergeConflicts

    /// What's read of each pull request something shows.
    @Published private(set) var states: [PRKey: State] = [:]

    /// What's being read of a pull request.
    private struct Reads {
        /// What its conflicts were last asked for as: its head and its target, which a push or another target changes.
        var asked: PullRequestFilesStore.Head?
        var task: Task<Void, Never>?
        /// The windows' pages that asked for the read under way: it's called off once no window shows any of them.
        var pages: Set<String> = []
        /// When reading them last failed.
        var failedAt: Date?
    }

    private let code: PullRequestCodeStore
    private let reader: Reader
    private let now: () -> Date
    private var reads: [PRKey: Reads] = [:]
    private var subscription: AnyCancellable?
    /// Who's signed in to the Azure CLI, which what's read was read as, once known.
    private var account: String?
    /// Azure DevOps was turned off: nothing's read any more.
    private var isStopped = false

    /// Reads Azure DevOps with `client`, or, in the demo, its made-up conflicts.
    convenience init(code: PullRequestCodeStore, demo: Bool, client: ADOClient) {
        self.init(code: code) { pullRequest in
            demo ? DemoData.conflicts(of: pullRequest) : try await MergeConflicts.read(pullRequest, with: client)
        }
    }

    /// Reads only while `code` lets the details read, with `reader`.
    init(code: PullRequestCodeStore, now: @escaping () -> Date = Date.init, reader: @escaping Reader) {
        self.code = code
        self.reader = reader
        self.now = now
        code.whenForgetting { [weak self] in self?.forgetWhatNothingShows() }
        // What only views on a page that no window shows on screen anymore asked for is called off: each view asks again
        // once its window shows it.
        subscription = code.$visibilityChanges.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.callOffWhatNoWindowShows() }
        }
    }

    func state(of key: PRKey) -> State? {
        states[key]
    }

    /// The conflicts read for a pull request as it is now, for a prompt that lists them: nil while they aren't, or were
    /// read before its branch or its target moved.
    func conflicts(for pullRequest: PullRequest) -> MergeConflicts? {
        guard case .read(let conflicts)? = states[pullRequest.key], conflicts.isCurrent(for: pullRequest) else { return nil }
        return conflicts
    }

    /// A pull request's conflicts came on screen, in its details: they're read, unless it's open and its merge conflicts,
    /// as Azure DevOps says, and they're read for this version of it already, or being read; or nothing shows it, or its
    /// window doesn't show its page on screen. A push or another target reads them anew.
    /// - Parameters:
    ///   - page: the window's page they're on (`PullRequestCodeStore.page`): nil outside one, where nothing is read.
    ///   - again: read them again even if they failed less than half a minute ago, as when you ask.
    func show(_ pullRequest: PullRequest, on page: String?, again: Bool = false) {
        let key = pullRequest.key
        guard !isStopped, pullRequest.status == .active, pullRequest.hasConflicts else { return }
        guard let page, code.isVisible(page), code.shows(key) else { return }
        let head = PullRequestFilesStore.Head(pullRequest)
        var pullRequestReads = reads[key] ?? Reads()
        if pullRequestReads.asked == head {
            if pullRequestReads.task != nil {
                reads[key]?.pages.insert(page)
                return
            }
            switch states[key] {
            case .read?:
                return
            case .failed(let error)?:
                guard Self.mayPass(error), again || isDue(pullRequestReads.failedAt) else { return }
            case .reading?, nil:
                break
            }
        }
        pullRequestReads.task?.cancel()
        pullRequestReads.asked = head
        pullRequestReads.pages = [page]
        let reader = reader
        pullRequestReads.task = Task { [weak self] in
            let result = await Self.read(pullRequest, with: reader)
            guard !Task.isCancelled else { return }
            self?.finish(key, head, result)
        }
        reads[key] = pullRequestReads
        states[key] = .reading
    }

    /// Reads them, and returns once they're read: for `--render`, which draws them only then, for a pull request something
    /// holds, whether a window shows it or not.
    func readAll(of pullRequest: PullRequest) async {
        let key = pullRequest.key
        guard !isStopped, pullRequest.status == .active, pullRequest.hasConflicts, code.shows(key) else { return }
        let head = PullRequestFilesStore.Head(pullRequest)
        reads[key, default: Reads()].asked = head
        finish(key, head, await Self.read(pullRequest, with: reader))
    }

    private static func read(_ pullRequest: PullRequest, with reader: Reader) async -> Result<MergeConflicts, ADOError> {
        do {
            return .success(try await reader(pullRequest))
        } catch let error as ADOError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private func finish(_ key: PRKey, _ head: PullRequestFilesStore.Head, _ result: Result<MergeConflicts, ADOError>) {
        // Unless they were asked for again since, or the pull request forgotten.
        guard reads[key]?.asked == head else { return }
        reads[key]?.task = nil
        reads[key]?.pages = []
        switch result {
        case .success(let conflicts):
            reads[key]?.failedAt = nil
            states[key] = .read(conflicts)
        case .failure(let error):
            reads[key]?.failedAt = now()
            states[key] = .failed(error)
            Log.app.error("Couldn't read a pull request's conflicts: \(error.description, privacy: .public)")
        }
    }

    /// Whether reading them again may show them: Azure DevOps couldn't be reached, asked BriefBar to wait, or didn't accept
    /// the sign-in. What isn't there, or isn't yours to read, stays so.
    static func mayPass(_ error: ADOError) -> Bool {
        ThreadCode.mayPass(.unreadable(error))
    }

    /// Half a minute after they couldn't be read, or at once when they never failed.
    private func isDue(_ failed: Date?) -> Bool {
        guard let failed else { return true }
        return now().timeIntervalSince(failed) >= PullRequestCodeStore.retryInterval
    }

    /// Calls off the reads that only pages no window shows on screen anymore asked for: they're read as one shows them
    /// again.
    private func callOffWhatNoWindowShows() {
        for (key, pullRequestReads) in reads where pullRequestReads.task != nil {
            guard !pullRequestReads.pages.contains(where: code.isVisible) else { continue }
            pullRequestReads.task?.cancel()
            reads[key]?.task = nil
            reads[key]?.pages = []
            reads[key]?.asked = nil
            if states[key] == .reading { states[key] = nil }
        }
    }

    /// Forgets the conflicts of the pull requests nothing shows anymore, and calls off what's being read of them.
    private func forgetWhatNothingShows() {
        for key in Set(reads.keys).union(states.keys) where !code.shows(key) {
            reads[key]?.task?.cancel()
            reads[key] = nil
            states[key] = nil
        }
    }

    /// Someone signed in to the Azure CLI, as the pull requests' refresh tells. When it's someone else than before, nothing
    /// read as the last one stays.
    func accountChanged(_ account: String?) {
        guard let account else { return }
        defer { self.account = account }
        guard let known = self.account, known != account else { return }
        letGo()
    }

    /// Stops for good, when Azure DevOps is turned off: what's read goes, the reads under way stop, and nothing is read any
    /// more.
    func stop() {
        isStopped = true
        subscription = nil
        letGo()
        account = nil
    }

    private func letGo() {
        for pullRequestReads in reads.values { pullRequestReads.task?.cancel() }
        reads = [:]
        states = [:]
    }
}
