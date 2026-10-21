import Foundation

/// What the pipelines engine knows at one point in time.
public struct PipelinesSnapshot: Sendable, Equatable {
    /// In the order the pipelines were pinned.
    public var statuses: [PipelineStatus]
    public var problem: PulseProblem?
    public var refreshedAt: Date?
    public var isRefreshing: Bool
    public var hasLoaded: Bool

    public init(
        statuses: [PipelineStatus] = [], problem: PulseProblem? = nil, refreshedAt: Date? = nil, isRefreshing: Bool = false,
        hasLoaded: Bool = false
    ) {
        self.statuses = statuses
        self.problem = problem
        self.refreshedAt = refreshedAt
        self.isRefreshing = isRefreshing
        self.hasLoaded = hasLoaded
    }
}

/// Reads the pipelines you pinned: every refresh, their recent runs (one request per project, for all its pinned
/// pipelines), and the stages of each one's latest run while it runs (one request each; a finished run's are read
/// once). It polls only while something shows them, and backs off when Azure DevOps can't be read. Every request
/// is a GET.
public actor PipelinesEngine {
    public typealias ChangeHandler = @Sendable (PipelinesSnapshot) -> Void

    public struct Configuration: Sendable, Equatable {
        public var pipelines: [PipelineRef]
        public var interval: TimeInterval
        /// Runs listed for each pipeline.
        public var runs: Int

        public init(pipelines: [PipelineRef], interval: TimeInterval = 60, runs: Int = 12) {
            self.pipelines = pipelines
            self.interval = interval
            self.runs = runs
        }
    }

    /// The most timelines read in one refresh: running runs first.
    static let timelinesPerRefresh = 6

    private struct Stages: Sendable {
        var stages: [PipelineStage]
        var failure: PipelineFailure?
        /// Read after the run finished: it won't change.
        var isFinal: Bool
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

    private var runs: [String: [PipelineRun]] = [:]
    /// Build ID → its stages.
    private var stages: [Int: Stages] = [:]
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
                if await self.isDue() { await self.refreshNow() }
                await self.waker.wait(for: await self.sleepTime())
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        waker.wake()
    }

    /// Whether something shows the pipelines. While nothing does, nothing is read; once something does, they're
    /// refreshed if they're more than half an interval old.
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
        self.configuration = configuration
        let kept = Set(configuration.pipelines.map(\.id))
        runs = runs.filter { kept.contains($0.key) }
        publish()
        if added {
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
        guard isActive, !configuration.pipelines.isEmpty else { return 3_600 }
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

    /// One refresh: the recent runs of every pinned pipeline, then the stages of the latest runs that need them.
    public func refreshNow() async {
        forced = false
        let configuration = self.configuration
        guard !configuration.pipelines.isEmpty else {
            problem = nil
            failures = 0
            hasLoaded = true
            refreshedAt = now()
            publish()
            return
        }
        isRefreshing = true
        publish()
        defer {
            isRefreshing = false
            hasLoaded = true
            refreshedAt = now()
            publish()
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
                let builds = try await client.get(url, as: ADOList<ADOBuild>.self).value
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
            } catch {
                errors.append(.network(error.localizedDescription))
            }
        }

        // The latest runs' stages: running ones every time, finished ones once.
        let latest = configuration.pipelines.compactMap { pipeline in runs[pipeline.id]?.first.map { (pipeline, $0) } }
        let due = latest
            .filter { _, run in stages[run.id].map { !$0.isFinal } ?? true }
            .sorted { lhs, rhs in (lhs.1.status.isFinished ? 1 : 0, lhs.1.id) < (rhs.1.status.isFinished ? 1 : 0, rhs.1.id) }
            .prefix(Self.timelinesPerRefresh)
        for (pipeline, run) in due where throttled == nil {
            do {
                let timeline = try await client.get(
                    ADOEndpoint.timeline(organization: pipeline.organization, projectId: pipeline.projectId, buildId: run.id), as: ADOTimeline.self
                )
                stages[run.id] = Stages(
                    stages: PipelineStage.stages(from: timeline, runFinished: run.status.isFinished),
                    failure: run.status == .failed ? PipelineFailure.first(in: timeline) : nil,
                    isFinal: run.status.isFinished
                )
            } catch ADOError.notFound {
                // A run that hasn't started has no timeline yet (Azure DevOps answers with no content).
                stages[run.id] = Stages(stages: [], failure: nil, isFinal: run.status.isFinished)
            } catch ADOError.throttled(let seconds) {
                throttled = .throttled(retryAfter: seconds)
            } catch {
                // Its stages stay as they were, and are read again next time.
            }
        }
        // Keep only the stages of runs still shown as the latest.
        let latestIds = Set(latest.map(\.1.id))
        stages = stages.filter { latestIds.contains($0.key) }

        if let throttled {
            problem = PulseProblem.from(throttled)
            failures += 1
        } else if let error = errors.first, errors.count >= groups.count {
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

    private func snapshot() -> PipelinesSnapshot {
        let statuses = configuration.pipelines.compactMap { pipeline -> PipelineStatus? in
            guard let runs = runs[pipeline.id] else { return hasLoaded ? PipelineStatus(pipeline: pipeline, runs: []) : nil }
            let latest = runs.first.flatMap { stages[$0.id] }
            return PipelineStatus(pipeline: pipeline, runs: runs, stages: latest?.stages ?? [], failure: latest?.failure)
        }
        return PipelinesSnapshot(
            statuses: statuses, problem: problem, refreshedAt: refreshedAt, isRefreshing: isRefreshing, hasLoaded: hasLoaded
        )
    }

    private func publish() {
        let current = snapshot()
        guard current != lastPublished else { return }
        lastPublished = current
        onChange(current)
    }
}

/// Finds pipelines to pin: a project's pipelines by name, and the projects to look in. Only when you search.
public enum PipelineSearch {
    public static func pipelines(
        containing text: String, organization: String, projectId: String, client: ADOClient
    ) async throws -> [PipelineRef] {
        let list = try await client.get(
            ADOEndpoint.buildDefinitions(organization: organization, projectId: projectId, containing: text), as: ADOList<ADOBuildDefinition>.self
        )
        return list.value.compactMap { PipelineRef(organization: organization, $0) }
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
