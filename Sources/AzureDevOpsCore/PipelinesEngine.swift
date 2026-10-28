import Foundation

/// What the pipelines engine knows at one point in time.
public struct PipelinesSnapshot: Sendable, Equatable {
    /// In the order the pipelines were pinned.
    public var statuses: [PipelineStatus]
    public var pullRequests: [PullRequestPipelines]
    public var problem: PulseProblem?
    public var refreshedAt: Date?
    public var isRefreshing: Bool
    public var hasLoaded: Bool

    public init(
        statuses: [PipelineStatus] = [], problem: PulseProblem? = nil, refreshedAt: Date? = nil, isRefreshing: Bool = false,
        hasLoaded: Bool = false, pullRequests: [PullRequestPipelines] = []
    ) {
        self.statuses = statuses
        self.pullRequests = pullRequests
        self.problem = problem
        self.refreshedAt = refreshedAt
        self.isRefreshing = isRefreshing
        self.hasLoaded = hasLoaded
    }
}

/// Reads pinned pipelines and your active PRs' validation runs: every refresh, their recent runs (one request per
/// pinned project/branch and per PR), and the stages of each latest run while it runs (a finished run's are read
/// once). It polls only while something shows them, stops reading when they're hidden mid-refresh, and backs off
/// when Azure DevOps can't be read. Every request is a GET.
public actor PipelinesEngine {
    public typealias ChangeHandler = @Sendable (PipelinesSnapshot) -> Void

    public struct Configuration: Sendable, Equatable {
        public var pipelines: [PipelineRef]
        public var pullRequests: [PullRequest]
        public var interval: TimeInterval
        /// Runs listed for each pipeline.
        public var runs: Int

        public init(pipelines: [PipelineRef], interval: TimeInterval = 60, runs: Int = 12, pullRequests: [PullRequest] = []) {
            self.pipelines = pipelines
            self.pullRequests = pullRequests.filter { $0.status == .active }
            self.interval = interval
            self.runs = runs
        }
    }

    /// The most timelines read in one refresh: the ones never read first, then the ones read longest ago.
    static let timelinesPerRefresh = 6
    /// A timeline that keeps failing is tried less and less often, up to this.
    static let longestTimelineBackoff: TimeInterval = 1_800

    /// A run: build IDs are unique only within an organization.
    struct RunKey: Hashable, Sendable {
        var organization: String
        var projectId: String
        var buildId: Int

        init(_ pipeline: PipelineRef, _ run: PipelineRun) {
            organization = pipeline.organization
            projectId = pipeline.projectId
            buildId = run.id
        }
    }

    /// What a timeline was read for: a run that's retried runs again, under the same build ID.
    struct RunState: Equatable, Sendable {
        var status: PipelineRun.Status
        var finishedAt: Date?

        init(_ run: PipelineRun) {
            status = run.status
            finishedAt = run.finishedAt
        }
    }

    private struct Stages: Sendable {
        var stages: [PipelineStage]
        var failure: PipelineFailure?
        var readFor: RunState
        var readAt: Date
        /// It won't change until the run does: the run had finished, or its timeline may not be read.
        var isFinal: Bool
    }

    /// Timeline reads in a row that failed, and when the last one was.
    private struct Attempts: Sendable {
        var last: Date
        var failures: Int
    }

    private let client: ADOClient
    private var configuration: Configuration
    private let onChange: ChangeHandler
    private let now: @Sendable () -> Date
    private let waker = Waker()
    private var loop: Task<Void, Never>?
    private var isActive = false
    private var forced = false
    private var catchUp = false
    /// The timer's refresh, which stops when nothing shows the pipelines any more; a one-off load doesn't.
    private var isPolling = false

    /// Whose sign-in the runs and stages were read with.
    private var account: String?
    private var runs: [String: [PipelineRun]] = [:]
    private var pullRequestBuilds: [PRKey: [ADOBuild]] = [:]
    private var stages: [RunKey: Stages] = [:]
    private var attempts: [RunKey: Attempts] = [:]
    private var problem: PulseProblem?
    private var refreshedAt: Date?
    private var hasLoaded = false
    private var isRefreshing = false
    private var failures = 0
    private var lastPublished: PipelinesSnapshot?

    public init(
        client: ADOClient, configuration: Configuration, now: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping ChangeHandler
    ) {
        self.client = client
        self.configuration = configuration
        self.now = now
        self.onChange = onChange
    }

    /// Refreshes on every interval while active, until stopped.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.isDue() { await self.refresh(polling: true) }
                await self.waker.wait(for: await self.sleepTime())
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        waker.wake()
    }

    /// Whether something shows the pipelines. While nothing does, nothing is read, and a refresh under way stops
    /// before its next request; once something does, they're refreshed if they're more than half an interval old.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            catchUp = true
            waker.wake()
        }
    }

    /// Refreshes as soon as possible, if something shows the pipelines.
    public func refresh() {
        forced = true
        waker.wake()
    }

    public func setConfiguration(_ configuration: Configuration) {
        guard configuration != self.configuration else { return }
        let added = !Set(configuration.pipelines).subtracting(self.configuration.pipelines).isEmpty
        let changedPRs = configuration.pullRequests != self.configuration.pullRequests
        self.configuration = configuration
        let kept = Set(configuration.pipelines.map(\.id))
        runs = runs.filter { kept.contains($0.key) }
        let keptPRs = Set(configuration.pullRequests.map(\.key))
        pullRequestBuilds = pullRequestBuilds.filter { keptPRs.contains($0.key) }
        publish()
        if added || changedPRs {
            forced = true
            waker.wake()
        }
    }

    /// One load, without the timer: for the command line and tests.
    public static func loadOnce(client: ADOClient, configuration: Configuration) async -> PipelinesSnapshot {
        let engine = PipelinesEngine(client: client, configuration: configuration) { _ in }
        await engine.refreshNow()
        return await engine.currentSnapshot()
    }

    public func currentSnapshot() -> PipelinesSnapshot {
        snapshot()
    }

    private func isDue() -> Bool {
        guard isActive else { return false }
        if forced { return true }
        guard let refreshedAt else { return true }
        let age = now().timeIntervalSince(refreshedAt)
        if catchUp {
            catchUp = false
            if age >= configuration.interval / 2 { return true }
        }
        return age >= nextDelay() - 1
    }

    /// How long to sleep: until the next refresh is due while active, and until woken while not, or while
    /// nothing is pinned (pinning one wakes it).
    func sleepTime() -> TimeInterval {
        guard isActive, !configuration.pipelines.isEmpty || !configuration.pullRequests.isEmpty else { return 3_600 }
        guard let refreshedAt else { return 1 }
        return max(1, nextDelay() - now().timeIntervalSince(refreshedAt))
    }

    func nextDelay() -> TimeInterval {
        let interval = configuration.interval
        switch problem {
        case .throttled(let until)?:
            return max(until.timeIntervalSince(now()), interval)
        case .cliNotFound?, .signedOut?, .authFailed?:
            return min(interval, 60)
        default:
            guard failures > 0 else { return interval }
            return min(interval * pow(2, Double(min(failures, 4))), 600)
        }
    }

    // MARK: Refreshing

    /// One refresh, start to finish: the recent runs of every pinned pipeline, then the stages of the latest runs
    /// that need them.
    public func refreshNow() async {
        await refresh(polling: false)
    }

    /// A refresh by the timer stops before its next request once nothing shows the pipelines, keeping what it read.
    private func refresh(polling: Bool) async {
        forced = false
        isPolling = polling
        defer { isPolling = false }
        let configuration = self.configuration
        guard !configuration.pipelines.isEmpty || !configuration.pullRequests.isEmpty else {
            problem = nil
            failures = 0
            hasLoaded = true
            refreshedAt = now()
            publish()
            return
        }
        isRefreshing = true
        publish()
        let startedAt = now()
        do {
            try await load(configuration, at: startedAt)
            hasLoaded = true
            refreshedAt = now()
        } catch is CancellationError {
            // Hidden while it read: the rest waits until something shows the pipelines again.
        } catch let error as ADOError {
            problem = PulseProblem.from(error)
            failures += 1
            hasLoaded = true
            refreshedAt = now()
        } catch {
            problem = .unreachable(error.localizedDescription)
            failures += 1
            hasLoaded = true
            refreshedAt = now()
        }
        isRefreshing = false
        publish()
    }

    /// Stops a refresh by the timer before another request when nothing shows the pipelines any more.
    private func get<T: Decodable & Sendable>(_ url: URL, as type: T.Type) async throws -> T {
        if isPolling && !isActive { throw CancellationError() }
        return try await client.get(url, as: type)
    }

    private func load(_ configuration: Configuration, at startedAt: Date) async throws {
        // Someone else signed in to the Azure CLI: the runs and stages read as the last one aren't theirs to see.
        let token: AccessToken
        do {
            token = try await client.tokens.token()
        } catch let error as AuthError {
            throw ADOError.auth(error)
        }
        if let signedIn = token.account {
            if let account, account != signedIn {
                runs = [:]
                pullRequestBuilds = [:]
                stages = [:]
                attempts = [:]
            }
            account = signedIn
        }

        // One request per project and branch filter, for all of its pinned pipelines.
        var groups: [String: [PipelineRef]] = [:]
        for pipeline in configuration.pipelines {
            groups["\(pipeline.organization)/\(pipeline.projectId)/\(pipeline.branch ?? "")", default: []].append(pipeline)
        }
        // Errors reading the lists, which say whether the page is up to date; a run's stages are extra.
        var errors: [ADOError] = []
        var throttled: ADOError?
        for key in groups.keys.sorted() {
            guard let pipelines = groups[key], let first = pipelines.first else { continue }
            do {
                let url = ADOEndpoint.builds(
                    organization: first.organization, projectId: first.projectId, definitionIds: pipelines.map(\.definitionId),
                    branch: first.branch, perDefinition: configuration.runs
                )
                let builds = try await get(url, as: ADOList<ADOBuild>.self).value
                for pipeline in pipelines {
                    runs[pipeline.id] = builds
                        .filter { $0.definition.id == pipeline.definitionId }
                        .map { PipelineRun(organization: pipeline.organization, projectName: pipeline.projectName, $0) }
                        .sorted { ($0.queuedAt ?? .distantPast, $0.id) > ($1.queuedAt ?? .distantPast, $1.id) }
                }
            } catch let error as ADOError {
                errors.append(error)
                if case .throttled = error {
                    throttled = error
                    break
                }
            }
        }

        for pr in configuration.pullRequests where throttled == nil {
            guard self.configuration.pullRequests.contains(where: { $0.key == pr.key }) else { continue }
            do {
                let builds = try await get(ADOEndpoint.pullRequestBuilds(pr), as: ADOList<ADOBuild>.self).value
                // Configuration can change while a request is in flight, including a PR closing.
                if self.configuration.pullRequests.contains(where: { $0.key == pr.key }) {
                    pullRequestBuilds[pr.key] = builds
                }
            } catch let error as ADOError {
                errors.append(error)
                if case .throttled = error { throttled = error }
            }
        }

        // The latest runs' stages: while a run runs, and once more each time it finishes (again, when it's retried).
        let pinned = configuration.pipelines.compactMap { pipeline in
            runs[pipeline.id]?.first.map { (pipeline: pipeline, run: $0, key: RunKey(pipeline, $0)) }
        }
        let prRuns = pullRequests().flatMap(\.pipelines).compactMap { status in
            status.latest.map { (pipeline: status.pipeline, run: $0, key: RunKey(status.pipeline, $0)) }
        }
        var seen: Set<RunKey> = []
        let latest = (pinned + prRuns).filter { seen.insert($0.key).inserted }
        let interval = configuration.interval
        let due = latest
            .filter { item in
                if let read = stages[item.key], read.isFinal, read.readFor == RunState(item.run) { return false }
                // One that keeps failing: again on the next refresh, then less and less often.
                guard let tried = attempts[item.key], tried.failures > 1 else { return true }
                let wait = min(interval * pow(2, Double(tried.failures - 2)), Self.longestTimelineBackoff)
                return startedAt.timeIntervalSince(tried.last) >= wait
            }
            // The ones never read first, then the ones read or tried longest ago: a few that keep failing don't hold
            // up the rest.
            .sorted { lhs, rhs in
                (lastTouched(lhs.key), lhs.run.status.isFinished ? 1 : 0, lhs.key.organization, lhs.run.id)
                    < (lastTouched(rhs.key), rhs.run.status.isFinished ? 1 : 0, rhs.key.organization, rhs.run.id)
            }
            .prefix(Self.timelinesPerRefresh)
        for item in due where throttled == nil {
            let state = RunState(item.run)
            do {
                let timeline = try await get(
                    ADOEndpoint.timeline(organization: item.pipeline.organization, projectId: item.pipeline.projectId, buildId: item.run.id),
                    as: ADOTimeline.self
                )
                stages[item.key] = Stages(
                    stages: PipelineStage.stages(from: timeline, runFinished: item.run.status.isFinished),
                    failure: item.run.status == .failed ? PipelineFailure.first(in: timeline) : nil,
                    readFor: state, readAt: startedAt, isFinal: item.run.status.isFinished
                )
                attempts[item.key] = nil
            } catch ADOError.notFound {
                // A run that hasn't started has no timeline yet (Azure DevOps answers with no content).
                stages[item.key] = Stages(stages: [], failure: nil, readFor: state, readAt: startedAt, isFinal: item.run.status.isFinished)
                attempts[item.key] = nil
            } catch ADOError.forbidden {
                // You may see the run but not its timeline: don't ask again until the run changes.
                stages[item.key] = Stages(stages: [], failure: nil, readFor: state, readAt: startedAt, isFinal: true)
                attempts[item.key] = nil
            } catch ADOError.throttled(let seconds) {
                throttled = .throttled(retryAfter: seconds)
            } catch is ADOError {
                // Its stages stay as they were, and are tried again later.
                let failures = (attempts[item.key]?.failures ?? 0) + 1
                attempts[item.key] = Attempts(last: startedAt, failures: failures)
            }
        }
        // Keep only what's about runs still shown as the latest.
        let latestKeys = Set(latest.map(\.key))
        stages = stages.filter { latestKeys.contains($0.key) }
        attempts = attempts.filter { latestKeys.contains($0.key) }

        if let throttled {
            problem = PulseProblem.from(throttled)
            failures += 1
        } else if let error = errors.first, errors.count >= groups.count + configuration.pullRequests.count {
            problem = PulseProblem.from(error)
            failures += 1
        } else if let error = errors.first {
            problem = .unreachable("Couldn't read some pipelines: \(error.description)")
            failures = 0
        } else {
            problem = nil
            failures = 0
        }
    }

    /// When a run's timeline was last read or tried; never, first.
    private func lastTouched(_ key: RunKey) -> Date {
        max(stages[key]?.readAt ?? .distantPast, attempts[key]?.last ?? .distantPast)
    }

    private func snapshot() -> PipelinesSnapshot {
        let statuses = configuration.pipelines.compactMap { pipeline -> PipelineStatus? in
            guard let runs = runs[pipeline.id] else { return hasLoaded ? PipelineStatus(pipeline: pipeline, runs: []) : nil }
            // Stages read for the run as it is now: not a retried run's last attempt.
            let latest = runs.first.flatMap { run in stages[RunKey(pipeline, run)].flatMap { $0.readFor == RunState(run) ? $0 : nil } }
            return PipelineStatus(pipeline: pipeline, runs: runs, stages: latest?.stages ?? [], failure: latest?.failure)
        }
        return PipelinesSnapshot(
            statuses: statuses, problem: problem, refreshedAt: refreshedAt, isRefreshing: isRefreshing, hasLoaded: hasLoaded,
            pullRequests: pullRequests()
        )
    }

    private func pullRequests() -> [PullRequestPipelines] {
        configuration.pullRequests.map { pr in
            PullRequestPipelines(pullRequest: pr, builds: pullRequestBuilds[pr.key]) { pipeline, runs in
                let latest = runs.first.flatMap { run in
                    stages[RunKey(pipeline, run)].flatMap { $0.readFor == RunState(run) ? $0 : nil }
                }
                return PipelineStatus(pipeline: pipeline, runs: runs, stages: latest?.stages ?? [], failure: latest?.failure)
            }
        }
    }

    private func publish() {
        let current = snapshot()
        guard current != lastPublished else { return }
        lastPublished = current
        onChange(current)
    }
}

/// Finds pipelines to pin: a project's pipelines by name or number, and the projects to look in. Only when you search.
public enum PipelineSearch {
    /// A project's pipelines whose names contain `text`. When it's a number, such as `1234` or `#1234`, the pipeline
    /// with that ID (`definitionId=1234` in its address) comes first, found at the same time.
    public static func pipelines(
        containing text: String, organization: String, projectId: String, client: ADOClient
    ) async throws -> [PipelineRef] {
        async let named = definitions(
            ADOEndpoint.buildDefinitions(organization: organization, projectId: projectId, containing: text), organization: organization, client: client
        )
        var numbered: [PipelineRef] = []
        if let id = number(in: text) {
            numbered = try await definitions(
                ADOEndpoint.buildDefinitions(organization: organization, projectId: projectId, ids: [id]), organization: organization, client: client
            )
        }
        return merge(numbered: numbered, named: try await named)
    }

    /// Pipelines at hand, such as the demo's, searched as Azure DevOps would.
    public static func pipelines(_ all: [PipelineRef], containing text: String) -> [PipelineRef] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let id = number(in: text)
        return merge(
            numbered: all.filter { $0.definitionId == id },
            named: all.filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
        )
    }

    /// The pipeline ID a search is, such as `1234` or `#1234`; nil for a name. Azure DevOps's are positive 32-bit numbers.
    public static func number(in text: String) -> Int? {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        if digits.first == "#" { digits = digits.dropFirst() }
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int32(digits), id > 0 else { return nil }
        return Int(id)
    }

    /// The pipeline with the number first, then the ones named like it, each once.
    private static func merge(numbered: [PipelineRef], named: [PipelineRef]) -> [PipelineRef] {
        numbered + named.filter { pipeline in !numbered.contains { $0.id == pipeline.id } }
    }

    private static func definitions(_ url: URL, organization: String, client: ADOClient) async throws -> [PipelineRef] {
        try await client.get(url, as: ADOList<ADOBuildDefinition>.self).value.compactMap { PipelineRef(organization: organization, $0) }
    }

    /// The pipeline a link is to: the pipeline's own, or one of its runs', showing then that run's branch, unless it's a
    /// pull request's.
    public static func pipeline(for link: PipelineLink, client: ADOClient) async throws -> PipelineRef {
        switch link.target {
        case .pipeline(let id):
            let definition = try await client.get(
                ADOEndpoint.buildDefinition(organization: link.organization, project: link.project, id: id), as: ADOBuildDefinition.self
            )
            guard let pipeline = PipelineRef(organization: link.organization, definition) else { throw ADOError.notFound }
            return pipeline
        case .run(let id):
            let build = try await client.get(ADOEndpoint.build(organization: link.organization, project: link.project, id: id), as: ADOBuild.self)
            guard let project = build.project else { throw ADOError.notFound }
            var pipeline = PipelineRef(
                organization: link.organization, projectId: project.id, projectName: project.name, definitionId: build.definition.id,
                name: PlainText.singleLine(build.definition.name ?? "Pipeline \(build.definition.id)"),
                folder: PipelineRef.folder(build.definition.path)
            )
            if let branch = build.sourceBranch, branch.hasPrefix("refs/heads/") {
                pipeline.branch = PipelineRun.branch(branch)
            }
            return pipeline
        }
    }

    /// An organization's projects, by name.
    public static func projects(organization: String, client: ADOClient) async throws -> [ProjectRef] {
        let list = try await client.get(ADOEndpoint.projects(organization: organization), as: ADOList<ADOProjectRef>.self)
        return list.value
            .map { ProjectRef(organization: organization, id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A project to search for pipelines in.
public struct ProjectRef: Sendable, Codable, Hashable, Identifiable {
    public var organization: String
    public var id: String
    public var name: String

    public init(organization: String, id: String, name: String) {
        self.organization = organization
        self.id = id
        self.name = name
    }
}
