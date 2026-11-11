import AppKit
import AzureDevOpsCore
import BriefBarCore
import Combine
import CopilotTasks

/// Main-thread view model for the Sprint section, in windows, widgets and popovers: your team's current sprint.
/// It reads Azure DevOps only while one of them is on screen.
@MainActor
final class SprintStore: ObservableObject {
    @Published private(set) var board: SprintBoard?
    /// Your teams, to choose from.
    @Published private(set) var teams: [TeamRef] = []
    @Published private(set) var problem: PulseProblem?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var hasLoaded = false
    /// Something shows the sprint on screen, so it's read.
    @Published private(set) var isShowing = false
    /// Your open tasks and bugs outside the sprint, as last read, while My Work wants them, or since (`setOutside`); nil
    /// until a read tried.
    @Published private(set) var outside: OutsideWork?
    /// My Work shows their cards, with + All My Tasks: Show Links reads their pull requests, as it does the sprint's.
    @Published private(set) var showsOutside = false

    let settings: AppSettings
    let mode: PRStore.Mode
    private let client: ADOClient
    private var engine: SprintEngine?
    /// What shows the sprint right now: windows, widgets and popovers, by name.
    private var viewers: Set<String> = []
    /// What My Work wants of your work outside the sprint, by the name its viewer shows the sprint by.
    private var outsideViewers: [String: OutsideWanted] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings, mode: PRStore.Mode, client: ADOClient) {
        self.settings = settings
        self.mode = mode
        self.client = client
        settings.$sprintJustMine
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// The board as the page shows it: everyone's, or just yours.
    var shownBoard: SprintBoard? {
        settings.sprintJustMine ? board?.justMine() : board
    }

    private var configuration: SprintEngine.Configuration {
        SprintEngine.Configuration(
            organizations: settings.organizations, team: settings.sprintTeam, interval: TimeInterval(settings.refreshSeconds)
        )
    }

    func start() {
        switch mode {
        case .demo:
            load(demo: Date())
        case .live:
            guard engine == nil else { return }
            let engine = SprintEngine(client: client, configuration: configuration) { [weak self] snapshot in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.receive(snapshot) }
                }
            }
            self.engine = engine
            Task { await engine.start() }
            settings.$organizations.map { _ in () }
                .merge(with: settings.$sprintTeam.map { _ in () }, settings.$refreshSeconds.map { _ in () })
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let engine = self.engine else { return }
                        let configuration = self.configuration
                        Task { await engine.setConfiguration(configuration) }
                    }
                }
                .store(in: &cancellables)
        }
    }

    /// Loads once and waits for it (for `--render`).
    func loadOnce() async {
        switch mode {
        case .demo: load(demo: Date())
        case .live: receive(await SprintEngine.loadOnce(client: client, configuration: configuration))
        }
    }

    private func load(demo now: Date) {
        board = DemoData.sprintBoard(now: now)
        outside = DemoData.outsideWork(now: now)
        teams = [DemoData.team, DemoData.otherTeam]
        refreshedAt = now.addingTimeInterval(-20)
        hasLoaded = true
    }

    private func receive(_ snapshot: SprintSnapshot) {
        if board != snapshot.board { board = snapshot.board }
        if outside != snapshot.outside {
            if let problem = snapshot.outside?.problem, problem != outside?.problem {
                Log.app.error("Sprint: your work outside it: \(problem, privacy: .public)")
            }
            outside = snapshot.outside
        }
        if teams != snapshot.teams { teams = snapshot.teams }
        if problem != snapshot.problem {
            problem = snapshot.problem
            if let problem = snapshot.problem { Log.app.error("Sprint: \(problem.logMessage, privacy: .public)") }
        }
        if isRefreshing != snapshot.isRefreshing { isRefreshing = snapshot.isRefreshing }
        if refreshedAt != snapshot.refreshedAt { refreshedAt = snapshot.refreshedAt }
        if snapshot.hasLoaded && !hasLoaded { hasLoaded = true }
        // Keep the team found with a sprint going on, so it isn't looked for again.
        if let found = snapshot.foundTeam, settings.sprintTeam == nil {
            Log.app.info("Showing the sprint of a team with one going on today")
            settings.sprintTeam = found
        }
    }

    /// Something started or stopped showing the sprint. Azure DevOps is read only while something does.
    func setVisible(_ visible: Bool, for viewer: String) {
        let wasActive = !viewers.isEmpty
        if visible { viewers.insert(viewer) } else { viewers.remove(viewer) }
        let active = !viewers.isEmpty
        if isShowing != active { isShowing = active }
        guard active != wasActive, let engine else { return }
        Task { await engine.setActive(active) }
    }

    /// What My Work wants of your open tasks and bugs outside the sprint, for one of its viewers: how many there are, for its
    /// line, or their cards too; nil for nothing. They're read with the sprint while any viewer wants either, as long as
    /// something shows the sprint; their pull requests only while one wants their cards.
    func setOutside(_ wanted: OutsideWanted?, for viewer: String) {
        let wasRead = !outsideViewers.isEmpty
        outsideViewers[viewer] = wanted
        let shows = outsideViewers.values.contains(.cards)
        if showsOutside != shows { showsOutside = shows }
        let read = !outsideViewers.isEmpty
        guard read != wasRead, let engine else { return }
        Task { await engine.setReadsOutside(read) }
    }

    /// Whether My Work wants your work outside the sprint read.
    var readsOutside: Bool {
        !outsideViewers.isEmpty
    }

    /// Stops reading for good, when Azure DevOps is turned off.
    func stop() {
        cancellables.removeAll()
        if let engine { Task { await engine.stop() } }
        engine = nil
        viewers = []
        isShowing = false
        outsideViewers = [:]
        showsOutside = false
    }

    func refresh() {
        guard let engine else { return }
        Task { await engine.refresh() }
    }

    func choose(_ team: TeamRef) {
        settings.sprintTeam = team
    }

    func open(_ item: WorkItem) {
        AzureDevOps.open(item.webURL)
    }

    /// A work item's title, if it's in the sprint shown, or among your work outside it.
    func title(of reference: WorkItemReference) -> String? {
        let items = (board?.items ?? []) + (outside?.items ?? [])
        return items.first { $0.copilotTask.reference.matches(reference) }?.title
    }

    func openBoard() {
        guard let board else { return }
        AzureDevOps.open(board.team.taskboardURL(sprint: board.sprint))
    }
}
