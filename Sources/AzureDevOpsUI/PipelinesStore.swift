import AppKit
import AzureDevOpsCore
import BriefBarCore
import Combine

/// Pipelines in windows, widgets and popovers: pinned runs, and your active PRs' validation runs for the page.
/// It reads Azure DevOps only while something shows the section.
@MainActor
final class PipelinesStore: ObservableObject {
    @Published private(set) var statuses: [PipelineStatus] = []
    @Published private(set) var pullRequests: [PullRequestPipelines] = []
    @Published private(set) var problem: PulseProblem?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var hasLoaded = false

    let settings: AppSettings
    let mode: PRStore.Mode
    private let client: ADOClient
    private var engine: PipelinesEngine?
    private var viewers: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    private var authoredPullRequests: [PullRequest] = []
    private var authoredAccount: String?

    init(settings: AppSettings, mode: PRStore.Mode, client: ADOClient) {
        self.settings = settings
        self.mode = mode
        self.client = client
    }

    var counts: PipelineCounts { PipelineCounts(statuses) }

    private var configuration: PipelinesEngine.Configuration {
        PipelinesEngine.Configuration(
            pipelines: settings.pinnedPipelines, interval: TimeInterval(settings.refreshSeconds), pullRequests: authoredPullRequests,
            pullRequestAccount: authoredAccount
        )
    }

    func setPullRequests(_ pullRequests: [PullRequest], account: String? = nil) {
        guard pullRequests != authoredPullRequests || account != authoredAccount else { return }
        if account != authoredAccount { self.pullRequests = [] }
        authoredAccount = account
        authoredPullRequests = pullRequests
        if mode == .demo {
            self.pullRequests = DemoData.pullRequestPipelines(pullRequests)
            return
        }
        self.pullRequests = pullRequests.map { pr in
            self.pullRequests.first { $0.pullRequest == pr }
                ?? PullRequestPipelines(pullRequest: pr, pipelines: [], revisions: [:], hasLoaded: false)
        }
        if let engine {
            let configuration = configuration
            Task { await engine.setConfiguration(configuration) }
        }
    }

    func start() {
        switch mode {
        case .demo:
            load(demo: Date())
        case .live:
            guard engine == nil else { return }
            let engine = PipelinesEngine(client: client, configuration: configuration) { [weak self] snapshot in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.receive(snapshot) }
                }
            }
            self.engine = engine
            Task { await engine.start() }
            settings.$pinnedPipelines.map { _ in () }
                .merge(with: settings.$refreshSeconds.map { _ in () })
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
        case .live: receive(await PipelinesEngine.loadOnce(client: client, configuration: configuration))
        }
    }

    private func load(demo now: Date) {
        statuses = DemoData.pipelines(now: now)
        pullRequests = DemoData.pullRequestPipelines(authoredPullRequests, now: now)
        if settings.pinnedPipelines.isEmpty {
            settings.pinnedPipelines = statuses.map(\.pipeline)
        }
        refreshedAt = now.addingTimeInterval(-20)
        hasLoaded = true
        settings.$pinnedPipelines.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinned in
                MainActor.assumeIsolated {
                    // The demo's pipelines, as pinned.
                    let all = DemoData.pipelines(now: Date()) + DemoData.morePipelines.map { PipelineStatus(pipeline: $0, runs: []) }
                    self?.statuses = pinned.compactMap { ref in all.first { $0.pipeline.id == ref.id }.map { status in
                        var status = status
                        status.pipeline = ref
                        return status
                    } }
                }
            }
            .store(in: &cancellables)
    }

    private func receive(_ snapshot: PipelinesSnapshot) {
        if statuses != snapshot.statuses { statuses = snapshot.statuses }
        // A refresh queued before a PR closed must not bring its card back.
        let pullRequests = snapshot.account == authoredAccount ? authoredPullRequests.map { pr in
            snapshot.pullRequests.first { $0.pullRequest == pr }
                ?? self.pullRequests.first { $0.pullRequest == pr }
                ?? PullRequestPipelines(pullRequest: pr, pipelines: [], revisions: [:], hasLoaded: false)
        } : []
        if self.pullRequests != pullRequests { self.pullRequests = pullRequests }
        if problem != snapshot.problem {
            problem = snapshot.problem
            if let problem = snapshot.problem { Log.app.error("Pipelines: \(problem.message, privacy: .public)") }
        }
        if isRefreshing != snapshot.isRefreshing { isRefreshing = snapshot.isRefreshing }
        if refreshedAt != snapshot.refreshedAt { refreshedAt = snapshot.refreshedAt }
        if snapshot.hasLoaded && !hasLoaded { hasLoaded = true }
    }

    /// Something started or stopped showing the pipelines. Azure DevOps is read only while something does.
    func setVisible(_ visible: Bool, for viewer: String) {
        let wasActive = !viewers.isEmpty
        if visible { viewers.insert(viewer) } else { viewers.remove(viewer) }
        let active = !viewers.isEmpty
        guard active != wasActive, let engine else { return }
        Task { await engine.setActive(active) }
    }

    /// Stops reading for good, when Azure DevOps is turned off.
    func stop() {
        cancellables.removeAll()
        if let engine { Task { await engine.stop() } }
        engine = nil
        viewers = []
    }

    func refresh() {
        guard let engine else { return }
        Task { await engine.refresh() }
    }

    // MARK: Pinning

    func isPinned(_ pipeline: PipelineRef) -> Bool {
        settings.pinnedPipelines.contains { $0.id == pipeline.id }
    }

    func pin(_ pipeline: PipelineRef) {
        guard !isPinned(pipeline) else { return }
        settings.pinnedPipelines.append(pipeline)
    }

    func unpin(_ pipeline: PipelineRef) {
        settings.pinnedPipelines.removeAll { $0.id == pipeline.id }
    }

    /// Shows only the runs of one branch, or of every branch.
    func setBranch(_ branch: String?, for pipeline: PipelineRef) {
        guard let index = settings.pinnedPipelines.firstIndex(where: { $0.id == pipeline.id }) else { return }
        settings.pinnedPipelines[index].branch = branch
    }

    func move(_ pipeline: PipelineRef, by offset: Int) {
        guard let index = settings.pinnedPipelines.firstIndex(where: { $0.id == pipeline.id }) else { return }
        let target = index + offset
        guard settings.pinnedPipelines.indices.contains(target) else { return }
        settings.pinnedPipelines.swapAt(index, target)
    }

    // MARK: Searching

    /// The projects to suggest first: those of your pinned pipelines, your pull requests and your teams.
    func suggestedProjects(pullRequests: [PRSnapshot], teams: [TeamRef]) -> [ProjectRef] {
        var projects: [ProjectRef] = []
        func add(_ project: ProjectRef) {
            if !projects.contains(where: { $0.organization == project.organization && $0.name == project.name }) {
                projects.append(project)
            }
        }
        settings.pinnedPipelines.forEach { add(ProjectRef(organization: $0.organization, id: $0.projectId, name: $0.projectName)) }
        teams.forEach { add(ProjectRef(organization: $0.organization, id: $0.projectId, name: $0.projectName)) }
        // Pull requests name their project, but not its ID: the name works in its place.
        pullRequests.forEach { add(ProjectRef(organization: $0.key.organization, id: $0.project, name: $0.project)) }
        if mode == .demo { add(ProjectRef(organization: DemoData.organization, id: DemoData.team.projectId, name: DemoData.team.projectName)) }
        return projects
    }

    /// Every project in the organizations you watch.
    func allProjects() async -> [ProjectRef] {
        if mode == .demo {
            return [ProjectRef(organization: DemoData.organization, id: DemoData.team.projectId, name: DemoData.team.projectName)]
        }
        var projects: [ProjectRef] = []
        for organization in settings.organizations {
            projects += (try? await PipelineSearch.projects(organization: organization, client: client)) ?? []
        }
        return projects
    }

    /// A project's pipelines whose names contain `text`, after the one with that number when `text` is a number.
    func search(_ text: String, in project: ProjectRef) async -> Result<[PipelineRef], ADOError> {
        if mode == .demo {
            return .success(PipelineSearch.pipelines(DemoData.pipelines().map(\.pipeline) + DemoData.morePipelines, containing: text))
        }
        do {
            return .success(try await PipelineSearch.pipelines(
                containing: text, organization: project.organization, projectId: project.id, client: client
            ))
        } catch let error as ADOError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// The pipeline a link is to: a pipeline's link, or one of its runs'.
    func pipeline(for link: PipelineLink) async -> Result<PipelineRef, ADOError> {
        if mode == .demo {
            let all = DemoData.pipelines().map(\.pipeline) + DemoData.morePipelines
            guard case .pipeline(let id) = link.target, let found = all.first(where: { $0.definitionId == id }) else {
                return .failure(.notFound)
            }
            return .success(found)
        }
        do {
            return .success(try await PipelineSearch.pipeline(for: link, client: client))
        } catch let error as ADOError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    func open(_ run: PipelineRun) {
        AzureDevOps.open(run.webURL)
    }

    func open(_ pipeline: PipelineRef) {
        AzureDevOps.open(pipeline.webURL)
    }
}
