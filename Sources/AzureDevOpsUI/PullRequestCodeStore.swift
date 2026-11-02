import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// Reads the code of a pull request's comment threads, one at a time: `PullRequestCode`, or a stand-in in tests.
protocol ThreadCodeReader: Sendable {
    func excerpt(of thread: ReviewThread, in pullRequest: PullRequest, context: Int) async -> Result<ThreadExcerpt, ThreadExcerpt.Problem>
}

extension PullRequestCode: ThreadCodeReader {}

/// The code that the comment threads of the pull request whose details show are on, read as each comes on screen
/// (`show`), through one `PullRequestCode` for that pull request, and called off as it leaves (`hide`) before it's read.
/// What's read stays while the details show that pull request, in memory only: showing another one, or none, forgets it.
/// It never reads by itself: a thread is read again only once it's on screen after a push, and one that couldn't be read
/// because Azure DevOps couldn't be reached, at most every half minute, or when you ask.
@MainActor
final class PullRequestCodeStore: ObservableObject {
    /// A thread's code, as far as it's read.
    enum State: Equatable {
        case reading
        case read(ThreadExcerpt)
        /// It can't be shown, for this reason.
        case failed(ThreadExcerpt.Problem)
    }

    /// By thread ID, for the pull request it reads.
    @Published private(set) var states: [Int: State] = [:]
    /// The pull request whose threads it reads.
    private(set) var key: PRKey?

    /// What the code of a thread was last asked for as: where the thread is, and the pull request's head and target, which
    /// a push or another target changes.
    struct Ask: Equatable {
        var location: ReviewThread.Location?
        var filePath: String?
        var line: Int?
        var source: String?
        var targetBranch: String
        var target: String?

        init(_ thread: ReviewThread, _ pullRequest: PullRequest) {
            location = thread.location
            filePath = thread.filePath
            line = thread.line
            source = pullRequest.sourceCommit
            targetBranch = pullRequest.targetBranch
            target = pullRequest.targetCommit
        }
    }

    /// How long a thread that couldn't be read waits before it's read again as it comes on screen.
    static let retryInterval: TimeInterval = 30

    private let makeReader: (PullRequest) -> any ThreadCodeReader
    private var reader: (any ThreadCodeReader)?
    private var asked: [Int: Ask] = [:]
    private var reads: [Int: Task<Void, Never>] = [:]
    /// When a read that may pass if read again failed.
    private var failedAt: [Int: Date] = [:]
    /// The threads whose code shows, but not all there is to know of it: as it was read before a push, since reading it
    /// again failed in a way that may pass; or without whether it changed since, which couldn't be read. They're read
    /// again as a read that failed in a way that may pass is.
    private var unsettled: Set<Int> = []
    private var subscription: AnyCancellable?
    private let now: () -> Date

    /// Reads Azure DevOps with `client`, or, in the demo, its made-up code.
    convenience init(demo: Bool, client: ADOClient) {
        self.init { pullRequest in demo ? PullRequestCode.demo(pullRequest) : PullRequestCode(pullRequest, client: client) }
    }

    init(now: @escaping () -> Date = Date.init, makeReader: @escaping (PullRequest) -> any ThreadCodeReader) {
        self.now = now
        self.makeReader = makeReader
    }

    /// Follows the details: what's read goes once they show another pull request, or none.
    func follow(_ details: PullRequestDetailsStore) {
        subscription = details.$selected.map { $0?.key }.removeDuplicates()
            .sink { [weak self] key in MainActor.assumeIsolated { self?.use(key) } }
    }

    /// Reads the threads of this pull request from now on, forgetting what was read of another one.
    func use(_ key: PRKey?) {
        guard key != self.key else { return }
        for read in reads.values { read.cancel() }
        reads = [:]
        asked = [:]
        failedAt = [:]
        unsettled = []
        reader = nil
        states = [:]
        self.key = key
    }

    func state(of threadId: Int) -> State? {
        states[threadId]
    }

    /// A thread on lines of a file came on screen: its code is read, unless it's read for this version of the pull request
    /// already, or being read. Read again, after a push, the code it showed stays until the new one is read.
    /// - Parameter again: read it again even if it failed less than half a minute ago, as when you ask.
    func show(_ thread: ReviewThread, of pullRequest: PullRequest, again: Bool = false) {
        guard pullRequest.key == key, ThreadCode.isOnLines(thread) else { return }
        let id = thread.id
        let ask = Ask(thread, pullRequest)
        if asked[id] == ask, !needsReading(id, again: again) { return }
        asked[id] = ask
        reads[id]?.cancel()
        if case .read? = states[id] {} else { states[id] = .reading }
        let reader = reader ?? makeReader(pullRequest)
        self.reader = reader
        reads[id] = Task { [weak self] in
            let result = await reader.excerpt(of: thread, in: pullRequest, context: ThreadExcerpt.context)
            guard !Task.isCancelled else { return }
            self?.finish(id, ask, result)
        }
    }

    /// Whether the code of a thread, asked for as it is now, is read again: not while it's read or being read, or once it
    /// failed for a reason that lasts; when it failed in a way that may pass, or shows without all there is to know of it,
    /// half a minute later, or at once when you ask.
    private func needsReading(_ id: Int, again: Bool) -> Bool {
        if reads[id] != nil { return false }
        switch states[id] {
        case nil, .reading?: return true
        case .read?: guard unsettled.contains(id) else { return false }
        case .failed(let problem)?: guard ThreadCode.mayPass(problem) else { return false }
        }
        guard !again, let failed = failedAt[id] else { return true }
        return now().timeIntervalSince(failed) >= Self.retryInterval
    }

    /// A thread left the screen: its code, unless it's read already, is called off, to be read when it's back.
    func hide(_ threadId: Int) {
        guard let read = reads.removeValue(forKey: threadId) else { return }
        read.cancel()
        asked[threadId] = nil
        if states[threadId] == .reading { states[threadId] = nil }
    }

    /// Reads the code of all these threads, and returns once it's read: for `--render`, which draws them only then.
    func readAll(_ threads: [ReviewThread], of pullRequest: PullRequest) async {
        guard pullRequest.key == key else { return }
        let reader = reader ?? makeReader(pullRequest)
        self.reader = reader
        for thread in threads where ThreadCode.isOnLines(thread) {
            let ask = Ask(thread, pullRequest)
            asked[thread.id] = ask
            finish(thread.id, ask, await reader.excerpt(of: thread, in: pullRequest, context: ThreadExcerpt.context))
        }
    }

    private func finish(_ id: Int, _ ask: Ask, _ result: Result<ThreadExcerpt, ThreadExcerpt.Problem>) {
        guard asked[id] == ask else { return }
        reads[id] = nil
        switch result {
        case .success(let excerpt):
            states[id] = .read(excerpt)
            // Whether it changed since couldn't be read, as when Azure DevOps couldn't be reached for it: the code shows,
            // and it's read again for that half a minute later. What was read of it is kept, so that's one request at
            // most, and none when what couldn't be read won't be.
            if excerpt.changedSince == nil {
                failedAt[id] = now()
                unsettled.insert(id)
            } else {
                failedAt[id] = nil
                unsettled.remove(id)
            }
        case .failure(let problem):
            failedAt[id] = now()
            // What showed stays, rather than a failure to read it again after a push, until it's read.
            if case .read? = states[id], ThreadCode.mayPass(problem) {
                unsettled.insert(id)
                return
            }
            unsettled.remove(id)
            states[id] = .failed(problem)
        }
    }

    /// Stops for good: when Azure DevOps is turned off.
    func stop() {
        subscription = nil
        use(nil)
    }
}
