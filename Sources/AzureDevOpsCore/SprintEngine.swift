import Foundation

/// What the sprint engine knows at one point in time.
public struct SprintSnapshot: Sendable, Equatable {
    public var board: SprintBoard?
    /// Your teams in the watched organizations, to choose from.
    public var teams: [TeamRef]
    /// The team the engine found with a sprint going on today, when none was chosen.
    public var foundTeam: TeamRef?
    public var problem: PulseProblem?
    public var refreshedAt: Date?
    public var isRefreshing: Bool
    public var hasLoaded: Bool

    public init(
        board: SprintBoard? = nil, teams: [TeamRef] = [], foundTeam: TeamRef? = nil, problem: PulseProblem? = nil,
        refreshedAt: Date? = nil, isRefreshing: Bool = false, hasLoaded: Bool = false
    ) {
        self.board = board
        self.teams = teams
        self.foundTeam = foundTeam
        self.problem = problem
        self.refreshedAt = refreshedAt
        self.isRefreshing = isRefreshing
        self.hasLoaded = hasLoaded
    }
}

/// Reads your team's current sprint: the sprint (hourly), how the team's board is set up (once), and every refresh
/// the sprint's work items, which is two requests (plus one per 200 work items). It polls only while something
/// shows the sprint, and backs off when Azure DevOps can't be read. Every request is a GET.
public actor SprintEngine {
    public typealias ChangeHandler = @Sendable (SprintSnapshot) -> Void

    public struct Configuration: Sendable, Equatable {
        /// Where to look for your teams.
        public var organizations: [String]
        /// The team to show; nil to find one with a sprint going on today.
        public var team: TeamRef?
        public var interval: TimeInterval

        public init(organizations: [String], team: TeamRef? = nil, interval: TimeInterval = 60) {
            self.organizations = organizations
            self.team = team
            self.interval = interval
        }
    }

    /// How a team's board is set up.
    struct BoardSetup: Sendable {
        var taskTypes: Set<String>
        /// Work item type → state → category.
        var categories: [String: [String: String]]
    }

    /// The most work items one request asks for.
    static let batchSize = 200
    /// A sprint is read again after this long, so the next one is picked up.
    static let sprintLifetime: TimeInterval = 3_600
    /// Your teams are looked up again after this long.
    static let teamsLifetime: TimeInterval = 6 * 3_600
    /// How many teams to check for a sprint going on today when none was chosen.
    static let teamsToTry = 25

    private let client: ADOClient
    private var configuration: Configuration
    private let onChange: ChangeHandler
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let waker = Waker()
    private var loop: Task<Void, Never>?
    private var isActive = false
    private var forced = false
    /// Just activated: refresh if the data is more than half an interval old.
    private var catchUp = false
    /// The timer's refresh, which stops when nothing shows the sprint any more; a one-off load doesn't.
    private var isPolling = false

    /// Whose sign-in the identities, teams and board are for.
    private var account: String?
    /// Organization → your identity ID there.
    private var identities: [String: String] = [:]
    private var teams: [String: (teams: [TeamRef], readAt: Date)] = [:]
    private var foundTeam: TeamRef?
    /// Teams checked for a sprint going on today, and when.
    private var checkedTeams: Date?
    private var sprints: [String: (sprint: Sprint?, readAt: Date)] = [:]
    private var setups: [String: BoardSetup] = [:]
    private var board: SprintBoard?
    private var problem: PulseProblem?
    private var refreshedAt: Date?
    private var hasLoaded = false
    private var isRefreshing = false
    private var failures = 0
    private var lastPublished: SprintSnapshot?

    public init(
        client: ADOClient, configuration: Configuration, now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current, onChange: @escaping ChangeHandler
    ) {
        self.client = client
        self.configuration = configuration
        self.now = now
        self.calendar = calendar
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

    /// Whether something shows the sprint. While nothing does, nothing is read, and a refresh under way stops before
    /// its next request; once something does, it's refreshed if it's more than half an interval old.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            catchUp = true
            waker.wake()
        }
    }

    /// Refreshes as soon as possible, if something shows the sprint.
    public func refresh() {
        forced = true
        waker.wake()
    }

    public func setConfiguration(_ configuration: Configuration) {
        guard configuration != self.configuration else { return }
        let old = self.configuration
        self.configuration = configuration
        if configuration.organizations != old.organizations {
            teams = teams.filter { configuration.organizations.contains($0.key) }
            checkedTeams = nil
            if configuration.team == nil {
                foundTeam = nil
                forced = true
            }
        }
        if let team = configuration.team, team != old.team, team.id != board?.team.id {
            // Another team: show nothing of the last one's while its sprint loads.
            board = nil
            problem = nil
            forced = true
        } else if configuration.team == nil, old.team != nil {
            foundTeam = nil
            checkedTeams = nil
            board = nil
            forced = true
        }
        publish()
        waker.wake()
    }

    /// One load, without the timer: for the command line and tests.
    public static func loadOnce(client: ADOClient, configuration: Configuration, now: Date = Date()) async -> SprintSnapshot {
        let engine = SprintEngine(client: client, configuration: configuration, now: { now }) { _ in }
        await engine.refreshNow()
        return await engine.currentSnapshot()
    }

    public func currentSnapshot() -> SprintSnapshot {
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

    /// How long to sleep: until the next refresh is due while active, and until woken while not.
    private func sleepTime() -> TimeInterval {
        guard isActive, let refreshedAt else { return isActive ? 1 : 3_600 }
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

    /// One refresh, start to finish: your teams if they're not known yet, the team's sprint, and its work items.
    public func refreshNow() async {
        await refresh(polling: false)
    }

    /// A refresh by the timer stops before its next request once nothing shows the sprint, keeping what it read.
    private func refresh(polling: Bool) async {
        forced = false
        isPolling = polling
        defer { isPolling = false }
        isRefreshing = true
        publish()
        do {
            problem = try await load()
            failures = 0
            hasLoaded = true
            refreshedAt = now()
        } catch is CancellationError {
            // Hidden while it read: the rest waits until something shows the sprint again.
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

    /// Stops a refresh by the timer before another request when nothing shows the sprint any more.
    private func get<T: Decodable & Sendable>(_ url: URL, as type: T.Type) async throws -> T {
        if isPolling && !isActive { throw CancellationError() }
        return try await client.get(url, as: type)
    }

    /// Reads what's due, and returns what's wrong when it can't show a sprint for a reason other than an error.
    private func load() async throws -> PulseProblem? {
        let configuration = self.configuration
        guard !configuration.organizations.isEmpty || configuration.team != nil else {
            board = nil
            return .noOrganizations
        }
        // Someone else signed in to the Azure CLI: everything read as the last one is theirs.
        let token: AccessToken
        do {
            token = try await client.tokens.token()
        } catch let error as AuthError {
            throw ADOError.auth(error)
        }
        if let signedIn = token.account {
            if let account, account != signedIn { forgetAccount() }
            account = signedIn
        }
        let date = now()
        try await loadTeams(configuration.organizations, at: date)
        guard let team = try await chosenTeam(configuration, at: date) else {
            board = nil
            return nil
        }
        guard let sprint = try await currentSprint(of: team, at: date) else {
            board = nil
            return nil
        }
        let me = try await identity(in: team.organization)
        let setup = try await boardSetup(of: team)
        let relations = try await get(
            ADOEndpoint.iterationWorkItems(team: team, iterationId: sprint.id), as: ADOIterationWorkItems.self
        ).workItemRelations.elements
        var ids: [Int] = []
        var seen: Set<Int> = []
        for relation in relations {
            for id in [relation.source?.id, relation.target.id].compactMap({ $0 }) where seen.insert(id).inserted {
                ids.append(id)
            }
        }
        var items: [WorkItem] = []
        for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
            let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
            let list = try await get(ADOEndpoint.workItems(organization: team.organization, ids: batch), as: ADOList<ADOWorkItem>.self)
            items += list.value.map { WorkItem(organization: team.organization, project: team.projectName, $0, categories: setup.categories) }
        }
        // The team may have changed while this loaded.
        guard self.configuration.team == nil || self.configuration.team?.id == team.id else { return nil }
        board = SprintBoard.build(team: team, sprint: sprint, me: me, relations: relations, items: items, taskTypes: setup.taskTypes)
        return nil
    }

    /// Your teams in each organization, read again every few hours. An organization that can't be read keeps the
    /// teams it had.
    private func loadTeams(_ organizations: [String], at date: Date) async throws {
        var lastError: ADOError?
        for organization in organizations where teams[organization].map({ date.timeIntervalSince($0.readAt) > Self.teamsLifetime }) ?? true {
            do {
                let list = try await get(ADOEndpoint.myTeams(organization: organization), as: ADOList<ADOTeam>.self)
                let found = list.value.compactMap { TeamRef(organization: organization, $0) }
                    .sorted { ($0.projectName.lowercased(), $0.name.lowercased()) < ($1.projectName.lowercased(), $1.name.lowercased()) }
                teams[organization] = (found, date)
            } catch let error as ADOError {
                switch error {
                case .forbidden, .notFound: teams[organization] = ([], date)
                default: lastError = error
                }
            }
        }
        if let lastError, allTeams.isEmpty { throw lastError }
    }

    private var allTeams: [TeamRef] {
        configuration.organizations.flatMap { teams[$0]?.teams ?? [] }
    }

    /// The team you chose; or, when you haven't, the one of your teams with a sprint going on today that has the most
    /// work assigned to you (once: the app keeps it).
    private func chosenTeam(_ configuration: Configuration, at date: Date) async throws -> TeamRef? {
        if let team = configuration.team { return team }
        if let foundTeam { return foundTeam }
        // Checked recently and none had a sprint today: wait a while before checking them all again.
        if let checkedTeams, date.timeIntervalSince(checkedTeams) < Self.sprintLifetime { return nil }
        var candidates: [(team: TeamRef, sprint: Sprint)] = []
        var incomplete = false
        for team in allTeams.prefix(Self.teamsToTry) {
            do {
                if let sprint = try await currentSprint(of: team, at: date), sprint.isCurrent(now: date, calendar: calendar) {
                    candidates.append((team, sprint))
                }
            } catch ADOError.notFound, ADOError.forbidden {
                continue
            } catch let error as ADOError {
                switch error {
                // Nothing else can be read either.
                case .auth, .unauthorized, .offline, .throttled: throw error
                // Just this team: look at the others, and at this one again next time.
                default: incomplete = true
                }
            }
        }
        guard candidates.count > 1 else {
            foundTeam = candidates.first?.team
            // None has a sprint today: don't look again for a while, unless some couldn't be read.
            if foundTeam == nil && !incomplete { checkedTeams = date }
            return foundTeam
        }
        var best: (team: TeamRef, mine: Int)?
        for candidate in candidates {
            let mine = try await assignedToMe(in: candidate.sprint, of: candidate.team)
            if mine > (best?.mine ?? -1) { best = (candidate.team, mine) }
        }
        foundTeam = best?.team
        return foundTeam
    }

    /// How many of a sprint's work items are assigned to you.
    private func assignedToMe(in sprint: Sprint, of team: TeamRef) async throws -> Int {
        let me = try await identity(in: team.organization)
        let relations = try await get(
            ADOEndpoint.iterationWorkItems(team: team, iterationId: sprint.id), as: ADOIterationWorkItems.self
        ).workItemRelations.elements
        let ids = Array(Set(relations.map(\.target.id))).sorted().prefix(Self.batchSize)
        guard !ids.isEmpty else { return 0 }
        let items = try await get(
            ADOEndpoint.workItems(organization: team.organization, ids: Array(ids), fields: ["System.AssignedTo"]), as: ADOList<ADOWorkItem>.self
        ).value
        return items.filter { $0.fields.assignedTo?.id.lowercased() == me }.count
    }

    /// The team's sprint going on today, read again every hour and once it's over. Azure DevOps calls the latest
    /// sprint "current" even after it's over, when a team stops planning sprints: that's no current sprint.
    private func currentSprint(of team: TeamRef, at date: Date) async throws -> Sprint? {
        if let cached = sprints[team.id], date.timeIntervalSince(cached.readAt) < Self.sprintLifetime,
           cached.sprint.map({ $0.isCurrent(now: date, calendar: calendar) }) ?? true {
            return cached.sprint
        }
        let list = try await get(ADOEndpoint.currentIteration(team: team), as: ADOList<ADOIteration>.self)
        let sprint = list.value.map(Sprint.init).first { $0.isCurrent(now: date, calendar: calendar) || $0.start == nil }
        sprints[team.id] = (sprint, date)
        return sprint
    }

    private func forgetAccount() {
        identities = [:]
        teams = [:]
        foundTeam = nil
        checkedTeams = nil
        sprints = [:]
        board = nil
    }

    private func identity(in organization: String) async throws -> String {
        if let known = identities[organization] { return known }
        let me = try await get(ADOEndpoint.connectionData(organization: organization), as: ADOConnectionData.self)
            .authenticatedUser.id.lowercased()
        identities[organization] = me
        return me
    }

    /// Which types are tasks and each state's category, once per team. Without it (some teams can't read it), Task
    /// is the task type and categories are guessed from the states' names.
    private func boardSetup(of team: TeamRef) async throws -> BoardSetup {
        if let setup = setups[team.id] { return setup }
        var setup = BoardSetup(taskTypes: ["Task"], categories: [:])
        do {
            let configuration = try await get(ADOEndpoint.backlogConfiguration(team: team), as: ADOBacklogConfiguration.self)
            let types = configuration.taskBacklog?.workItemTypes?.elements.map(\.name) ?? []
            if !types.isEmpty { setup.taskTypes = Set(types) }
            for mapped in configuration.workItemTypeMappedStates?.elements ?? [] {
                setup.categories[mapped.workItemTypeName] = mapped.states
            }
        } catch ADOError.forbidden, ADOError.notFound {
            // Guess, as above.
        }
        setups[team.id] = setup
        return setup
    }

    private func snapshot() -> SprintSnapshot {
        SprintSnapshot(
            board: board, teams: allTeams, foundTeam: configuration.team == nil ? foundTeam : nil, problem: problem,
            refreshedAt: refreshedAt, isRefreshing: isRefreshing, hasLoaded: hasLoaded
        )
    }

    private func publish() {
        let current = snapshot()
        guard current != lastPublished else { return }
        lastPublished = current
        onChange(current)
    }
}
