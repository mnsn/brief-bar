import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation

extension AzureDevOpsCommandLine {
    /// `--mcp`: Azure DevOps for agents. They read what the app shows, with its settings and what you've seen in it,
    /// and change only which pull requests you watch and which pipelines you pin. The demo keeps those in memory.
    package static func mcp(_ options: CommandLineOptions) -> MCPSource? {
        let demoStages = options.demoStages
        let options = Options(options)
        let defaults = options.demo ? MemoryDefaults() : appDefaults ?? MemoryDefaults()
        let reader = AzureDevOpsReader(
            demo: options.demo, organizations: options.organizations, defaults: defaults, demoStages: demoStages
        )
        return AzureDevOpsAgent(reader: reader).source
    }
}

/// What `--mcp` reads from Azure DevOps, as the app shows it. One engine reads the pull requests for the whole session,
/// again only when a tool needs them and what it read is a minute old, as the app does at its most often: an agent's
/// calls one after another share one read. A read that failed in a way you can fix, by signing in to the Azure CLI, say,
/// isn't kept; one that read other organizations is, even when signing in to a directory would read the rest. Each
/// read runs on its own, so a call the agent cancels doesn't cut short what the next one reads.
actor AzureDevOpsReader {
    static let freshFor: TimeInterval = 60

    let demo: Bool
    /// The app's settings, or the demo's, in memory.
    private let defaults: UserDefaults
    /// `--org`, instead of the app's organizations.
    private let named: [String]
    /// Nil for the demo, which reads nothing.
    nonisolated let client: ADOClient?
    private var engine: PulseEngine?
    /// Your organizations with pull requests, found once when the app has none chosen.
    private var discovered: [String]?
    /// Your organizations discovery couldn't look in, for want of a sign-in to their directory, or as they failed: looked in
    /// again at most once a minute, so that signing in there finds yours there.
    private var discoveryPending: [String] = []
    /// When the pending ones were last looked in.
    private var pendingLookedAt: Date?
    private var discoveryProblem: String?
    private var readAt: Date?
    /// The read under way, which says whether what it read is worth keeping.
    private var reading: Task<Bool, Never>?
    private var pipelinesRead: (at: Date, pinned: [PipelineRef], snapshot: PipelinesSnapshot)?
    private var pipelinesLoad: (pinned: [PipelineRef], task: Task<PipelinesSnapshot, Never>)?
    private var sprintRead: (at: Date, configuration: SprintEngine.Configuration, snapshot: SprintSnapshot)?
    private var sprintLoad: (configuration: SprintEngine.Configuration, task: Task<SprintSnapshot, Never>)?
    /// Where the Copilot app keeps its files, in tests; `AppSessions.home()` otherwise.
    private let appHome: URL?
    /// Tells the app its settings changed.
    private let announce: @Sendable () -> Void
    /// What sessions set through the demo's `pull_request_stage`, which it keeps in memory.
    private let demoStages: DemoSessionStages?

    init(
        demo: Bool, organizations: [String], defaults: UserDefaults, client: ADOClient? = nil, appHome: URL? = nil,
        announce: @escaping @Sendable () -> Void = AgentChanges.post, demoStages: DemoSessionStages? = nil
    ) {
        self.demo = demo
        named = organizations
        self.defaults = defaults
        self.client = demo ? nil : client ?? ADOClient(tokens: AzureDevOpsCommandLine.tokens(defaults))
        self.appHome = appHome
        self.announce = announce
        self.demoStages = demoStages
    }

    // MARK: Pull requests

    struct PullRequests: Sendable {
        /// Every pull request read, the ones Done no longer lists included, for their details.
        var records: [PRRecord]
        /// As the app lists them, in its order.
        var items: [PRSnapshot]
        var problem: String?
        /// The app counts To Review in the menu bar.
        var showToReview: Bool
        /// The pull requests you watch that are closed, or that you can't read.
        var closedLinks: Set<PRKey> = []
        /// The account they were read with, whose stages the user set apply; none in the demo.
        var account: String?
        /// When what's listed of each was read (`PulseSnapshot.readTimes`, `StageFacts.readAt`).
        var readAt: [PRKey: Date] = [:]
    }

    /// - Parameter freshFor: how old what it read can be, to share it: a minute (`freshFor`), as the app reads at its most
    ///   often, unless a tool needs it newer.
    func pullRequests(now: Date = Date(), freshFor: TimeInterval = AzureDevOpsReader.freshFor) async -> PullRequests {
        let watched = watchedKeys
        if demo {
            var snapshot = DemoData.snapshot(now: now)
            snapshot.records = snapshot.records.map { watched.contains($0.id) ? $0.watched() : $0 }
            let items = AzureDevOpsCommandLine.resolve(snapshot, seen: DemoData.seenState(now: now), options: ClassifierOptions(), now: now)
            return PullRequests(records: snapshot.records, items: items, problem: nil, showToReview: false, readAt: snapshot.readTimes)
        }
        await readIfStale(now: now, freshFor: freshFor)
        let showToReview = defaults.bool(forKey: SettingsKey.showToReview)
        guard let engine else {
            return PullRequests(records: [], items: [], problem: discoveryProblem, showToReview: showToReview)
        }
        var snapshot = await engine.currentSnapshot()
        snapshot.records = snapshot.records.map { watched.contains($0.id) ? $0.watched() : $0 }
        let seen = AzureDevOpsCommandLine.seenBook(defaults).state(for: snapshot.account)
        let items = AzureDevOpsCommandLine.resolve(snapshot, seen: seen, options: AzureDevOpsCommandLine.classifierOptions(defaults), now: now)
        var problem = snapshot.problem.map(Self.text(of:))
        if snapshot.organizations.isEmpty, let discoveryProblem { problem = discoveryProblem }
        return PullRequests(
            records: snapshot.records, items: items, problem: problem, showToReview: showToReview, closedLinks: snapshot.closedLinks,
            account: snapshot.account, readAt: snapshot.readTimes
        )
    }

    /// Whether Pull Request Order is on, as the app keeps it: the demo's always is.
    var ordersPullRequests: Bool { demo || PullRequestOrderSetting.isOn(in: defaults) }

    /// What Pull Request Order keeps, for the stages agents are told, while it's on; nil while it's off. The demo's is made
    /// up, as the app's demo's is (`DemoPullRequestOrder`).
    func orderKept(now: Date) -> OrderKept? {
        if demo {
            return OrderKept(
                orders: DemoPullRequestOrder.orders(now: now), evidence: DemoPullRequestOrder.evidence(now: now),
                focus: DemoPullRequestOrder.focus, changes: DemoPullRequestOrder.changes(now: now), marks: StageMarks(),
                sessionStages: demoStages?.stages ?? SessionStages(), demoMarks: DemoPullRequestOrder.stages(now: now),
                demoSessionMarks: DemoPullRequestOrder.sessionStages(now: now)
            )
        }
        guard PullRequestOrderSetting.isOn(in: defaults) else { return nil }
        return OrderKept(
            orders: DeclaredOrders.load(from: defaults), evidence: OrderEvidence.load(from: defaults),
            focus: OrderFocus.load(from: defaults), changes: OrderChanges.load(from: defaults), marks: StageMarks.load(from: defaults),
            sessionStages: SessionStages.load(from: defaults, now: now), picks: UpNextPicks.Kept.load(from: defaults)
        )
    }

    /// The branch a pull request merges into, as Azure DevOps says now, read with one request each time, rather than as the
    /// lists read it, up to a minute before (`freshFor`): for `pull_request`, which an agent checks it with right before it
    /// pushes, as Push & Reply's prompt has it. Nil for the demo, which reads nothing.
    nonisolated func targetNow(of key: PRKey) async -> Result<String, any Error>? {
        guard let client else { return nil }
        do {
            let dto = try await client.get(ADOEndpoint.pullRequest(organization: key.organization, id: key.number), as: ADOPullRequest.self)
            let target = PullRequest(organization: key.organization, dto).targetBranch
            return target.isEmpty ? .failure(NoTarget()) : .success(target)
        } catch {
            return .failure(error)
        }
    }

    /// A pull request as Azure DevOps says now, read with one request, rather than as the lists read it, up to a minute
    /// before: for the stage a session sets, which keeps its votes and its commit (`StageRules.mark`). Nil for the demo,
    /// which reads nothing, or when it can't be read.
    nonisolated func pullRequestNow(_ key: PRKey) async -> PullRequest? {
        guard let client else { return nil }
        let endpoint = ADOEndpoint.pullRequest(organization: key.organization, id: key.number)
        guard let dto = try? await client.get(endpoint, as: ADOPullRequest.self) else { return nil }
        return PullRequest(organization: key.organization, dto)
    }

    /// Azure DevOps named no branch the pull request merges into.
    struct NoTarget: Error, LocalizedError {
        var errorDescription: String? { "Azure DevOps didn't say." }
    }

    /// A problem, as an agent is told it: with what to run when signing in fixes it, since the app's Sign In button isn't
    /// there, and when to ask again, since a read that other organizations' pull requests came from is kept for a minute.
    /// Only this says a directory's ID, which signing in to it needs.
    static func text(of problem: PulseProblem) -> String {
        guard let command = problem.signInCommand else { return problem.message }
        return "\(problem.message) Run \(command), then ask again\(keeps(problem) ? " in a minute" : "")."
    }

    /// An error reading something on its own, as an agent is told it: for an organization in a directory the Azure CLI
    /// isn't signed in to, which one, and what to run; when signed out, what to run, in your directory when it's that one
    /// that wants you to sign in again.
    static func describe(_ error: Error) -> String {
        guard let error = error as? ADOError else { return error.localizedDescription }
        if case .auth(.signedOut) = error, let command = PulseProblem.from(error).signInCommand {
            return "You're signed out of the Azure CLI. Run \(command), then ask again."
        }
        guard case .otherDirectory(let organization, let tenant) = error else { return error.description }
        return "\(organization) is in a directory your Azure CLI isn't signed in to. "
            + "Run az login --tenant \(tenant) --allow-no-subscriptions, then ask again."
    }

    /// Reads unless what it read is fresh; a call that comes while it reads waits for that read.
    private func readIfStale(now: Date, freshFor: TimeInterval = AzureDevOpsReader.freshFor) async {
        if let reading {
            _ = await reading.value
            return
        }
        if let readAt, now.timeIntervalSince(readAt) < freshFor { return }
        let task = Task { await read(now: now) }
        reading = task
        let keep = await task.value
        reading = nil
        // As of when it was asked for: a read that took a while is that much older.
        readAt = keep ? now : nil
    }

    /// Whether what was read stays for a minute: unless it failed in a way that you can fix, by signing in to the Azure
    /// CLI, say, or that a moment fixes, such as going offline. Some organizations failing still leaves the rest, even
    /// ones that signing in to their directory would read, and Azure DevOps asking to slow down is a reason not to read
    /// again.
    static func keeps(_ problem: PulseProblem?) -> Bool {
        switch problem {
        case nil, .someOrganizations?, .otherDirectory?, .throttled?: return true
        default: return false
        }
    }

    /// Returns whether what it read is worth keeping.
    private func read(now: Date) async -> Bool {
        guard let client else { return false }
        let organizations = await organizations(client: client, now: now)
        let options = AzureDevOpsCommandLine.classifierOptions(defaults)
        let configuration = PulseEngine.Configuration(
            organizations: organizations, keepDoneFor: options.keepDoneFor,
            followMerges: defaults.object(forKey: SettingsKey.followMerges) as? Bool ?? true
        )
        let engine = self.engine ?? PulseEngine(client: client, configuration: configuration) { _ in }
        self.engine = engine
        await engine.setConfiguration(configuration)
        await engine.setLinkedPullRequests(watchedKeys)
        await engine.refreshNow()
        return Self.keeps(await engine.currentSnapshot().problem)
    }

    /// `--org`, the app's organizations, or with none chosen yet, the ones where you have pull requests: those in a
    /// directory the Azure CLI isn't signed in to are looked in again at most once a minute, whichever call asks.
    private func organizations(client: ADOClient, now: Date) async -> [String] {
        if !named.isEmpty { return named }
        let chosen = defaults.stringArray(forKey: SettingsKey.organizations) ?? []
        if !chosen.isEmpty { return chosen }
        if var discovered {
            guard !discoveryPending.isEmpty, now.timeIntervalSince(pendingLookedAt ?? .distantPast) >= Self.freshFor else {
                return discovered
            }
            pendingLookedAt = now
            let probe = await OrganizationDiscovery.probe(discoveryPending, client: client)
            let new = probe.withPullRequests.filter { name in
                !discovered.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            discovered += new
            discoveryPending = probe.elsewhere + probe.failures.keys.sorted()
            self.discovered = discovered
            return discovered
        }
        do {
            let found = try await OrganizationDiscovery.discover(client: client)
            discovered = found.withPullRequests
            discoveryPending = found.elsewhere
            pendingLookedAt = now
            discoveryProblem = nil
            return found.withPullRequests
        } catch {
            discoveryProblem = "Couldn't find your organizations: \(Self.describe(error))"
            return []
        }
    }

    // MARK: Pipelines and the sprint

    /// The pinned pipelines, read again when they're a minute old or you pin others.
    func pinnedStatuses(now: Date = Date()) async -> (statuses: [PipelineStatus], problem: String?) {
        if demo { return (DemoData.pipelines(now: now), nil) }
        let pinned = pinnedPipelines
        guard let client, !pinned.isEmpty else { return ([], nil) }
        if let read = pipelinesRead, read.pinned == pinned, now.timeIntervalSince(read.at) < Self.freshFor {
            return (read.snapshot.statuses, read.snapshot.problem.map(Self.text(of:)))
        }
        let task: Task<PipelinesSnapshot, Never>
        if let load = pipelinesLoad, load.pinned == pinned {
            task = load.task
        } else {
            task = Task { await PipelinesEngine.loadOnce(client: client, configuration: PipelinesEngine.Configuration(pipelines: pinned)) }
            pipelinesLoad = (pinned, task)
        }
        let snapshot = await task.value
        if pipelinesLoad?.task == task { pipelinesLoad = nil }
        if Self.keeps(snapshot.problem) { pipelinesRead = (now, pinned, snapshot) }
        return (snapshot.statuses, snapshot.problem.map(Self.text(of:)))
    }

    /// The sprint of the app's team, or with none chosen, of the first of yours with one going on today.
    func sprint(now: Date = Date()) async -> (board: SprintBoard?, problem: String?) {
        if demo { return (DemoData.sprintBoard(now: now), nil) }
        guard let client else { return (nil, nil) }
        let team = defaults.data(forKey: SettingsKey.sprintTeam).flatMap { try? JSONDecoder().decode(TeamRef.self, from: $0) }
        let configuration = SprintEngine.Configuration(organizations: await organizations(client: client, now: now), team: team)
        if let read = sprintRead, read.configuration == configuration, now.timeIntervalSince(read.at) < Self.freshFor {
            return (read.snapshot.board, read.snapshot.problem.map(Self.text(of:)))
        }
        let task: Task<SprintSnapshot, Never>
        if let load = sprintLoad, load.configuration == configuration {
            task = load.task
        } else {
            task = Task { await SprintEngine.loadOnce(client: client, configuration: configuration, now: now) }
            sprintLoad = (configuration, task)
        }
        let snapshot = await task.value
        if sprintLoad?.task == task { sprintLoad = nil }
        if Self.keeps(snapshot.problem) { sprintRead = (now, configuration, snapshot) }
        return (snapshot.board, snapshot.problem.map(Self.text(of:)))
    }

    // MARK: Settings

    var watchedPullRequests: [PullRequestLink] {
        defaults.data(forKey: SettingsKey.watchedPullRequests).flatMap { try? JSONDecoder().decode([PullRequestLink].self, from: $0) } ?? []
    }

    private var watchedKeys: Set<PRKey> { Set(watchedPullRequests.map(\.key)) }

    var pinnedPipelines: [PipelineRef] {
        defaults.data(forKey: SettingsKey.pinnedPipelines).flatMap { try? JSONDecoder().decode([PipelineRef].self, from: $0) } ?? []
    }

    /// Watches a pull request, as Watch a Pull Request… does, to be read with the next tool that needs it. False when
    /// it's watched already.
    func watch(_ link: PullRequestLink) -> Bool {
        var links = watchedPullRequests
        guard !links.contains(where: { $0.key == link.key }) else { return false }
        links.append(link)
        store(links, forKey: SettingsKey.watchedPullRequests)
        readAt = nil
        return true
    }

    /// Stops watching the pull requests, and returns the ones it did watch.
    func unwatch(_ match: (PullRequestLink) -> Bool) -> [PullRequestLink] {
        var links = watchedPullRequests
        let removed = links.filter(match)
        guard !removed.isEmpty else { return [] }
        links.removeAll(where: match)
        store(links, forKey: SettingsKey.watchedPullRequests)
        return removed
    }

    /// Pins a pipeline, last, as the Pipelines page does. False when it's pinned already.
    func pin(_ pipeline: PipelineRef) -> Bool {
        var pinned = pinnedPipelines
        guard !pinned.contains(where: { $0.id == pipeline.id }) else { return false }
        pinned.append(pipeline)
        store(pinned, forKey: SettingsKey.pinnedPipelines)
        return true
    }

    func unpin(_ pipeline: PipelineRef) {
        store(pinnedPipelines.filter { $0.id != pipeline.id }, forKey: SettingsKey.pinnedPipelines)
    }

    /// Saves as the app does, and tells the app, which reads it again at once.
    private func store<T: Encodable>(_ value: T, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
        if !demo { announce() }
    }

    // MARK: Copilot tasks

    var sendsToCopilot: Bool { demo || defaults.bool(forKey: SettingsKey.copilotEnabled) }

    /// The titles of the sprint's work items, once the sprint has been read: the tasks sent to Copilot keep none.
    func workItemTitles(now: Date = Date()) -> [Int: String] {
        guard let board = demo ? DemoData.sprintBoard(now: now) : sprintRead?.snapshot.board else { return [:] }
        var titles: [Int: String] = [:]
        for row in board.rows {
            if let parent = row.parent { titles[parent.id] = parent.title }
            for task in row.tasks { titles[task.id] = task.title }
        }
        return titles
    }

    /// The tasks sent to Copilot, newest first, each with how it's going, from whether its process runs and its log.
    func copilotTasks(now: Date = Date()) async -> [CopilotTaskEntry] {
        if demo { return CopilotTaskEntry.demo(now: now) }
        let runs = (defaults.data(forKey: SettingsKey.copilotRuns).flatMap { try? JSONDecoder().decode([CopilotRun].self, from: $0) } ?? [])
            .filter(\.isValid)
        let home = CopilotCLI.home(environment: Attribution.environment)
        let monitor = RunMonitor()
        var entries: [CopilotTaskEntry] = []
        for run in runs {
            let log = await monitor.log(id: run.id, events: run.events(in: home))
            let isRunning = run.ended == nil && DetachedProgram.isRunning(run.process)
            var status = RunStatus.derive(
                log: log, startedAt: run.launchedAt, isRunning: isRunning, exitStatus: nil,
                stoppedByYou: run.stoppedByYou == true, output: nil
            )
            if let ended = run.ended { status.phase = ended }
            entries.append(CopilotTaskEntry(
                id: run.id, workItem: run.workItem, onPullRequest: run.onPullRequest, action: run.action, options: run.options,
                startedAt: run.startedAt, status: status, pullRequest: run.pullRequest, run: run
            ))
        }
        return entries.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: The session a pull request's work goes to

    /// How often the app's Send Work to Copilot is read again while the session a pull request's work goes to is found.
    static let recheckEvery = Duration.milliseconds(100)

    /// The Copilot session BriefBar sends an open pull request's work to, as its details show it (`PullRequestSession`,
    /// through `CopilotTasksStore.pullRequestSession`), with the session you chose for it in the app's settings, and
    /// whether the Copilot app has it; or that its work goes to a new session, as you chose; or the sessions BriefBar asks
    /// you to choose from; or, when none goes with it, one that may have opened it. Only while Send Work to Copilot is on,
    /// which is when the app reads sessions, and never in the demo, whose window reads none. Turned off meanwhile, it reads
    /// nothing more of Copilot's, as the window's search stops, and names none. Nil when there's nothing to say.
    /// - Parameter tasks: the tasks sent to Copilot, as `copilotTasks` found them.
    func session(for record: PRRecord, tasks: [CopilotTaskEntry], now: Date = Date()) async -> AgentSession? {
        guard !demo, record.pullRequest.status == .active, sendsToCopilot else { return nil }
        let home = appHome ?? CopilotCLI.home(environment: Attribution.environment)
        var runs: [CopilotRun] = []
        for task in tasks {
            guard var run = task.run else { continue }
            // As it stands: one whose log says it ended has, though the app may not have heard yet; and the pull request
            // it opened meanwhile, as while BriefBar was quit, is found as the app finds it when it next looks
            // (`CopilotTasksStore.refresh`): from what Copilot said last, else from what it printed.
            if run.ended == nil, !task.status.phase.isActive { run.ended = task.status.phase }
            if run.ended != nil, run.pullRequest == nil {
                // Turned off meanwhile, nothing more of Copilot's is read.
                guard sendsToCopilot else { return nil }
                let (events, output) = (run.events(in: home), run.output(in: CopilotTasksStore.outputFolder))
                let launchedAt = run.launchedAt
                run.pullRequest = await Task.detached {
                    RunTranscript.openedPullRequest(events: events, printed: nil, since: launchedAt)
                        ?? LocalFile.tail(of: output, maxBytes: 8_192)
                        .flatMap { RunTranscript.pullRequest(in: String(decoding: $0, as: UTF8.self)) }
                }.value
            }
            runs.append(run)
        }
        guard sendsToCopilot else { return nil }
        let pullRequest = PullRequestTasks.task(for: record)
        let chosen = PullRequestSessionChoice.load(from: defaults, now: now)
        let known = await links(of: record.id.linkRef, now: now)
        // Again after that wait, which may read Copilot's list: it may have been turned off meanwhile.
        guard sendsToCopilot else { return nil }
        let store = await Self.store(
            for: pullRequest, runs: runs, chosen: chosen, links: known.graph, told: known.told, workItems: workItemTitles(now: now),
            appHome: appHome
        )
        // The store has a copy of the app's setting: it stops reading once the app's is off, as the app's store does.
        let watch = Task {
            while !Task.isCancelled, sendsToCopilot {
                try? await Task.sleep(for: Self.recheckEvery)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { store.settings.copilotEnabled = false }
        }
        let found = await store.pullRequestSession(for: pullRequest, createdAt: record.pullRequest.createdAt)
        watch.cancel()
        guard let found, sendsToCopilot else { return nil }
        switch found.pick {
        case .session(let choice, let basis):
            var isInApp = choice.appSession != nil || choice.run?.isAppSession == true
            if !isInApp {
                // A task's session that you opened in the app, which its database lists now, whether the app has it open or not.
                let home = await MainActor.run { store.appHome }
                isInApp = await Task.detached { ((try? AppSessions.load(home: home)) ?? []).contains { $0.id == choice.id } }.value
            }
            // Once more, after the last read: turned off meanwhile, it names none.
            guard sendsToCopilot else { return nil }
            return .session(SuggestedSession(choice: choice, basis: basis, isInApp: isInApp))
        case .newSession(chosenByYou: true):
            return .newSession
        case .newSession(chosenByYou: false):
            return found.guess.map(AgentSession.guess)
        case .ask(let choices):
            return .undecided(choices)
        }
    }

    /// What Show Links knows of a pull request's sessions while it's on, as the app's settings keep it: the links you made;
    /// and, with Updates from Copilot Sessions on too, what sessions told BriefBar they work on and opened, as Show Links
    /// shows it, for the sessions Copilot's list has now (`MCPRelated.sessionListing`), which is asked, since it reads
    /// every session, only once a session told BriefBar something of this pull request; both settings are checked again
    /// after that wait, as either may have been turned off meanwhile. The ones Copilot records and those by branch, the
    /// app's database says (`CopilotTasksStore.reasons`).
    private func links(of pullRequest: ItemRef, now: Date) async -> (graph: LinkGraph, told: SessionReports) {
        guard defaults.bool(forKey: Links.enabledKey) else { return (LinkGraph(), SessionReports()) }
        var edits = LinkEdits.load(from: defaults)
        edits.forget(before: now.addingTimeInterval(-LinkEdits.lifetime))
        guard SessionUpdatesSetting.isOn(in: defaults) else { return (LinkGraph(edits: edits), SessionReports()) }
        let told = SessionReports.load(from: defaults, now: now)
        guard told.reports.values.contains(where: { $0.workingOn.contains(pullRequest) || $0.opened[pullRequest] != nil }) else {
            return (LinkGraph(edits: edits), SessionReports())
        }
        let listing = await MCPRelated.sessionListing()
        guard defaults.bool(forKey: Links.enabledKey) else { return (LinkGraph(), SessionReports()) }
        guard let listing, SessionUpdatesSetting.isOn(in: defaults) else { return (LinkGraph(edits: edits), SessionReports()) }
        return (LinkGraph(links: told.links(listing, now: now), edits: edits), told)
    }

    /// A store to find the session with, as the window's store does, that reads as the app's does: over these tasks and the
    /// sessions you chose for pull requests' work, in memory, so nothing it does is saved; with the environment `--mcp`
    /// started with, rather than your login shell's, which it would have to run; and with what Show Links knows, and when
    /// each session that told BriefBar it's working on something began to say so. It starts and follows nothing.
    @MainActor
    private static func store(
        for pullRequest: TaskPullRequest, runs: [CopilotRun], chosen: [PullRequestSessionChoice], links: LinkGraph,
        told: SessionReports, workItems: [Int: String], appHome: URL?
    ) -> CopilotTasksStore {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        settings.copilotRuns = runs
        settings.copilotPullRequestSessions = chosen
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        store.appHomeForTests = appHome
        // The Copilot CLI's files are where the test put the app's.
        store.useEnvironment(appHome.map { ["COPILOT_HOME": $0.path] } ?? Attribution.environment)
        store.title = { workItems[$0.id] }
        store.pullRequestTitle = { $0.matches(organization: pullRequest.organization, id: pullRequest.id) ? pullRequest.title : nil }
        store.linkedSessions = { ref in
            links.visibleConnections(of: ref).filter { $0.item.kind == .session }.map {
                LinkedSession(
                    id: $0.item.id, origins: $0.origins, isThrough: $0.via != nil,
                    began: $0.origins.contains(.session) ? told[$0.item]?.workingOnBegan[ref] : nil
                )
            }
        }
        return store
    }

    // MARK: The work that goes with pull requests

    /// A pull request's work items, each with the one it's under, such as a task's story, as `pull_request` tells them:
    /// read as it answers (`PullRequestWork.read`), or the demo's; or why they couldn't be read.
    func work(of pullRequest: PullRequest, now: Date = Date()) async -> (work: [LinkedWork]?, problem: String?) {
        if demo {
            let links = DemoData.workLinks(now: now)
            let known = Self.demoWorkItems(now: now)
            let items = (links.workItemsOfPullRequests[pullRequest.key] ?? []).compactMap { known[$0] }
            return (PullRequestWork.linked(items, known: known), nil)
        }
        guard let client else { return (nil, "BriefBar can't read Azure DevOps here.") }
        do {
            return (try await PullRequestWork.read(pullRequest, client: client), nil)
        } catch {
            return (nil, Self.describe(error))
        }
    }

    /// The pull requests linked to each of a work item's tasks, as `work_item` lists them: one GET for all of them, or the
    /// demo's; or why they couldn't be read.
    func pullRequests(ofTasks tasks: [WorkItem], now: Date = Date()) async -> (found: [Int: [PRKey]], problem: String?) {
        guard let organization = tasks.first?.organization else { return ([:], nil) }
        let ids = tasks.filter { $0.organization.caseInsensitiveCompare(organization) == .orderedSame }.map(\.id)
        if demo {
            let links = DemoData.workLinks(now: now).pullRequestsOfWorkItems
            return (Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                links[WorkItemKey(organization, id)].map { (id, $0) }
            }), nil)
        }
        guard let client else { return ([:], "BriefBar can't read Azure DevOps here.") }
        do {
            return (try await PullRequestWork.pullRequests(of: ids, in: organization, client: client), nil)
        } catch {
            return ([:], Self.describe(error))
        }
    }

    /// Every made-up work item, by its ID: the sprint's, and those linked to its pull requests with what they're under.
    static func demoWorkItems(now: Date) -> [Int: WorkItem] {
        var known: [Int: WorkItem] = [:]
        for row in DemoData.sprintBoard(now: now).rows {
            for item in [row.parent].compactMap({ $0 }) + row.tasks { known[item.id] = item }
        }
        let links = DemoData.workLinks(now: now)
        for (key, item) in links.workItems.merging(links.parents, uniquingKeysWith: { first, _ in first }) where known[key.id] == nil {
            known[key.id] = item
        }
        return known
    }

    // MARK: A work item

    /// A work item, as the `work_item` tool tells it: its details, where it is in the sprint, and the pull requests it
    /// links to, yours as your lists have them and the others as they say themselves.
    struct WorkItemRead: Sendable {
        var item: WorkItem
        var details: WorkItemDetails?
        /// Its tasks in the sprint, in backlog order, for a story or a bug; or its children, as its details have them, for
        /// one that isn't in the sprint.
        var tasks: [WorkItem]
        var tasksAreInSprint: Bool
        /// The pull requests linked to each of its tasks, by the task's ID.
        var tasksPullRequests: [Int: [PRKey]] = [:]
        /// Why they couldn't be read, so that no task looks as if none is linked to it.
        var tasksPullRequestsProblem: String?
        /// The story or bug it's a task of.
        var parent: WorkItem?
        /// You, in the sprint's organization, to mark your tasks.
        var me: String?
        /// The sprint going on, with its dates, to say when the work item's ends.
        var sprint: Sprint?
        var pullRequests: [PRKey]
        /// Your lists, which have yours, the ones you review and the ones you watch.
        var lists: PullRequests
        /// The others, read for this, and those that couldn't be.
        var others: LinkEngine.Lookups

        /// One of its pull requests, as your lists have it or as it was read for this; nil when it couldn't be read.
        func pullRequest(_ key: PRKey) -> PullRequest? {
            lists.records.first { $0.id.linkRef == key.linkRef }?.pullRequest
                ?? others.read.first { $0.key.linkRef == key.linkRef }?.value
        }
    }

    /// Reads a work item by its number, in the organization its link names, or else the sprint's or one of yours, with the
    /// GET requests its details make, one for each pull request it links to that your lists don't have, and one for the
    /// pull requests of its tasks.
    func workItem(_ id: Int, organization: String?, now: Date = Date()) async throws -> WorkItemRead {
        let board = await sprint(now: now).board
        let rows = board?.rows ?? []
        func isIt(_ item: WorkItem) -> Bool {
            item.id == id && (organization.map { item.organization.caseInsensitiveCompare($0) == .orderedSame } ?? true)
        }
        let row = rows.first { $0.parent.map(isIt) == true }
        let parentRow = row == nil ? rows.first { $0.tasks.contains(where: isIt) } : nil
        let inSprint = row?.parent ?? parentRow?.tasks.first(where: isIt)
        let lists = await pullRequests(now: now)
        // With the pull requests of each of its tasks.
        func withTasksPullRequests(_ read: WorkItemRead) async -> WorkItemRead {
            var read = read
            (read.tasksPullRequests, read.tasksPullRequestsProblem) = await pullRequests(ofTasks: read.tasks, now: now)
            return read
        }
        func told(_ details: WorkItemDetails, others: LinkEngine.Lookups) -> WorkItemRead {
            // In backlog order, as a story's mission lists their pull requests.
            let tasks = (row?.tasks ?? details.children.compactMap(\.item)).sorted(by: WorkItem.ordered)
            return WorkItemRead(
                item: WorkItemDetailsStore.newest(inSprint, details.item) ?? details.item, details: details,
                tasks: tasks, tasksAreInSprint: row != nil,
                parent: parentRow?.parent ?? details.parent?.item, me: board?.me, sprint: board?.sprint,
                pullRequests: details.pullRequests, lists: lists, others: others
            )
        }
        if demo {
            let organization = inSprint?.organization ?? organization ?? DemoData.organization
            guard let details = DemoData.workItemDetails(organization: organization, id: id, now: now) else {
                throw MCPToolError("The demo's sprint has no work item \(id).")
            }
            return await withTasksPullRequests(told(details, others: LinkEngine.Lookups(read: DemoData.workLinks(now: now).pullRequests)))
        }
        guard let client else { throw MCPToolError("BriefBar can't read Azure DevOps here.") }
        var organizations = organization.map { [$0] } ?? inSprint.map { [$0.organization] } ?? []
        if organizations.isEmpty { organizations = await self.organizations(client: client, now: now) }
        if organizations.isEmpty { throw MCPToolError(discoveryProblem ?? "BriefBar doesn't know your Azure DevOps organizations.") }
        // One in a directory to sign in to may have it, as may the others: it's said only if none of them does.
        var elsewhere: ADOError?
        for organization in organizations {
            let item = inSprint ?? WorkItem(
                id: id, organization: organization, project: "", type: "Work Item", title: "Work item \(id)", state: "", category: .proposed
            )
            let read = await WorkItemDetailsStore.read(item, client: client)
            switch read.result {
            case .success(let details):
                return await withTasksPullRequests(told(details, others: await lookUp(details.pullRequests, notIn: lists, client: client)))
            case .failure(let error):
                // Another of your organizations may have it.
                if case .notFound = error, organizations.count > 1 { continue }
                if case .auth(.signedOut) = error { throw MCPToolError(AzureDevOpsReader.describe(error)) }
                if case .otherDirectory = error {
                    elsewhere = elsewhere ?? error
                    continue
                }
                throw MCPToolError(WorkItemDetailsStore.message(for: error))
            }
        }
        if let elsewhere { throw MCPToolError(AzureDevOpsReader.describe(elsewhere)) }
        throw MCPToolError("None of your organizations has a work item \(id) you can see: give its link.")
    }

    /// The pull requests your lists don't have, as Show Links reads them.
    private func lookUp(_ keys: [PRKey], notIn lists: PullRequests, client: ADOClient) async -> LinkEngine.Lookups {
        let listed = Set(lists.records.map(\.id.linkRef))
        let others = Set(keys.filter { !listed.contains($0.linkRef) })
        return await LinkEngine.lookUp(others.sorted(), client: client)
    }
}

/// The session BriefBar sends a pull request's work to, for `pull_request` (`AzureDevOpsReader.session`).
struct SuggestedSession: Sendable, Equatable {
    var choice: SessionChoice
    /// Why it's the pull request's.
    var basis: PullRequestSession.Basis
    /// The Copilot app has it, so an agent there can send it a message: one of the app's own sessions, one a task of
    /// BriefBar's went on with, or a task's that you opened there, which the app's database lists. Not whether it's open.
    var isInApp: Bool
}

/// What `pull_request` says of a pull request's Copilot session, as its details show it (`PullRequestSession`).
enum AgentSession: Sendable, Equatable {
    /// The session BriefBar sends its work to.
    case session(SuggestedSession)
    /// You chose a new session for its work.
    case newSession
    /// Two or more go with it as well as each other, the most recently active first: BriefBar asks you which.
    case undecided([SessionChoice])
    /// None goes with it; this one, whose log has a link to it and that was there before it was created, may have opened it.
    case guess(SessionChoice)
}

/// The tools `--mcp` gives agents for Azure DevOps.
struct AzureDevOpsAgent: Sendable {
    let reader: AzureDevOpsReader
    /// This copy of BriefBar, which `pull_request`'s command to wait on one of your pull requests runs (`--wait`).
    var executable = Bundle.main.executablePath ?? AppIdentity.name

    /// How old the lists can be when a session sets the stage of a pull request they don't have, such as one it just
    /// opened, before they're read again for it.
    static let freshForStages: TimeInterval = 10

    var source: MCPSource {
        MCPSource(
            name: "Azure DevOps", tools: tools,
            stages: MCPStages(read: { refs in try await stages(of: refs) }, sessions: { await stageSessions() })
        ) { try await needsYou() }
    }

    /// What `pull_request_stage` reads of these pull requests: what each one's stage is worked out from, as the app's
    /// would be (`PullRequestOrderFacts.stageFacts`), from the lists, read again first when one isn't in them, and as
    /// Azure DevOps says it now, with one request each, so that what would end the stage a session sets is as it is now
    /// (`StageRules.mark`); and the account the lists were read with. One the lists don't have is left out; what it throws
    /// says why it couldn't read them at all.
    func stages(of refs: [ItemRef], now: Date = Date()) async throws -> MCPStages.Read {
        let keys = refs.compactMap { ref in ref.kind == .pullRequest ? ref.number.map { PRKey(ref.scope, $0) } : nil }
        guard !keys.isEmpty else { return MCPStages.Read(account: nil, facts: [:]) }
        var read = await reader.pullRequests(now: now)
        if keys.contains(where: { key in !read.records.contains { $0.id == key } }) {
            read = await reader.pullRequests(now: now, freshFor: Self.freshForStages)
        }
        if read.records.isEmpty, let problem = read.problem { throw MCPToolError(problem) }
        let tasks = await reader.sendsToCopilot ? await reader.copilotTasks(now: now) : []
        var facts: [ItemRef: StageFacts] = [:]
        for key in keys {
            guard var record = read.records.first(where: { $0.id == key }) else { continue }
            if let fresh = await reader.pullRequestNow(key) {
                record.pullRequest.status = fresh.status
                record.pullRequest.isDraft = fresh.isDraft
                record.pullRequest.closedAt = fresh.closedAt
                record.pullRequest.reviewers = fresh.reviewers
                record.pullRequest.sourceCommit = fresh.sourceCommit
            }
            let item = read.items.first { $0.key == key }
            let on = tasks.filter { $0.pullRequestKey == key }
            guard var fact = await PullRequestOrderFacts.stageFacts(record, item: item, tasks: on) else { continue }
            fact.isListed = item != nil
            facts[key.linkRef] = fact
        }
        return MCPStages.Read(account: read.account, facts: facts)
    }

    var tools: [MCPTool] {
        [
            MCPTool(
                name: "pull_requests",
                title: "Pull Requests",
                description: """
                    The user's Azure DevOps pull requests as BriefBar groups them, each with why it's there and its link: \
                    Needs You (new comments, replies, mentions, review requests, votes that want changes, and comments \
                    they've seen that still wait on them), Answered, Failing (failed builds or checks, merge conflicts, a \
                    pipeline that failed after it merged), Ready to Complete, To Review, Waiting, Done and Idle. Theirs, \
                    the ones they review, and the ones they watch.
                    """,
                inputSchema: MCPSchema.object([
                    "group": MCPSchema.string("Only this group", oneOf: PRGroup.allCases.map(\.agentName)),
                ])
            ) { arguments in try await pullRequests(group: arguments["group"]) },
            MCPTool(
                name: "pull_request",
                title: "Pull Request",
                description: """
                    One pull request in detail, by its number or link: where it stands in BriefBar, its branches, the one \
                    it merges into as Azure DevOps says when you ask, its work items and the story each is for, reviewers' \
                    votes, checks and where a failed build failed, merge conflicts, the pipelines after its merge, what's \
                    new for the user and what they've seen that still waits on them, its unresolved \
                    comment threads word for word with their files and lines, what Copilot can do with it, with Pull \
                    Request Order on, its stage and who set it, and, while Send Work to Copilot is on, its session: the \
                    Copilot session BriefBar sends its work to.
                    """,
                inputSchema: MCPSchema.object([
                    "pull_request": MCPSchema.string("Its number, such as 4088, or its link"),
                ], required: ["pull_request"])
            ) { arguments in try await pullRequest(arguments["pull_request"]) },
            MCPTool(
                name: "pull_request_prompt",
                title: "Pull Request Prompt",
                description: """
                    The prompt BriefBar gives Copilot to work on a pull request, with everything it knows for the job: \
                    the comment threads that wait on the user, word for word with their files and lines (fix_comments), \
                    where each failed build failed and its errors (fix_build), the branches that conflict \
                    (resolve_conflicts), what to look at in a review (review), or how to push the changes and answer \
                    the threads (push_and_reply). Follow it to do the work here. pull_request tells which apply.
                    """,
                inputSchema: MCPSchema.object([
                    "pull_request": MCPSchema.string("Its number, such as 4088, or its link"),
                    "action": MCPSchema.string("What to do", oneOf: PullRequestAction.allCases.map(\.agentName)),
                ], required: ["pull_request", "action"])
            ) { arguments in try await prompt(arguments["pull_request"], action: arguments["action"]) },
            MCPTool(
                name: "pipelines",
                title: "Pipelines",
                description: """
                    The pipelines the user pinned in BriefBar, each with its latest run's stages, where it failed and its \
                    recent runs, and the pipelines running after their merged pull requests, such as a deployment \
                    waiting for approval.
                    """
            ) { _ in try await pipelines() },
            MCPTool(
                name: "sprint",
                title: "Sprint",
                description: """
                    The current sprint of the user's team in Azure DevOps: its stories and bugs, each with its tasks, \
                    their states, who has them and the hours left.
                    """,
                inputSchema: MCPSchema.object([
                    "mine": MCPSchema.boolean("Only the user's own stories and tasks"),
                ])
            ) { arguments in try await sprint(mine: arguments["mine"]?.bool ?? false) },
            MCPTool(
                name: "work_item",
                title: "Work Item",
                description: """
                    One work item and what goes with it, by its number or link: where it stands, who has it and who it \
                    waits on, its tasks in backlog order, each with its pull requests, each pull request linked to it in \
                    Azure DevOps with its reviewers' votes, \
                    comments, merge and the pipelines that ran on it, the Copilot sessions on those pull requests with \
                    what Copilot recorded of their work, the work BriefBar sent to Copilot for it, and its description and \
                    latest comments. For what's going on with a story, a bug or a task.
                    """,
                inputSchema: MCPSchema.object([
                    "work_item": MCPSchema.string("Its number, such as 5101, or its link"),
                ], required: ["work_item"])
            ) { arguments in try await workItem(arguments["work_item"]) },
            MCPTool(
                name: "copilot_tasks",
                title: "Copilot Tasks",
                description: """
                    The work BriefBar sent to the Copilot CLI on the user's request: which work item or pull request, \
                    what for, how it's going or how it ended, and its worktree and session.
                    """
            ) { _ in try await copilotTasks() },
            MCPTool(
                name: "watch_pull_request",
                title: "Watch a Pull Request",
                description: """
                    Lists a pull request in BriefBar by its link, though the user isn't on it, as one they review, until it \
                    closes or they stop watching it. It changes nothing in Azure DevOps.
                    """,
                inputSchema: MCPSchema.object([
                    "link": MCPSchema.string("The pull request's link"),
                ], required: ["link"]),
                readOnly: false
            ) { arguments in try await watch(arguments["link"]) },
            MCPTool(
                name: "stop_watching_pull_request",
                title: "Stop Watching a Pull Request",
                description: "Stops listing a pull request that watch_pull_request, or the user, added to BriefBar.",
                inputSchema: MCPSchema.object([
                    "pull_request": MCPSchema.string("Its number, such as 4088, or its link"),
                ], required: ["pull_request"]),
                readOnly: false
            ) { arguments in try await stopWatching(arguments["pull_request"]) },
            MCPTool(
                name: "pin_pipeline",
                title: "Pin a Pipeline",
                description: """
                    Pins a pipeline to BriefBar's Pipelines page by its link, or a run's, which then shows only that \
                    run's branch. It changes nothing in Azure DevOps.
                    """,
                inputSchema: MCPSchema.object([
                    "link": MCPSchema.string("The pipeline's link, or one of its runs'"),
                ], required: ["link"]),
                readOnly: false
            ) { arguments in try await pin(arguments["link"]) },
            MCPTool(
                name: "unpin_pipeline",
                title: "Unpin a Pipeline",
                description: "Takes a pipeline off BriefBar's Pipelines page.",
                inputSchema: MCPSchema.object([
                    "pipeline": MCPSchema.string("Its name, as pipelines shows it, or its link"),
                ], required: ["pipeline"]),
                readOnly: false
            ) { arguments in try await unpin(arguments["pipeline"]) },
        ]
    }

    // MARK: Reading

    func needsYou(now: Date = Date()) async throws -> String? {
        let read = await reader.pullRequests(now: now)
        if read.items.isEmpty, let problem = read.problem { throw MCPToolError(problem) }
        var groups: [PRGroup] = [.needsYou, .failing, .ready]
        if read.showToReview { groups.append(.toReview) }
        var sections: [String] = []
        if let problem = read.problem { sections.append("BriefBar couldn't read everything: \(problem)") }
        for group in groups {
            let items = read.items.filter { $0.group == group }
            guard !items.isEmpty else { continue }
            sections.append("\(group.title) (\(items.count)):\n" + items.map { item in
                AgentText.line(item, now: now)
            }.joined(separator: "\n"))
        }
        if let stages = await stages(read, now: now), let text = AgentText.stages(stages, items: read.items) {
            sections.append(text)
        }
        let pinned = await reader.pinnedStatuses(now: now)
        if pinned.statuses.isEmpty, let problem = pinned.problem {
            sections.append("BriefBar couldn't read the pinned pipelines: \(problem)")
        }
        let failed = pinned.statuses.filter { $0.latest?.status == .failed }
        if !failed.isEmpty {
            sections.append("Pinned pipelines that failed (\(failed.count)):\n" + failed.map { status in
                "- \(QuotedText.inLine(status.briefSentence))" + (status.latest.map { "\n  \($0.webURL.absoluteString)" } ?? "")
            }.joined(separator: "\n"))
        }
        // Nil only when nothing needs you and everything could be read.
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    func pullRequests(group: JSONValue?, now: Date = Date()) async throws -> String {
        var only: PRGroup?
        if let group {
            guard let name = group.string, let found = PRGroup.named(name) else {
                throw MCPToolError("There's no group “\(group.string ?? "")”: use one of \(PRGroup.allCases.map(\.agentName).joined(separator: ", ")).")
            }
            only = found
        }
        let read = await reader.pullRequests(now: now)
        if read.items.isEmpty, let problem = read.problem { throw MCPToolError(problem) }
        let counts = GroupCounts(read.items)
        var lines: [String] = []
        if let problem = read.problem { lines.append("BriefBar couldn't read everything: \(problem)\n") }
        lines.append(PRGroup.allCases.map { "\(counts[$0]) \($0.countLabel)" }.joined(separator: " · "))
        for group in only.map({ [$0] }) ?? PRGroup.allCases {
            let items = read.items.filter { $0.group == group }
            guard !items.isEmpty || only != nil else { continue }
            lines.append("\n## \(group.title) (\(items.count))")
            lines += items.isEmpty ? ["None."] : items.map { item in AgentText.line(item, now: now) }
        }
        return lines.joined(separator: "\n")
    }

    func pullRequest(_ reference: JSONValue?, now: Date = Date()) async throws -> String {
        let read = await reader.pullRequests(now: now)
        var record = try Self.find(reference, in: read)
        // The branch it merges into as Azure DevOps says now, rather than as the lists read it, up to a minute before: an
        // agent checks it right before it pushes.
        var unreadTarget: String?
        switch await reader.targetNow(of: record.id) {
        case .success(let target)?: record.pullRequest.targetBranch = target
        case .failure(let error)?: unreadTarget = AzureDevOpsReader.describe(error)
        case nil: break
        }
        let item = read.items.first { $0.key == record.id }
        let sent = await reader.sendsToCopilot ? await reader.copilotTasks(now: now) : []
        let session = await reader.session(for: record, tasks: sent, now: now)
        let stages = await stages(read, now: now)
        let stage = stages.flatMap { stages in stages.readings[record.id.linkRef].map { AgentText.stage($0, stages: stages) } }
        let work = await reader.work(of: record.pullRequest, now: now)
        let waits = record.role == .author && record.pullRequest.status == .active
        return AgentText.details(
            record, item: item, actions: PullRequestTasks.actions(for: record, canShip: false), tasks: sent.filter { $0.isOn(record.id) },
            session: session, stage: stage, work: work, unreadTarget: unreadTarget,
            wait: waits ? WaitCLI.command(executable: executable, link: record.pullRequest.webURL, demo: reader.demo) : nil, now: now
        )
    }

    func prompt(_ reference: JSONValue?, action name: JSONValue?, now: Date = Date()) async throws -> String {
        let read = await reader.pullRequests(now: now)
        let record = try Self.find(reference, in: read)
        guard let name = name?.string, let action = PullRequestAction.named(name) else {
            throw MCPToolError("Say what to do: one of \(PullRequestAction.allCases.map(\.agentName).joined(separator: ", ")).")
        }
        // Push & Reply ships what the agent changed for one of yours, which BriefBar can't see: its prompt checks first.
        guard PullRequestTasks.actions(for: record, canShip: true).contains(action) else {
            let pr = record.pullRequest
            let why: String
            switch action {
            case _ where pr.status != .active: why = "it's \(pr.status.rawValue)"
            case .fixComments: why = "no comment thread on it is unresolved"
            case .fixBuild: why = "no build that blocks it failed"
            case .resolveConflicts: why = "it has no merge conflicts"
            case .review: why = "it's yours"
            case .pushAndReply: why = "it isn't yours"
            }
            let others = PullRequestTasks.actions(for: record, canShip: false)
            let applies = others.isEmpty ? "" : " What applies: \(others.map(\.agentName).joined(separator: ", "))."
            throw MCPToolError("\(action.agentName) doesn't apply to !\(pr.key.number): \(why).\(applies)")
        }
        return await PullRequestTasks.agentPrompt(
            action, for: record, client: reader.client, ordersPullRequests: await reader.ordersPullRequests
        )
    }

    func pipelines(now: Date = Date()) async throws -> String {
        async let pinned = reader.pinnedStatuses(now: now)
        async let pullRequests = reader.pullRequests(now: now)
        let (statuses, problem) = await pinned
        let merges = await pullRequests.records.compactMap(\.merge).sorted { ($0.mergedAt, $0.pullRequest) > ($1.mergedAt, $1.pullRequest) }
        var lines: [String] = []
        if let problem { lines.append("BriefBar couldn't read every pipeline: \(problem)\n") }
        lines.append("## Pinned (\(statuses.count))")
        if statuses.isEmpty {
            lines.append(await reader.pinnedPipelines.isEmpty ? "None pinned: pin_pipeline pins one by its link." : "Couldn't read them.")
        }
        for status in statuses {
            lines += AgentText.pipeline(status, now: now)
        }
        if !merges.isEmpty {
            lines.append("\n## After your merges (\(merges.count))")
            for merge in merges {
                lines += AgentText.merged(merge, now: now)
            }
        }
        lines.append("\n\(AgentText.legend)")
        return lines.joined(separator: "\n")
    }

    func sprint(mine: Bool, now: Date = Date()) async throws -> String {
        let (board, problem) = await reader.sprint(now: now)
        guard let board else { throw MCPToolError(problem ?? "None of your teams has a sprint going on today.") }
        return AgentText.sprint(board, mine: mine, problem: problem, now: now)
    }

    func workItem(_ reference: JSONValue?, now: Date = Date()) async throws -> String {
        let (id, organization) = try Self.workItemReference(reference)
        let read = try await reader.workItem(id, organization: organization, now: now)
        let item = read.item
        let sent = await reader.sendsToCopilot ? await reader.copilotTasks(now: now) : []
        let tasks = Self.tasks(sent, for: item, tasks: read.tasks, pullRequests: read.pullRequests)
        // What the other sources know of its pull requests, such as the Copilot sessions on them.
        let related = read.pullRequests.isEmpty ? [] : await MCPRelated.ask(Self.query(for: read))
        return AgentText.workItem(read, tasks: tasks, allSent: sent, related: related, now: now)
    }

    /// What `work_item` asks the other sources about: the work item and its pull requests, and what links each pull request
    /// to a session by its branch, as Show Links has it.
    static func query(for read: AzureDevOpsReader.WorkItemRead) -> MCPRelated.Query {
        var branches: [ItemRef: BranchHint] = [:]
        for key in read.pullRequests {
            guard let pullRequest = read.pullRequest(key) else { continue }
            branches[key.linkRef] = BranchHint(
                branch: pullRequest.sourceBranch, target: pullRequest.targetBranch, repositories: [pullRequest.repositoryName]
            )
        }
        return MCPRelated.Query(
            items: [read.item.linkRef] + read.pullRequests.map(\.linkRef), branches: branches, limit: AgentText.relatedShown
        )
    }

    /// The work sent to Copilot for a work item or its tasks, and on its pull requests: a session sent from another work item
    /// may have gone on to one of them.
    static func tasks(_ all: [CopilotTaskEntry], for item: WorkItem, tasks: [WorkItem], pullRequests: [PRKey]) -> [CopilotTaskEntry] {
        let ids = Set([item.id] + tasks.map(\.id))
        return all.filter { task in
            if let workItem = task.workItem, ids.contains(workItem.id),
               workItem.organization.caseInsensitiveCompare(item.organization) == .orderedSame {
                return true
            }
            return pullRequests.contains { task.isOn($0) }
        }
    }

    func copilotTasks(now: Date = Date()) async throws -> String {
        guard await reader.sendsToCopilot else {
            throw MCPToolError("Send Work to Copilot is off in BriefBar: it's in Azure DevOps' settings.")
        }
        let tasks = await reader.copilotTasks(now: now)
        guard !tasks.isEmpty else { return "BriefBar hasn't sent any work to Copilot." }
        let titles = Dictionary(await reader.pullRequests(now: now).records.map { ($0.id, $0.pullRequest.title) },
                                uniquingKeysWith: { first, _ in first })
        let workItems = await reader.workItemTitles(now: now)
        return tasks.prefix(20).map { AgentText.task($0, titles: titles, workItems: workItems, now: now) }.joined(separator: "\n")
    }

    // MARK: Changing BriefBar's settings

    func watch(_ link: JSONValue?, now: Date = Date()) async throws -> String {
        guard let text = link?.string, let found = PullRequestLink.find(in: text).first else {
            throw MCPToolError("That isn't a pull request's link, such as https://dev.azure.com/org/project/_git/repo/pullrequest/123.")
        }
        let listed = await reader.pullRequests(now: now).records.first { $0.id == found.key && !$0.isWatched && $0.role != .linked }
        if let listed {
            return "BriefBar lists !\(found.number) already, as \(listed.role == .author ? "yours" : "one you review")."
        }
        guard await reader.watch(found) else { return "BriefBar watches !\(found.number) already." }
        if reader.demo {
            return "BriefBar watches !\(found.number) in \(found.organization) now. (The demo keeps this in memory, and reads nothing.)"
        }
        let read = await reader.pullRequests(now: now)
        if let record = read.records.first(where: { $0.id == found.key }) {
            return """
                BriefBar watches !\(found.number) “\(QuotedText.oneLine(record.pullRequest.title))” in \(found.organization) now, and lists it until \
                it closes or you stop watching it.
                """
        }
        if read.closedLinks.contains(found.key) {
            _ = await reader.unwatch { $0.key == found.key }
            throw MCPToolError("BriefBar didn't watch !\(found.number): it's closed, or you can't read it.")
        }
        return "BriefBar watches !\(found.number) in \(found.organization) now, and lists it once it has read it."
    }

    func stopWatching(_ reference: JSONValue?) async throws -> String {
        let (number, organization) = try Self.reference(reference)
        let removed = await reader.unwatch { link in
            link.number == number && (organization.map { link.organization.caseInsensitiveCompare($0) == .orderedSame } ?? true)
        }
        guard !removed.isEmpty else { throw MCPToolError("BriefBar doesn't watch !\(number).") }
        return "BriefBar stopped watching !\(number)."
    }

    func pin(_ link: JSONValue?) async throws -> String {
        guard let text = link?.string, let found = PipelineLink(text) else {
            throw MCPToolError("That isn't a pipeline's link, or a run's, such as https://dev.azure.com/org/project/_build?definitionId=12.")
        }
        guard let client = reader.client else { throw MCPToolError("The demo reads no pipelines: it has only its own.") }
        let pipeline: PipelineRef
        do {
            pipeline = try await PipelineSearch.pipeline(for: found, client: client)
        } catch {
            throw MCPToolError("Couldn't read that pipeline: \(AzureDevOpsReader.describe(error))")
        }
        guard await reader.pin(pipeline) else { return "“\(QuotedText.oneLine(pipeline.name))” is pinned already." }
        return "Pinned “\(QuotedText.oneLine(pipeline.name))”\(pipeline.branch.map { ", showing runs of \(AgentText.runBranch($0))" } ?? "")."
    }

    func unpin(_ name: JSONValue?) async throws -> String {
        guard let text = name?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw MCPToolError("Name the pipeline, as pipelines shows it, or give its link.")
        }
        let pinned = await reader.pinnedPipelines
        var matches: [PipelineRef]
        if let link = PipelineLink(text), case .pipeline(let id) = link.target {
            matches = pinned.filter { $0.definitionId == id && $0.organization.caseInsensitiveCompare(link.organization) == .orderedSame }
        } else {
            matches = pinned.filter { $0.name.caseInsensitiveCompare(text) == .orderedSame }
        }
        guard let pipeline = matches.first else { throw MCPToolError("No pinned pipeline is “\(text)”.") }
        guard matches.count == 1 else { throw MCPToolError("More than one pinned pipeline is “\(text)”: give its link.") }
        await reader.unpin(pipeline)
        return "Unpinned “\(QuotedText.oneLine(pipeline.name))”."
    }

    // MARK: Pull requests named

    /// A pull request an agent names: its number, such as 4088 or !4088, or its link, which says its organization too.
    static func reference(_ value: JSONValue?) throws -> (number: Int, organization: String?) {
        if let number = value?.int, number > 0 { return (number, nil) }
        if let text = value?.string?.trimmingCharacters(in: .whitespaces) {
            if let link = PullRequestLink.find(in: text).first { return (link.number, link.organization) }
            if text.hasPrefix("!"), let number = Int(text.dropFirst()), number > 0 { return (number, nil) }
        }
        throw MCPToolError("Name the pull request by its number, such as 4088, or its link.")
    }

    /// A work item an agent names: its number, such as 5101 or #5101, or its link, which says its organization too.
    static func workItemReference(_ value: JSONValue?) throws -> (id: Int, organization: String?) {
        if let number = value?.int, number > 0 { return (number, nil) }
        if let text = value?.string?.trimmingCharacters(in: .whitespaces) {
            if let ref = ItemRef.from(link: text), ref.kind == .workItem, let id = Int(ref.id) { return (id, ref.scope) }
            if let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text), number > 0 { return (number, nil) }
        }
        throw MCPToolError("Name the work item by its number, such as 5101, or its link.")
    }

    static func find(_ value: JSONValue?, in read: AzureDevOpsReader.PullRequests) throws -> PRRecord {
        let (number, organization) = try reference(value)
        let matches = read.records.filter { record in
            record.id.number == number
                && (organization.map { record.id.organization.caseInsensitiveCompare($0) == .orderedSame } ?? true)
        }
        if matches.count > 1 { throw MCPToolError("More than one organization has !\(number): give its link.") }
        guard let record = matches.first else {
            if let problem = read.problem, read.records.isEmpty { throw MCPToolError(problem) }
            throw MCPToolError("""
                !\(number) isn't among the pull requests BriefBar lists: yours, the ones you review, and the ones you \
                watch. watch_pull_request lists another by its link.
                """)
        }
        return record
    }
}

extension PRGroup {
    /// What agents call it: `needs_you`, `to_review`.
    var agentName: String { rawValue.snakeCased }

    static func named(_ name: String) -> PRGroup? {
        allCases.first { $0.agentName == name.lowercased() || $0.rawValue.lowercased() == name.lowercased() }
    }
}

extension PullRequestAction {
    /// What agents call it: `fix_comments`, `push_and_reply`.
    var agentName: String { rawValue.snakeCased }

    static func named(_ name: String) -> PullRequestAction? {
        allCases.first { $0.agentName == name.lowercased() || $0.rawValue.lowercased() == name.lowercased() }
    }
}

extension String {
    /// `needsYou` as `needs_you`.
    var snakeCased: String {
        reduce(into: "") { result, character in
            if character.isUppercase {
                result += "_" + character.lowercased()
            } else {
                result.append(character)
            }
        }
    }
}

/// What BriefBar shows, in words for agents: Markdown, with each pull request's and run's link.
enum AgentText {
    /// “5m ago”, or “just now”.
    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let elapsed = Elapsed.short(since: date, now: now)
        return elapsed == "now" ? "just now" : "\(elapsed) ago"
    }

    /// Whose it is: “yours”, “by Chen Wei, you review it”, “by Chen Wei, watched”. BriefBar speaks to you, the user.
    static func whose(role: PRRole, author: String, isWatched: Bool, isDraft: Bool) -> String {
        var parts: [String] = []
        switch role {
        case .author: parts.append("yours")
        case .reviewer, .linked: parts.append("by \(author), \(isWatched ? "watched" : role == .reviewer ? "you review it" : "sent to you")")
        }
        if isDraft { parts.append("draft") }
        return parts.joined(separator: ", ")
    }

    /// A pull request in a list: what it is, why it's there and since when, and its link. In Needs You, whether you've
    /// seen what's there. What others named or wrote in it stays on its line (`QuotedText`), and the branches its detail
    /// names are written as a command may hold them (`statusDetail`).
    static func line(_ item: PRSnapshot, now: Date) -> String {
        let whose = whose(role: item.role, author: QuotedText.oneLine(item.author), isWatched: item.isWatched, isDraft: item.isDraft)
        var text = "- !\(item.key.number) “\(QuotedText.oneLine(item.title))” in \(QuotedText.oneLine(item.repository)) "
            + "(\(whose)): \(QuotedText.inLine(item.headline))"
        if let since = item.since { text += ", \(ago(since, now: now))" }
        if item.group == .needsYou && !item.hasNews { text += " (seen, still waiting on you)" }
        // Its detail says who wrote it, when that's all it says, as whose it is does.
        if let detail = statusDetail(of: item), item.detail != "By \(item.author)" {
            text += ". " + detail
        }
        return text + "\n  \(item.url.absoluteString)"
    }

    /// One pull request, for the `pull_request` tool. What others named or wrote in it, its title, names, checks, branches
    /// and comments, stays on its line, as the prompts quote it (`QuotedText.oneLine`), with its branches as a command may
    /// hold them (`QuotedText.commandWord`), and what people wrote follows a note that it isn't instructions.
    /// - Parameters:
    ///   - session: its Copilot session, as its details show it, if there's something to say.
    ///   - stage: its stage, with Pull Request Order on (`AgentText.stage`).
    ///   - work: its work items, each with the one it's under, as Azure DevOps links them, or why they couldn't be read.
    ///   - unreadTarget: why BriefBar couldn't read again which branch it merges into, as it asked, for the agent to know
    ///     that the one named may not be it any more (`AzureDevOpsReader.targetNow(of:)`).
    ///   - wait: the command that waits on it for an agent (`--wait`), for one of your open pull requests.
    static func details(
        _ record: PRRecord, item: PRSnapshot?, actions: [PullRequestAction], tasks: [CopilotTaskEntry], session: AgentSession? = nil,
        stage: String? = nil, work: (work: [LinkedWork]?, problem: String?)? = nil, unreadTarget: String? = nil, wait: String? = nil,
        now: Date
    ) -> String {
        let pr = record.pullRequest
        let (source, target) = (QuotedText.commandWord(pr.sourceBranch), QuotedText.commandWord(pr.targetBranch))
        var lines = ["# !\(pr.key.number) “\(QuotedText.oneLine(pr.title))”", pr.webURL.absoluteString, ""]
        lines.append(
            "- \(QuotedText.oneLine(pr.repositoryName)), in \(QuotedText.oneLine(pr.projectName)) "
                + "(\(QuotedText.oneLine(pr.key.organization))), from \(source) into \(target)"
        )
        if let unreadTarget {
            lines.append(
                "- BriefBar couldn't read which branch it merges into just now, so it can't tell whether that's still \(target): "
                    + QuotedText.oneLine(unreadTarget)
            )
        }
        var state = [
            record.role == .author
                ? "Yours, opened \(ago(pr.createdAt, now: now))" : "By \(QuotedText.oneLine(pr.author.name)), opened \(ago(pr.createdAt, now: now))"
        ]
        state.append(pr.status.rawValue)
        if pr.isDraft { state.append("a draft") }
        if pr.autoComplete { state.append("set to complete automatically") }
        if let closed = pr.closedAt, pr.status != .active { state.append("closed \(ago(closed, now: now))") }
        lines.append("- " + state.joined(separator: ", "))
        if let item {
            var status = "- In BriefBar: \(item.group.title), \(QuotedText.inLine(item.headline))"
            if let since = item.since { status += ", \(ago(since, now: now))" }
            if let detail = Self.statusDetail(of: item) { status += ". \(detail)" }
            lines.append(status)
        }
        if let stage { lines.append("- " + stage) }
        if let items = work?.work {
            lines.append(items.isEmpty ? "- No work item is linked to it in Azure DevOps." : "- Its work items: " + Self.work(items) + ".")
        } else if let problem = work?.problem {
            lines.append("- BriefBar couldn't read its work items: " + QuotedText.oneLine(problem))
        }
        let reviewers = pr.reviewers.map { reviewer in
            var name = QuotedText.oneLine(reviewer.person.name)
            if reviewer.isRequired { name += " (required)" }
            return "\(name): \(reviewer.hasDeclined ? "declined" : Self.vote(reviewer.vote))"
        }
        if !reviewers.isEmpty { lines.append("- Reviewers: " + reviewers.joined(separator: "; ")) }
        if let details = record.details {
            let checks = details.checks.filter { $0.state != .notApplicable }.map { check in
                var text = "\(QuotedText.oneLine(check.name)): \(Self.state(check.state))"
                if !check.isBlocking { text += " (optional)" }
                if check.state == .failed, let failure = check.failure {
                    text += ", at " + [failure.stage, failure.summary].compactMap { $0 }.map(QuotedText.oneLine).joined(separator: " › ")
                }
                return text
            }
            if !checks.isEmpty { lines.append("- Checks:\n" + checks.map { "  - \($0)" }.joined(separator: "\n")) }
        }
        if pr.hasConflicts { lines.append("- It has merge conflicts with \(target).") }
        if let problem = pr.mergeProblem { lines.append("- \(problem.detail.text(naming: QuotedText.commandWord)).") }
        if let merge = record.merge {
            lines.append("- After it merged into \(QuotedText.commandWord(merge.targetBranch)) \(ago(merge.mergedAt, now: now)):")
            for status in merge.pipelines {
                lines += Self.pipeline(status, now: now).map { "  \($0)" }
            }
        }

        // What people wrote is quoted below the first of these headings, after the note that it isn't instructions.
        let pending = item?.pendingEvents ?? []
        var said = pending.contains { $0.text?.isEmpty == false } ? [PullRequestPrompt.commentsSaid] : []
        let news = pending.filter(\.isNew)
        if !news.isEmpty {
            lines.append("\n## New for you")
            lines += said + news.map { Self.event($0, now: now) }
            said = []
        }
        let seen = pending.filter { !$0.isNew }
        if !seen.isEmpty {
            lines.append("\n## Seen, still waiting on you")
            lines += said + seen.map { Self.event($0, now: now) }
        }

        if let details = record.details {
            let threads = details.threads.filter { !$0.isResolved }
            lines.append("\n## Unresolved comment threads (\(threads.count))")
            lines.append(threads.isEmpty ? "None." : PullRequestPrompt.listed(threads, record: record))
        } else if pr.status == .active {
            lines.append("\nBriefBar hasn't read its comments and checks yet.")
        }

        lines.append("\n## Copilot")
        var copilot = actions.isEmpty ? [] : ["pull_request_prompt has the prompt to: \(actions.map(\.agentName).joined(separator: ", "))."]
        if record.role == .author, pr.status == .active {
            copilot.append("Once you've changed it, push_and_reply's prompt pushes the changes and answers its threads.")
        }
        lines.append(copilot.isEmpty ? "Nothing for Copilot to do with it now." : copilot.joined(separator: " "))
        if let wait {
            lines.append("""
                To wait on it, start `\(wait)` in the background and end your turn: it reads the pull request every minute, \
                and ends on its next build's result, comments that wait on you, merge conflicts or its closing, printing what \
                to do then, as pull_request_prompt does. Set --timeout a few minutes longer than its build usually takes, \
                120 at most. Wait only on a short build that the next step needs: for a long pipeline, just end your turn. \
                BriefBar notifies you if it fails.
                """)
        }
        if let session { lines.append(Self.session(session, now: now)) }
        for task in tasks {
            lines.append(Self.task(task, titles: [:], workItems: [:], now: now))
        }
        return lines.joined(separator: "\n")
    }

    /// "Task 5182 “Show delivery estimates”, under User Story 5180 “Checkout redesign”": a pull request's work items, each
    /// with the one it's under, such as a task's story, its type and title on its line, as `work_item` quotes them.
    static func work(_ items: [LinkedWork]) -> String {
        items.map { linked in
            let item = linked.item
            var text = "\(QuotedText.oneLine(item.type)) \(item.id) “\(QuotedText.oneLine(item.title))”"
            if let parent = linked.parent {
                text += ", under \(QuotedText.oneLine(parent.type)) \(parent.id) “\(QuotedText.oneLine(parent.title))”"
            } else if let parent = item.parentId {
                text += ", under work item \(parent)"
            }
            return text
        }.joined(separator: "; ")
    }

    /// What the lists say of a pull request after its headline, on its line (`QuotedText.oneLine`), with its branches as a
    /// command may hold them where it names them, as the rest of `pull_request` does (`QuotedText.commandWord`): where its
    /// conflicts are, what failed to merge, or what it merged into. The classifier keeps them apart in it
    /// (`PRSnapshot.detailText`), so they're named so whatever they hold. The lists themselves show them as they are. Nil
    /// when it says nothing.
    static func statusDetail(of item: PRSnapshot) -> String? {
        item.detail(naming: QuotedText.commandWord).flatMap { $0.isEmpty ? nil : QuotedText.oneLine($0) }
    }

    /// A pull request's Copilot session, for `pull_request`, as its details show it (`PullRequestSession`): the session
    /// BriefBar sends its work to; a new session, which you chose; the sessions BriefBar asks you to choose from, since they
    /// go with it as well as each other; or, when none goes with it, one that may have opened it.
    static func session(_ session: AgentSession, now: Date) -> String {
        switch session {
        case .session(let suggested):
            return Self.session(suggested, now: now)
        case .newSession:
            return "Its session: a new one. The user chose in BriefBar that its work goes to a new Copilot session, rather than one that's there."
        case .undecided(let choices):
            let sessions = choices.map { "“\(QuotedText.oneLine($0.name))” (\(names($0.reasons.map(\.phrase))), session \($0.id))" }
            return "Its session isn't settled: \(names(sessions)) go with it as well as each other, so BriefBar asks the user "
                + "which before it sends its work to one. Ask them which, too."
        case .guess(let choice):
            return "It has no Copilot session of its own: BriefBar sends its work to a new session unless the user chooses one. "
                + "“\(QuotedText.oneLine(choice.name))”, in the Copilot app, has a link to it and was there before it was created, so it may have "
                + "opened it.\n  " + (appFacts(choice, now: now) + ["session \(choice.id)"]).joined(separator: " · ")
        }
    }

    /// The session BriefBar sends a pull request's work to, for `pull_request`: its name, where it is and why, and whether
    /// Copilot works in it now; then where it works, and its ID. One the Copilot app has, or a task BriefBar runs with the
    /// Copilot CLI, which the app doesn't have unless you opened it there.
    static func session(_ session: SuggestedSession, now: Date) -> String {
        let choice = session.choice
        var why: String
        var facts: [String] = []
        switch choice.kind {
        case .task(let run):
            switch session.basis {
            case .chosenByYou: why = "which the user chose for it"
            case .openedIt: why = "the session of the work item's task that opened it"
            default: why = "the session of its last task"
            }
            facts.append("worktree \(QuotedText.inLine(run.worktree.path))")
        case .app:
            why = session.basis == .chosenByYou ? "which the user chose for it" : names(choice.reasons.map(\.phrase))
            facts += appFacts(choice, now: now)
        }
        let place = session.isInApp ? "in the Copilot app" : "which BriefBar runs with the Copilot CLI and the Copilot app doesn't have"
        let parts = choice.appSession != nil ? [place, why] : [why, place]
        facts.append("session \(choice.id)")
        var text = "Its session, where BriefBar sends its work unless you choose another: “\(QuotedText.oneLine(choice.name))”, "
            + parts.filter { !$0.isEmpty }.joined(separator: ", ") + "."
        if choice.isBusy {
            text += " Copilot is still working in it, for a task BriefBar sent: nothing more goes to it until that's done."
        } else if choice.isFolderBusy {
            text += " Copilot is working in its checkout for another task BriefBar sent: nothing goes to it until that's done."
        }
        return text + "\n  " + facts.joined(separator: " · ")
    }

    /// Where one of the Copilot app's sessions works, whether it runs a turn now, and when it was last active.
    /// Its project and branch, as the window has them (`SessionChoices.place(of:)`), are written apart: the project on its line
    /// (`QuotedText.oneLine`), the branch as a command may hold it (`QuotedText.commandWord`).
    private static func appFacts(_ choice: SessionChoice, now: Date) -> [String] {
        var facts: [String] = []
        if let session = choice.appSession {
            if session.isChat {
                facts.append("a chat")
            } else {
                facts += [session.projectName.map(QuotedText.oneLine), session.branch.map(QuotedText.commandWord)]
                    .compactMap { $0 }.filter { !$0.isEmpty }
            }
        } else if let place = choice.place {
            facts.append(QuotedText.oneLine(place))
        }
        if choice.appSession?.isRunning == true { facts.append("working now") }
        let active = ago(choice.lastActive, now: now)
        if !active.isEmpty { facts.append("active \(active)") }
        return facts
    }

    static func vote(_ vote: Vote) -> String {
        switch vote {
        case .approved: return "approved"
        case .approvedWithSuggestions: return "approved with suggestions"
        case .none: return "no vote yet"
        case .waitingForAuthor: return "waiting for the author"
        case .rejected: return "rejected"
        }
    }

    static func state(_ state: Check.State) -> String {
        switch state {
        case .passed: return "passed"
        case .failed: return "failed"
        case .running: return "running"
        case .queued: return "queued"
        case .expired: return "expired"
        case .notRun: return "not run"
        case .pending: return "pending"
        case .notApplicable: return "not applicable"
        }
    }

    /// Something that happened on a pull request, with who did it and what they wrote, each on its line (`QuotedText`).
    static func event(_ event: PREvent, now: Date) -> String {
        let who = event.actor.map(QuotedText.oneLine) ?? "Someone"
        var text: String
        switch event.kind {
        case .mention: text = "\(who) mentioned you"
        case .sentInChat: text = "\(who) sent it in a chat"
        case .reply: text = "\(who) replied"
        case .comment: text = "\(who) commented"
        case .reviewRequest: text = "Your review was requested"
        case .newCommits: text = (event.count ?? 1) == 1 ? "A new commit" : "\(event.count ?? 1) new commits"
        case .changesRequested: text = "\(who) asked for changes"
        case .rejected: text = "\(who) rejected it"
        case .approved: text = "\(who) approved it"
        }
        text = "- \(text), \(ago(event.at, now: now))"
        if let quote = event.text, !quote.isEmpty { text += ": “\(QuotedText.oneLine(quote))”" }
        return text
    }

    /// A pipeline as `--pipelines` prints it, as a list item, with its latest run's link: each of its lines one line, whatever
    /// its pipeline, stages, branch or errors are named, and none starting a fence, as a pipeline named "~~~Deploy" would
    /// once it's a list item's (`QuotedText.oneLine`), and its branches as a command may hold them (`runBranch`).
    static func pipeline(_ status: PipelineStatus, now: Date) -> [String] {
        var lines = WorkCLI.pipelineLines(status, now: now, naming: runBranch).map(QuotedText.oneLine)
        guard !lines.isEmpty else { return [] }
        lines[0] = "- " + lines[0]
        if let run = status.latest { lines.append("  \(run.webURL.absoluteString)") }
        return lines
    }

    /// A pull request that merged, with the pipelines that ran after it, for `pipelines`: its title on its line
    /// (`QuotedText.oneLine`), and its target branch as a command may hold it (`QuotedText.commandWord`).
    static func merged(_ merge: MergePipelines, now: Date) -> [String] {
        var lines = [
            "- !\(merge.pullRequest.number) “\(QuotedText.oneLine(merge.title))” into \(QuotedText.commandWord(merge.targetBranch)), "
                + "merged \(ago(merge.mergedAt, now: now)):",
            "  \(merge.url.absoluteString)",
        ]
        for status in merge.pipelines {
            lines += pipeline(status, now: now).map { "  \($0)" }
        }
        return lines
    }

    /// The sprint, as `--sprint` prints it, for `sprint`: each of its lines one line, whatever its sprint, team, work items
    /// and people are named, and none starting a fence (`QuotedText.oneLine`).
    static func sprint(_ board: SprintBoard, mine: Bool, problem: String?, now: Date) -> String {
        var lines = WorkCLI.boardLines(mine ? board.justMine() : board, whole: board, now: now).map(QuotedText.oneLine)
        if let problem { lines.insert("BriefBar couldn't read everything: \(problem)\n", at: 0) }
        lines.append("\n✓ done, ◐ in progress, ○ to do. (you) marks your own tasks.")
        return lines.joined(separator: "\n")
    }

    /// A branch a pipeline's run built, or one a pipeline is pinned to, as a command may hold it (`QuotedText.commandWord`);
    /// what a pull request's run built, "!4071", which is no branch's name, as it is.
    static func runBranch(_ branch: String) -> String {
        branch.wholeMatch(of: /![0-9]+/) != nil ? branch : QuotedText.commandWord(branch)
    }

    static let legend = "✓ succeeded, ✕ failed, ▶ running, ⏸ waiting for approval, ○ not started, ! succeeded with issues, – canceled or skipped."

    /// A task sent to Copilot: what for, how it's going, and where.
    static func task(_ task: CopilotTaskEntry, titles: [PRKey: String], workItems: [Int: String], now: Date) -> String {
        var subject: String
        if let pullRequest = task.onPullRequest {
            let key = PRKey(pullRequest.organization, pullRequest.id)
            subject = "\(task.action?.title ?? "Work") on !\(pullRequest.id)" + (titles[key].map { " “\(QuotedText.oneLine($0))”" } ?? "")
                + " in \(QuotedText.oneLine(pullRequest.repository))"
        } else if let workItem = task.workItem {
            subject = "Work item \(workItem.id)" + (workItems[workItem.id].map { " “\(QuotedText.oneLine($0))”" } ?? "")
                + " in \(QuotedText.oneLine(workItem.project))"
        } else {
            subject = "A task"
        }
        let status = task.status
        var line = "- \(subject): \(status.phase.rawValue)"
        if let since = status.since ?? (status.phase.isActive ? task.startedAt : nil) {
            line += status.phase.isActive ? ", started \(ago(task.startedAt, now: now))" : ", \(ago(since, now: now))"
        }
        if let detail = status.detail, !detail.isEmpty { line += ". \(QuotedText.inLine(detail))" }
        var facts = [task.options.title]
        if let run = task.run { facts += ["worktree \(QuotedText.inLine(run.worktree.path))", "session \(run.id)"] } else { facts.append("session \(task.id)") }
        line += "\n  " + facts.joined(separator: " · ")
        if let link = task.pullRequest { line += "\n  \(link.absoluteString)" }
        return line
    }

    // MARK: A work item

    /// How many of what another source tells of a work item's pull requests, such as the Copilot sessions on them, are told
    /// in full: the rest by name.
    static let relatedShown = 5

    /// A work item and what goes with it, for the `work_item` tool: where it stands and who it waits on; its tasks, its pull
    /// requests, what the other sources know of those, such as the Copilot sessions on them, and the work sent to Copilot
    /// for it; then what people wrote in it, quoted, since that's data.
    /// - Parameter allSent: all the work sent to Copilot, to tell whether a failed one was sent again since; `tasks` when nil.
    static func workItem(
        _ read: AzureDevOpsReader.WorkItemRead, tasks: [CopilotTaskEntry], allSent: [CopilotTaskEntry]? = nil,
        related: [MCPRelated.Part] = [], now: Date
    ) -> String {
        let item = read.item
        let me = read.me ?? read.lists.records.first { $0.id.organization.caseInsensitiveCompare(item.organization) == .orderedSame }?.me
        // The latest work sent for one of its tasks goes on that task's line; the rest, for it or on its pull requests, below.
        var latest: [Int: CopilotTaskEntry] = [:]
        var rest: [CopilotTaskEntry] = []
        for task in tasks {
            if task.onPullRequest == nil, let workItem = task.workItem, workItem.id != item.id,
               workItem.organization.caseInsensitiveCompare(item.organization) == .orderedSame,
               read.tasks.contains(where: { $0.id == workItem.id }) {
                if latest[workItem.id] == nil { latest[workItem.id] = task }
            } else {
                rest.append(task)
            }
        }
        // A session BriefBar sent work to is told with that work.
        let sessions = Set(tasks.map { $0.id.lowercased() })
        let parts = related.map { part in
            var part = part
            part.items.removeAll { $0.ref.kind == .session && sessions.contains($0.ref.id) }
            return part
        }

        var lines = ["# \(QuotedText.oneLine(item.type)) \(item.id) “\(QuotedText.oneLine(item.title))”"]
        lines.append(item.project.isEmpty ? "- In \(QuotedText.oneLine(item.organization))" : item.webURL.absoluteString)
        if let parent = read.parent {
            lines.append("- Under \(QuotedText.oneLine(parent.type.lowercased())) \(parent.id) “\(QuotedText.oneLine(parent.title))”")
        }
        lines.append("- " + standing(item, details: read.details, me: me, now: now))
        if let progress = progress(read, now: now) { lines.append("- " + QuotedText.oneLine(progress)) }
        let waits = Self.waits(read, tasks: tasks, allSent: allSent, related: parts.flatMap(\.items), me: me)
        if !waits.isEmpty { lines.append("- Waiting on: " + waits.map { QuotedText.inLine($0.text) }.joined(separator: " · ")) }
        lines.append("- You can: " + QuotedText.inLine(youCan(waits, read: read, tasks: tasks, me: me)))

        if !read.tasks.isEmpty {
            lines += ["", read.tasksAreInSprint ? "## Tasks" : "## Children"]
            lines += read.tasks.map { task in
                "- " + taskLine(task, me: me, copilot: latest[task.id], pullRequests: read.tasksPullRequests[task.id] ?? [], now: now)
            }
            if let problem = read.tasksPullRequestsProblem {
                lines.append("BriefBar couldn't read which pull requests are linked to them: \(QuotedText.oneLine(problem))")
            }
        }
        lines += ["", "## Pull requests"]
        if read.pullRequests.isEmpty { lines.append("None is linked to it in Azure DevOps.") }
        for key in read.pullRequests {
            lines += pullRequest(key, in: read, me: me, now: now)
        }
        for part in parts {
            lines += told(part)
        }
        if !rest.isEmpty {
            lines += ["", "## Sent to Copilot"]
            lines += rest.map { sent($0, for: item, now: now) }
        }
        lines += texts(read.details)
        lines += comments(read.details, me: me, now: now)
        return lines.joined(separator: "\n")
    }

    /// "State: Active (work started), changed 1h ago · assigned to you (Robin Diaz)": its state and why, and who has it.
    static func standing(_ item: WorkItem, details: WorkItemDetails?, me: String?, now: Date) -> String {
        var state = "State: " + (item.state.isEmpty ? "unknown" : QuotedText.inLine(item.state))
        if let reason = details?.reason, !reason.isEmpty, reason.caseInsensitiveCompare(item.state) != .orderedSame {
            state += " (\(QuotedText.inLine(lowercasingFirst(reason))))"
        }
        if let changed = item.changedAt { state += ", changed \(ago(changed, now: now))" }
        let who = item.assignedTo.map { person in
            let name = QuotedText.inLine(person.name)
            return isMe(person, me) ? "assigned to you (\(name))" : "assigned to \(name)"
        } ?? "unassigned"
        return "\(state) · \(who)"
    }

    /// "work started" for "Work started", in a sentence; "PR merged" as it is.
    static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase, text.dropFirst().first?.isLowercase == true else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// "Sprint 42 ends 2 Nov (5 days left) · 1 of 4 tasks done · 6 h left": its sprint, how many of its tasks are done, and
    /// the hours left, those that are known.
    static func progress(_ read: AzureDevOpsReader.WorkItemRead, now: Date, calendar: Calendar = .current) -> String? {
        var parts: [String] = []
        if let iteration = iteration(read.details?.iterationPath, sprint: read.sprint, now: now, calendar: calendar) {
            parts.append(iteration)
        }
        if !read.tasks.isEmpty {
            let kind = read.tasksAreInSprint ? "tasks" : "children"
            parts.append("\(read.tasks.filter(\.isDone).count) of \(read.tasks.count) \(kind) done")
        }
        if let hours = remaining(read.item, tasks: read.tasksAreInSprint ? read.tasks : []) {
            parts.append("\(Hours.text(hours)) left")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Sprint 42 ends 2 Nov (5 days left)", for the sprint going on, whose dates the sprint has; "In Sprint 41" for another.
    /// Nil without an iteration, or for the project's own, which is the backlog.
    static func iteration(_ path: String?, sprint: Sprint?, now: Date, calendar: Calendar = .current) -> String? {
        guard let path, let name = path.split(separator: "\\").dropFirst().last else { return nil }
        guard let sprint, sprint.path.caseInsensitiveCompare(path) == .orderedSame, let finish = sprint.finish,
              let left = sprint.daysLeft(now: now, calendar: calendar)
        else { return "In \(name)" }
        // Azure DevOps keeps a sprint's days in UTC.
        let day = finish.formatted(
            Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC") ?? .gmt).day().month(.abbreviated)
        )
        switch left {
        case 0: return "\(sprint.name) ended \(day)"
        case 1: return "\(sprint.name) ends today, \(day)"
        default: return "\(sprint.name) ends \(day) (\(left) days left)"
        }
    }

    /// Its own hours left, or its tasks' that aren't done.
    static func remaining(_ item: WorkItem, tasks: [WorkItem]) -> Double? {
        if let own = item.remainingWork, own > 0, !item.isDone { return own }
        let left = tasks.filter { !$0.isDone }.compactMap(\.remainingWork).reduce(0, +)
        return left > 0 ? left : nil
    }

    /// "5103 Show saved items under the cart: Active · you · 3 h left · Copilot working (started 6m ago): Run the cart
    /// tests": a task, who has it, its hours left, and the latest work sent to Copilot for it. All on its line, with no
    /// fence after its number, whatever its title (`QuotedText.oneLine`).
    static func taskLine(_ task: WorkItem, me: String?, copilot: CopilotTaskEntry?, pullRequests: [PRKey] = [], now: Date) -> String {
        var parts = [task.state.isEmpty ? "unknown" : task.state]
        parts.append(task.assignedTo.map { isMe($0, me) ? "you" : $0.name } ?? "unassigned")
        if let hours = task.remainingWork, hours > 0, !task.isDone { parts.append("\(Hours.text(hours)) left") }
        if !pullRequests.isEmpty {
            let numbers = OrderText.list(pullRequests.sorted().map(\.linkRef))
            parts.append((pullRequests.count == 1 ? "pull request " : "pull requests ") + numbers)
        }
        if let copilot { parts.append("Copilot " + sentStatus(copilot, now: now)) }
        return QuotedText.oneLine("\(task.id) \(task.title): " + parts.joined(separator: " · "))
    }

    /// How work sent to Copilot is going: "working (started 6m ago): Run the cart tests", "finished 12m ago. Opened pull
    /// request 4091."
    static func sentStatus(_ task: CopilotTaskEntry, now: Date) -> String {
        let status = task.status
        var text = status.phase.rawValue
        if status.phase.isActive {
            text += " (started \(ago(task.startedAt, now: now)))"
        } else if let since = status.since {
            text += " \(ago(since, now: now))"
        }
        if let detail = status.detail.map({ StoryText.line($0, limit: 240) }), !detail.isEmpty {
            text += (status.phase.isActive ? ": " : ". ") + detail
        }
        return text
    }

    /// Work sent to Copilot for the work item, or on one of its pull requests: what for, how it's going, and where.
    static func sent(_ task: CopilotTaskEntry, for item: WorkItem, now: Date) -> String {
        let subject: String
        if let pullRequest = task.onPullRequest {
            subject = "\(task.action?.title ?? "Work") on !\(pullRequest.id)"
        } else if let workItem = task.workItem, workItem.id == item.id {
            subject = "This \(QuotedText.inLine(item.type.lowercased()))"
        } else {
            subject = task.workItem.map { "Work item \($0.id)" } ?? "A task"
        }
        var line = "- \(subject): Copilot \(QuotedText.inLine(sentStatus(task, now: now)))"
        let facts = task.run.map { ["worktree \(QuotedText.inLine($0.worktree.path))", "session \($0.id)"] } ?? ["session \(task.id)"]
        line += "\n  " + facts.joined(separator: " · ")
        if let link = task.pullRequest { line += "\n  \(link.absoluteString)" }
        return line
    }

    /// A pull request linked to a work item: where it stands, with its branch; its reviewers, comments and merge; who wrote
    /// it; the pipelines that ran on it; and, for one not in your lists, what isn't read of it. Yours as your lists have it,
    /// another as it says itself.
    private static func pullRequest(_ key: PRKey, in read: AzureDevOpsReader.WorkItemRead, me: String?, now: Date) -> [String] {
        let record = read.lists.records.first { $0.id.linkRef == key.linkRef }
        let snapshot = read.lists.items.first { $0.key.linkRef == key.linkRef }
        guard let pullRequest = read.pullRequest(key) else {
            let failed = read.others.failed.contains { $0.linkRef == key.linkRef }
            return ["", "### !\(key.number)", failed
                ? "BriefBar couldn't read it."
                : "BriefBar didn't read it: Azure DevOps asked it to slow down. Ask again in a minute."]
        }
        let me = record?.me ?? me
        // What it says of its branches, as a command may hold them, as everywhere they're named here.
        let story = snapshot.map { PullRequestStory.mine($0, record: record, naming: QuotedText.commandWord) }
            ?? PullRequestStory.others(pullRequest, me: me, naming: QuotedText.commandWord)
        var lines = ["", "### !\(key.number) “\(QuotedText.oneLine(pullRequest.title))”", pullRequest.webURL.absoluteString]
        // Its branches as a command may hold them (`QuotedText.commandWord`), as `pull_request` writes them.
        var branch = QuotedText.commandWord(pullRequest.sourceBranch)
        if !pullRequest.targetBranch.isEmpty { branch += " → \(QuotedText.commandWord(pullRequest.targetBranch))" }
        let place = (branch.isEmpty ? "" : "\(branch), ") + "in \(QuotedText.oneLine(pullRequest.repositoryName))"
        let state = story.sentence.isEmpty ? pullRequest.status.rawValue.capitalized : QuotedText.oneLine(story.sentence)
        lines.append("- \(state) · \(place)")
        // Who wrote it, once, saying "you" for yours.
        lines += story.facts.filter { $0.label != "Author" }.map {
            "- \($0.label): \(QuotedText.inLine(StoryText.line($0.value, limit: 300)))"
        }
        lines.append("- Author: " + (record?.role == .author || isMe(pullRequest.author, me) ? "you" : QuotedText.oneLine(pullRequest.author.name)))
        if !story.runs.isEmpty {
            lines.append("- Pipelines:")
            for run in story.runs.prefix(8) {
                lines.append(
                    "  - \(QuotedText.oneLine(run.name)): \(QuotedText.inLine(run.status))"
                        + (run.detail.map { " (\(QuotedText.inLine(StoryText.line($0, limit: 200))))" } ?? "")
                )
                if let url = run.url { lines.append("    \(url.absoluteString)") }
            }
        }
        if record == nil {
            if pullRequest.status == .active { lines.append("- Not read: builds and comment threads (you're not on it)") }
        } else if record?.details?.threads.contains(where: { !$0.isResolved }) == true {
            lines.append("- Threads: pull_request \(key.number)")
        }
        return lines
    }

    /// What another source told of a work item's pull requests, under its title: the first few in full, a heading each with
    /// where it stands and why it goes with them, its link and a few lines; then the rest by name. Or why it couldn't tell.
    /// Nothing when it knows of none.
    static func told(_ part: MCPRelated.Part) -> [String] {
        if let problem = part.problem { return ["", "## \(part.title)", problem] }
        guard !part.items.isEmpty else { return [] }
        var lines = ["", "## \(part.title)"]
        for item in part.items.prefix(relatedShown) {
            let why = item.links.map(\.reason).joined(separator: ", ")
            lines += ["", "### “\(QuotedText.oneLine(item.title))”: \(QuotedText.inLine(item.status))" + (why.isEmpty ? "" : ", \(why)")]
            if let url = item.url { lines.append(url.absoluteString) }
            lines += item.lines.map { "- \(QuotedText.oneLine($0))" }
        }
        let rest = part.items.dropFirst(relatedShown)
        if !rest.isEmpty {
            let named = rest.map { "“\(QuotedText.oneLine($0.title))” (\(QuotedText.inLine($0.status)))" }
            lines += ["", "And \(rest.count) more: " + named.joined(separator: ", ") + "."]
        }
        return lines
    }

    /// Its description and its other long texts, such as acceptance criteria or repro steps, each quoted as written: the
    /// description first, then the others under their names.
    static func texts(_ details: WorkItemDetails?) -> [String] {
        let texts = (details?.texts ?? []).compactMap { text -> (field: String, title: String, text: String)? in
            let plain = StoryText.paragraph(text.text.plainText, limit: 1_500)
            return plain.isEmpty ? nil : (text.id, text.title, plain)
        }
        guard !texts.isEmpty else { return [] }
        var lines = ["", "## Description"]
        for text in texts {
            if text.field != "System.Description" { lines += ["", "### \(QuotedText.oneLine(text.title))"] }
            lines += quote(text.text)
        }
        return lines
    }

    /// Its latest comments, the newest first, each with who wrote it and when, quoted as written.
    static func comments(_ details: WorkItemDetails?, me: String?, now: Date, limit: Int = 5) -> [String] {
        guard let details else { return [] }
        if details.comments.isEmpty, let problem = details.commentsProblem {
            return ["", "## Latest comments", "BriefBar couldn't read them: \(problem)"]
        }
        var lines: [String] = []
        var shown = 0
        for comment in details.comments.prefix(limit) {
            let text = StoryText.paragraph(comment.text.plainText, limit: 600)
            guard !text.isEmpty else { continue }
            let who = comment.author.map { isMe($0, me) ? "You" : QuotedText.oneLine($0.name) } ?? "Someone"
            lines.append("- \(who)" + (comment.createdAt.map { ", \(ago($0, now: now))" } ?? "") + ":")
            lines += quote(text, indent: "  ")
            shown += 1
        }
        guard shown > 0 else { return [] }
        let count = details.commentCount > shown ? ", \(shown) of \(details.commentCount)" : ""
        return ["", "## Latest comments (newest first\(count))"] + lines
    }

    /// Text as a Markdown quote, a line each, at every line break, with what controls how a line reads or hides text
    /// written out, and no line starting a fence (`QuotedText.oneLine`), so that all of it stays quoted.
    static func quote(_ text: String, indent: String = "") -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            let line = QuotedText.oneLine(String(line))
            return line.isEmpty ? "\(indent)>" : "\(indent)> \(line)"
        }
    }

    /// Whether a person is you.
    static func isMe(_ person: Person, _ me: String?) -> Bool {
        guard let me, !me.isEmpty else { return false }
        return person.id == me.lowercased()
    }

    /// "Priya Shah", "Priya Shah and Chen Wei", "Alex Kim, Priya Shah and Chen Wei"; past three, "and 2 more".
    static func names(_ names: [String]) -> String {
        if names.count > 3 { return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more" }
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: Who a work item waits on

    /// What you can do now: what waits on you, "complete !4091"; and what's yours and not started, unless Copilot works on
    /// it, "start task 5104", or "start it" for a work item without tasks. Otherwise, that nothing waits on you.
    static func youCan(
        _ waits: [ItemStory.Wait], read: AzureDevOpsReader.WorkItemRead, tasks: [CopilotTaskEntry], me: String?
    ) -> String {
        var things = waits.filter { $0.who == .you }.map { wait in
            var text = Substring(wait.text)
            if text.hasPrefix("you, ") { text = text.dropFirst(5) }
            if text.hasPrefix("to ") { text = text.dropFirst(3) }
            return String(text)
        }
        func toStart(_ item: WorkItem) -> Bool {
            item.category == .proposed && item.assignedTo.map { isMe($0, me) } == true
                && !tasks.contains { $0.status.phase.isActive && $0.workItem?.id == item.id && $0.onPullRequest == nil }
        }
        let yours = read.tasks.filter(toStart).map { "\($0.id)" }
        if yours.count == 1 { things.append("start task \(yours[0])") }
        if yours.count > 1 { things.append("start tasks " + names(yours)) }
        if read.tasks.isEmpty, toStart(read.item) { things.append("start it") }
        return things.isEmpty ? "nothing waits on you" : things.joined(separator: " · ")
    }

    /// Who a work item waits on, and for what: "you, to complete !4091", "reviewers of Sam Rivera's !4120", "Copilot, on
    /// 5103". From its pull requests (`PullRequestWait`), the work sent to Copilot, as the details have it
    /// (`CopilotTaskEntry.waits(of:isDone:)`), and what the other sources told, such as a Copilot session that waits for
    /// you or stopped; you first, then other people, then Copilot. Empty when nothing waits.
    static func waits(
        _ read: AzureDevOpsReader.WorkItemRead, tasks: [CopilotTaskEntry], allSent: [CopilotTaskEntry]? = nil,
        related: [MCPRelated.Item], me: String?
    ) -> [ItemStory.Wait] {
        var waits: [ItemStory.Wait] = []
        for key in read.pullRequests {
            if let snapshot = read.lists.items.first(where: { $0.key.linkRef == key.linkRef }) {
                waits += [PullRequestWait.waiting(on: snapshot, record: read.lists.records.first { $0.id.linkRef == key.linkRef })]
                    .compactMap { $0 }
            } else if let pullRequest = read.pullRequest(key) {
                waits += [PullRequestWait.waiting(on: pullRequest, me: me)].compactMap { $0 }
            }
        }
        // What the work was sent for, as read with it.
        func isDone(_ ref: ItemRef) -> Bool {
            switch ref.kind {
            case .workItem: return ([read.item] + read.tasks).first { $0.linkRef == ref }?.isDone ?? false
            case .pullRequest:
                // Whether it's one of the work item's or not, such as one a task's work went on to.
                let pullRequest = read.lists.records.first { $0.id.linkRef == ref }?.pullRequest
                    ?? read.others.read.first { $0.key.linkRef == ref }?.value
                return pullRequest.map { $0.status != .active } ?? false
            case .gitHubPullRequest, .session: return false
            }
        }
        waits += CopilotTaskEntry.waits(of: tasks, among: allSent, isDone: isDone) { ref in
            ([read.item] + read.tasks).first { $0.linkRef == ref }?.type
        }
        for item in related {
            // As its source says it, when it does, such as a session's question relayed to the one that asks it for it.
            guard item.waits.isEmpty else {
                waits += item.waits
                continue
            }
            let session = item.ref.kind == .session
            let name = session ? "session “\(item.title)”" : "“\(item.title)”"
            switch item.state {
            case .needsYou?:
                waits.append(ItemStory.Wait(.you, session ? "you, to answer in \(name)" : "you, to look at \(name)", about: item.ref))
            case .failing?: waits.append(ItemStory.Wait(.you, "you, to look at \(name), which stopped", about: item.ref))
            case .running?:
                waits.append(ItemStory.Wait(.copilot, "Copilot, " + (session ? "in \(name)" : "on \(name)"), about: item.ref))
            case .done?, nil: break
            }
        }
        return ItemStory.Wait.said(ItemStory.Wait.ordered(waits), on: read.item.linkRef)
    }

    /// What `waits` says, as the "Waiting on:" line has it.
    static func waitingOn(
        _ read: AzureDevOpsReader.WorkItemRead, tasks: [CopilotTaskEntry], related: [MCPRelated.Item], me: String?
    ) -> [String] {
        waits(read, tasks: tasks, related: related, me: me).map(\.text)
    }
}
