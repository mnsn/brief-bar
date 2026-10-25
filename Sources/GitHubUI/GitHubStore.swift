import BriefBarCore
import Combine
import Foundation
import GitHubCore

/// Your GitHub pull requests, read every few minutes while GitHub is on: one request each time.
@MainActor
final class GitHubStore: ObservableObject {
    enum Mode {
        case live
        /// Made-up pull requests only: it never runs `gh` or connects to GitHub.
        case demo
    }

    @Published private(set) var items: [GitHubPRSnapshot] = []
    @Published private(set) var counts = GitHubGroupCounts()
    @Published private(set) var problem: GitHubProblem?
    /// What GitHub couldn't read, alongside the list.
    @Published private(set) var notice: String?
    @Published private(set) var moreThanShown = false
    /// Who the GitHub CLI is signed in as.
    @Published private(set) var login: String?
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshedAt: Date?
    /// For how long ago each pull request changed: it ticks while the store runs.
    @Published private(set) var now = Date()
    @Published private(set) var isStarted = false

    let mode: Mode
    let settings: AppSettings
    /// The GitHub CLI's tokens, made when it starts; tests give it a CLI that isn't there.
    private let makeTokens: () -> GitHubCLITokenProvider
    /// While it runs: they're made by `start()`, so nothing runs `gh` or connects before then.
    private(set) var tokens: GitHubCLITokenProvider?
    private var client: GitHubClient?
    private var ticker: Timer?
    private var task: Task<Void, Never>?
    private var lastAttempt: Date?
    /// Goes up with every stop, so a read that ends afterwards changes nothing.
    private var generation = 0

    /// How soon a popover opening reads again.
    static let minimumGap: TimeInterval = 10
    /// How often it tries again while you need to sign in or are offline, so a fix shows within a minute.
    static let retryInterval: TimeInterval = 60

    init(settings: AppSettings, mode: Mode, makeTokens: @escaping () -> GitHubCLITokenProvider = { GitHubCLITokenProvider() }) {
        self.settings = settings
        self.mode = mode
        self.makeTokens = makeTokens
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        now = Date()
        switch mode {
        case .demo:
            receive(GitHubDemoData.load(now: now))
        case .live:
            let tokens = makeTokens()
            self.tokens = tokens
            client = GitHubClient(tokens: tokens)
            refresh()
        }
        let ticker = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker.tolerance = 3
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Stops reading, and forgets what it read.
    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        ticker?.invalidate()
        ticker = nil
        client = nil
        tokens = nil
        lastAttempt = nil
        isStarted = false
        items = []
        counts = GitHubGroupCounts()
        problem = nil
        notice = nil
        moreThanShown = false
        login = nil
        hasLoaded = false
        isRefreshing = false
        refreshedAt = nil
    }

    private func tick() {
        now = Date()
        if isDue(at: now) { refresh() }
    }

    /// Whether it's time to read again: every few minutes, every minute while there's something to fix, and not
    /// before GitHub said to.
    func isDue(at date: Date) -> Bool {
        guard mode == .live, isStarted else { return false }
        if case .throttled(let until) = problem, date < until { return false }
        guard let lastAttempt else { return true }
        let interval: TimeInterval
        switch problem {
        case .cliNotFound?, .signedOut?, .authFailed?, .offline?: interval = min(Self.retryInterval, settings.refreshInterval)
        default: interval = settings.refreshInterval
        }
        return date.timeIntervalSince(lastAttempt) >= interval
    }

    /// Reads GitHub now, unless a read is under way.
    func refresh() {
        guard mode == .live, isStarted, task == nil, let client else { return }
        if case .throttled(let until) = problem, Date() < until { return }
        lastAttempt = Date()
        isRefreshing = true
        let generation = self.generation
        task = Task { [weak self] in
            let result: Result<GitHubLoad, Error>
            do {
                result = .success(try await GitHubReader.load(client: client))
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == generation else { return }
            self.task = nil
            self.isRefreshing = false
            switch result {
            case .success(let load): self.receive(load)
            case .failure(let error): self.fail(error)
            }
        }
    }

    /// A popover opened: read again, unless it just did.
    func refreshIfStale() {
        guard let lastAttempt else {
            refresh()
            return
        }
        if Date().timeIntervalSince(lastAttempt) >= Self.minimumGap { refresh() }
    }

    func receive(_ load: GitHubLoad) {
        items = load.items
        counts = load.counts
        login = load.login
        notice = load.notice
        moreThanShown = load.moreThanShown
        problem = nil
        hasLoaded = true
        refreshedAt = Date()
        now = Date()
        Log.app.info(
            "Read \(load.items.count, privacy: .public) pull requests: \(load.counts.needsYou, privacy: .public) need you"
        )
    }

    func fail(_ error: Error) {
        if error is CancellationError { return }
        let problem = GitHubProblem.from(error)
        self.problem = problem
        hasLoaded = true
        now = Date()
        // Signed out, or as someone else: the list was theirs. Otherwise keep the last one, which may be out of date.
        if problem.needsSignIn {
            items = []
            counts = GitHubGroupCounts()
            login = nil
            notice = nil
            moreThanShown = false
        }
        Log.app.error("Couldn't read GitHub: \(problem.message, privacy: .public)")
    }

    /// For `--render`: reads once, without the timer.
    func loadOnce() async {
        switch mode {
        case .demo:
            receive(GitHubDemoData.load())
        case .live:
            do {
                receive(try await GitHubReader.load(client: GitHubClient(tokens: makeTokens())))
            } catch {
                fail(error)
            }
        }
    }

    /// Installs the GitHub CLI, or signs in to it in Terminal.
    func signIn() {
        if problem == .cliNotFound {
            GitHub.open(GitHub.installCLIPage)
            return
        }
        let tokens = tokens
        Task {
            let path = await tokens?.executablePath
            GitHub.signIn(ghPath: path)
        }
    }

    func open(_ item: GitHubPRSnapshot) {
        GitHub.open(item.pullRequest.url)
    }

    func openPullRequestsPage() {
        GitHub.open(GitHub.pullRequestsPage)
    }

    func items(in group: GitHubPRGroup) -> [GitHubPRSnapshot] {
        items.filter { $0.group == group }
    }
}
