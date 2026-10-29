import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import SwiftUI

/// Tells Show Links what Azure DevOps knows: the work items linked to your pull requests, the pull requests linked to the
/// sprint's work items, the work items and pull requests you sent to Copilot and the pull requests it opened; and what each
/// of them is, for other rows to show, and what's known of each beyond its row, for the details (`ItemStories`). It reads
/// Azure DevOps for it only while Show Links is on, with the pull requests' client, after each of their refreshes
/// (`LinkEngine`).
@MainActor
final class WorkLinksStore {
    private let links: Links
    private let stories: ItemStories
    private let store: PRStore
    private let sprint: SprintStore
    private let copilot: CopilotTasksStore
    private let settings: AppSettings
    private var engine: LinkEngine?
    private var read = WorkLinks()
    private var lastInputs: LinkEngine.Inputs?
    private var cancellables: Set<AnyCancellable> = []

    init(links: Links, stories: ItemStories, store: PRStore, sprint: SprintStore, copilot: CopilotTasksStore, settings: AppSettings) {
        self.links = links
        self.stories = stories
        self.store = store
        self.sprint = sprint
        self.copilot = copilot
        self.settings = settings
    }

    func start() {
        guard cancellables.isEmpty else { return }
        tellStories()
        // After the change: a @Published value emits before it's set.
        links.$isOn.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in MainActor.assumeIsolated { self?.showLinks(on) } }
            .store(in: &cancellables)
        // What the rows show, and what's in the sprint.
        store.$items.map { _ in () }
            .merge(with: sprint.$board.map { _ in () }, sprint.$isShowing.removeDuplicates().map { _ in () })
            .merge(with: copilot.objectWillChange.map { _ in () }, settings.$showToReview.removeDuplicates().map { _ in () })
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
        // Things newly linked that your lists and the sprint don't show, such as a work item you linked: read what they are.
        links.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateEngine() } }
            .store(in: &cancellables)
        // After each refresh of the pull requests, what's due.
        store.$refreshedAt.removeDuplicates().dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshEngine() } }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        stopEngine()
        lastInputs = nil
        read = WorkLinks()
        links.withdraw(.azureDevOps)
        stories.withdraw(.azureDevOps)
    }

    /// Reads once and tells Show Links, for `--render`: the demo's made-up links, or yours while Show Links is on.
    func loadOnce() async {
        guard links.isOn else { return }
        tellStories()
        switch store.mode {
        case .demo:
            read = DemoData.workLinks(now: Date())
        case .live:
            let engine = LinkEngine(client: store.client) { _ in }
            await engine.update(inputs())
            read = await engine.currentLinks()
        }
        publish()
    }

    private func showLinks(_ on: Bool) {
        lastInputs = nil
        if on {
            switch store.mode {
            case .demo:
                read = DemoData.workLinks(now: Date())
            case .live:
                engine = LinkEngine(client: store.client) { [weak self] read in
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.receive(read) }
                    }
                }
            }
        } else {
            stopEngine()
            read = WorkLinks()
        }
        update()
    }

    /// Stops reading: a refresh under way stops before its next request.
    private func stopEngine() {
        if let engine { Task { await engine.stop() } }
        engine = nil
    }

    private func receive(_ read: WorkLinks) {
        guard engine != nil, read != self.read else { return }
        self.read = read
        publish()
    }

    private func update() {
        publish()
        updateEngine()
    }

    private func updateEngine() {
        guard let engine, links.isOn else { return }
        let inputs = inputs()
        guard inputs != lastInputs else { return }
        lastInputs = inputs
        Task { await engine.update(inputs) }
    }

    private func refreshEngine() {
        guard let engine else { return }
        Task { await engine.refresh() }
    }

    /// Your pull requests, the sprint's work items while it shows, and what's linked that neither shows, for the engine
    /// to read what it is. What the engine read of those stays in the lookups: taking it out would make the engine forget
    /// it, then read it again, over and over.
    func inputs() -> LinkEngine.Inputs {
        var pullRequests: [PRKey: LinkEngine.Place] = [:]
        for record in store.records {
            pullRequests[record.id] = LinkEngine.Place(projectId: record.pullRequest.projectId, repositoryId: record.pullRequest.repositoryId)
        }
        let listed = Set(store.items.map(\.key.linkRef)).union(sprintItems.map(\.linkRef))
        let lookups = Self.lookups(links.linked([.workItem, .pullRequest]), listed: listed)
        return LinkEngine.Inputs(
            pullRequests: pullRequests,
            sprintItems: Set(sprintItems.map { WorkItemKey($0.organization, $0.id) }),
            sprintShows: sprint.isShowing,
            workItemLookups: lookups.workItems,
            pullRequestLookups: lookups.pullRequests
        )
    }

    /// The work items and pull requests in links that your lists and the sprint don't show.
    static func lookups(_ linked: Set<ItemRef>, listed: Set<ItemRef>) -> (workItems: Set<WorkItemKey>, pullRequests: Set<PRKey>) {
        var workItems: Set<WorkItemKey> = []
        var pullRequests: Set<PRKey> = []
        for ref in linked.subtracting(listed) {
            guard let number = ref.number else { continue }
            switch ref.kind {
            case .workItem: workItems.insert(WorkItemKey(ref.scope, number))
            case .pullRequest: pullRequests.insert(PRKey(ref.scope, number))
            case .gitHubPullRequest, .session: break
            }
        }
        return (workItems, pullRequests)
    }

    private var sprintItems: [WorkItem] {
        (sprint.board?.rows ?? []).flatMap { ($0.parent.map { [$0] } ?? []) + $0.tasks }
    }

    // MARK: Telling Show Links

    private func publish() {
        guard links.isOn else {
            links.withdraw(.azureDevOps)
            return
        }
        var facts = read.links
        var items: [LinkedItem] = []
        let showToReview = settings.showToReview
        for item in store.items {
            let record = store.record(for: item.key)
            items.append(LinkedItem(
                ref: .pullRequest(organization: item.key.organization, number: item.key.number), label: "!\(item.key.number)",
                title: item.title, symbol: item.group == .done ? "arrow.triangle.merge" : "arrow.triangle.pull", color: item.rowColor,
                state: item.group.state(showToReview: showToReview), status: item.group.title, place: item.repository,
                hint: record.map { Self.hint($0.pullRequest) }, date: item.since,
                open: { [weak store] in
                    // As it is when you click it.
                    store?.open(store?.items.first { $0.key == item.key } ?? item)
                }
            ))
        }
        for pullRequest in read.pullRequests.values {
            items.append(Self.item(pullRequest))
        }
        for workItem in sprintItems + read.workItems.values {
            items.append(Self.item(workItem))
        }
        if copilot.isOn {
            let now = Date()
            for entry in copilot.entries {
                guard let session = ItemRef.session(entry.id) else { continue }
                facts += Self.links(of: entry, session: session)
                let phase = entry.status.phase
                let copilot = self.copilot
                items.append(LinkedItem(
                    ref: session, label: copilot.subject(of: entry), title: "Copilot: \(copilot.subject(of: entry))",
                    symbol: "paperplane.fill", color: phase.color, state: phase.state, status: entry.sentence(now: now),
                    date: entry.status.since ?? entry.startedAt,
                    menu: { AnyView(CopilotRunMenuItems(entry: entry).environmentObject(copilot)) }
                ))
            }
        }
        links.publish(.azureDevOps, links: facts, items: items)
    }

    /// What a task sent to Copilot links: its session to the work item or pull request it was sent from, and to the pull
    /// request it opened, which goes with the work item too.
    static func links(of entry: CopilotTaskEntry, session: ItemRef) -> [ItemLink] {
        var links: [ItemLink?] = []
        let workItem = entry.workItem.map { ItemRef.workItem(organization: $0.organization, id: $0.id) }
        if let workItem { links.append(ItemLink(session, workItem, origin: .copilot)) }
        if let pullRequest = entry.onPullRequest {
            links.append(ItemLink(session, .pullRequest(organization: pullRequest.organization, number: pullRequest.id), origin: .copilot))
        }
        if let url = entry.pullRequest, let opened = ItemRef.from(link: url.absoluteString) {
            links.append(ItemLink(session, opened, origin: .copilot))
            if let workItem { links.append(ItemLink(workItem, opened, origin: .copilot)) }
        }
        return links.compactMap { $0 }
    }

    // MARK: What's known of them

    /// Tells the details what's known of its pull requests and tasks, when they ask.
    private func tellStories() {
        stories.register(.azureDevOps, kinds: [.pullRequest, .session]) { [weak self] ref in self?.tell(ref) }
    }

    /// What Azure DevOps knows of one of its things beyond its row, from what it read already: one of your pull requests
    /// from all of it, one that's only linked from the pull request itself, and a task sent to Copilot from how it went.
    func tell(_ ref: ItemRef) -> ItemStory? {
        switch ref.kind {
        case .pullRequest:
            if let snapshot = store.items.first(where: { $0.key.linkRef == ref }) {
                return PullRequestStory.mine(snapshot, record: store.record(for: snapshot.key))
            }
            let pullRequest = read.pullRequests.values.first { $0.key.linkRef == ref }
                ?? store.records.first { $0.id.linkRef == ref }?.pullRequest
            return pullRequest.map(PullRequestStory.others)
        case .session:
            guard copilot.isOn, let entry = copilot.entries.first(where: { ItemRef.session($0.id) == ref }) else { return nil }
            return Self.story(of: entry, now: Date())
        case .workItem, .gitHubPullRequest:
            return nil
        }
    }

    /// A task sent to Copilot: how it went, what for and when, the pull request it opened, and the summary it ended with.
    /// What Copilot recorded of its work, its checkpoints, comes from Copilot's own files, when that source is on.
    static func story(of entry: CopilotTaskEntry, now: Date) -> ItemStory {
        var facts: [ItemStory.Fact] = []
        let ago = Elapsed.short(since: entry.startedAt, now: now)
        let sent = ago == "now" ? "Just now" : "\(ago) ago"
        let sentFor = [entry.action?.title, sent, "with \(entry.options.title)"].compactMap { $0 }
        facts.append(ItemStory.Fact("Sent", sentFor.joined(separator: " · ")))
        if entry.onPullRequest == nil, let url = entry.pullRequest, let opened = ItemRef.from(link: url.absoluteString),
           let number = opened.number {
            facts.append(ItemStory.Fact("Opened", opened.kind == .gitHubPullRequest ? "#\(number)" : "!\(number)"))
        }
        var account: ItemStory.Account?
        if !entry.status.phase.isActive, let detail = entry.status.detail, !detail.isEmpty {
            account = ItemStory.Account(
                source: "Copilot's summary", date: entry.status.since, overview: StoryText.paragraph(detail, limit: 700)
            )
        }
        return ItemStory(sentence: entry.sentence(now: now), date: entry.status.since ?? entry.startedAt, facts: facts, account: account)
    }

    static func hint(_ pullRequest: PullRequest) -> BranchHint {
        BranchHint(branch: pullRequest.sourceBranch, target: pullRequest.targetBranch, repositories: [pullRequest.repositoryName])
    }

    /// A pull request that's linked but not in your lists, such as a teammate's on a sprint's work item.
    static func item(_ pullRequest: PullRequest) -> LinkedItem {
        let (status, color): (String, Color) = switch pullRequest.status {
        case .active: (pullRequest.isDraft ? "Draft" : "Active", .blue)
        case .completed: ("Completed", Color(nsColor: .systemPurple))
        case .abandoned: ("Abandoned", .secondary)
        case .other: ("Closed", .secondary)
        }
        return LinkedItem(
            ref: .pullRequest(organization: pullRequest.key.organization, number: pullRequest.key.number),
            label: "!\(pullRequest.key.number)", title: pullRequest.title,
            symbol: pullRequest.status == .completed ? "arrow.triangle.merge" : "arrow.triangle.pull", color: color, status: status,
            place: pullRequest.repositoryName, hint: hint(pullRequest), date: pullRequest.closedAt ?? pullRequest.createdAt,
            open: { AzureDevOps.open(pullRequest.webURL) }
        )
    }

    static func item(_ workItem: WorkItem) -> LinkedItem {
        LinkedItem(
            ref: .workItem(organization: workItem.organization, id: workItem.id), label: String(workItem.id), title: workItem.title,
            symbol: workItem.typeSymbol, color: workItem.typeColor, status: workItem.state, place: workItem.project,
            date: workItem.changedAt, open: { AzureDevOps.open(workItem.webURL) }
        )
    }
}

extension RunPhase {
    /// What a task sent to Copilot means for you: at work, done, or something went wrong. Stopping it yourself isn't.
    var state: ItemState? {
        switch self {
        case .preparing, .working: return .running
        case .finished: return .done
        case .failed: return .failing
        case .stopped: return nil
        }
    }
}
