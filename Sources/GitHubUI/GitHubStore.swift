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
    /// Who the GitHub CLI is signed in as: its active account, unless that couldn't be read.
    @Published private(set) var login: String?
    /// Every account it reads as, the GitHub CLI's active one first.
    @Published private(set) var logins: [String] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshedAt: Date?
    /// For how long ago each pull request changed: it ticks while the store runs.
    @Published private(set) var now = Date()
    @Published private(set) var isStarted = false

    let mode: Mode
    let settings: AppSettings
    /// Reads the GitHub CLI's accounts, made when it starts; tests give it a CLI that isn't there.
    private let makeReader: () -> GitHubAccountsReader
    /// Whether Pull Request Order is on: each read then sends the order's query, which reads what an order needs too.
    var ordersOn: () -> Bool = { false }
    /// While it runs: it's made by `start()`, so nothing runs `gh` or connects before then.
    private(set) var reader: GitHubAccountsReader?
    private var ticker: Timer?
    private var task: Task<Void, Never>?
    /// When the last read started: `isDue(at:)` counts from it.
    private(set) var lastAttempt: Date?
    /// Until when GitHub asked BriefBar to slow down as every account it reads as: it reads nothing before then.
    private(set) var waitsUntil: Date?
    /// Goes up with every stop, so a read that ends afterwards changes nothing.
    private var generation = 0
    /// Until when each read lists the GitHub CLI's accounts again, every minute, after you chose to sign in to one, so that
    /// it shows soon; nil otherwise, and once an account it didn't read as then shows.
    private(set) var listsAccountsUntil: Date?
    /// The accounts it read as when you chose to sign in to one.
    private var loginsBeforeSignIn: [String] = []

    /// How soon a popover opening reads again.
    static let minimumGap: TimeInterval = 10
    /// How often it tries again while you need to sign in or are offline, so a fix shows within a minute.
    static let retryInterval: TimeInterval = 60
    /// For how long after you choose to sign in each read lists the GitHub CLI's accounts again.
    static let signInWait: TimeInterval = 10 * 60

    init(settings: AppSettings, mode: Mode, makeReader: @escaping () -> GitHubAccountsReader = { GitHubAccountsReader() }) {
        self.settings = settings
        self.mode = mode
        self.makeReader = makeReader
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        now = Date()
        switch mode {
        case .demo:
            receive(GitHubDemoData.load(now: now, order: ordersOn()))
        case .live:
            reader = makeReader()
            refresh()
        }
        let ticker = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker.tolerance = 3
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Stops reading, and forgets what it read. Cancelling the read under way stops a run of `gh` it waits for, so the
    /// token that run would get reaches nothing (`GitHubCLITokenProvider.token()`).
    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        ticker?.invalidate()
        ticker = nil
        reader = nil
        lastAttempt = nil
        waitsUntil = nil
        listsAccountsUntil = nil
        loginsBeforeSignIn = []
        isStarted = false
        items = []
        counts = GitHubGroupCounts()
        problem = nil
        notice = nil
        moreThanShown = false
        login = nil
        logins = []
        hasLoaded = false
        isRefreshing = false
        refreshedAt = nil
    }

    private func tick() {
        now = Date()
        if isDue(at: now) { refresh() }
    }

    /// Whether it's time to read again: every few minutes, every minute while there's something to fix or it waits for you
    /// to sign in, and not before GitHub said to.
    func isDue(at date: Date) -> Bool {
        guard mode == .live, isStarted else { return false }
        if let waitsUntil, date < waitsUntil { return false }
        guard let lastAttempt else { return true }
        let interval: TimeInterval
        switch problem {
        case .cliNotFound?, .signedOut?, .authFailed?, .offline?: interval = min(Self.retryInterval, settings.refreshInterval)
        default:
            interval = isListingAccounts(at: date) ? min(Self.retryInterval, settings.refreshInterval) : settings.refreshInterval
        }
        return date.timeIntervalSince(lastAttempt) >= interval
    }

    /// Whether reads list the GitHub CLI's accounts again, at `date`, as they do for a while after you chose to sign in.
    func isListingAccounts(at date: Date) -> Bool {
        listsAccountsUntil.map { date < $0 } ?? false
    }

    /// Reads GitHub now, unless a read is under way.
    /// - Parameter listingAccounts: whether to list the GitHub CLI's accounts again first, as Refresh Now does, rather than
    ///   use the list it keeps for half an hour.
    func refresh(listingAccounts: Bool = false) {
        guard mode == .live, isStarted, task == nil, let reader else { return }
        if let waitsUntil, Date() < waitsUntil { return }
        let started = Date()
        lastAttempt = started
        isRefreshing = true
        let generation = self.generation
        let order = ordersOn()
        let listsAgain = listingAccounts || isListingAccounts(at: started)
        task = Task { [weak self] in
            let result: Result<GitHubLoad, Error>
            do {
                if listsAgain { await reader.listAgain() }
                result = .success(try await reader.load(order: order))
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

    /// Pull Request Order was turned on or off: read again now, with its query or without it. A read under way used the
    /// setting as it was, so it's called off, and what it would have read goes nowhere.
    func orderChanged() {
        guard isStarted else { return }
        switch mode {
        case .demo:
            receive(GitHubDemoData.load(now: Date(), order: ordersOn()))
        case .live:
            if let task {
                generation += 1
                task.cancel()
                self.task = nil
                isRefreshing = false
            }
            refresh()
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
        show(load)
        problem = nil
        waitsUntil = nil
        hasLoaded = true
        refreshedAt = Date()
        now = Date()
        Log.app.info(
            "Read \(load.items.count, privacy: .public) pull requests as \(load.logins.count, privacy: .public) accounts: \(load.counts.needsYou, privacy: .public) need you"
        )
    }

    func fail(_ error: Error) {
        if error is CancellationError { return }
        let problem = GitHubProblem.from(error)
        self.problem = problem
        hasLoaded = true
        now = Date()
        if let failure = error as? GitHubAccountsReader.Failure, !problem.needsSignIn {
            // None of its accounts could be read, and some not for a sign-in: what's left of each one's list, as when only
            // some can't be.
            show(failure.load)
            waitsUntil = failure.waitsUntil
        } else {
            if case .throttled(let until) = problem { waitsUntil = until } else { waitsUntil = nil }
            // Signed out, or as someone else: the list was theirs, and every view hides it until you sign in. Otherwise keep
            // the last one, which may be out of date.
            if problem.needsSignIn {
                items = []
                counts = GitHubGroupCounts()
                login = nil
                logins = []
                notice = nil
                moreThanShown = false
            }
        }
        Log.app.error("Couldn't read GitHub: \(problem.message, privacy: .public)")
    }

    /// Shows what a read found, or what's left of the list when none of its accounts could be read.
    private func show(_ load: GitHubLoad) {
        items = load.items
        counts = load.counts
        login = load.login
        logins = load.logins
        notice = load.notice
        moreThanShown = load.moreThanShown
        // An account it didn't read as when you chose to sign in shows: reads go back to the list kept for half an hour.
        // Not for the same accounts in another order, as `gh auth switch` leaves them, or fewer.
        if listsAccountsUntil != nil, load.logins.contains(where: { !loginsBeforeSignIn.contains($0) }) {
            listsAccountsUntil = nil
        }
    }

    /// For `--render`: reads once, without the timer.
    func loadOnce() async {
        switch mode {
        case .demo:
            receive(GitHubDemoData.load(order: ordersOn()))
        case .live:
            do {
                receive(try await makeReader().load(order: ordersOn()))
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
        waitForSignIn()
        let reader = reader
        Task {
            GitHub.signIn(ghPath: await reader?.executablePath)
        }
    }

    /// Signs the GitHub CLI in to another account, in Terminal, whose pull requests BriefBar then reads too. The account the
    /// GitHub CLI uses in Terminal stays the one it was as you clicked.
    func addAccount() {
        waitForSignIn()
        let reader = reader
        Task {
            GitHub.signIn(ghPath: await reader?.executablePath, keepingActive: true)
        }
    }

    /// For a while, each read, every minute, lists the GitHub CLI's accounts again, until the one you sign in to shows.
    func waitForSignIn() {
        guard mode == .live, isStarted else { return }
        listsAccountsUntil = Date().addingTimeInterval(Self.signInWait)
        loginsBeforeSignIn = logins
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

    /// Whether the list can say "All quiet": its last read worked, read every pull request there is and found none. Not
    /// before a read has worked, nor while it says you're offline, GitHub can't be reached, some pull requests couldn't
    /// be read or there are more than it reads.
    var isAllQuiet: Bool {
        hasLoaded && problem == nil && notice == nil && !moreThanShown && items.isEmpty
    }
}
