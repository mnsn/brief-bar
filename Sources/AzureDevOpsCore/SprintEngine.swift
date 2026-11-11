import Foundation

/// What the sprint engine knows at one point in time.
public struct SprintSnapshot: Sendable, Equatable {
    public var board: SprintBoard?
    /// Your teams in the watched organizations, to choose from.
    public var teams: [TeamRef]
    /// The team the engine found with a sprint going on today, when none was chosen, to keep: not while some
    /// organizations' teams, in a directory to sign in to, couldn't be compared with it.
    public var foundTeam: TeamRef?
    public var problem: PulseProblem?
    public var refreshedAt: Date?
    public var isRefreshing: Bool
    public var hasLoaded: Bool
    /// Your open tasks and bugs outside the sprint, while My Work wants them (`SprintEngine.setReadsOutside`), as last read;
    /// nil until a read tried.
    public var outside: OutsideWork?

    public init(
        board: SprintBoard? = nil, teams: [TeamRef] = [], foundTeam: TeamRef? = nil, problem: PulseProblem? = nil,
        refreshedAt: Date? = nil, isRefreshing: Bool = false, hasLoaded: Bool = false, outside: OutsideWork? = nil
    ) {
        self.board = board
        self.teams = teams
        self.foundTeam = foundTeam
        self.problem = problem
        self.refreshedAt = refreshedAt
        self.isRefreshing = isRefreshing
        self.hasLoaded = hasLoaded
        self.outside = outside
    }
}

/// Reads your team's current sprint: the sprint (hourly), how the team's board is set up (once), and every refresh
/// the sprint's work items, which is two requests (plus one per 200 work items); while My Work wants them, your open tasks
/// and bugs outside it too, two more (plus one per 200). It polls only while something shows the sprint, and backs off
/// when Azure DevOps can't be read. Every request is a GET.
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
        /// Its portfolio backlogs' types, such as Feature and Epic; none when its configuration couldn't be read.
        var portfolioTypes: Set<String> = []
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
    /// The organizations whose teams couldn't be read, in a directory the Azure CLI isn't signed in to: the sprint can't
    /// be looked for there until you sign in.
    private var teamsElsewhere: [(organization: String, error: ADOError)] = []
    /// The organizations whose teams couldn't be read otherwise at the last refresh, and why: said with those in a
    /// directory to sign in to.
    private var teamsFailed: [(organization: String, error: ADOError)] = []
    private var foundTeam: TeamRef?
    /// The organizations whose teams were in a directory to sign in to when `foundTeam` was found, by lowercased name:
    /// while there are any, it's shown, but not kept, and it's looked for again among them all once one can be read.
    private var foundWithout: Set<String> = []
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
    /// Whether each refresh reads your work outside the sprint too, for My Work (`setReadsOutside`).
    private var readsOutside = false
    /// Your work outside the sprint, as last read; nil until a read tried, and once the team or who's signed in changes.
    private var outside: OutsideWork?
    /// The ID of the team whose project it was read in.
    private var outsideTeam: String?

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

    /// Whether each refresh reads your open tasks and bugs outside the sprint too, for My Work, after the sprint. Once
    /// they're wanted, a refresh reads them as soon as something shows the sprint, unless a read got them less than half an
    /// interval ago; while they aren't, what was read stays, read no more.
    public func setReadsOutside(_ reads: Bool) {
        guard reads != readsOutside else { return }
        readsOutside = reads
        guard reads else { return }
        if let readAt = outside?.readAt, outside?.problem == nil, now().timeIntervalSince(readAt) < configuration.interval / 2 { return }
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
            outside = nil
            problem = nil
            forced = true
        } else if configuration.team == nil, old.team != nil {
            foundTeam = nil
            checkedTeams = nil
            board = nil
            outside = nil
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
        case .otherDirectory? where failures > 0:
            // Nothing was read until you sign in to its organization's directory.
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
        } catch let unread as TeamsUnread {
            problem = unread.problem
            failures += 1
            hasLoaded = true
            refreshedAt = now()
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
            outside = nil
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
        try await loadTeams(configuration.organizations, at: date, choosing: configuration.team == nil)
        // Each team found for you whose organization turns out to wait on a sign-in is set aside, with its organization's
        // teams: at most one pass per organization.
        while true {
            let chosen = try await chosenTeam(configuration, at: date)
            // Shown with the sprint, or without one: the organizations whose teams couldn't be read are named, those in a
            // directory to sign in to first, since one of theirs may be yours.
            let unread = teamsElsewhere + teamsFailed
            let teamsProblem = unread.isEmpty ? nil : PulseProblem.organizations(unread)
            guard let team = chosen else {
                board = nil
                outside = nil
                // No team's sprint could be read, for want of a sign-in to their directory: as when no teams could be, it's
                // looked at again within a minute.
                if allTeams.isEmpty, !teamsElsewhere.isEmpty, let teamsProblem { throw TeamsUnread(problem: teamsProblem) }
                return teamsProblem
            }
            // Another team's board, such as one just set aside, isn't shown in its stead if this one's can't be read.
            if board?.team.id != team.id { board = nil }
            if outsideTeam != team.id { outside = nil }
            do {
                try await readBoard(of: team, at: date)
                if readsOutside { try await readOutside(of: team, at: date) }
                return teamsProblem
            } catch let error as ADOError where configuration.team == nil && PulseProblem.isOtherDirectory(error) {
                // The team found for you is in a directory to sign in to now: its organization waits on that sign-in, and
                // another of yours is looked for, rather than this one shown, or kept as your choice, meanwhile. Its board
                // goes, even if the next one can't be read.
                waitForSignIn(to: team.organization, error)
                foundTeam = nil
                board = nil
            } catch let error as ADOError where !teamsElsewhere.isEmpty {
                // The team's sprint couldn't be read: said with the organizations whose teams wait on a sign-in, rather than
                // in their stead, unless Azure DevOps asked to slow down, which comes first.
                if case .throttled = error { throw error }
                let failed = unread + [(organization: team.organization, error: error)]
                throw TeamsUnread(problem: PulseProblem.organizations(failed) ?? PulseProblem.from(error))
            }
        }
    }

    /// Reads the team's sprint going on today, with its work items, for the board; without one, there's no board.
    private func readBoard(of team: TeamRef, at date: Date) async throws {
        guard let sprint = try await currentSprint(of: team, at: date) else {
            board = nil
            return
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
        guard self.configuration.team == nil || self.configuration.team?.id == team.id else { return }
        board = SprintBoard.build(
            team: team, sprint: sprint, me: me, relations: relations, items: items, taskTypes: setup.taskTypes,
            portfolioTypes: setup.portfolioTypes
        )
    }

    /// Your open tasks and bugs in the team's project that its sprint's board doesn't have (`OutsideWork.yours`): Azure
    /// DevOps' Assigned to me query, then those it lists that the board doesn't have, 200 a request, with the iteration each
    /// is in. A read that fails keeps what was read before, saying why; but Azure DevOps asking to slow down, or the read
    /// stopping, ends the refresh, as for the sprint. Once My Work no longer wants them, as when it goes while the Sprint
    /// page still shows, the rest isn't read, and what was read before stays.
    private func readOutside(of team: TeamRef, at date: Date) async throws {
        do {
            let setup = try await boardSetup(of: team)
            guard readsOutside else { return }
            let query = try await get(
                ADOEndpoint.assignedToMe(organization: team.organization, project: team.projectId), as: ADOPredefinedQuery.self
            )
            let onBoard = Set((board?.items ?? []).map(\.id))
            var seen: Set<Int> = []
            let ids = query.ids.filter { !onBoard.contains($0) && seen.insert($0).inserted }
            var found: [WorkItem] = []
            for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
                guard readsOutside else { return }
                let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
                let list = try await get(
                    ADOEndpoint.workItems(organization: team.organization, ids: batch, fields: ADOWorkItem.fieldNamesWithIteration),
                    as: ADOList<ADOWorkItem>.self
                )
                found += list.value.map { WorkItem(organization: team.organization, project: team.projectName, $0, categories: setup.categories) }
            }
            // The team may have changed while this loaded.
            guard configuration.team == nil || configuration.team?.id == team.id else { return }
            outside = OutsideWork(
                items: OutsideWork.yours(found, board: board, taskTypes: setup.taskTypes), sprintPath: board?.sprint.path,
                isPartial: query.hasMore, readAt: date, taskTypes: setup.taskTypes
            )
            outsideTeam = team.id
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ADOError {
            if case .throttled = error { throw error }
            outsideFailed(error.description, team: team)
        } catch {
            outsideFailed(error.localizedDescription, team: team)
        }
    }

    /// The read of your work outside the sprint failed: what was read before stays, without what the sprint's board has
    /// now, saying why; but for a team no longer chosen, as one changed while its read was under way, it says nothing.
    private func outsideFailed(_ problem: String, team: TeamRef) {
        guard configuration.team == nil || configuration.team?.id == team.id else { return }
        var failed = (outside ?? OutsideWork()).without(board)
        failed.sprintPath = board?.sprint.path
        failed.problem = problem
        outside = failed
        outsideTeam = team.id
    }

    /// Your teams in each organization, read again every few hours. An organization that can't be read keeps the
    /// teams it had, but one in a directory the Azure CLI isn't signed in to: its teams are dropped, read again every
    /// refresh, and said, until you've signed in there. With no teams to choose from when `choosing`, why is thrown; a
    /// team you chose is read whatever happens to them.
    private func loadTeams(_ organizations: [String], at date: Date, choosing: Bool) async throws {
        var lastError: ADOError?
        var elsewhere: [(organization: String, error: ADOError)] = []
        var failed: [(organization: String, error: ADOError)] = []
        for organization in organizations where teams[organization].map({ date.timeIntervalSince($0.readAt) > Self.teamsLifetime }) ?? true {
            do {
                let list = try await get(ADOEndpoint.myTeams(organization: organization), as: ADOList<ADOTeam>.self)
                let found = list.value.compactMap { TeamRef(organization: organization, $0) }
                    .sorted { ($0.projectName.lowercased(), $0.name.lowercased()) < ($1.projectName.lowercased(), $1.name.lowercased()) }
                teams[organization] = (found, date)
            } catch let error as ADOError {
                switch error {
                case .forbidden, .notFound: teams[organization] = ([], date)
                // Its teams wait on that sign-in: those read before aren't chosen from or compared meanwhile.
                case .otherDirectory:
                    teams[organization] = nil
                    elsewhere.append((organization: organization, error: error))
                // Nothing more goes out until then: that comes first, before any sign-in.
                case .throttled: throw error
                default:
                    lastError = error
                    failed.append((organization: organization, error: error))
                }
            }
        }
        teamsElsewhere = elsewhere
        teamsFailed = failed
        guard choosing, allTeams.isEmpty else { return }
        // With no teams at all, signing in to a directory is what to do first: each organization it's needed for is
        // named, then why the others couldn't be read.
        if !elsewhere.isEmpty, let problem = PulseProblem.organizations(elsewhere + failed) { throw TeamsUnread(problem: problem) }
        if let lastError { throw lastError }
    }

    /// No teams to choose from, for want of a sign-in to some organizations' directory: what's wrong.
    private struct TeamsUnread: Error {
        var problem: PulseProblem
    }

    private var allTeams: [TeamRef] {
        configuration.organizations.flatMap { teams[$0]?.teams ?? [] }
    }

    /// The team you chose; or, when you haven't, the one of your teams with a sprint going on today that has the most
    /// work assigned to you (once: the app keeps it, when it was found among all your teams).
    private func chosenTeam(_ configuration: Configuration, at date: Date) async throws -> TeamRef? {
        if let team = configuration.team { return team }
        let missing = missingTeams()
        // Found while some organizations' teams couldn't be compared with it: once one of theirs is read, it's looked for
        // among them all, and so it is once its own organization's teams wait on a sign-in. Those that go missing
        // meanwhile count too.
        if let foundTeam, foundWithout.isSubset(of: missing), !Self.names(teamsElsewhere).contains(foundTeam.organization.lowercased()) {
            if !foundWithout.isEmpty { foundWithout = missing }
            return foundTeam
        }
        // Checked recently and none had a sprint today: wait a while before checking them all again.
        if let checkedTeams, date.timeIntervalSince(checkedTeams) < Self.sprintLifetime { return nil }
        var candidates: [(team: TeamRef, sprint: Sprint)] = []
        var incomplete = false
        // A few teams at most, not counting those of organizations waiting on a sign-in, which aren't asked.
        var tried = 0
        for team in allTeams where !Self.names(teamsElsewhere).contains(team.organization.lowercased()) {
            guard tried < Self.teamsToTry else { break }
            tried += 1
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
                // Its organization is in a directory to sign in to now: as when its teams can't be read, it's said, and its
                // teams are read again, and compared with what's found meanwhile, once you've signed in there. It doesn't
                // count among the teams tried: the rest of its organization's aren't.
                case .otherDirectory:
                    tried -= 1
                    waitForSignIn(to: team.organization, error)
                // Just this team: look at the others, and at this one again next time.
                default: incomplete = true
                }
            }
        }
        // A team whose sprint was known, from an organization that turned out to wait on a sign-in while the rest of its
        // teams were looked at, isn't one either.
        candidates.removeAll { Self.names(teamsElsewhere).contains($0.team.organization.lowercased()) }
        guard candidates.count > 1 else {
            foundTeam = candidates.first?.team
            foundWithout = missingTeams()
            // None has a sprint today: don't look again for a while, unless some couldn't be read, or some organizations'
            // teams are in a directory to sign in to.
            if foundTeam == nil && !incomplete && teamsElsewhere.isEmpty { checkedTeams = date }
            return foundTeam
        }
        var best: (team: TeamRef, mine: Int)?
        for candidate in candidates where !Self.names(teamsElsewhere).contains(candidate.team.organization.lowercased()) {
            let mine: Int
            do {
                mine = try await assignedToMe(in: candidate.sprint, of: candidate.team)
            } catch let error as ADOError where PulseProblem.isOtherDirectory(error) {
                // Its sprint was known, but its organization is in a directory to sign in to now: the others are compared.
                waitForSignIn(to: candidate.team.organization, error)
                continue
            }
            if mine > (best?.mine ?? -1) { best = (candidate.team, mine) }
        }
        foundTeam = best?.team
        foundWithout = missingTeams()
        return foundTeam
    }

    /// The organizations whose teams can't be compared now, by lowercased name, among those watched: the ones waiting
    /// on a sign-in, and the ones missing when the team was found whose teams haven't been read since.
    private func missingTeams() -> Set<String> {
        let read = Set(teams.keys.map { $0.lowercased() })
        let watched = Set(configuration.organizations.map { $0.lowercased() })
        return Self.names(teamsElsewhere).union(foundWithout.subtracting(read)).intersection(watched)
    }

    /// An organization whose team's sprint can't be read for want of a sign-in to its directory: its teams are
    /// forgotten, to be read again at each refresh until you've signed in there, and it's said, as when they can't be.
    private func waitForSignIn(to organization: String, _ error: ADOError) {
        teams[organization] = nil
        guard !Self.names(teamsElsewhere).contains(organization.lowercased()) else { return }
        teamsElsewhere.append((organization: organization, error: error))
    }

    /// Organizations' names as Azure DevOps tells them apart: ignoring their letter case.
    private static func names(_ failures: [(organization: String, error: ADOError)]) -> Set<String> {
        Set(failures.map { $0.organization.lowercased() })
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
        teamsElsewhere = []
        teamsFailed = []
        foundTeam = nil
        foundWithout = []
        checkedTeams = nil
        sprints = [:]
        board = nil
        outside = nil
        outsideTeam = nil
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
            setup.portfolioTypes = Set((configuration.portfolioBacklogs?.elements ?? []).flatMap { $0.workItemTypes?.elements.map(\.name) ?? [] })
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
            board: board, teams: allTeams, foundTeam: configuration.team == nil && foundWithout.isEmpty ? foundTeam : nil, problem: problem,
            refreshedAt: refreshedAt, isRefreshing: isRefreshing, hasLoaded: hasLoaded, outside: outside
        )
    }

    private func publish() {
        let current = snapshot()
        guard current != lastPublished else { return }
        lastPublished = current
        onChange(current)
    }
}
