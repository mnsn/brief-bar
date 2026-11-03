import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// Reads a pull request's code: the code its comment threads are on, and, for its Files, the files its change touched and
/// each one's diff. `PullRequestCode`, or a stand-in in tests.
protocol ThreadCodeReader: Sendable {
    func excerpt(of thread: ReviewThread, in pullRequest: PullRequest, context: Int) async -> Result<ThreadExcerpt, ThreadExcerpt.Problem>
    func changedFiles(of pullRequest: PullRequest, scope: ChangeScope) async -> Result<ChangedFiles, ThreadExcerpt.Problem>
    func diff(of file: FileChange, in files: ChangedFiles, of pullRequest: PullRequest) async -> Result<FileDiff, ThreadExcerpt.Problem>
}

extension ThreadCodeReader {
    /// A stand-in that reads only threads' code has no files.
    func changedFiles(of pullRequest: PullRequest, scope: ChangeScope) async -> Result<ChangedFiles, ThreadExcerpt.Problem> {
        .failure(.noIterations)
    }

    func diff(of file: FileChange, in files: ChangedFiles, of pullRequest: PullRequest) async -> Result<FileDiff, ThreadExcerpt.Problem> {
        .failure(.noIterations)
    }
}

extension PullRequestCode: ThreadCodeReader {}

/// The code that pull requests' comment threads are on, read as each thread comes on screen (`show`), through one
/// `PullRequestCode` for each pull request, and called off as it leaves (`hide`) before it's read. It reads only for what
/// shows a pull request's details: the panel beside the list, which it follows (`follow`), and the views on screen that
/// hold a pull request (`hold`), such as its comments on its page over a work item's details; and only for a thread on
/// screen in a window that shows its page on screen (`setVisible`), whatever other windows show. What's read stays in
/// memory only, while something shows
/// that pull request: once nothing does, it's forgotten. It never reads by itself: a thread is read again only once it's
/// on screen after a push, and one that couldn't be read because Azure DevOps couldn't be reached, at most every half
/// minute, or when you ask.
@MainActor
final class PullRequestCodeStore: ObservableObject {
    /// A thread's code, as far as it's read.
    enum State: Equatable {
        case reading
        case read(ThreadExcerpt)
        /// It can't be shown, for this reason.
        case failed(ThreadExcerpt.Problem)
    }

    /// What's read of each pull request that something shows, by thread ID. Azure DevOps numbers each pull request's
    /// threads from 1, so a thread is only ever looked up with its pull request.
    @Published private(set) var states: [PRKey: [Int: State]] = [:]
    /// How many times a window started or stopped showing, on screen, a page where a pull request's details can show:
    /// what each thread asks for its code again by, once its window shows it again, however SwiftUI gathers the changes
    /// in between.
    @Published private(set) var visibilityChanges = 0

    /// What the code of a thread was last asked for as: where the thread is, and the pull request's head and target, which
    /// a push or another target changes. Its paths and branch are compared by their bytes, as Git tells them apart:
    /// Swift's strings are equal when they look the same, as "é" written in one character and in two, but those are two
    /// files to Git, and a thread moved from one to the other is read again.
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

        static func == (lhs: Ask, rhs: Ask) -> Bool {
            lhs.location == rhs.location && lhs.line == rhs.line && lhs.source == rhs.source && lhs.target == rhs.target
                && same(lhs.filePath, rhs.filePath) && same(lhs.location?.path, rhs.location?.path)
                && same(lhs.location?.tracking?.originalPath, rhs.location?.tracking?.originalPath)
                && same(lhs.targetBranch, rhs.targetBranch)
        }

        /// Whether two strings are the same byte for byte.
        private static func same(_ lhs: String?, _ rhs: String?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): true
            case let (lhs?, rhs?): lhs.utf8.elementsEqual(rhs.utf8)
            default: false
            }
        }
    }

    /// How long a thread that couldn't be read waits before it's read again as it comes on screen.
    static let retryInterval: TimeInterval = 30

    /// What's being read of a pull request, and what's to read again.
    private struct Reads {
        var reader: (any ThreadCodeReader)?
        /// What each thread's code was last asked for as.
        var asked: [Int: Ask] = [:]
        var tasks: [Int: Task<Void, Never>] = [:]
        /// When a read that may pass if read again failed.
        var failedAt: [Int: Date] = [:]
        /// The threads whose code shows, but not all there is to know of it: as it was read before a push, since reading
        /// it again failed in a way that may pass; or without whether it changed since, which couldn't be read. They're
        /// read again as a read that failed in a way that may pass is.
        var unsettled: Set<Int> = []
        /// The views on screen that show each thread, by the token each has, with the page each is on (`page`): a read is
        /// called off once none does, or none whose window shows its page on screen.
        var showing: [Int: [UUID: String]] = [:]
    }

    private let makeReader: (PullRequest) -> any ThreadCodeReader
    private var reads: [PRKey: Reads] = [:]
    /// The pull request the panel beside the list shows, which it follows.
    private var followed: PRKey?
    /// The pull requests that views hold, by the number each hold got.
    private var holds: [Int: PRKey] = [:]
    private var lastHold = 0
    /// The pages where a pull request's details can show that windows show on screen (`page`).
    private var visiblePages: Set<String> = []
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

    // MARK: What shows

    /// Follows the panel's details: its pull request's code is read and kept while they show it, pages over them
    /// included, and forgotten once they show another one, or none, unless something else holds it.
    func follow(_ details: PullRequestDetailsStore) {
        subscription = details.$selected.map { $0?.key }.removeDuplicates()
            .sink { [weak self] key in MainActor.assumeIsolated { self?.follow(key) } }
    }

    /// The pull request the panel's details show from now on.
    func follow(_ key: PRKey?) {
        guard key != followed else { return }
        followed = key
        forgetWhatNothingShows()
    }

    /// A view on screen shows a pull request's threads, such as its comments on its page, until it lets go with
    /// `release`: its code is read, and kept, meanwhile. What it returns is what it lets go with.
    func hold(_ key: PRKey) -> Int {
        lastHold += 1
        holds[lastHold] = key
        return lastHold
    }

    /// The view that held a pull request doesn't show it anymore: once nothing does, its code is forgotten, and what's
    /// being read of it called off.
    func release(_ hold: Int) {
        guard holds.removeValue(forKey: hold) != nil else { return }
        forgetWhatNothingShows()
    }

    /// Whether something shows a pull request: the panel's details, or a view that holds it.
    func shows(_ key: PRKey) -> Bool {
        followed == key || holds.values.contains(key)
    }

    /// What a window's page is called here: its section, the Pull Requests page or the Sprint page, whose work items'
    /// details open pull requests' pages, and its window, by the ID `SectionViewer` gives it.
    nonisolated static func page(_ section: SectionID, window: String) -> String {
        "\(section.rawValue) in window \(window)"
    }

    /// Whether a window shows this page on screen (`page`): what a thread on it is read only while.
    func isVisible(_ page: String?) -> Bool {
        page.map(visiblePages.contains) ?? false
    }

    /// A window started or stopped showing, on screen, a page where a pull request's details can show: minimized, hidden
    /// or covered, its threads don't ask for anything anymore, and what only they asked for is called off, to be read when
    /// it shows them again. A read that a thread on another page still asks for, such as the same pull request's details
    /// in another window, goes on.
    func setVisible(_ visible: Bool, for page: String) {
        if visible {
            guard visiblePages.insert(page).inserted else { return }
        } else {
            guard visiblePages.remove(page) != nil else { return }
            for (key, pullRequestReads) in reads {
                for (id, views) in pullRequestReads.showing {
                    let left = views.filter { $0.value != page }
                    guard left.count < views.count else { continue }
                    reads[key]?.showing[id] = left.isEmpty ? nil : left
                    if left.isEmpty { callOff(id, of: key) }
                }
            }
        }
        visibilityChanges += 1
    }

    /// Forgets the code of the pull requests nothing shows anymore, and calls off what's being read of them.
    private func forgetWhatNothingShows() {
        for key in Set(reads.keys).union(states.keys) where !shows(key) {
            reads[key]?.tasks.values.forEach { $0.cancel() }
            reads[key] = nil
            states[key] = nil
        }
        forgot()
    }

    /// Called once it's forgotten the pull requests nothing shows anymore: the files' store forgets them too.
    var forgot: () -> Void = {}

    /// The reader of a pull request something shows, for its files: the one its threads' code is read with, so that a
    /// file read for one isn't read again for the other. Nil while nothing shows it.
    func reader(for pullRequest: PullRequest) -> (any ThreadCodeReader)? {
        let key = pullRequest.key
        guard shows(key) else { return nil }
        if let reader = reads[key]?.reader { return reader }
        let reader = makeReader(pullRequest)
        reads[key, default: Reads()].reader = reader
        return reader
    }

    // MARK: Reading

    func state(of threadId: Int, in key: PRKey) -> State? {
        states[key]?[threadId]
    }

    /// A thread on lines of a file came on screen: its code is read, unless it's read for this version of the pull request
    /// already, or being read, or nothing shows its pull request, or no window shows its page on screen. Read again,
    /// after a push, the code it showed stays until the new one is read.
    /// - Parameters:
    ///   - viewer: the view that shows it, which says so again with `hide` once it leaves the screen.
    ///   - page: the window's page it's on (`page`): nil outside one, where nothing is read.
    ///   - again: read it again even if it failed less than half a minute ago, as when you ask.
    func show(_ thread: ReviewThread, of pullRequest: PullRequest, by viewer: UUID, on page: String?, again: Bool = false) {
        let key = pullRequest.key
        guard let page, isVisible(page), shows(key), ThreadCode.isOnLines(thread) else { return }
        let id = thread.id
        reads[key, default: Reads()].showing[id, default: [:]][viewer] = page
        let ask = Ask(thread, pullRequest)
        if reads[key]?.asked[id] == ask, !needsReading(id, of: key, again: again) { return }
        var pullRequestReads = reads[key] ?? Reads()
        pullRequestReads.asked[id] = ask
        pullRequestReads.tasks[id]?.cancel()
        let reader = pullRequestReads.reader ?? makeReader(pullRequest)
        pullRequestReads.reader = reader
        pullRequestReads.tasks[id] = Task { [weak self] in
            let result = await reader.excerpt(of: thread, in: pullRequest, context: ThreadExcerpt.context)
            guard !Task.isCancelled else { return }
            self?.finish(id, of: key, ask, result)
        }
        reads[key] = pullRequestReads
        if case .read? = state(of: id, in: key) {} else { states[key, default: [:]][id] = .reading }
    }

    /// Whether the code of a thread, asked for as it is now, is read again: not while it's read or being read, or once it
    /// failed for a reason that lasts; when it failed in a way that may pass, or shows without all there is to know of it,
    /// half a minute later, or at once when you ask.
    private func needsReading(_ id: Int, of key: PRKey, again: Bool) -> Bool {
        let pullRequestReads = reads[key] ?? Reads()
        if pullRequestReads.tasks[id] != nil { return false }
        switch state(of: id, in: key) {
        case nil, .reading?: return true
        case .read?: guard pullRequestReads.unsettled.contains(id) else { return false }
        case .failed(let problem)?: guard ThreadCode.mayPass(problem) else { return false }
        }
        guard !again, let failed = pullRequestReads.failedAt[id] else { return true }
        return now().timeIntervalSince(failed) >= Self.retryInterval
    }

    /// A view that showed a thread of a pull request doesn't anymore: it left the screen, or went. Once no view on screen
    /// shows the thread, what's being read of its code is called off, to be read when one does again. The same thread's
    /// read goes on while another view still shows it, such as the same pull request's details in another window; and so
    /// does another pull request's thread with the same ID, as when the details move from one to another while the first
    /// fades away.
    func hide(_ threadId: Int, of key: PRKey, by viewer: UUID) {
        guard reads[key] != nil else { return }
        reads[key]?.showing[threadId]?[viewer] = nil
        guard reads[key]?.showing[threadId]?.isEmpty ?? true else { return }
        reads[key]?.showing[threadId] = nil
        callOff(threadId, of: key)
    }

    /// Calls off what's being read of a thread's code, to be read when it's asked for again.
    private func callOff(_ threadId: Int, of key: PRKey) {
        guard let task = reads[key]?.tasks.removeValue(forKey: threadId) else { return }
        task.cancel()
        reads[key]?.asked[threadId] = nil
        if state(of: threadId, in: key) == .reading { states[key]?[threadId] = nil }
    }

    /// Reads the code of all these threads, and returns once it's read: for `--render`, which draws them only then, for a
    /// pull request something holds, whether a window shows it or not.
    func readAll(_ threads: [ReviewThread], of pullRequest: PullRequest) async {
        let key = pullRequest.key
        guard shows(key) else { return }
        let reader = reads[key]?.reader ?? makeReader(pullRequest)
        reads[key, default: Reads()].reader = reader
        for thread in threads where ThreadCode.isOnLines(thread) {
            let ask = Ask(thread, pullRequest)
            reads[key, default: Reads()].asked[thread.id] = ask
            finish(thread.id, of: key, ask, await reader.excerpt(of: thread, in: pullRequest, context: ThreadExcerpt.context))
        }
    }

    /// The code of a thread, for a prompt about it, as it's read for this version of the pull request; else read now, as
    /// you open a composer on a thread that doesn't show its own, on its file's page, and kept as one that shows is. Nil
    /// for a thread that isn't on lines, or can't be read, or while nothing shows its pull request.
    func excerpt(of thread: ReviewThread, in pullRequest: PullRequest) async -> ThreadExcerpt? {
        let key = pullRequest.key
        let ask = Ask(thread, pullRequest)
        let asked = reads[key]?.asked[thread.id]
        if case .read(let excerpt)? = state(of: thread.id, in: key), asked == ask { return excerpt }
        guard ThreadCode.isOnLines(thread), let reader = reader(for: pullRequest) else { return nil }
        let result = await reader.excerpt(of: thread, in: pullRequest, context: ThreadExcerpt.context)
        // Kept unless its pull request was forgotten meanwhile, or a thread that shows it asked for it since.
        if shows(key), reads[key]?.tasks[thread.id] == nil, reads[key]?.asked[thread.id] == asked {
            reads[key, default: Reads()].asked[thread.id] = ask
            finish(thread.id, of: key, ask, result)
        }
        return try? result.get()
    }

    private func finish(_ id: Int, of key: PRKey, _ ask: Ask, _ result: Result<ThreadExcerpt, ThreadExcerpt.Problem>) {
        // Unless it was asked for again since, or its pull request forgotten.
        guard reads[key]?.asked[id] == ask else { return }
        reads[key]?.tasks[id] = nil
        switch result {
        case .success(let excerpt):
            states[key, default: [:]][id] = .read(excerpt)
            // Whether it changed since couldn't be read, as when Azure DevOps couldn't be reached for it: the code shows,
            // and it's read again for that half a minute later. What was read of it is kept, so that's one request at
            // most, and none when what couldn't be read won't be.
            if excerpt.changedSince == nil {
                reads[key]?.failedAt[id] = now()
                reads[key]?.unsettled.insert(id)
            } else {
                reads[key]?.failedAt[id] = nil
                reads[key]?.unsettled.remove(id)
            }
        case .failure(let problem):
            reads[key]?.failedAt[id] = now()
            // What showed stays, rather than a failure to read it again after a push, until it's read.
            if case .read? = state(of: id, in: key), ThreadCode.mayPass(problem) {
                reads[key]?.unsettled.insert(id)
                return
            }
            reads[key]?.unsettled.remove(id)
            states[key, default: [:]][id] = .failed(problem)
        }
    }

    /// Stops for good: when Azure DevOps is turned off.
    func stop() {
        subscription = nil
        followed = nil
        holds = [:]
        visiblePages = []
        forgetWhatNothingShows()
    }
}
