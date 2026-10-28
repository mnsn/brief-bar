import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation

extension AzureDevOpsCommandLine {
    /// `--mcp`: Azure DevOps for agents. They read what the app shows, with its settings and what you've seen in it,
    /// and change only which pull requests you watch and which pipelines you pin. The demo keeps those in memory.
    package static func mcp(_ options: CommandLineOptions) -> MCPSource? {
        let options = Options(options)
        let defaults = options.demo ? MemoryDefaults() : appDefaults ?? MemoryDefaults()
        let reader = AzureDevOpsReader(demo: options.demo, organizations: options.organizations, defaults: defaults)
        return AzureDevOpsAgent(reader: reader).source
    }
}

/// What `--mcp` reads from Azure DevOps, as the app shows it. One engine reads the pull requests for the whole session,
/// again only when a tool needs them and what it read is a minute old, as the app does at its most often: an agent's
/// calls one after another share one read. A read that failed in a way you can fix, by signing in, say, isn't kept. Each
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
    private var discoveryProblem: String?
    private var readAt: Date?
    /// The read under way, which says whether what it read is worth keeping.
    private var reading: Task<Bool, Never>?
    private var pipelinesRead: (at: Date, pinned: [PipelineRef], snapshot: PipelinesSnapshot)?
    private var pipelinesLoad: (pinned: [PipelineRef], task: Task<PipelinesSnapshot, Never>)?
    private var sprintRead: (at: Date, configuration: SprintEngine.Configuration, snapshot: SprintSnapshot)?
    private var sprintLoad: (configuration: SprintEngine.Configuration, task: Task<SprintSnapshot, Never>)?
    /// Tells the app its settings changed.
    private let announce: @Sendable () -> Void

    init(
        demo: Bool, organizations: [String], defaults: UserDefaults, client: ADOClient? = nil,
        announce: @escaping @Sendable () -> Void = AgentChanges.post
    ) {
        self.demo = demo
        named = organizations
        self.defaults = defaults
        self.client = demo ? nil : client ?? ADOClient(tokens: AzureCLITokenProvider())
        self.announce = announce
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
    }

    func pullRequests(now: Date = Date()) async -> PullRequests {
        let watched = watchedKeys
        if demo {
            var snapshot = DemoData.snapshot(now: now)
            snapshot.records = snapshot.records.map { watched.contains($0.id) ? $0.watched() : $0 }
            let items = AzureDevOpsCommandLine.resolve(snapshot, seen: DemoData.seenState(now: now), options: ClassifierOptions(), now: now)
            return PullRequests(records: snapshot.records, items: items, problem: nil, showToReview: false)
        }
        await readIfStale(now: now)
        let showToReview = defaults.bool(forKey: SettingsKey.showToReview)
        guard let engine else {
            return PullRequests(records: [], items: [], problem: discoveryProblem, showToReview: showToReview)
        }
        var snapshot = await engine.currentSnapshot()
        snapshot.records = snapshot.records.map { watched.contains($0.id) ? $0.watched() : $0 }
        let seen = AzureDevOpsCommandLine.seenBook(defaults).state(for: snapshot.account)
        let items = AzureDevOpsCommandLine.resolve(snapshot, seen: seen, options: AzureDevOpsCommandLine.classifierOptions(defaults), now: now)
        var problem = snapshot.problem.map { problem in
            // What fixes it, for an agent: the app has a button for it.
            if case .signedOut = problem { return problem.message + " Run az login, then ask again." }
            return problem.message
        }
        if snapshot.organizations.isEmpty, let discoveryProblem { problem = discoveryProblem }
        return PullRequests(
            records: snapshot.records, items: items, problem: problem, showToReview: showToReview, closedLinks: snapshot.closedLinks
        )
    }

    /// Reads unless what it read is fresh; a call that comes while it reads waits for that read.
    private func readIfStale(now: Date) async {
        if let reading {
            _ = await reading.value
            return
        }
        if let readAt, now.timeIntervalSince(readAt) < Self.freshFor { return }
        let task = Task { await read() }
        reading = task
        let keep = await task.value
        reading = nil
        // As of when it was asked for: a read that took a while is that much older.
        readAt = keep ? now : nil
    }

    /// Whether what was read stays for a minute: unless it failed in a way that you can fix, by signing in to the Azure
    /// CLI, say, or that a moment fixes, such as going offline. Some organizations failing still leaves the rest, and
    /// Azure DevOps asking to slow down is a reason not to read again.
    static func keeps(_ problem: PulseProblem?) -> Bool {
        switch problem {
        case nil, .someOrganizations?, .throttled?: return true
        default: return false
        }
    }

    /// Returns whether what it read is worth keeping.
    private func read() async -> Bool {
        guard let client else { return false }
        let organizations = await organizations(client: client)
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

    /// `--org`, the app's organizations, or with none chosen yet, the ones where you have pull requests.
    private func organizations(client: ADOClient) async -> [String] {
        if !named.isEmpty { return named }
        let chosen = defaults.stringArray(forKey: SettingsKey.organizations) ?? []
        if !chosen.isEmpty { return chosen }
        if let discovered { return discovered }
        do {
            let found = try await OrganizationDiscovery.discover(client: client).withPullRequests
            discovered = found
            discoveryProblem = nil
            return found
        } catch {
            discoveryProblem = "Couldn't find your organizations: \((error as? ADOError)?.description ?? error.localizedDescription)"
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
            return (read.snapshot.statuses, read.snapshot.problem?.message)
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
        return (snapshot.statuses, snapshot.problem?.message)
    }

    /// The sprint of the app's team, or with none chosen, of the first of yours with one going on today.
    func sprint(now: Date = Date()) async -> (board: SprintBoard?, problem: String?) {
        if demo { return (DemoData.sprintBoard(now: now), nil) }
        guard let client else { return (nil, nil) }
        let team = defaults.data(forKey: SettingsKey.sprintTeam).flatMap { try? JSONDecoder().decode(TeamRef.self, from: $0) }
        let configuration = SprintEngine.Configuration(organizations: await organizations(client: client), team: team)
        if let read = sprintRead, read.configuration == configuration, now.timeIntervalSince(read.at) < Self.freshFor {
            return (read.snapshot.board, read.snapshot.problem?.message)
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
        return (snapshot.board, snapshot.problem?.message)
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
                log: log, isRunning: isRunning, exitStatus: nil, stoppedByYou: run.stoppedByYou == true, output: nil
            )
            if let ended = run.ended { status.phase = ended }
            entries.append(CopilotTaskEntry(
                id: run.id, workItem: run.workItem, onPullRequest: run.onPullRequest, action: run.action, options: run.options,
                startedAt: run.startedAt, status: status, pullRequest: run.pullRequest, run: run
            ))
        }
        return entries.sorted { $0.startedAt > $1.startedAt }
    }
}

/// The tools `--mcp` gives agents for Azure DevOps.
struct AzureDevOpsAgent: Sendable {
    let reader: AzureDevOpsReader

    var source: MCPSource {
        MCPSource(name: "Azure DevOps", tools: tools) { try await needsYou() }
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
                    One pull request in detail, by its number or link: where it stands in BriefBar, its branches, \
                    reviewers' votes, checks and where a failed build failed, merge conflicts, the pipelines after its \
                    merge, what's new for the user and what they've seen that still waits on them, its unresolved \
                    comment threads word for word with their files and lines, and what Copilot can do with it.
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
            sections.append("\(group.title) (\(items.count)):\n" + items.map { AgentText.line($0, now: now) }.joined(separator: "\n"))
        }
        let pinned = await reader.pinnedStatuses(now: now)
        if pinned.statuses.isEmpty, let problem = pinned.problem {
            sections.append("BriefBar couldn't read the pinned pipelines: \(problem)")
        }
        let failed = pinned.statuses.filter { $0.latest?.status == .failed }
        if !failed.isEmpty {
            sections.append("Pinned pipelines that failed (\(failed.count)):\n" + failed.map { status in
                "- \(status.briefSentence)" + (status.latest.map { "\n  \($0.webURL.absoluteString)" } ?? "")
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
            lines += items.isEmpty ? ["None."] : items.map { AgentText.line($0, now: now) }
        }
        return lines.joined(separator: "\n")
    }

    func pullRequest(_ reference: JSONValue?, now: Date = Date()) async throws -> String {
        let read = await reader.pullRequests(now: now)
        let record = try Self.find(reference, in: read)
        let item = read.items.first { $0.key == record.id }
        let tasks = await reader.sendsToCopilot ? await reader.copilotTasks(now: now).filter { $0.isOn(record.id) } : []
        return AgentText.details(record, item: item, actions: PullRequestTasks.actions(for: record, canShip: false), tasks: tasks, now: now)
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
        return await PullRequestTasks.prompt(action, for: record, client: reader.client, workplace: .agent)
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
                lines.append("- !\(merge.pullRequest.number) “\(merge.title)” into \(merge.targetBranch), merged \(AgentText.ago(merge.mergedAt, now: now)):")
                lines.append("  \(merge.url.absoluteString)")
                for status in merge.pipelines {
                    lines += AgentText.pipeline(status, now: now).map { "  \($0)" }
                }
            }
        }
        lines.append("\n\(AgentText.legend)")
        return lines.joined(separator: "\n")
    }

    func sprint(mine: Bool, now: Date = Date()) async throws -> String {
        let (board, problem) = await reader.sprint(now: now)
        guard let board else { throw MCPToolError(problem ?? "None of your teams has a sprint going on today.") }
        var lines = WorkCLI.boardLines(mine ? board.justMine() : board, whole: board, now: now)
        if let problem { lines.insert("BriefBar couldn't read everything: \(problem)\n", at: 0) }
        lines.append("\n✓ done, ◐ in progress, ○ to do. (you) marks your own tasks.")
        return lines.joined(separator: "\n")
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
                BriefBar watches !\(found.number) “\(record.pullRequest.title)” in \(found.organization) now, and lists it until \
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
            throw MCPToolError("Couldn't read that pipeline: \((error as? ADOError)?.description ?? error.localizedDescription)")
        }
        guard await reader.pin(pipeline) else { return "“\(pipeline.name)” is pinned already." }
        return "Pinned “\(pipeline.name)”\(pipeline.branch.map { ", showing runs of \($0)" } ?? "")."
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
        return "Unpinned “\(pipeline.name)”."
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
    /// seen what's there.
    static func line(_ item: PRSnapshot, now: Date) -> String {
        var text = "- !\(item.key.number) “\(item.title)” in \(item.repository) "
            + "(\(whose(role: item.role, author: item.author, isWatched: item.isWatched, isDraft: item.isDraft))): \(item.headline)"
        if let since = item.since { text += ", \(ago(since, now: now))" }
        if item.group == .needsYou && !item.hasNews { text += " (seen, still waiting on you)" }
        // Its detail says who wrote it, when that's all it says, as whose it is does.
        if let detail = item.detail, !detail.isEmpty, detail != "By \(item.author)" { text += ". \(detail)" }
        return text + "\n  \(item.url.absoluteString)"
    }

    /// One pull request, for the `pull_request` tool.
    static func details(_ record: PRRecord, item: PRSnapshot?, actions: [PullRequestAction], tasks: [CopilotTaskEntry], now: Date) -> String {
        let pr = record.pullRequest
        var lines = ["# !\(pr.key.number) “\(pr.title)”", pr.webURL.absoluteString, ""]
        lines.append("- \(pr.repositoryName), in \(pr.projectName) (\(pr.key.organization)), from \(pr.sourceBranch) into \(pr.targetBranch)")
        var state = [record.role == .author ? "Yours, opened \(ago(pr.createdAt, now: now))" : "By \(pr.author.name), opened \(ago(pr.createdAt, now: now))"]
        state.append(pr.status.rawValue)
        if pr.isDraft { state.append("a draft") }
        if pr.autoComplete { state.append("set to complete automatically") }
        if let closed = pr.closedAt, pr.status != .active { state.append("closed \(ago(closed, now: now))") }
        lines.append("- " + state.joined(separator: ", "))
        if let item {
            var status = "- In BriefBar: \(item.group.title), \(item.headline)"
            if let since = item.since { status += ", \(ago(since, now: now))" }
            if let detail = item.detail, !detail.isEmpty { status += ". \(detail)" }
            lines.append(status)
        }
        let reviewers = pr.reviewers.map { reviewer in
            var name = reviewer.person.name
            if reviewer.isRequired { name += " (required)" }
            return "\(name): \(reviewer.hasDeclined ? "declined" : Self.vote(reviewer.vote))"
        }
        if !reviewers.isEmpty { lines.append("- Reviewers: " + reviewers.joined(separator: "; ")) }
        if let details = record.details {
            let checks = details.checks.filter { $0.state != .notApplicable }.map { check in
                var text = "\(check.name): \(Self.state(check.state))"
                if !check.isBlocking { text += " (optional)" }
                if check.state == .failed, let failure = check.failure {
                    text += ", at " + [failure.stage, failure.summary].compactMap { $0 }.joined(separator: " › ")
                }
                return text
            }
            if !checks.isEmpty { lines.append("- Checks:\n" + checks.map { "  - \($0)" }.joined(separator: "\n")) }
        }
        if pr.hasConflicts { lines.append("- It has merge conflicts with \(pr.targetBranch).") }
        if let merge = record.merge {
            lines.append("- After it merged into \(merge.targetBranch) \(ago(merge.mergedAt, now: now)):")
            for status in merge.pipelines {
                lines += Self.pipeline(status, now: now).map { "  \($0)" }
            }
        }

        let pending = item?.pendingEvents ?? []
        let news = pending.filter(\.isNew)
        if !news.isEmpty {
            lines.append("\n## New for you")
            lines += news.map { Self.event($0, now: now) }
        }
        let seen = pending.filter { !$0.isNew }
        if !seen.isEmpty {
            lines.append("\n## Seen, still waiting on you")
            lines += seen.map { Self.event($0, now: now) }
        }

        if let details = record.details {
            let threads = details.threads.filter { !$0.isResolved }
            lines.append("\n## Unresolved comment threads (\(threads.count))")
            lines.append(threads.isEmpty ? "None." : PullRequestPrompt.list(threads, record: record))
        } else if pr.status == .active {
            lines.append("\nBriefBar hasn't read its comments and checks yet.")
        }

        lines.append("\n## Copilot")
        var copilot = actions.isEmpty ? [] : ["pull_request_prompt has the prompt to: \(actions.map(\.agentName).joined(separator: ", "))."]
        if record.role == .author, pr.status == .active {
            copilot.append("Once you've changed it, push_and_reply's prompt pushes the changes and answers its threads.")
        }
        lines.append(copilot.isEmpty ? "Nothing for Copilot to do with it now." : copilot.joined(separator: " "))
        for task in tasks {
            lines.append(Self.task(task, titles: [:], workItems: [:], now: now))
        }
        return lines.joined(separator: "\n")
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

    static func event(_ event: PREvent, now: Date) -> String {
        let who = event.actor ?? "Someone"
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
        if let quote = event.text, !quote.isEmpty { text += ": “\(quote)”" }
        return text
    }

    /// A pipeline as `--pipelines` prints it, as a list item, with its latest run's link.
    static func pipeline(_ status: PipelineStatus, now: Date) -> [String] {
        var lines = WorkCLI.pipelineLines(status, now: now)
        guard !lines.isEmpty else { return [] }
        lines[0] = "- " + lines[0]
        if let run = status.latest { lines.append("  \(run.webURL.absoluteString)") }
        return lines
    }

    static let legend = "✓ succeeded, ✕ failed, ▶ running, ⏸ waiting for approval, ○ not started, ! succeeded with issues, – canceled or skipped."

    /// A task sent to Copilot: what for, how it's going, and where.
    static func task(_ task: CopilotTaskEntry, titles: [PRKey: String], workItems: [Int: String], now: Date) -> String {
        var subject: String
        if let pullRequest = task.onPullRequest {
            let key = PRKey(pullRequest.organization, pullRequest.id)
            subject = "\(task.action?.title ?? "Work") on !\(pullRequest.id)" + (titles[key].map { " “\($0)”" } ?? "") + " in \(pullRequest.repository)"
        } else if let workItem = task.workItem {
            subject = "Work item \(workItem.id)" + (workItems[workItem.id].map { " “\($0)”" } ?? "") + " in \(workItem.project)"
        } else {
            subject = "A task"
        }
        let status = task.status
        var line = "- \(subject): \(status.phase.rawValue)"
        if let since = status.since ?? (status.phase.isActive ? task.startedAt : nil) {
            line += status.phase.isActive ? ", started \(ago(task.startedAt, now: now))" : ", \(ago(since, now: now))"
        }
        if let detail = status.detail, !detail.isEmpty { line += ". \(detail)" }
        var facts = [task.options.title]
        if let run = task.run { facts += ["worktree \(run.worktree.path)", "session \(run.id)"] } else { facts.append("session \(task.id)") }
        line += "\n  " + facts.joined(separator: " · ")
        if let link = task.pullRequest { line += "\n  \(link.absoluteString)" }
        return line
    }
}
