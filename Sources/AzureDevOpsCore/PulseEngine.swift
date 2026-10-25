import Foundation
import Synchronization

/// Why the list may be missing or out of date.
public enum PulseProblem: Sendable, Equatable {
    case noOrganizations
    case cliNotFound
    case signedOut(String)
    case authFailed(String)
    case offline
    case throttled(until: Date)
    /// Nothing could be read; the list shown is the last one that could.
    case unreachable(String)
    /// Some organizations couldn't be read.
    case someOrganizations(String)

    public var message: String {
        switch self {
        case .noOrganizations: return "No Azure DevOps organizations to watch yet."
        case .cliNotFound: return "BriefBar signs in with the Azure CLI, which isn't installed."
        case .signedOut: return "Sign in to the Azure CLI to see your pull requests."
        case .authFailed(let message): return "Couldn't get a token from the Azure CLI: \(message)"
        case .offline: return "You're offline. The list may be out of date."
        case .throttled(let until):
            return "Azure DevOps asked BriefBar to slow down, until \(until.formatted(date: .omitted, time: .shortened))."
        case .unreachable(let message): return "\(message) The list may be out of date."
        case .someOrganizations(let message): return message
        }
    }

    /// Fixed by signing in (or installing the Azure CLI first).
    public var needsSignIn: Bool {
        switch self {
        case .cliNotFound, .signedOut: return true
        default: return false
        }
    }

    public static func from(_ error: ADOError, organization: String? = nil) -> PulseProblem {
        switch error {
        case .auth(.cliNotFound): return .cliNotFound
        case .auth(.signedOut(let message)): return .signedOut(message)
        case .auth(.failed(let message)): return .authFailed(message)
        case .offline: return .offline
        case .throttled(let seconds): return .throttled(until: Date().addingTimeInterval(seconds))
        case .unauthorized: return .signedOut(error.description)
        default:
            let prefix = organization.map { "Can't read \($0): " } ?? ""
            return .unreachable(prefix + error.description)
        }
    }
}

/// Everything the engine knows at one point in time.
public struct PulseSnapshot: Sendable, Equatable {
    public var records: [PRRecord]
    public var organizations: [String]
    /// Who's signed in to the Azure CLI (`AccessToken.account`), when known: the records are theirs.
    public var account: String?
    /// Your name, as Azure DevOps knows it.
    public var userName: String?
    /// When each organization's lists were first read: what happened there before is in the panel, not news.
    public var firstLoaded: [String: Date]
    public var problem: PulseProblem?
    public var refreshedAt: Date?
    public var isRefreshing: Bool
    public var hasLoaded: Bool

    public init(
        records: [PRRecord] = [], organizations: [String] = [], account: String? = nil, userName: String? = nil,
        firstLoaded: [String: Date] = [:], problem: PulseProblem? = nil, refreshedAt: Date? = nil, isRefreshing: Bool = false,
        hasLoaded: Bool = false
    ) {
        self.records = records
        self.organizations = organizations
        self.account = account
        self.userName = userName
        self.firstLoaded = firstLoaded
        self.problem = problem
        self.refreshedAt = refreshedAt
        self.isRefreshing = isRefreshing
        self.hasLoaded = hasLoaded
    }
}

/// Polls Azure DevOps: the pull request lists every refresh (three requests per organization), the details of the
/// pull requests the `RefreshPlanner` picks (two requests each), and, once, the timeline of each failed build of your
/// pull requests, for where it failed. Azure DevOps can't push changes to a personal app, and pull requests and builds
/// take minutes to hours, so a refresh a minute is plenty. Every request is a GET.
public actor PulseEngine {
    public typealias ChangeHandler = @Sendable (PulseSnapshot) -> Void

    public struct Configuration: Sendable, Equatable {
        public var organizations: [String]
        public var interval: TimeInterval
        /// Completed pull requests from this far back are listed (as Done).
        public var keepDoneFor: TimeInterval
        /// Drafts and pull requests idle for this long have their details refreshed less often.
        public var inactiveAfter: TimeInterval?
        public var planner: RefreshPlanner.Options
        /// Pull requests whose details are fetched at the same time.
        public var concurrency: Int
        /// Follows the pipelines that run after you merge a pull request, while Done keeps it.
        public var followMerges: Bool

        public init(
            organizations: [String], interval: TimeInterval = 60, keepDoneFor: TimeInterval = 86_400,
            inactiveAfter: TimeInterval? = 14 * 86_400, planner: RefreshPlanner.Options = RefreshPlanner.Options(),
            concurrency: Int = 4, followMerges: Bool = true
        ) {
            self.organizations = organizations
            self.interval = interval
            self.keepDoneFor = keepDoneFor
            self.inactiveAfter = inactiveAfter
            self.planner = planner
            self.concurrency = concurrency
            self.followMerges = followMerges
        }
    }

    private struct Listed: Sendable {
        var pullRequest: PullRequest
        var role: PRRole
    }

    /// One read of a pull request's details. Its policies and its threads are read separately, and either can fail
    /// while the other doesn't.
    private struct DetailsRead: Sendable {
        /// The policies, nil when the project doesn't let you read them; or what went wrong reading them.
        var policies: Result<[ADOPolicyEvaluation]?, ADOError>
        var threads: Result<[ADOThread], ADOError>

        var errors: [ADOError] {
            var errors: [ADOError] = []
            if case .failure(let error) = policies { errors.append(error) }
            if case .failure(let error) = threads { errors.append(error) }
            return errors
        }
    }

    /// One of your pull requests that left the active list without showing up as completed.
    private struct Vanished: Sendable {
        var pullRequest: PullRequest
        /// When it left the list.
        var since: Date
        /// When it was last looked up, and how many lookups in a row failed.
        var lastLookup: Date?
        var failures = 0

        /// Whether to look it up on a refresh at `date`: right away, again on the next refresh if that fails, then
        /// less and less often, so the ones that keep failing don't cost requests every refresh.
        func isDue(at date: Date, interval: TimeInterval) -> Bool {
            guard let lastLookup, failures > 1 else { return true }
            return date.timeIntervalSince(lastLookup) >= min(interval * pow(2, Double(failures - 2)), 1_800)
        }
    }

    private struct OrganizationLists: Sendable {
        var me: String
        var name: String?
        var mine: [PullRequest]
        var reviewing: [PullRequest]
        var completed: [PullRequest]
    }

    /// A failed build of one of your pull requests, whose timeline says where it failed. A build that's retried keeps
    /// its ID and fails again later, so when it completed is part of it.
    private struct FailedBuild: Hashable, Sendable {
        var organization: String
        var projectId: String
        var buildId: Int
        var completedAt: Date?
    }

    /// The most failed builds whose timelines are read in one refresh: each is read once.
    static let buildTimelinesPerRefresh = 4
    /// The most merges whose runs are looked for in one refresh, the newest first.
    static let mergesPerRefresh = 5
    /// The most timelines of runs after merges read in one refresh: a run's while it runs, and once when it finishes.
    static let mergeTimelinesPerRefresh = 4

    /// What's known of the pipelines after one of your merges.
    private struct MergeFollow: Sendable {
        struct Found: Sendable {
            var pipeline: PipelineRef
            var run: PipelineRun
        }

        struct Timeline: Sendable {
            var stages: [PipelineStage]
            var failure: PipelineFailure?
            /// The run's status when it was read: a finished run's is read once more.
            var readFor: PipelineRun.Status
            var readAt: Date
        }

        /// The runs found so far, by ID.
        var runs: [Int: Found] = [:]
        var timelines: [Int: Timeline] = [:]
        /// When the runs were last looked for, and how many lookups in a row failed.
        var lastLookup: Date?
        var failures = 0

        /// Each pipeline's runs, newest first, the pipelines in the order their first runs were queued.
        var byPipeline: [(pipeline: PipelineRef, runs: [PipelineRun])] {
            let grouped = Dictionary(grouping: runs.values, by: \.pipeline.id)
            return grouped.values
                .map { found in
                    (pipeline: found[0].pipeline,
                     runs: found.map(\.run).sorted { ($0.queuedAt ?? .distantPast, $0.id) > ($1.queuedAt ?? .distantPast, $1.id) })
                }
                .sorted { lhs, rhs in
                    (lhs.runs.compactMap(\.queuedAt).min() ?? .distantFuture, lhs.pipeline.definitionId)
                        < (rhs.runs.compactMap(\.queuedAt).min() ?? .distantFuture, rhs.pipeline.definitionId)
                }
        }

        var latestRuns: [PipelineRun] { byPipeline.compactMap(\.runs.first) }
    }

    private let client: ADOClient
    private var configuration: Configuration
    private let onChange: ChangeHandler
    private let now: @Sendable () -> Date
    private let waker = Waker()
    private var loop: Task<Void, Never>?

    /// Organization → your identity ID there.
    private var identities: [String: String] = [:]
    /// Whose sign-in the identities, lists and details are for.
    private var account: String?
    private var userName: String?
    private var firstLoaded: [String: Date] = [:]
    /// Pull requests people sent you, to list even when you're not on them.
    private var linkedKeys: Set<PRKey> = []
    /// Linked pull requests that couldn't be read or are closed, and when, to try again only an hour later.
    private var linkedFailures: [PRKey: Date] = [:]
    /// Linked pull requests as last read, and when: kept between refreshes, which read only a few each.
    private var linked: [PRKey: (listed: Listed, readAt: Date)] = [:]
    private var active: [PRKey: Listed] = [:]
    private var done: [PRKey: PullRequest] = [:]
    private var details: [PRKey: PRDetails] = [:]
    private var entries: [PRKey: RefreshPlanner.Entry] = [:]
    /// Your pull requests that left the active list without completing: abandoned, or completed just now. Each
    /// is looked up by its ID, a few per refresh, until that works or it's too old to show as done.
    private var vanished: [PRKey: Vanished] = [:]
    /// Where your pull requests' failed builds failed, from their timelines; and which have been read, including the
    /// ones whose timelines had nothing to say or couldn't be read for good.
    private var buildFailures: [FailedBuild: PipelineFailure] = [:]
    private var buildsRead: Set<FailedBuild> = []
    /// Failed builds whose timelines couldn't be read: when last tried, and how many tries in a row failed.
    private var buildAttempts: [FailedBuild: (last: Date, failures: Int)] = [:]
    /// The pipelines after your merges, by pull request, while Done keeps it.
    private var merges: [PRKey: MergeFollow] = [:]
    private var problem: PulseProblem?
    private var refreshedAt: Date?
    private var hasLoaded = false
    private var isRefreshing = false
    /// Refreshes in a row that read nothing, for backing off.
    private var failures = 0
    private var lastPublished: PulseSnapshot?

    public init(
        client: ADOClient, configuration: Configuration, now: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping ChangeHandler
    ) {
        self.client = client
        self.configuration = configuration
        self.now = now
        self.onChange = onChange
    }

    /// Refreshes now and then on every interval, until stopped.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNow()
                let delay = await self.nextDelay()
                await self.waker.wait(for: delay)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        waker.wake()
    }

    /// Asks for a refresh as soon as possible, for example when the panel opens or the Mac wakes.
    public nonisolated func refresh() {
        waker.wake()
    }

    public func setConfiguration(_ configuration: Configuration) {
        guard configuration != self.configuration else { return }
        let organizationsChanged = configuration.organizations != self.configuration.organizations
        self.configuration = configuration
        if organizationsChanged {
            let kept = Set(configuration.organizations)
            // Pull requests people sent you stay, whichever organizations are watched.
            active = active.filter { kept.contains($0.key.organization) || linked[$0.key] != nil }
            done = done.filter { kept.contains($0.key.organization) }
            vanished = vanished.filter { kept.contains($0.key.organization) }
            firstLoaded = firstLoaded.filter { kept.contains($0.key) }
            publish()
        }
        waker.wake()
    }

    /// One load, without the timer: for the command line and tests.
    public static func loadOnce(client: ADOClient, configuration: Configuration, linked: Set<PRKey> = []) async -> PulseSnapshot {
        let engine = PulseEngine(client: client, configuration: configuration) { _ in }
        await engine.setLinkedPullRequests(linked)
        await engine.refreshNow()
        return await engine.currentSnapshot()
    }

    /// Pull requests people sent you. The ones not in your lists are read by ID, and listed as `linked`.
    public func setLinkedPullRequests(_ keys: Set<PRKey>) {
        guard keys != linkedKeys else { return }
        let added = !keys.subtracting(linkedKeys).isEmpty
        linkedKeys = keys
        linkedFailures = linkedFailures.filter { keys.contains($0.key) }
        // The ones listed only because someone sent them go with their links, now rather than on the next refresh.
        let gone = Set(linked.keys).subtracting(keys)
        linked = linked.filter { keys.contains($0.key) }
        for key in gone {
            active[key] = nil
            details[key] = nil
            entries[key] = nil
        }
        if configuration.organizations.isEmpty && keys.isEmpty { listNothing() }
        publish()
        if added { waker.wake() }
    }

    public func currentSnapshot() -> PulseSnapshot {
        snapshot()
    }

    /// One refresh: the lists, then the details the planner picks.
    public func refreshNow() async {
        let configuration = self.configuration
        let organizations = configuration.organizations
        // Pull requests people sent you are read even without organizations to watch.
        guard !organizations.isEmpty || !linkedKeys.isEmpty else {
            listNothing()
            publish()
            return
        }
        isRefreshing = true
        publish()
        defer {
            isRefreshing = false
            hasLoaded = true
            publish()
        }

        // Signing in comes first: nothing works without a token, and a failure here says exactly what's wrong.
        let token: AccessToken
        do {
            token = try await client.tokens.token()
        } catch {
            problem = PulseProblem.from((error as? AuthError).map(ADOError.auth) ?? .auth(.failed(String(describing: error))))
            failures += 1
            return
        }
        // Someone else signed in: your identity in each organization, and everything read as the last one, is out
        // of date.
        if let signedIn = token.account {
            if let account, account != signedIn { forgetAccount() }
            account = signedIn
        }

        let startedAt = now()
        let closedSince = startedAt.addingTimeInterval(-configuration.keepDoneFor)
        let client = self.client
        let known = identities
        var results: [String: Result<OrganizationLists, ADOError>] = [:]
        await withTaskGroup(of: (String, Result<OrganizationLists, ADOError>).self) { group in
            for organization in organizations {
                group.addTask {
                    (organization, await Self.lists(organization, me: known[organization], client: client, closedSince: closedSince))
                }
            }
            for await (organization, result) in group {
                results[organization] = result
            }
        }

        var listed: [PRKey: Listed] = [:]
        var completed: [PRKey: PullRequest] = [:]
        var errors: [(String, ADOError)] = []
        for organization in organizations {
            switch results[organization] {
            case .success(let lists):
                identities[organization] = lists.me
                if let name = lists.name { userName = name }
                if firstLoaded[organization] == nil { firstLoaded[organization] = startedAt }
                for pr in lists.mine where pr.status == .active {
                    listed[pr.key] = Listed(pullRequest: pr, role: .author)
                }
                for pr in lists.reviewing where pr.status == .active && pr.author.id != lists.me && listed[pr.key] == nil {
                    listed[pr.key] = Listed(pullRequest: pr, role: .reviewer)
                }
                for pr in lists.completed {
                    completed[pr.key] = pr
                }
            case .failure(let error):
                errors.append((organization, error))
                // Keep what we had until it can be read again.
                for (key, item) in active where key.organization == organization { listed[key] = item }
                for (key, pr) in done where key.organization == organization { completed[key] = pr }
            case nil:
                break
            }
        }

        if errors.count == organizations.count, let (organization, error) = errors.first {
            problem = PulseProblem.from(error, organization: organizations.count > 1 ? organization : nil)
            failures += 1
            return
        }
        failures = 0

        // Your pull requests that left the active list without completing were abandoned (or completed
        // just now): look each up by its ID, a few per refresh, and again next time if that fails.
        let succeeded = Set(organizations).subtracting(errors.map(\.0))
        for item in active.values where item.role == .author && succeeded.contains(item.pullRequest.key.organization) {
            let key = item.pullRequest.key
            if listed[key] == nil, completed[key] == nil, vanished[key] == nil {
                vanished[key] = Vanished(pullRequest: item.pullRequest, since: startedAt)
            }
        }
        // Back in the list, listed as completed, or gone longer than Done shows anything.
        vanished = vanished.filter { key, item in listed[key] == nil && completed[key] == nil && item.since > closedSince }
        // The ones never looked up first, then the ones looked up longest ago: a few that keep failing don't hold up
        // the rest.
        let due = vanished.values
            .filter { succeeded.contains($0.pullRequest.key.organization) && $0.isDue(at: startedAt, interval: configuration.interval) }
            .sorted {
                ($0.lastLookup ?? .distantPast, $0.since, $0.pullRequest.key) < ($1.lastLookup ?? .distantPast, $1.since, $1.pullRequest.key)
            }
            .prefix(5)
        for item in due {
            let key = item.pullRequest.key
            do {
                let dto = try await client.get(ADOEndpoint.pullRequest(organization: key.organization, id: key.number), as: ADOPullRequest.self)
                let fresh = PullRequest(organization: key.organization, dto)
                if fresh.status == .completed || fresh.status == .abandoned { completed[key] = fresh }
                vanished[key] = nil
            } catch ADOError.notFound, ADOError.forbidden {
                // Deleted, or moved somewhere you can't read: nothing to show.
                vanished[key] = nil
            } catch ADOError.throttled {
                break
            } catch {
                vanished[key]?.lastLookup = startedAt
                vanished[key]?.failures += 1
            }
        }
        for (key, pr) in done where completed[key] == nil && listed[key] == nil {
            completed[key] = pr
        }
        // The organizations may have changed while the lists loaded: keep only the ones still watched.
        let watched = Set(self.configuration.organizations)
        listed = listed.filter { watched.contains($0.key.organization) }
        completed = completed.filter { watched.contains($0.key.organization) }
        vanished = vanished.filter { watched.contains($0.key.organization) }
        firstLoaded = firstLoaded.filter { watched.contains($0.key) }
        await addLinked(to: &listed, at: startedAt)
        active = listed
        done = completed.filter { listed[$0.key] == nil && ($0.value.closedAt ?? .distantPast) > closedSince }
        details = details.filter { listed[$0.key] != nil }
        entries = entries.filter { listed[$0.key] != nil }

        // Details for every pull request without them (all of them on the first load), and a budget of others.
        let candidates = listed.values.map {
            RefreshPlanner.Candidate(key: $0.pullRequest.key, fingerprint: $0.pullRequest.fingerprint)
        }
        let keys = RefreshPlanner.plan(
            candidates, cache: entries, now: startedAt, options: configuration.planner, limit: configuration.planner.budget
        )
        var throttled = await fetchDetails(keys.compactMap { listed[$0]?.pullRequest }, configuration: configuration)
        if throttled == nil {
            throttled = await readBuildFailures(at: startedAt, interval: configuration.interval)
        }
        if throttled == nil {
            throttled = await followMerges(at: startedAt, configuration: configuration)
        }

        refreshedAt = now()
        if let throttled {
            problem = PulseProblem.from(throttled)
        } else if !errors.isEmpty {
            let names = errors.map { "\($0.0) (\($0.1.description))" }.joined(separator: ", ")
            problem = .someOrganizations("Couldn't read \(names).")
        } else {
            problem = nil
        }
    }

    /// Reads the pull requests people sent you that aren't in your lists, ten a refresh: the ones never read
    /// first, then the ones read longest ago. Each stays listed as it was last read in between. One that's closed
    /// or couldn't be read is tried again an hour later.
    private func addLinked(to listed: inout [PRKey: Listed], at date: Date) async {
        let wanted = linkedKeys.filter { listed[$0] == nil }
        linked = linked.filter { wanted.contains($0.key) }
        let due = wanted
            .filter { linkedFailures[$0].map { date.timeIntervalSince($0) > 3_600 } ?? true }
            .sorted { (linked[$0]?.readAt ?? .distantPast, $0) < (linked[$1]?.readAt ?? .distantPast, $1) }
        for key in due.prefix(10) {
            do {
                let me: String
                if let known = identities[key.organization] {
                    me = known
                } else {
                    me = try await client.get(ADOEndpoint.connectionData(organization: key.organization), as: ADOConnectionData.self)
                        .authenticatedUser.id.lowercased()
                    identities[key.organization] = me
                }
                let dto = try await client.get(ADOEndpoint.pullRequest(organization: key.organization, id: key.number), as: ADOPullRequest.self)
                let pr = PullRequest(organization: key.organization, dto)
                // A closed one is read again an hour later too, in case it's reopened.
                linkedFailures[key] = pr.status == .active ? nil : date
                guard pr.status == .active, linkedKeys.contains(key) else {
                    linked[key] = nil
                    continue
                }
                let role: PRRole = pr.author.id == me ? .author : pr.reviewer(me) != nil ? .reviewer : .linked
                linked[key] = (Listed(pullRequest: pr, role: role), date)
            } catch {
                linkedFailures[key] = date
                // Gone, or no access: nothing to list. Otherwise it stays as last read.
                if case .notFound = error as? ADOError { linked[key] = nil }
                if case .forbidden = error as? ADOError { linked[key] = nil }
            }
        }
        for (key, read) in linked { listed[key] = read.listed }
    }

    /// Without organizations to watch or pull requests sent to you, there's nothing to read, or to list.
    private func listNothing() {
        active = [:]
        done = [:]
        details = [:]
        entries = [:]
        vanished = [:]
        linked = [:]
        forgetRuns()
        problem = .noOrganizations
        hasLoaded = true
    }

    private func forgetAccount() {
        identities = [:]
        userName = nil
        firstLoaded = [:]
        active = [:]
        done = [:]
        details = [:]
        entries = [:]
        vanished = [:]
        linkedFailures = [:]
        linked = [:]
        forgetRuns()
    }

    /// Forgets the failed builds and the merges' runs read so far.
    private func forgetRuns() {
        buildFailures = [:]
        buildsRead = []
        buildAttempts = [:]
        merges = [:]
    }

    /// Fetches details a few pull requests at a time. Returns the error if Azure DevOps asked to slow down.
    private func fetchDetails(_ pullRequests: [PullRequest], configuration: Configuration) async -> ADOError? {
        guard !pullRequests.isEmpty else { return nil }
        let client = self.client
        let fetchedAt = now()
        var queue = pullRequests[...]
        var throttled: ADOError?
        await withTaskGroup(of: (PullRequest, DetailsRead).self) { group in
            for _ in 0..<max(1, configuration.concurrency) {
                guard let pr = queue.popFirst() else { break }
                group.addTask { (pr, await Self.details(of: pr, client: client)) }
            }
            while let (pr, read) = await group.next() {
                switch (read.policies, read.threads) {
                case (.success(let policies), .success(let threads)):
                    let fetched = PRDetails(fetchedAt: fetchedAt, pullRequest: pr, evaluations: policies, threads: threads)
                    details[pr.key] = fetched
                    entries[pr.key] = RefreshPlanner.Entry(
                        fetchedAt: fetchedAt, fingerprint: pr.fingerprint, isBusy: fetched.hasChecksInProgress,
                        isQuiet: isQuiet(pr, fetched, configuration: configuration, at: fetchedAt)
                    )
                default:
                    // Keep the old details, and try again on the normal schedule rather than every refresh. But what
                    // the policies say now replaces what they said, even when the threads couldn't be read: a pull
                    // request whose policies you may no longer read, or whose build failed since, isn't ready.
                    if case .success(let policies) = read.policies, var kept = details[pr.key] {
                        kept.checks = policies?.compactMap(Check.init) ?? []
                        kept.checksKnown = policies != nil
                        details[pr.key] = kept
                    }
                    entries[pr.key] = RefreshPlanner.Entry(
                        fetchedAt: fetchedAt, fingerprint: pr.fingerprint, isBusy: details[pr.key]?.hasChecksInProgress ?? false,
                        isQuiet: details[pr.key].map { isQuiet(pr, $0, configuration: configuration, at: fetchedAt) } ?? false
                    )
                    if let error = read.errors.first(where: { if case .throttled = $0 { true } else { false } }) {
                        throttled = error
                        queue.removeAll()
                    }
                }
                if let next = queue.popFirst() {
                    group.addTask { (next, await Self.details(of: next, client: client)) }
                }
            }
        }
        return throttled
    }

    private func isQuiet(_ pr: PullRequest, _ details: PRDetails, configuration: Configuration, at date: Date) -> Bool {
        if pr.isDraft { return true }
        guard let inactiveAfter = configuration.inactiveAfter, let last = details.lastActivity else { return false }
        return date.timeIntervalSince(max(last, pr.createdAt)) > inactiveAfter
    }

    /// The failed builds of your pull requests, as their policies report them now.
    private func failedBuilds() -> Set<FailedBuild> {
        var builds: Set<FailedBuild> = []
        for (key, item) in active where item.role == .author {
            for check in details[key]?.checks ?? [] {
                guard let buildId = check.failedBuildId else { continue }
                builds.insert(FailedBuild(
                    organization: key.organization, projectId: item.pullRequest.projectId, buildId: buildId, completedAt: check.completedAt
                ))
            }
        }
        return builds
    }

    /// Reads where your pull requests' failed builds failed, from their timelines, a few per refresh: each once, the
    /// ones never tried first. A timeline that can't be read is tried again later, less and less often; one that
    /// isn't there or that you may not read, never. Returns the error if Azure DevOps asked to slow down.
    private func readBuildFailures(at date: Date, interval: TimeInterval) async -> ADOError? {
        let wanted = failedBuilds()
        buildFailures = buildFailures.filter { wanted.contains($0.key) }
        buildsRead = buildsRead.intersection(wanted)
        buildAttempts = buildAttempts.filter { wanted.contains($0.key) }
        let due = wanted
            .filter { build in
                guard !buildsRead.contains(build) else { return false }
                guard let tried = buildAttempts[build], tried.failures > 1 else { return true }
                return date.timeIntervalSince(tried.last) >= min(interval * pow(2, Double(tried.failures - 2)), 1_800)
            }
            .sorted {
                (buildAttempts[$0]?.last ?? .distantPast, $0.organization, $0.buildId)
                    < (buildAttempts[$1]?.last ?? .distantPast, $1.organization, $1.buildId)
            }
            .prefix(Self.buildTimelinesPerRefresh)
        for build in due {
            do {
                let timeline = try await client.get(
                    ADOEndpoint.timeline(organization: build.organization, projectId: build.projectId, buildId: build.buildId),
                    as: ADOTimeline.self
                )
                buildFailures[build] = PipelineFailure.first(in: timeline)
                buildsRead.insert(build)
                buildAttempts[build] = nil
            } catch ADOError.notFound, ADOError.forbidden {
                // No timeline, or one you may not read: the list says which build failed, as before.
                buildsRead.insert(build)
                buildAttempts[build] = nil
            } catch ADOError.throttled(let seconds) {
                return .throttled(retryAfter: seconds)
            } catch {
                buildAttempts[build] = (date, (buildAttempts[build]?.failures ?? 0) + 1)
            }
        }
        return nil
    }

    /// Looks for the runs after your merges, and reads their timelines: each merge for half an hour after it merged,
    /// while a run hasn't finished, and for a little while after the last one did; the newest merges first, a few a
    /// refresh. A lookup that fails is tried again on the next refresh, then less and less often. Returns the error if
    /// Azure DevOps asked to slow down.
    private func followMerges(at date: Date, configuration: Configuration) async -> ADOError? {
        guard configuration.followMerges else {
            merges = [:]
            return nil
        }
        let merged = done.values.filter { $0.status == .completed && $0.mergeCommit != nil && $0.closedAt != nil }
        let keys = Set(merged.map(\.key))
        merges = merges.filter { keys.contains($0.key) }
        let interval = configuration.interval
        let due = merged
            .filter { pr in
                let follow = merges[pr.key] ?? MergeFollow()
                guard let mergedAt = pr.closedAt,
                      MergeChain.isFollowing(mergedAt: mergedAt, runs: follow.latestRuns, at: date)
                else { return false }
                guard let last = follow.lastLookup, follow.failures > 1 else { return true }
                return date.timeIntervalSince(last) >= min(interval * pow(2, Double(follow.failures - 2)), 1_800)
            }
            .sorted { ($0.closedAt ?? .distantPast, $0.key) > ($1.closedAt ?? .distantPast, $1.key) }
            .prefix(Self.mergesPerRefresh)
        for pr in due {
            guard let commit = pr.mergeCommit, let mergedAt = pr.closedAt else { continue }
            var follow = merges[pr.key] ?? MergeFollow()
            let since = mergedAt.addingTimeInterval(-MergeChain.clockSlack)
            let organization = pr.key.organization
            do {
                let onBranch = try await client.get(ADOEndpoint.branchBuilds(
                    organization: organization, projectId: pr.projectId, repositoryId: pr.repositoryId, branch: pr.targetBranch,
                    queuedSince: since
                ), as: ADOList<ADOBuild>.self).value
                var chain = MergeChain.runs(onBranch: onBranch, triggered: [], mergeCommit: commit)
                // The runs they started are looked for only once there's a run to start them.
                if !chain.isEmpty {
                    let triggered = try await client.get(
                        ADOEndpoint.triggeredBuilds(organization: organization, projectId: pr.projectId, queuedSince: since),
                        as: ADOList<ADOBuild>.self
                    ).value
                    chain = MergeChain.runs(onBranch: onBranch, triggered: triggered, mergeCommit: commit)
                }
                for build in chain {
                    let projectId = build.project?.id ?? pr.projectId
                    let projectName = build.project?.name ?? pr.projectName
                    let pipeline = PipelineRef(
                        organization: organization, projectId: projectId, projectName: projectName, definitionId: build.definition.id,
                        name: PlainText.singleLine(build.definition.name ?? "Pipeline \(build.definition.id)"),
                        folder: PipelineRef.folder(build.definition.path)
                    )
                    follow.runs[build.id] = MergeFollow.Found(
                        pipeline: pipeline, run: PipelineRun(organization: organization, projectName: projectName, build)
                    )
                }
                follow.lastLookup = date
                follow.failures = 0
            } catch ADOError.throttled(let seconds) {
                merges[pr.key] = follow
                return .throttled(retryAfter: seconds)
            } catch {
                follow.lastLookup = date
                follow.failures += 1
            }
            merges[pr.key] = follow
        }
        return await readMergeTimelines(at: date)
    }

    /// Reads the timelines of the latest runs after your merges: a run's every refresh while it runs, for its stages
    /// and whether one waits for an approval, and once more when it finishes, for where it failed. The ones never
    /// read first, then the ones read longest ago.
    private func readMergeTimelines(at date: Date) async -> ADOError? {
        var due: [(key: PRKey, found: MergeFollow.Found, lastRead: Date?)] = []
        for (key, follow) in merges {
            for (pipeline, runs) in follow.byPipeline {
                guard let run = runs.first, run.status != .queued else { continue }
                let read = follow.timelines[run.id]
                // Read once for how it finished; a retried run, running again under the same ID, is read again.
                if let read, run.status.isFinished, read.readFor == run.status { continue }
                due.append((key, MergeFollow.Found(pipeline: pipeline, run: run), read?.readAt))
            }
        }
        let picked = due
            .sorted { ($0.lastRead ?? .distantPast, $0.found.run.id) < ($1.lastRead ?? .distantPast, $1.found.run.id) }
            .prefix(Self.mergeTimelinesPerRefresh)
        for item in picked {
            let run = item.found.run
            let pipeline = item.found.pipeline
            do {
                let timeline = try await client.get(
                    ADOEndpoint.timeline(organization: pipeline.organization, projectId: pipeline.projectId, buildId: run.id),
                    as: ADOTimeline.self
                )
                merges[item.key]?.timelines[run.id] = MergeFollow.Timeline(
                    stages: PipelineStage.stages(from: timeline, runFinished: run.status.isFinished),
                    failure: run.status == .failed ? PipelineFailure.first(in: timeline) : nil,
                    readFor: run.status, readAt: date
                )
            } catch ADOError.notFound, ADOError.forbidden {
                // No timeline yet, or one you may not read: a finished run's isn't asked for again.
                if run.status.isFinished {
                    merges[item.key]?.timelines[run.id] = MergeFollow.Timeline(stages: [], failure: nil, readFor: run.status, readAt: date)
                }
            } catch ADOError.throttled(let seconds) {
                return .throttled(retryAfter: seconds)
            } catch {
                // Tried again on the next refresh.
            }
        }
        return nil
    }

    /// The pipelines after one of your merges, as known now; nil before any run was found.
    private func mergePipelines(for pr: PullRequest) -> MergePipelines? {
        guard let follow = merges[pr.key], !follow.runs.isEmpty, let mergedAt = pr.closedAt else { return nil }
        let statuses = follow.byPipeline.map { pipeline, runs in
            let timeline = runs.first.flatMap { follow.timelines[$0.id] }
            return PipelineStatus(
                pipeline: pipeline, runs: runs, stages: timeline?.stages ?? [],
                failure: runs.first?.status == .failed ? timeline?.failure : nil
            )
        }
        return MergePipelines(
            pullRequest: pr.key, title: pr.title.isEmpty ? "Pull request \(pr.key.number)" : pr.title, targetBranch: pr.targetBranch,
            mergedAt: mergedAt, url: pr.webURL, pipelines: statuses,
            isFollowing: MergeChain.isFollowing(mergedAt: mergedAt, runs: follow.latestRuns, at: now())
        )
    }

    /// The details with where each failed build failed, once that's been read.
    private func withFailures(_ details: PRDetails?, of pr: PullRequest) -> PRDetails? {
        guard var details, !buildFailures.isEmpty else { return details }
        for index in details.checks.indices {
            guard let buildId = details.checks[index].failedBuildId else { continue }
            details.checks[index].failure = buildFailures[FailedBuild(
                organization: pr.key.organization, projectId: pr.projectId, buildId: buildId, completedAt: details.checks[index].completedAt
            )]
        }
        return details
    }

    private static func lists(
        _ organization: String, me known: String?, client: ADOClient, closedSince: Date
    ) async -> Result<OrganizationLists, ADOError> {
        do {
            let me: String
            var name: String?
            if let known {
                me = known
            } else {
                let user = try await client.get(ADOEndpoint.connectionData(organization: organization), as: ADOConnectionData.self)
                    .authenticatedUser
                me = user.id.lowercased()
                name = user.providerDisplayName
            }
            typealias List = ADOList<ADOPullRequest>
            async let mine = client.get(ADOEndpoint.pullRequests(organization: organization, creatorId: me, status: "active"), as: List.self)
            async let reviewing = client.get(
                ADOEndpoint.pullRequests(organization: organization, reviewerId: me, status: "active"), as: List.self)
            async let completed = client.get(ADOEndpoint.pullRequests(
                organization: organization, creatorId: me, status: "completed", closedSince: closedSince, top: 50
            ), as: List.self)
            let (m, r, c) = try await (mine, reviewing, completed)
            func convert(_ list: List) -> [PullRequest] { list.value.map { PullRequest(organization: organization, $0) } }
            return .success(OrganizationLists(me: me, name: name, mine: convert(m), reviewing: convert(r), completed: convert(c)))
        } catch let error as ADOError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private static func details(of pr: PullRequest, client: ADOClient) async -> DetailsRead {
        let organization = pr.key.organization
        async let evaluations = capture {
            try await client.get(ADOEndpoint.policyEvaluations(
                organization: organization, projectId: pr.projectId, pullRequestId: pr.key.number
            ), as: ADOList<ADOPolicyEvaluation>.self).value
        }
        async let threads = capture {
            try await client.get(ADOEndpoint.threads(
                organization: organization, projectId: pr.projectId, repositoryId: pr.repositoryId, pullRequestId: pr.key.number
            ), as: ADOList<ADOThread>.self).value
        }
        let (policyResult, threadResult) = await (evaluations, threads)
        let policies: Result<[ADOPolicyEvaluation]?, ADOError>
        switch policyResult {
        case .success(let value): policies = .success(value)
        // Some projects don't let everyone read their policies. The pull request still has its threads, but
        // whether it's ready is unknown, which isn't the same as having no policies.
        case .failure(.forbidden), .failure(.notFound): policies = .success(nil)
        case .failure(let error): policies = .failure(error)
        }
        return DetailsRead(policies: policies, threads: threadResult)
    }

    private static func capture<T: Sendable>(_ body: () async throws -> T) async -> Result<T, ADOError> {
        do {
            return .success(try await body())
        } catch let error as ADOError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private func nextDelay() -> TimeInterval {
        let interval = configuration.interval
        switch problem {
        case .throttled(let until)?:
            return max(until.timeIntervalSince(now()), interval)
        case .cliNotFound?, .signedOut?, .authFailed?:
            // Pick up an `az login` within a minute; asking the CLI costs nothing on the network.
            return min(interval, 60)
        default:
            guard failures > 0 else { return interval }
            return min(interval * pow(2, Double(min(failures, 4))), 600)
        }
    }

    private func snapshot() -> PulseSnapshot {
        var records = active.map { key, item in
            PRRecord(
                pullRequest: item.pullRequest, role: item.role, details: withFailures(details[key], of: item.pullRequest),
                me: identities[key.organization] ?? ""
            )
        }
        records += done.map { key, pr in
            PRRecord(pullRequest: pr, role: .author, me: identities[key.organization] ?? "", merge: mergePipelines(for: pr))
        }
        records.sort { $0.id < $1.id }
        return PulseSnapshot(
            records: records, organizations: configuration.organizations, account: account, userName: userName, firstLoaded: firstLoaded,
            problem: problem, refreshedAt: refreshedAt, isRefreshing: isRefreshing, hasLoaded: hasLoaded
        )
    }

    private func publish() {
        let current = snapshot()
        guard current != lastPublished else { return }
        lastPublished = current
        onChange(current)
    }
}

/// Lets the refresh loop sleep until its next refresh, or until something asks for one sooner.
final class Waker: Sendable {
    private struct State {
        var pending = false
        var continuation: CheckedContinuation<Void, Never>?
        var generation = 0
    }

    private let state = Mutex(State())

    func wake() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let continuation = state.continuation else {
                state.pending = true
                return nil
            }
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    /// Returns after `seconds`, or as soon as `wake()` is called (including before this was).
    func wait(for seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let generation = state.withLock { state -> Int? in
                if state.pending {
                    state.pending = false
                    return nil
                }
                state.generation += 1
                state.continuation = continuation
                return state.generation
            }
            guard let generation else {
                continuation.resume()
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                self?.expire(generation)
            }
        }
    }

    private func expire(_ generation: Int) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard state.generation == generation, let continuation = state.continuation else { return nil }
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
