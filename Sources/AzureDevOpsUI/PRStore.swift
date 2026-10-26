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
    @Published private(set) var discovery: Discovery = .idle
    @Published private(set) var brief: [BriefItem] = []
    /// The pipelines after your merges, the newest merge first.
    @Published private(set) var merges: [MergePipelines] = []
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

    let settings: AppSettings
    let summarizer: Summarizer
    let mode: Mode
    /// How pull requests sent in chats are read: only the app's own store is given Notification Center.
    let chats: ChatReading
    private let notifier: Notifier?
    private let tokens = AzureCLITokenProvider()
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
    private var cancellables: Set<AnyCancellable> = []

    init(
        settings: AppSettings, summarizer: Summarizer = Summarizer(), notifier: Notifier? = nil, mode: Mode = .live,
        chats: ChatReading = .inert
    ) {
        self.settings = settings
        self.summarizer = summarizer
        self.notifier = notifier
        self.mode = mode
        self.chats = chats
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

    var organizations: [String] {
        mode == .demo ? [DemoData.organization] : settings.organizations
    }

    // MARK: Lifecycle

    func start() {
        guard ticker == nil else { return }
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
        // Stops reading Notification Center; what it found stays until Azure DevOps is turned off.
        chatMonitor?.stop()
        chatMonitor = nil
        if let engine {
            Task { await engine.stop() }
        }
        engine = nil
    }

    // MARK: Actions

    func refresh() {
        engine?.refresh()
        if mode == .live, settings.organizations.isEmpty, !settings.hasDiscovered, discovery != .running {
            discoverOrganizations()
        }
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
        AzureDevOps.open(item.url)
    }

    /// Opens what a notification is about (its own comment, rather than the one the panel would open), and marks
    /// the pull request seen like a click in the panel.
    func openFromNotification(key: String?, url: URL) {
        if let item = items.first(where: { $0.key.description == key }) {
            markSeen(item)
        }
        AzureDevOps.open(url)
    }

    private func markSeen(_ item: PRSnapshot) {
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
    /// while you checked the prompt, say, or one in a thread the prompt doesn't quote, still needs you. It leaves the
    /// Needs You of the account the prompt was written with, even if another has signed in to the Azure CLI since.
    func sentToCopilot(_ handOff: CommentHandOff, prompt: String) {
        guard let through = handOff.handedOff(in: prompt) else { return }
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

    func signIn() {
        if problem == .cliNotFound {
            AzureDevOps.open(AzureDevOps.installCLIPage)
            return
        }
        Task {
            let path = await tokens.executablePath
            AzureDevOps.signIn(azPath: path)
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
        // Someone else signed in to the Azure CLI: what they've seen is their own, and the list to compare the next
        // one with, to announce what's new, was the other account's, as was what the panel showed in Answered.
        if mode == .live, let account = snapshot.account, settings.useAccount(account) {
            announced = nil
            answeredInPanel = [:]
            Log.app.info("Signed in to the Azure CLI as another account")
        }
        state = snapshot
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
                now: now, options: options
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
            if let newProblem { Log.app.error("\(newProblem.message, privacy: .public)") }
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
                let firstLoaded = state.firstLoaded
                let startedAt = self.startedAt
                let notes = NotificationPlanner.plan(previous: announced, current: sorted) { item in
                    // An organization added later starts from when it was first read.
                    max(startedAt, firstLoaded[item.key.organization] ?? .distantFuture)
                }
                .filter { delivered.insert($0.id).inserted }
                if !notes.isEmpty {
                    Log.app.info("Announcing \(notes.count) update(s)")
                    notifier.post(notes.map { note in
                        var info: [String: String] = [:]
                        if let url = note.url { info["url"] = url.absoluteString }
                        if let key = note.key { info["pullRequest"] = key.description }
                        return BriefBarNotification(
                            id: note.id, source: .azureDevOps, title: note.title, subtitle: note.subtitle, body: note.body,
                            thread: note.url?.absoluteString ?? "azure-devops", userInfo: info
                        )
                    })
                }
            }
            announced = sorted
        }
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

    /// What Copilot can do with a pull request now (`PullRequestTasks.actions`): Push & Reply once a task that changed
    /// code has finished, in its session.
    func copilotActions(for item: PRSnapshot, continuable: CopilotRun?) -> [PullRequestAction] {
        guard let record = record(for: item.key) else { return [] }
        let canShip = continuable.map { $0.action?.changesCode == true && $0.ended == .finished } ?? false
        return PullRequestTasks.actions(for: record, canShip: canShip)
    }

    /// Writes the prompt for what Copilot should do with a pull request, then opens the composer with it: for a failed
    /// build, once each failed build's errors have been read.
    func composeCopilot(_ action: PullRequestAction, for item: PRSnapshot, copilot: CopilotTasksStore) {
        guard let record = record(for: item.key) else { return }
        let pr = record.pullRequest
        let task = TaskPullRequest(
            organization: pr.key.organization, project: pr.projectName, repository: pr.repositoryName, id: pr.key.number,
            title: pr.title, url: pr.webURL, sourceBranch: pr.sourceBranch, targetBranch: pr.targetBranch,
            projectId: pr.projectId, repositoryId: pr.repositoryId
        )
        let client = mode == .live ? client : nil
        let handOff = commentHandOff(action, for: record)
        Task {
            let prompt = await PullRequestTasks.prompt(action, for: record, client: client)
            copilot.compose(task, action: action, prompt: prompt, handOff: handOff)
        }
    }

    /// What a task takes off Needs You once you send it: for Fix Comments and Push & Reply on your pull request, the comments
    /// that wait on you as the prompt is written from `record`, not as they are when you send it, for the account signed in
    /// now.
    func commentHandOff(_ action: PullRequestAction, for record: PRRecord) -> CommentHandOff? {
        guard action.takesCareOfComments, record.role == .author else { return nil }
        return CommentHandOff(record, dismissedCutoff: settings.dismissedCutoff(for: record.id), account: settings.account)
    }
}
