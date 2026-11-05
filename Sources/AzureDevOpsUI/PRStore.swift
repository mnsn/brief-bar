import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import NotificationCenterDB

/// Main-thread view model: turns engine snapshots into the sorted, grouped pull request list, and decides
/// what to announce and summarize.
@MainActor
final class PRStore: ObservableObject {
    enum Mode {
        case live
        /// Made-up pull requests (`--demo`).
        case demo
    }

    enum Discovery: Equatable {
        case idle
        case running
        case failed(String)
    }

    @Published private(set) var items: [PRSnapshot] = []
    @Published private(set) var counts = GroupCounts()
    /// Reference time for relative labels; ticks every 15 s.
    @Published private(set) var now = Date()
    @Published private(set) var problem: PulseProblem?
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshedAt: Date?
    /// Each refresh, once its pull requests are listed: what was read of one can change without its row, such as an
    /// optional build that passed. `refreshedAt` changes before they're listed.
    let refreshed = PassthroughSubject<Void, Never>()
    @Published private(set) var discovery: Discovery = .idle
    @Published private(set) var brief: [BriefItem] = []
    /// The pipelines after your merges, the newest merge first.
    @Published private(set) var merges: [MergePipelines] = []
    @Published private(set) var authoredPullRequestList = AuthoredPullRequestList()
    var authoredPullRequests: [PullRequest] { authoredPullRequestList.pullRequests }
    /// Your name in Azure DevOps, so a brief's line can say "you" where a comment names you.
    private(set) var reader: String?
    /// Notifications are on for Azure DevOps but turned off for BriefBar in System Settings.
    @Published private(set) var notificationsBlocked = false
    /// Whether BriefBar can read Notification Center, for pull requests sent in chats; nil while that's off.
    @Published private(set) var chatAccess: AccessStatus?
    /// Why Notification Center couldn't be read, though BriefBar has access.
    @Published private(set) var chatProblem: String?
    /// Opens the window that explains Full Disk Access.
    var showChatAccessSetup: (() -> Void)?
    /// Whether Notification Center could be read, each time that changes: for the Full Disk Access window.
    var chatAccessChanged: ((AccessStatus) -> Void)?
    /// Opens a pull request's link: in the browser, or, in tests, where they say.
    var openLink: (URL) -> Void = { AzureDevOps.open($0) }
    /// What the details read of one of a pull request's builds, while it's open there, as its check and the pull request are
    /// now (`BuildInvestigationStore.current`): Fix the Build's prompt quotes it, rather than only its errors.
    var investigation: (_ check: Check, _ pullRequest: PullRequest) -> BuildInvestigation? = { _, _ in nil }

    let settings: AppSettings
    let summarizer: Summarizer
    let mode: Mode
    /// How pull requests sent in chats are read: only the app's own store is given Notification Center.
    let chats: ChatReading
    private let notifier: Notifier?
    /// Asks for tokens in the directory BriefBar last read your pull requests with, so signing in to another directory
    /// for an organization there, which makes it the Azure CLI's default, doesn't read you as someone else.
    private let tokens: AzureCLITokenProvider
    /// Stopped, as when Azure DevOps is turned off: a read the engine queued before then is dropped, so nothing it
    /// carries, such as who's signed in, is saved again once the source has deleted it.
    private var isStopped = false
    /// Shared with the Sprint and Pipelines sections: one sign-in, and one wait when Azure DevOps asks to slow down.
    let client: ADOClient
    private var engine: PulseEngine?
    private var state = PulseSnapshot()
    private let startedAt = Date()
    /// The list as of the last refresh, to compare the next one with.
    private var announced: [PRSnapshot]?
    private var delivered: Set<String> = []
    private var lastDiscovery: Date?
    private var discoveryProblem: PulseProblem?
    /// Checking the organizations you're adding, while it runs: by name, in lowercase.
    private var accessChecks: [String: Task<Void, Never>] = [:]
    /// The reads of pull requests after changes to their threads (`changed`, `mayHaveChanged`, `threadsReadAgain`), under
    /// way, by their IDs: stopping calls them off.
    private var changeReads: [UUID: Task<[ReviewThread]?, Never>] = [:]
    private var ticker: Timer?
    private var monitor: NetworkMonitor?
    private var chatMonitor: ChatLinkMonitor?
    /// Set when you turn the feature on, so the Full Disk Access window opens if access is missing.
    private var setUpChatAccessWhenNeeded = false
    /// What the open panel has shown in Answered, and when you answered each: seen once the panel closes.
    private var answeredInPanel: [PRKey: Date] = [:]
    /// What shows the list right now: popovers and windows' pages, by name.
    private var openViewers: Set<String> = []
    private var isPanelOpen: Bool { !openViewers.isEmpty }
    private var isOnline = true
    /// The changes you made to pull requests' threads (`changed(_:by:)`), as Azure DevOps answered them, or as the demo made
    /// them up, by pull request: each shows from then on, until the engine's snapshots have it; the demo's, while it runs.
    private var madeChanges: [PRKey: [ThreadChange]] = [:]
    /// The tags you changed on pull requests (`changedTags`), as Azure DevOps answered, or as the demo made them, by pull
    /// request: they show from then on, over a snapshot read before, until one has them, or has other tags, from a change
    /// made since; the demo's, while it runs.
    private var madeTags: [PRKey: MadeTags] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(
        settings: AppSettings, summarizer: Summarizer = Summarizer(), notifier: Notifier? = nil, mode: Mode = .live,
        chats: ChatReading = .inert, tokens: AzureCLITokenProvider? = nil
    ) {
        self.settings = settings
        self.summarizer = summarizer
        self.notifier = notifier
        self.mode = mode
        self.chats = chats
        let tokens = tokens ?? AzureCLITokenProvider(homeTenant: settings.pinnedDirectory, homeAccountTenant: settings.accountOrigin)
        self.tokens = tokens
        client = ADOClient(tokens: tokens)
        summarizer.isEnabled = settings.summaries
        notifier?.$isBlocked
            .removeDuplicates()
            .sink { [weak self] blocked in MainActor.assumeIsolated { self?.notificationsBlocked = blocked } }
            .store(in: &cancellables)
        // Summaries arrive one at a time; the views read them through the store.
        summarizer.objectWillChange
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &cancellables)
    }

    var activeItems: [PRSnapshot] { items.filter { $0.group != .idle } }

    /// Loading for the first time, or for organizations just chosen: nothing to show yet.
    var isLoading: Bool {
        guard mode == .live, !settings.organizations.isEmpty else { return false }
        return items.isEmpty && (isRefreshing || !hasLoaded || state.organizations != settings.organizations)
    }

    func items(in group: PRGroup) -> [PRSnapshot] {
        items.filter { $0.group == group }
    }

    /// The list in the order you chose: `items`, by status; or by when each was created.
    func items(by order: PROrder) -> [PRSnapshot] {
        order.isByDate ? PROrdering.sorted(items, by: order) : items
    }

    /// What a list by date has in one, by when each was created: every pull request but Done's and Idle's, which keep
    /// their own sections after it.
    func dateList(_ order: PROrder) -> [PRSnapshot] {
        items(by: order).filter { $0.group != .done && $0.group != .idle }
    }

    var organizations: [String] {
        mode == .demo ? [DemoData.organization] : settings.organizations
    }

    // MARK: Lifecycle

    func start() {
        guard ticker == nil else { return }
        isStopped = false
        observeSettings()
        let ticker = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker.tolerance = 3
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker

        switch mode {
        case .demo:
            settings.useSeenState(DemoData.seenState(now: now))
            let snapshot = DemoData.snapshot(now: now)
            receive(snapshot)
            // A new comment a few seconds later, so the demo shows a notification too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                MainActor.assumeIsolated { self?.receive(DemoData.update(snapshot, at: Date())) }
            }
        case .live:
            let engine = PulseEngine(client: client, configuration: settings.engineConfiguration) { [weak self] snapshot in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.receive(snapshot) }
                }
            }
            self.engine = engine
            Task { await engine.start() }
            if settings.organizations.isEmpty && !settings.hasDiscovered {
                discoverOrganizations()
            }
            watchNetworkAndSleep()
            updateChatMonitor()
        }
    }

    /// Loads once and waits for it (for `--render`).
    func loadOnce() async {
        switch mode {
        case .demo:
            settings.useSeenState(DemoData.seenState(now: now))
            receive(DemoData.snapshot(now: now))
        case .live:
            receive(await PulseEngine.loadOnce(client: client, configuration: settings.engineConfiguration))
        }
    }

    private func observeSettings() {
        Publishers.MergeMany(
            settings.$organizations.map { _ in () }.eraseToAnyPublisher(),
            settings.$refreshSeconds.map { _ in () }.eraseToAnyPublisher(),
            settings.$keepDoneHours.map { _ in () }.eraseToAnyPublisher(),
            settings.$idleDays.map { _ in () }.eraseToAnyPublisher(),
            settings.$followMerges.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(5)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let configuration = self.settings.engineConfiguration
                if let engine = self.engine { Task { await engine.setConfiguration(configuration) } }
                self.recompute()
            }
        }
        .store(in: &cancellables)

        settings.$watchedPullRequests.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateLinkedPullRequests()
                    self?.recompute()
                }
            }
            .store(in: &cancellables)

        settings.$seen.dropFirst().map { _ in () }
            .merge(with: settings.$seenSentInChats.dropFirst().map { _ in () })
            .merge(with: settings.$dismissedSentInChats.dropFirst().map { _ in () })
            .merge(with: settings.$readSentInChats.dropFirst().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &cancellables)

        settings.$summaries.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    self?.summarizer.isEnabled = enabled
                    self?.recompute()
                }
            }
            .store(in: &cancellables)

        settings.$notifications.dropFirst().filter { $0 }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.notifier?.requestAuthorization() } }
            .store(in: &cancellables)

        settings.$chatLinksEnabled.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    self?.setUpChatAccessWhenNeeded = enabled
                    self?.updateChatMonitor()
                }
            }
            .store(in: &cancellables)

        settings.$chatLinks.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateLinkedPullRequests()
                    self?.recompute()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Pull requests sent in chats

    /// Reads Notification Center only while the feature is on, and only through `chats`; turning it off forgets what
    /// was found.
    func updateChatMonitor() {
        guard mode == .live else { return }
        if settings.chatLinksEnabled {
            guard chatMonitor == nil else { return }
            // Delivered on the main thread, where turning the feature off stops it: nothing it read before arrives after.
            var current: ChatLinkMonitor?
            let monitor = chats.monitor { [weak self] snapshot in
                MainActor.assumeIsolated {
                    guard let self, let current, self.chatMonitor === current, self.settings.chatLinksEnabled else { return }
                    self.receiveChats(snapshot)
                }
            }
            if let monitor {
                current = monitor
                chatMonitor = monitor
                monitor.start()
                Log.app.info("Looking for pull requests sent in chats")
            }
        } else {
            if let chatMonitor {
                chatMonitor.stop()
                Log.app.info("Stopped looking for pull requests sent in chats")
            }
            chatMonitor = nil
            chatAccess = nil
            chatProblem = nil
            settings.forgetChatLinks()
        }
        updateLinkedPullRequests()
        recompute()
    }

    private func receiveChats(_ snapshot: ChatLinkMonitor.Snapshot) {
        if chatAccess != snapshot.access {
            chatAccess = snapshot.access
            Log.app.info("Notification Center access: \(snapshot.access.rawValue, privacy: .public)")
            chatAccessChanged?(snapshot.access)
        }
        if chatProblem != snapshot.problem {
            chatProblem = snapshot.problem
            if let problem = snapshot.problem { Log.app.error("\(problem, privacy: .public)") }
        }
        if snapshot.access == .granted {
            if settings.addChatLinks(snapshot.links) {
                Log.app.info("Pull request links in chats: \(self.settings.chatLinks.links.count, privacy: .private)")
            }
        } else if setUpChatAccessWhenNeeded {
            showChatAccessSetup?()
        }
        setUpChatAccessWhenNeeded = false
    }

    /// The pull requests to read by their links: those sent in chats, and those you watch.
    private func updateLinkedPullRequests() {
        let keys = (settings.chatLinksEnabled ? settings.chatLinks.keys : []).union(settings.watchedKeys)
        if let engine { Task { await engine.setLinkedPullRequests(keys) } }
    }

    /// Watches a pull request by its link, and reads it right away.
    func watch(_ link: PullRequestLink) {
        guard settings.watch(link) else { return }
        Log.app.info("Watching a pull request: \(self.settings.watchedPullRequests.count, privacy: .public) now")
    }

    func stopWatching(_ item: PRSnapshot) {
        settings.unwatch([item.key])
    }

    /// Opens the steps for Full Disk Access if Notification Center turns out not to be readable: when you turn
    /// Azure DevOps on with pull requests sent in chats on.
    func askForChatAccessIfMissing() {
        setUpChatAccessWhenNeeded = true
    }

    /// Reads Notification Center again now: the Full Disk Access window saw the access granted.
    func refreshChats() {
        chatMonitor?.refresh()
    }

    /// Opens the message that sent the pull request: the exact message in Teams, or the app otherwise.
    func openSource(_ item: PRSnapshot) {
        guard let source = item.chatSource else { return }
        if let url = source.messageURL, NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.app) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func watchNetworkAndSleep() {
        let monitor = NetworkMonitor { [weak self] online in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.networkChanged(online: online) }
            }
        }
        monitor.start()
        self.monitor = monitor

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.app.info("Woke from sleep: refreshing")
                    self?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    private func networkChanged(online: Bool) {
        defer { isOnline = online }
        if online && !isOnline {
            Log.app.info("Back online: refreshing")
            refresh()
        }
    }

    private func tick() {
        recompute()
        // Whichever section read with your sign-in's token: the pipelines or the sprint, without pull requests, too.
        if mode == .live { Task { await keepSignIn() } }
        // Retry finding organizations, for example once you've signed in.
        if mode == .live, settings.organizations.isEmpty, !settings.hasDiscovered, discovery != .running,
           Date().timeIntervalSince(lastDiscovery ?? .distantPast) > 60 {
            discoverOrganizations()
        }
    }

    /// Stops reading Azure DevOps, when it's turned off or the app quits.
    func stop() {
        ticker?.invalidate()
        ticker = nil
        monitor?.cancel()
        monitor = nil
        accessChecks.values.forEach { $0.cancel() }
        accessChecks = [:]
        changeReads.values.forEach { $0.cancel() }
        changeReads = [:]
        // Stops reading Notification Center; what it found stays until Azure DevOps is turned off.
        chatMonitor?.stop()
        chatMonitor = nil
        if let engine {
            Task { await engine.stop() }
        }
        engine = nil
        isStopped = true
    }

    /// Keeps your sign-in's directory, and where your account is from, as the Azure CLI's tokens tell them once any
    /// section has read with one, for after a restart (`AppSettings.accountDirectory`, `accountOrigin`). Never once
    /// stopped, as when Azure DevOps is turned off, which forgets them.
    func keepSignIn() async {
        guard mode == .live, !isStopped, let signedIn = await tokens.signedIn, !isStopped else { return }
        if settings.accountDirectory != signedIn.directory { settings.accountDirectory = signedIn.directory }
        if settings.accountOrigin != signedIn.origin { settings.accountOrigin = signedIn.origin }
    }

    // MARK: Actions

    func refresh() {
        engine?.refresh()
        if mode == .live, settings.organizations.isEmpty, !settings.hasDiscovered, discovery != .running {
            discoverOrganizations()
        }
    }

    /// Refreshes now, reading these pull requests' details too, as a Copilot session said it changed them (`AgentRereads`).
    func reread(_ keys: Set<PRKey>) {
        guard let engine else { return }
        Task { await engine.reread(keys) }
    }

    /// When the panel opens: refresh unless that just happened.
    func refreshIfStale() {
        chatMonitor?.refresh()
        guard Date().timeIntervalSince(refreshedAt ?? .distantPast) > 30 else { return }
        refresh()
    }

    /// A popover or a window's page shows the list: what it shows in Answered counts as seen once nothing does.
    func viewerDidOpen(_ viewer: String) {
        openViewers.insert(viewer)
        noteAnsweredInPanel()
    }

    /// Nothing shows the list anymore: what it showed in Answered goes back to its usual group. Each is seen up to
    /// when you answered it, not up to now, so whatever came after still counts as new.
    func viewerDidClose(_ viewer: String) {
        guard openViewers.remove(viewer) != nil, openViewers.isEmpty else { return }
        let shown = answeredInPanel
        answeredInPanel = [:]
        settings.markSeen(shown.map { (key: $0.key, date: $0.value) }, sentInChats: sentInChats(shown.keys))
    }

    private func noteAnsweredInPanel() {
        for item in items where item.group == .answered {
            answeredInPanel[item.key] = max(answeredInPanel[item.key] ?? .distantPast, item.since ?? now)
        }
    }

    /// Opens the pull request (at the comment that needs you) and marks it seen. Comments that wait on you there keep it
    /// in Needs You, no longer as new, until you answer them or remove it.
    func open(_ item: PRSnapshot) {
        markSeen(item)
        openLink(item.url)
    }

    /// Opens what a notification is about (its own comment, rather than the one the panel would open), and marks
    /// the pull request seen like a click in the panel.
    func openFromNotification(key: String?, url: URL) {
        if let item = items.first(where: { $0.key.description == key }) {
            markSeen(item)
        }
        AzureDevOps.open(url)
    }

    /// Sees a pull request, as opening it does: what needs you there now is no longer new.
    func markSeen(_ item: PRSnapshot) {
        settings.markSeen([item.key], at: max(Date(), item.events.map(\.at).max() ?? .distantPast), sentInChats: sentInChats([item.key]))
    }

    /// Marks a group's pull requests seen: Needs You keeps only those whose comments still wait on you, and Done empties.
    /// Each is seen up to what the panel showed, not up to now, so a comment that arrives before the next refresh still
    /// counts as new.
    func clear(_ group: PRGroup) {
        let cleared = items(in: group)
        settings.markSeen(cleared.map { item in
            (item.key, item.events.map(\.at).max() ?? item.since ?? Date())
        }, sentInChats: sentInChats(cleared.map(\.key)))
    }

    /// Takes a pull request off Needs You, up to what the panel showed: what waited on you there doesn't anymore, and
    /// it's seen. Anything that comes after needs you again.
    func dismiss(_ item: PRSnapshot) {
        settings.dismiss([(item.key, item.events.map(\.at).max() ?? item.since ?? Date())], sentInChats: sentInChats([item.key]))
    }

    /// A task that takes care of a pull request's comments started in Copilot, with the prompt you sent: what waited on
    /// you in the threads it quotes leaves Needs You, as it was when the prompt was written. A comment that came after,
    /// while you checked the prompt, say, one in a thread the prompt doesn't quote, or one that waits on you as the list
    /// last read the pull request but the prompt doesn't have, such as in a thread reopened meanwhile, still needs you. It
    /// leaves the Needs You of the account the prompt was written with, even if another has signed in to the Azure CLI
    /// since.
    func sentToCopilot(_ handOff: CommentHandOff, prompt: String) {
        // With the threads its account has marked as read as they are now, such as one marked as unread since.
        let read = settings.readThreads(of: handOff.key, for: handOff.account)
        guard let through = handOff.handedOff(in: prompt, now: record(for: handOff.key), read: read) else { return }
        settings.dismiss([(handOff.key, through)], for: handOff.account)
    }

    /// The pull requests among these that are listed only because someone sent them to you, or aren't listed at all:
    /// what you've seen of them stays in memory (`AppSettings.seenSentInChats`).
    private func sentInChats<S: Sequence>(_ keys: S) -> Set<PRKey> where S.Element == PRKey {
        let yours = Set(state.records.filter { $0.role != .linked }.map(\.id)).union(settings.watchedKeys)
        return Set(keys).subtracting(yours)
    }

    func openPullRequestsPage() {
        AzureDevOps.openPullRequests(organizations: organizations)
    }

    /// Signs in to the Azure CLI, or installs it first: for `problem`, or the pull requests' when there's none, and in
    /// its organizations' directory when that's what's wrong.
    func signIn(for problem: PulseProblem? = nil) {
        let problem = problem ?? self.problem
        if problem == .cliNotFound {
            AzureDevOps.open(AzureDevOps.installCLIPage)
            return
        }
        signIn(toTenant: problem?.signInTenant)
    }

    /// Opens Terminal to sign in to the Azure CLI; with `tenant`, in that directory.
    func signIn(toTenant tenant: String?) {
        Task {
            let path = await tokens.executablePath
            AzureDevOps.signIn(azPath: path, tenant: tenant)
        }
    }

    /// Whether your sign-in can read an organization you're adding, and if not, why: it's watched unless it can't be
    /// read for a reason that neither signing in nor waiting fixes, then `found` hears what the check found. Stopping
    /// Azure DevOps cancels it, and then nothing is watched or told.
    func add(organization name: String, found: @escaping (OrganizationDiscovery.Access) -> Void) {
        // Adding it again checks again; adding another checks that one too.
        let key = name.lowercased()
        accessChecks[key]?.cancel()
        accessChecks[key] = Task { [weak self] in
            guard let self else { return }
            let access = await OrganizationDiscovery.access(to: name, client: client)
            guard !Task.isCancelled else { return }
            accessChecks[key] = nil
            if access.watches, !settings.isWatching(name) { settings.toggleOrganization(name) }
            found(access)
        }
    }

    /// Finds your organizations, and watches the ones where you have pull requests.
    func discoverOrganizations() {
        guard mode == .live, discovery != .running else { return }
        discovery = .running
        lastDiscovery = Date()
        Task {
            do {
                // Throws when it couldn't tell, for example offline: it tries again, rather than settling on none.
                let found = try await OrganizationDiscovery.discover(client: client)
                settings.knownOrganizations = found.all
                // Keep the ones you chose yourself too, spelled the way Azure DevOps does.
                settings.organizations = OrganizationDiscovery.merged(settings.organizations, preferring: found.withPullRequests)
                settings.hasDiscovered = true
                discovery = .idle
                discoveryProblem = nil
                Log.app.info("Found \(found.all.count) organizations, \(found.withPullRequests.count) with pull requests")
            } catch {
                let message = (error as? ADOError)?.description ?? error.localizedDescription
                discovery = .failed(message)
                discoveryProblem = PulseProblem.from((error as? ADOError) ?? .network(message))
                Log.app.error("Couldn't find organizations: \(message, privacy: .public)")
            }
            recompute()
        }
    }

    // MARK: Updates

    func receive(_ snapshot: PulseSnapshot) {
        guard !isStopped else { return }
        // Someone else signed in to the Azure CLI: what they've seen is their own, and the list to compare the next
        // one with, to announce what's new, was the other account's, as was what the panel showed in Answered.
        if mode == .live, let account = snapshot.account, settings.useAccount(account) {
            announced = nil
            answeredInPanel = [:]
            Log.app.info("Signed in to the Azure CLI as another account")
        }
        // Your sign-in's directory, and where the account is from, kept for after a restart: a sign-in that your own
        // directory wants again then isn't taken for someone else's, nor another directory's default for yours.
        if mode == .live, snapshot.account != nil { Task { await keepSignIn() } }
        // With the changes you made to threads that it doesn't have yet: the demo's, always, since it reads nothing.
        var snapshot = snapshot
        if mode == .live { madeChanges = Self.pending(madeChanges, in: snapshot.records) }
        snapshot.records = Self.applying(madeChanges, to: snapshot.records)
        // And with the tags you changed, as Azure DevOps answered: until it has them, or, in the demo, always.
        if mode == .live { madeTags = Self.pending(madeTags, in: snapshot.records) }
        snapshot.records = Self.applying(madeTags, to: snapshot.records)
        state = snapshot
        let authored = snapshot.records.filter { $0.role == .author && $0.pullRequest.status == .active }
            .map(\.pullRequest).sorted { ($0.createdAt, $0.key) > ($1.createdAt, $1.key) }
        let authoredList = AuthoredPullRequestList(account: snapshot.account, pullRequests: authored)
        if authoredList != authoredPullRequestList { authoredPullRequestList = authoredList }
        let newMerges = snapshot.records.compactMap(\.merge).sorted { ($0.mergedAt, $0.pullRequest) > ($1.mergedAt, $1.pullRequest) }
        if newMerges != merges { merges = newMerges }
        if refreshedAt != snapshot.refreshedAt { refreshedAt = snapshot.refreshedAt }
        if isRefreshing != snapshot.isRefreshing { isRefreshing = snapshot.isRefreshing }
        if snapshot.hasLoaded && !hasLoaded { hasLoaded = true }
        if snapshot.hasLoaded, !snapshot.isRefreshing, !snapshot.organizations.isEmpty {
            // Ask about notifications once there are pull requests to talk about, rather than at the first launch.
            if settings.notifications { notifier?.requestAuthorization() }
            if mode == .live, snapshot.problem == nil {
                settings.pruneSeen(keeping: Set(snapshot.records.map(\.id)))
            }
        }
        // What earlier builds saved of pull requests sent in chats moves out of the preferences once they're listed.
        // What you've seen of the ones you watch stays there, like your own.
        settings.keepSeenInMemory(Set(snapshot.records.filter { $0.role == .linked }.map(\.id)).subtracting(settings.watchedKeys))
        // Watched pull requests that closed, or that you can't read anymore, aren't watched anymore.
        if mode == .live { settings.unwatch(snapshot.closedLinks) }
        recompute(announce: true)
        refreshed.send()
    }

    private func recompute(announce: Bool = false) {
        let now = Date()
        let options = settings.classifierOptions
        let links = settings.chatLinksEnabled ? settings.chatLinks : ChatLinkState()
        let watched = settings.watchedKeys
        let resolved = state.records.compactMap { record -> PRSnapshot? in
            var record = watched.contains(record.id) ? record.watched() : record
            let found = links.links(for: record.id).filter { link in !record.chatLinks.contains { $0.id == link.id } }
            record.chatLinks += found
            return PRClassifier.snapshot(
                for: record, seenCutoff: settings.seenCutoff(for: record.id), dismissedCutoff: settings.dismissedCutoff(for: record.id),
                read: settings.readThreads(of: record.id), now: now, options: options
            )
        }
        let sorted = PROrdering.sorted(resolved)
        self.now = now
        if sorted != items { items = sorted }
        if isPanelOpen { noteAnsweredInPanel() }
        let newCounts = GroupCounts(sorted)
        if newCounts != counts {
            counts = newCounts
            let summary = PRGroup.allCases.filter { newCounts[$0] > 0 }.map { "\(newCounts[$0]) \($0.rawValue)" }
            Log.app.info("Pull requests: \(summary.isEmpty ? "none" : summary.joined(separator: ", "), privacy: .public)")
        }

        var newProblem = state.problem
        // The engine hasn't picked up organizations just chosen yet.
        if newProblem == .noOrganizations, !settings.organizations.isEmpty { newProblem = nil }
        if mode == .live, settings.organizations.isEmpty {
            switch discovery {
            // The panel says it's looking.
            case .running: newProblem = nil
            case .failed: newProblem = discoveryProblem ?? state.problem
            case .idle: newProblem = settings.hasDiscovered ? state.problem : nil
            }
        }
        if newProblem != problem {
            problem = newProblem
            if let newProblem { Log.app.error("\(newProblem.logMessage, privacy: .public)") }
        }

        reader = state.userName
        let newBrief = Brief.items(from: sorted, reader: state.userName)
        if newBrief != brief { brief = newBrief }
        if settings.summaries {
            for item in newBrief {
                if let request = briefRequest(item) { summarizer.request(request) }
            }
        }

        // Only new data is announced: when what you've seen, a setting or the time changes, the list it's
        // compared with next moves along without announcing anything.
        if state.hasLoaded {
            if announce, !state.isRefreshing, let announced, settings.notifications, let notifier {
                let loaded = state
                let startedAt = self.startedAt
                let news = NotificationPlanner.news(previous: announced, current: sorted) { item in
                    // An organization added later starts from when it was first read, however it's spelled.
                    max(startedAt, loaded.firstRead(of: item.key.organization) ?? .distantFuture)
                }
                .filter { delivered.insert($0.id).inserted }
                if !news.isEmpty {
                    Log.app.info("Announcing \(news.count) update(s)")
                    // A few notifications at most, but the Notifications page lists every update, the newest first.
                    let plan = NotificationPlanner.collapse(news)
                    let summary = plan.summary.map { [Self.notification($0, sumsUp: true)] } ?? []
                    let more = plan.summarized.map { Self.notification($0) }
                    notifier.post(plan.shown.map { Self.notification($0) } + summary, more: more)
                }
            }
            announced = sorted
        }
    }

    /// A pull request's news, as a notification that opens it.
    private static func notification(_ note: PulseNotification, sumsUp: Bool = false) -> BriefBarNotification {
        var info: [String: String] = [:]
        if let url = note.url { info["url"] = url.absoluteString }
        if let key = note.key { info["pullRequest"] = key.description }
        return BriefBarNotification(
            id: note.id, source: .azureDevOps, state: note.state, title: note.title, subtitle: note.subtitle, body: note.body,
            thread: note.url?.absoluteString ?? "azure-devops", userInfo: info, sumsUp: sumsUp
        )
    }

    /// The demo's news so far, for the Notifications page, each as of when it happened. None outside the demo.
    var demoNotifications: [(notification: BriefBarNotification, date: Date)] {
        guard mode == .demo else { return [] }
        return DemoData.notifications(for: items).map { (Self.notification($0), $0.at) }
    }

    // MARK: Changes in Azure DevOps

    /// A change you made to one of a pull request's threads, with Make Changes in Azure DevOps on (`ThreadChanges`), as
    /// Azure DevOps answered it: it shows at once, and the pull request is read again, so Needs You, what's left, the brief
    /// and the counts follow it. In the demo, which reads nothing, the made-up change stays in its made-up data while it runs.
    func changed(_ key: PRKey, by change: ThreadChange) {
        madeChanges[key] = Self.adding(change, to: madeChanges[key] ?? [])
        state.records = Self.applying(madeChanges, to: state.records)
        recompute()
        refreshed.send()
        readAgain(key, after: change)
    }

    /// A change to a pull request's thread may have been made, though Azure DevOps didn't say how, as one it didn't answer in
    /// time: a read under way that started before now isn't taken, and the pull request is read again now; nothing in the
    /// demo.
    func mayHaveChanged(_ key: PRKey) {
        readAgain(key, after: nil)
    }

    /// A pull request's threads as Azure DevOps has them now, read again for it, as before a reply that may have gone is sent
    /// again: as a read that started now has them, never one under way before; nil when they couldn't be read now, once
    /// stopped, and in the demo. Called off with its caller, or as Azure DevOps stops.
    func threadsReadAgain(_ key: PRKey) async -> [ReviewThread]? {
        guard let read = readAgain(key, after: nil) else { return nil }
        return await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
    }

    /// Reads a pull request again after a change to its threads, the engine's way (`PulseEngine.changed`, with what Azure
    /// DevOps answered, or `mayHaveChanged`): a test's stand-in, or nil for the engine.
    var readAfterChange: (@Sendable (PRKey, ThreadChange?) async -> [ReviewThread]?)?

    /// How many reads after changes are under way, for tests.
    var changeReadsUnderWay: Int { changeReads.count }

    /// Reads a pull request again after a change to its threads, in a task that stopping calls off (`changeReads`): nil
    /// once stopped, and in the demo, which reads nothing.
    @discardableResult
    private func readAgain(_ key: PRKey, after change: ThreadChange?) -> Task<[ReviewThread]?, Never>? {
        guard mode == .live, !isStopped else { return nil }
        let read: @Sendable (PRKey, ThreadChange?) async -> [ReviewThread]?
        if let readAfterChange {
            read = readAfterChange
        } else if let engine {
            read = { key, change in
                guard let change else { return await engine.mayHaveChanged(key) }
                await engine.changed(key, by: change)
                return nil
            }
        } else {
            return nil
        }
        let id = UUID()
        let task = Task { [weak self] in
            let threads = await read(key, change)
            self?.changeReads[id] = nil
            return threads
        }
        changeReads[id] = task
        return task
    }

    /// A pull request's changes with another: a status it sets replaces any set before on that thread, whose comments stay,
    /// so that a status set back, as Reactivate after Resolve, isn't undone by the one before it until a snapshot has both;
    /// and a comment it edits or deletes, the edits of it before, and a comment it deletes, the reply that added it, so that
    /// neither puts back what the comment said, or the comment, until a snapshot has it.
    static func adding(_ change: ThreadChange, to made: [ThreadChange]) -> [ThreadChange] {
        let edited = Set(change.edited.map(\.id)), deleted = Set(change.deleted)
        guard change.status != nil || !edited.isEmpty || !deleted.isEmpty else { return made + [change] }
        let kept = made.compactMap { earlier -> ThreadChange? in
            guard earlier.thread == change.thread else { return earlier }
            var earlier = earlier
            if change.status != nil { earlier.status = nil }
            earlier.edited.removeAll { edited.contains($0.id) || deleted.contains($0.id) }
            earlier.comments.removeAll { deleted.contains($0.id) }
            return earlier.isEmpty ? nil : earlier
        }
        return kept + [change]
    }

    /// The pull requests with the changes made to their threads.
    static func applying(_ changes: [PRKey: [ThreadChange]], to records: [PRRecord]) -> [PRRecord] {
        guard !changes.isEmpty else { return records }
        return records.map { record in
            guard let made = changes[record.id], var details = record.details else { return record }
            for change in made { details.apply(change) }
            var record = record
            record.details = details
            return record
        }
    }

    // MARK: Tags

    /// Tags you changed on a pull request: as they are now, and as they were before each change, which a snapshot read
    /// before has.
    struct MadeTags: Equatable {
        var tags: [PullRequestTag]
        var replaced: [[PullRequestTag]] = []
    }

    /// You changed a pull request's tags, with Make Changes in Azure DevOps on (`TagChanges`), and Azure DevOps answered: they
    /// show at once, as it answered, and then the engine reads them again (`readTags(afterChanging:to:)`). In the demo, which
    /// reads nothing, they stay in its made-up data while it runs.
    func changedTags(_ key: PRKey, to tags: [PullRequestTag]) {
        var made = madeTags[key] ?? MadeTags(tags: tags)
        if let before = record(for: key)?.tags, !PullRequestTag.same(before, tags) { made.replaced.append(before) }
        made.tags = PullRequestTag.sorted(tags)
        madeTags[key] = made
        state.records = Self.applying(madeTags, to: state.records)
        recompute()
        refreshed.send()
    }

    /// After a change to a pull request's tags (`changedTags`): the engine keeps them as Azure DevOps answered, over any read
    /// that started before, then reads them again, one request, for anyone else's change meanwhile (`PulseEngine.changedTags`),
    /// in its caller's task, which turning Azure DevOps off calls off (`TagChanges`). Nil in the demo, which reads nothing.
    func readTags(afterChanging key: PRKey, to tags: [PullRequestTag]) async -> Result<[PullRequestTag], ADOError>? {
        guard mode == .live, let engine else { return nil }
        return await engine.changedTags(key, to: tags)
    }

    /// Reads a pull request's tags on their own now, one request, as Azure DevOps has them: for one whose list doesn't carry
    /// them, or after a change that may have been made. Nil in the demo, which reads nothing.
    func readTags(_ key: PRKey) async -> Result<[PullRequestTag], ADOError>? {
        guard mode == .live, let engine else { return nil }
        return await engine.readTags(key)
    }

    /// The tags of each pull request BriefBar read in a project, which adding a tag there suggests.
    func tags(inProjectOf pullRequest: PullRequest) -> [[PullRequestTag]] {
        state.records.compactMap { record in
            guard record.pullRequest.projectId.caseInsensitiveCompare(pullRequest.projectId) == .orderedSame,
                  record.pullRequest.key.organization.caseInsensitiveCompare(pullRequest.key.organization) == .orderedSame
            else { return nil }
            return record.tags
        }
    }

    /// The pull requests with the tags you changed on them.
    static func applying(_ made: [PRKey: MadeTags], to records: [PRRecord]) -> [PRRecord] {
        guard !made.isEmpty else { return records }
        return records.map { record in
            guard let tags = made[record.id]?.tags else { return record }
            var record = record
            record.tags = tags
            return record
        }
    }

    /// The tags you changed that pull requests as read don't have yet: those of a snapshot read before a change, which has
    /// them as they were, or that doesn't know them. Once one has them, or has others, as after a change someone made since,
    /// they're done with, and so are those of a pull request that isn't there.
    static func pending(_ made: [PRKey: MadeTags], in records: [PRRecord]) -> [PRKey: MadeTags] {
        made.filter { key, made in
            guard let record = records.first(where: { $0.id == key }) else { return false }
            guard let read = record.tags else { return true }
            if PullRequestTag.same(read, made.tags) { return false }
            return made.replaced.contains { PullRequestTag.same($0, read) }
        }
    }

    /// The changes that pull requests as read don't have yet: one they have, which changes nothing applied again, after
    /// those before it, is done with, and so are those of a pull request that isn't there, or whose threads weren't read. An
    /// edit of your reply is still to show while the reply is.
    static func pending(_ changes: [PRKey: [ThreadChange]], in records: [PRRecord]) -> [PRKey: [ThreadChange]] {
        var pending: [PRKey: [ThreadChange]] = [:]
        for (key, made) in changes {
            guard var details = records.first(where: { $0.id == key })?.details else { continue }
            var left: [ThreadChange] = []
            for change in made {
                let applied = details.applying(change)
                if applied != details { left.append(change) }
                details = applied
            }
            if !left.isEmpty { pending[key] = left }
        }
        return pending
    }

    // MARK: Summaries

    /// Whether the brief shows: summaries on, Apple Intelligence available, and something to say.
    var showsBrief: Bool {
        settings.summaries && summarizer.isAvailable && !brief.isEmpty
    }

    func briefText(_ item: BriefItem) -> String {
        briefRequest(item).flatMap { summarizer.text(for: $0) } ?? item.sentence
    }

    /// Whether the on-device model wrote this line (rather than the plain sentence).
    func isSummarized(_ item: BriefItem) -> Bool {
        briefRequest(item).flatMap { summarizer.text(for: $0) } != nil
    }

    func briefRequest(_ item: BriefItem) -> Summarizer.Request? {
        item.prompt.map { Summarizer.Request(prompt: $0, instructions: Brief.instructions) }
    }

    // MARK: Copilot

    /// The pull requests as the engine read them, for Show Links.
    var records: [PRRecord] { state.records }

    /// A pull request as the engine read it, for Copilot's prompts.
    func record(for key: PRKey) -> PRRecord? {
        guard let record = state.records.first(where: { $0.id == key }) else { return nil }
        return settings.watchedKeys.contains(key) ? record.watched() : record
    }

    /// When you last looked at a pull request, as far as BriefBar remembers.
    func seenCutoff(for key: PRKey) -> Date {
        settings.seenCutoff(for: key)
    }

    /// When you last looked at a pull request yourself, for what changed since; nil when you never did.
    func lastLooked(at key: PRKey) -> Date? {
        settings.lastLooked(at: key)
    }

    /// Up to when what waited on you in a pull request doesn't anymore: when you last removed it from Needs You, or sent
    /// its comments to Copilot.
    func dismissedCutoff(for key: PRKey) -> Date {
        settings.dismissedCutoff(for: key)
    }

    /// A pull request as the list would have it had you last looked at it at `seenCutoff`, the rest as it is now: what
    /// was new then, and what waited on you, but not what you've answered, removed from Needs You, sent to Copilot or
    /// marked as read since.
    func snapshot(of record: PRRecord, seenAt seenCutoff: Date) -> PRSnapshot? {
        PRClassifier.snapshot(
            for: record, seenCutoff: seenCutoff, dismissedCutoff: settings.dismissedCutoff(for: record.id),
            read: settings.readThreads(of: record.id), now: now, options: settings.classifierOptions
        )
    }

    /// What a thread was read up to before you marked it as read, and for whom: what Mark as Unread puts back.
    struct ReadMark: Equatable {
        var before: Date?
        var account: String?
    }

    /// Marks one of a pull request's comment threads as read, up to `date`, the latest comment in it as its details show
    /// it: what waited on you there until then doesn't anymore, whatever its status, and once nothing else does, the pull
    /// request leaves Needs You. A comment after it waits on you again. It's BriefBar's own, as what you've seen is:
    /// nothing goes to Azure DevOps. It's kept for the account signed in now, whose list it's in; for a pull request
    /// listed only because someone sent it to you, in memory only. Returns what Mark as Unread puts back.
    @discardableResult
    func markRead(_ thread: Int, of key: PRKey, upTo date: Date) -> ReadMark {
        let mark = ReadMark(before: settings.readThreads(of: key)[thread], account: settings.account)
        settings.markRead(thread, of: key, upTo: date, for: mark.account, sentInChat: sentInChats([key]).contains(key))
        return mark
    }

    /// Puts a thread you marked as read back as it was before, as Mark as Unread does: what waited on you there does again.
    /// Where the pull request's marks are kept now, which may have changed since, as for one you stopped watching that
    /// someone also sent you.
    func markUnread(_ thread: Int, of key: PRKey, as mark: ReadMark) {
        settings.setRead(thread, of: key, to: mark.before, for: mark.account, sentInChat: sentInChats([key]).contains(key))
    }

    /// What Copilot can do with a pull request now (`PullRequestTasks.actions`): Push & Reply once a task that changed
    /// code has finished, in its session.
    func copilotActions(for item: PRSnapshot, continuable: CopilotRun?) -> [PullRequestAction] {
        guard let record = record(for: item.key) else { return [] }
        let canShip = continuable.map { $0.action?.changesCode == true && $0.ended == .finished } ?? false
        return PullRequestTasks.actions(for: record, canShip: canShip)
    }

    /// Writes the prompts for what Copilot should do with a pull request, then opens the composer with them: for a failed
    /// build, once each failed build's errors have been read; for its conflicts, with the files that conflict, once its
    /// details read them (`conflicts`). Each takes on what its prompt does, for each to say what became of it
    /// (`PullRequestTasks.parts`).
    /// - Parameters:
    ///   - start: where it goes to begin with, rather than BriefBar's suggestion, such as the session whose fixes Push &
    ///     Reply ships.
    ///   - parts: for Push & Reply, what the fixes it ships took on: its prompt lists their threads alone, and replies on
    ///     those alone, or on none for a build's fix alone; without any, it lists those Fix Comments does.
    func composeCopilot(
        _ action: PullRequestAction, for item: PRSnapshot, copilot: CopilotTasksStore, start: ComposerStart? = nil,
        parts: [PullRequestPart] = []
    ) {
        guard let record = record(for: item.key) else { return }
        let pr = record.pullRequest
        // Push & Reply for some fixes, such as one session's when they're in more than one, ships, replies on and hands off
        // their threads alone.
        let scope = action == .pushAndReply ? PullRequestTasks.shippedThreads(parts) : nil
        let handOff = commentHandOff(action, for: record, threads: scope)
        let taken = PullRequestTasks.parts(action, for: record, shipping: action == .pushAndReply ? parts : [])
        // What its details read of its builds, which Fix the Build quotes rather than only their errors.
        var investigations: [Int: BuildInvestigation] = [:]
        if action == .fixBuild {
            for check in PullRequestTasks.failedBuilds(record) {
                if let buildId = check.buildId, let investigation = investigation(check, pr) { investigations[buildId] = investigation }
            }
        }
        Task {
            // Gone from your lists while it waited for the files that conflict: nothing opens.
            guard let written = await copilotPrompts(action, for: record, threads: scope, investigations: investigations) else { return }
            copilot.compose(
                PullRequestTasks.task(for: written.record), action: action, prompt: written.prompts.worktree,
                sessionPrompt: written.prompts.session, createdAt: pr.createdAt, handOff: handOff, start: start, parts: taken
            )
        }
    }

    /// The prompts `composeCopilot` opens the composer with, and the pull request as they're written for: for its conflicts,
    /// once a read of them under way ends, the pull request as the list has it then, with the files read for it (`conflicts`),
    /// so they're listed even when you ask before they're read, and a push or a retarget meanwhile is taken in; nil once the
    /// list has it no more, or it was completed or abandoned meanwhile.
    /// - Parameters:
    ///   - threads: for Push & Reply, the threads it ships alone.
    ///   - investigations: what the details read of its builds, by run, which Fix the Build quotes.
    func copilotPrompts(
        _ action: PullRequestAction, for record: PRRecord, threads: [Int]? = nil, investigations: [Int: BuildInvestigation] = [:]
    ) async -> (record: PRRecord, prompts: (worktree: String, session: String))? {
        var record = record
        var files: MergeConflicts?
        if action == .resolveConflicts, let conflicts {
            guard let current = await conflicts(record.pullRequest.key), current.record.pullRequest.status == .active else { return nil }
            record = current.record
            files = current.conflicts
        }
        let client = mode == .live ? client : nil
        let prompts = await PullRequestTasks.prompts(
            action, for: record, client: client, threads: threads, investigations: investigations, conflicts: files
        )
        return (record, prompts)
    }

    /// The files that conflict with a pull request's target branch, as its details read them, once a read of them under way
    /// ends, with the pull request as the list has it then, or nil once it has it no more: the source's
    /// (`PullRequestConflictsStore.forPrompt`). Nil without a store that reads them, as in tests, where the prompt goes
    /// without them.
    var conflicts: (@MainActor (PRKey) async -> (record: PRRecord, conflicts: MergeConflicts?)?)?

    /// What a task takes off Needs You once you send it: for Fix Comments and Push & Reply on your pull request, the comments
    /// that wait on you as the prompt is written from `record`, not as they are when you send it, for the account signed in
    /// now.
    /// - Parameter threads: for Push & Reply, the threads it ships alone.
    func commentHandOff(_ action: PullRequestAction, for record: PRRecord, threads: [Int]? = nil) -> CommentHandOff? {
        guard action.takesCareOfComments, record.role == .author else { return nil }
        return CommentHandOff(
            record, dismissedCutoff: settings.dismissedCutoff(for: record.id), read: settings.readThreads(of: record.id),
            account: settings.account, threads: threads
        )
    }
}
