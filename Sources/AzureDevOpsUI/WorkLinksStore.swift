import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import SwiftUI

/// Tells Show Links what Azure DevOps knows: the work items linked to your pull requests, the pull requests linked to the
/// sprint's work items, the work items and pull requests you sent to Copilot and the pull requests it opened; and what each
/// of them is, for other rows to show, what's known of each beyond its row, for the details, and more of each for a summary,
/// as one is written (`ItemStories`). It reads Azure DevOps for it only while Show Links is on, with the pull requests'
/// client: after each of their refreshes (`LinkEngine`), and for a summary (`context`). While Pull Request Order is on too,
/// it works out which stories your pull requests are for (`WorkItemStories`), with the parent and place in the backlog of
/// their work items, and what those stories are when nothing else has them, which the engine reads then.
@MainActor
final class WorkLinksStore {
    /// The stories your pull requests are for, while Show Links reads them and Pull Request Order wants them.
    struct Stories: Equatable {
        /// Whether it reads them: Show Links and Pull Request Order are both on.
        var areRead = false
        /// By pull request, its organization lowercased: none for one whose work items aren't read yet.
        var byPullRequest: [PRKey: [OrderStory]] = [:]
        /// Those stories and their tasks, for their titles.
        var workItems: [WorkItem] = []
    }

    private let links: Links
    private let stories: ItemStories
    private let store: PRStore
    private let sprint: SprintStore
    private let copilot: CopilotTasksStore
    private let settings: AppSettings
    /// Pull Request Order, which wants stories while it's on.
    private let order: PullRequestOrder?
    /// The stories your pull requests are for, for Pull Request Order.
    @Published private(set) var storiesRead = Stories()
    private var engine: LinkEngine?
    /// How many engines it started: what one reads is taken only while it's the last started, as one replaced, when
    /// someone else signed in, may still tell what it was reading as the last one.
    private var engines = 0
    /// Makes an engine that tells `onChange` what it reads, with the pull requests' client: tests read without it.
    var makeEngine: (_ onChange: @escaping LinkEngine.ChangeHandler) -> LinkEngine
    private var read = WorkLinks()
    private var lastInputs: LinkEngine.Inputs?
    private var cancellables: Set<AnyCancellable> = []
    /// The details on screen, for what's known of the work item they show: whenever they're read, its story is told
    /// again with them, rather than as it was before they came.
    weak var details: WorkItemDetailsStore? {
        didSet {
            detailsRead = details?.$details.compactMap { $0?.item.linkRef }
                .sink { [weak self] ref in MainActor.assumeIsolated { self?.stories.invalidate(ref) } }
        }
    }
    private var detailsRead: AnyCancellable?
    /// Shows one of your pull requests in its details on the window's Pull Requests page: whether it could. The source's.
    var showPullRequest: (PRKey) -> Bool = { _ in false }
    /// Who's signed in to the Azure CLI, as the pull requests' refresh last told.
    private var account: String?
    /// Whether it tells the details about its things: from `start` or `loadOnce`, until `stop`, whether Show Links is on
    /// or not, as `ItemStories` asks only while it is.
    private var tellsStories = false

    init(
        links: Links, stories: ItemStories, store: PRStore, sprint: SprintStore, copilot: CopilotTasksStore, settings: AppSettings,
        order: PullRequestOrder? = nil
    ) {
        self.links = links
        self.stories = stories
        self.store = store
        self.sprint = sprint
        self.copilot = copilot
        self.settings = settings
        self.order = order
        makeEngine = { [client = store.client] onChange in LinkEngine(client: client, onChange: onChange) }
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
        // Stories, while Pull Request Order wants them.
        order?.$isOn.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        stopEngine()
        lastInputs = nil
        read = WorkLinks()
        links.withdraw(.azureDevOps)
        stories.withdraw(.azureDevOps)
        tellsStories = false
        storiesRead = Stories()
    }

    /// Reads once and tells Show Links, for `--render`: the demo's made-up links, or yours while Show Links is on.
    func loadOnce() async {
        guard links.isOn else { return }
        tellStories()
        switch store.mode {
        case .demo:
            read = DemoData.workLinks(now: Date())
        case .live:
            let engine = makeEngine { _ in }
            await engine.update(inputs())
            read = await engine.currentLinks()
            // And the stories of what it read, when they're wanted.
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
                startEngine()
            }
        } else {
            stopEngine()
            read = WorkLinks()
        }
        update()
    }

    /// Starts reading with nothing read, in place of the engine that read before.
    private func startEngine() {
        stopEngine()
        engines += 1
        let number = engines
        lastInputs = nil
        engine = makeEngine { [weak self] read in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.receive(read, from: number) }
            }
        }
    }

    /// Stops reading: a refresh under way stops before its next request.
    private func stopEngine() {
        if let engine { Task { await engine.stop() } }
        engine = nil
    }

    private func receive(_ read: WorkLinks, from number: Int) {
        guard engine != nil, number == engines, read != self.read else { return }
        self.read = read
        publish()
        // What it read can change what's to read: the parents of tasks, once their parents are read with them.
        updateEngine()
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

    /// Reads again now what a Copilot session said it changed, while Show Links reads anything (`LinkEngine.reread`).
    func reread(pullRequests: Set<PRKey>, workItems: Set<WorkItemKey>) {
        guard let engine else { return }
        Task { await engine.reread(pullRequests: pullRequests, workItems: workItems) }
    }

    /// What the engine was told to read last, while it reads.
    var engineInputs: LinkEngine.Inputs? {
        engine == nil ? nil : lastInputs
    }

    /// The organizations of what it looks up, what's linked that your lists and the sprint don't show, while it reads:
    /// any, not only those you chose, as a session or a link you added may link another organization's work item.
    var lookupOrganizations: Set<String> {
        guard engine != nil, let lastInputs else { return [] }
        return Set(lastInputs.workItemLookups.map(\.organization) + lastInputs.pullRequestLookups.map(\.organization))
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
        let wantsStories = order?.isOn == true
        return LinkEngine.Inputs(
            pullRequests: pullRequests,
            sprintItems: Set(sprintItems.map { WorkItemKey($0.organization, $0.id) }),
            sprintShows: sprint.isShowing,
            workItemLookups: lookups.workItems,
            pullRequestLookups: lookups.pullRequests,
            wantsStories: wantsStories,
            parentLookups: wantsStories ? storyFinder.parents(ofTasksIn: linkedToPullRequests) : []
        )
    }

    /// The work items linked to your pull requests, as read.
    private var linkedToPullRequests: Set<WorkItemKey> {
        Set(read.workItemsOfPullRequests.flatMap { key, ids in ids.map { WorkItemKey(key.organization, $0) } })
    }

    /// Which stories work items are for, from what's read of them: the sprint's, the linked ones' and their parents'.
    private var storyFinder: WorkItemStories {
        WorkItemStories(workItems: sprintItems + Array(read.workItems.values) + Array(read.parents.values), board: sprint.board)
    }

    /// Works out which stories your pull requests are for, while Show Links reads them and Pull Request Order wants them;
    /// none otherwise.
    private func updateStories() {
        guard links.isOn, order?.isOn == true else {
            if storiesRead != Stories() { storiesRead = Stories() }
            return
        }
        let finder = storyFinder
        let known = Dictionary(
            (sprintItems + Array(read.workItems.values) + Array(read.parents.values)).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var byPullRequest: [PRKey: [OrderStory]] = [:]
        var named: Set<WorkItemKey> = []
        for (key, ids) in read.workItemsOfPullRequests {
            // Until each of its work items is read, or Azure DevOps says it can't be, its stories aren't known: its mission
            // isn't named from half of what it's made of.
            guard !ids.contains(where: { read.pendingWorkItems.contains(WorkItemKey(key.organization, $0)) }) else { continue }
            let found = finder.stories(of: key, workItems: ids)
            byPullRequest[PRKey(key.organization.lowercased(), key.number)] = found
            for ref in found.flatMap({ [$0.ref, $0.task].compactMap { $0 } }) {
                if let id = ref.number { named.insert(WorkItemKey(ref.scope, id)) }
            }
        }
        let stories = Stories(areRead: true, byPullRequest: byPullRequest, workItems: named.sorted().compactMap { known[$0] })
        if stories != storiesRead { storiesRead = stories }
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
        updateStories()
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
                state: item.group.state(showToReview: showToReview), status: item.group.title,
                sharedStatus: PullRequestStory.sharedStatus(item), place: item.repository,
                hint: record.map { Self.hint($0.pullRequest) }, date: item.since,
                open: { [weak store] in
                    // As it is when you click it.
                    store?.open(store?.items.first { $0.key == item.key } ?? item)
                },
                url: item.url,
                show: { [weak self] in self?.showPullRequest(item.key) ?? false }
            ))
        }
        for pullRequest in read.pullRequests.values {
            items.append(Self.item(pullRequest))
        }
        let rows = sprint.board?.rows ?? []
        for workItem in sprintItems + read.workItems.values {
            // A story's or a bug's tasks, in the sprint.
            let tasks = rows.first { $0.parent?.key == workItem.key }?.tasks.count ?? 0
            items.append(Self.item(workItem, tasks: tasks))
        }
        if copilot.isOn {
            for entry in copilot.entries {
                guard let session = ItemRef.session(entry.id) else { continue }
                facts += Self.links(of: entry, session: session)
                let phase = entry.status.phase
                let copilot = self.copilot
                let from = entry.target
                let fromLabel = entry.onPullRequest.map { "!\($0.id)" } ?? entry.workItem.map { String($0.id) }
                let fromTitle: String? = if let pullRequest = entry.onPullRequest {
                    copilot.pullRequestTitle(pullRequest)
                } else {
                    entry.workItem.flatMap { copilot.title($0) }
                }
                // Without how long it's been at it, which its date says: its row stays the same while it works.
                items.append(LinkedItem(
                    ref: session, label: copilot.subject(of: entry), title: "Copilot: \(copilot.subject(of: entry))",
                    symbol: "paperplane.fill", color: phase.color, state: phase.state, status: entry.sentence(now: nil),
                    date: entry.status.since ?? entry.startedAt,
                    menu: { AnyView(CopilotRunMenuItems(entry: entry).environmentObject(copilot)) },
                    sent: SentToCopilot(action: entry.action?.title, from: from, label: fromLabel, title: fromTitle)
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

    /// Someone else signed in to the Azure CLI: what was read as the last one goes, and what's still being read as them is
    /// left out, so it's read again from the start, as the new one; and what was told of Azure DevOps' things goes, with
    /// the summaries made of it and those being written, as when the source stops. They're told again, as the new one, when
    /// they're asked for.
    func accountChanged(_ account: String?) {
        guard let account else { return }
        defer { self.account = account }
        guard let known = self.account, known != account else { return }
        if store.mode == .live {
            read = WorkLinks()
            if engine != nil { startEngine() }
            update()
        }
        stories.withdraw(.azureDevOps)
        if tellsStories { tellStories() }
    }

    /// Tells the details what's known of its work items, pull requests and tasks, when they ask; and reads more of its work
    /// items and pull requests for a summary, as one is written.
    private func tellStories() {
        tellsStories = true
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest, .session]) { [weak self] ref in self?.tell(ref) }
        stories.registerContext(.azureDevOps, kinds: [.workItem, .pullRequest]) { [weak self] ref in await self?.context(ref) ?? [] }
    }

    /// What Azure DevOps knows of one of its things beyond its row, from what it read already: a work item from the sprint,
    /// and from its details when they show it; one of your pull requests from all of it, one that's only linked from the
    /// pull request itself; and a task sent to Copilot from how it went.
    func tell(_ ref: ItemRef) -> ItemStory? {
        switch ref.kind {
        case .workItem:
            let rows = sprint.board?.rows ?? []
            let shown = details?.selected.flatMap { $0.linkRef == ref ? $0 : nil }
            guard let item = shown ?? (sprintItems + read.workItems.values).first(where: { $0.linkRef == ref }) else { return nil }
            let tasks = rows.first { $0.parent?.linkRef == ref }?.tasks ?? []
            // How the work you sent to Copilot for each stands, without for how long; and Copilot, while it's at it.
            let entries = copilot.isOn ? tasks.compactMap { task in copilot.latest(for: task).map { (task, $0) } } : []
            let runs = Dictionary(entries.map { ($0.0.id, $0.1.sentence(now: nil)) }, uniquingKeysWith: { first, _ in first })
            var story = WorkItemStory.make(item, details: details?.details, tasks: tasks, taskRuns: runs)
            let waits = CopilotTaskEntry.waits(of: entries.map(\.1), among: copilot.entries, isDone: isDone) { self.workItem($0)?.type }
            story.waits = ItemStory.Wait.ordered(waits)
            return story
        case .pullRequest:
            if let snapshot = store.items.first(where: { $0.key.linkRef == ref }) {
                return PullRequestStory.mine(snapshot, record: store.record(for: snapshot.key))
            }
            let pullRequest = read.pullRequests.values.first { $0.key.linkRef == ref }
                ?? store.records.first { $0.id.linkRef == ref }?.pullRequest
            // You, in its organization, as your pull requests have you.
            let me = store.records.first { $0.id.organization.lowercased() == ref.scope }?.me
            return pullRequest.map { PullRequestStory.others($0, me: me) }
        case .session:
            guard copilot.isOn, let entry = copilot.entries.first(where: { ItemRef.session($0.id) == ref }) else { return nil }
            var story = Self.story(of: entry)
            // Its failure waits on you only while it's the latest sent for what it was sent for, and that isn't done.
            story.waits = CopilotTaskEntry.waits(of: [entry], among: copilot.entries, isDone: isDone) { self.workItem($0)?.type }
            return story
        case .gitHubPullRequest:
            return nil
        }
    }

    // MARK: More, for a summary

    /// What Azure DevOps reads of one of its things for a summary, as one is written, while Show Links is on: a pull
    /// request's description and comment threads, from Azure DevOps, but for your pull requests' threads, which it has; a
    /// work item's texts and latest comments, from its details on screen, or read for it. The demo reads nothing: it has its
    /// pull requests' threads, a few made-up descriptions, and its sprint's details. Nothing is kept, and nothing read as
    /// someone other than who's signed in, as far as it knows, is taken.
    func context(_ ref: ItemRef) async -> [ItemStory.Fact] {
        guard links.isOn, !Task.isCancelled else { return [] }
        let parts: [ItemStory.Fact]
        switch ref.kind {
        case .pullRequest: parts = await pullRequestContext(ref)
        case .workItem: parts = await workItemContext(ref)
        case .gitHubPullRequest, .session: return []
        }
        // Show Links went off, or the summary was taken back, meanwhile.
        guard links.isOn, !Task.isCancelled else { return [] }
        return parts
    }

    /// A pull request's description and comment threads: one of yours, or one that's only linked.
    private func pullRequestContext(_ ref: ItemRef) async -> [ItemStory.Fact] {
        let record = store.records.first { $0.id.linkRef == ref }
        guard let pullRequest = record?.pullRequest ?? read.pullRequests.values.first(where: { $0.key.linkRef == ref }) else {
            return []
        }
        // You, in its organization, as your pull requests have you.
        let me = record?.me ?? store.records.first { $0.id.organization.lowercased() == ref.scope }?.me
        let threads = record?.details?.threads
        switch store.mode {
        case .demo:
            let description = DemoData.pullRequestDescription(pullRequest.key)
            return PullRequestContext.parts(of: pullRequest, description: description, threads: threads, me: me)
        case .live:
            let parts = await PullRequestContext.read(pullRequest, threads: threads, me: me, client: store.client)
            guard !parts.isEmpty else { return [] }
            // The sign-in its requests went with, which the client keeps.
            return isCurrentAccount(try? await store.client.tokens.token().account) ? parts : []
        }
    }

    /// A work item's texts and latest comments, from its details on screen when they're its own, or else read, for one of
    /// the sprint's, or one read for what's linked.
    private func workItemContext(_ ref: ItemRef) async -> [ItemStory.Fact] {
        if let shown = details?.details, shown.item.linkRef == ref {
            return WorkItemStory.context(shown)
        }
        guard let item = details?.selected.flatMap({ $0.linkRef == ref ? $0 : nil }) ?? workItem(ref) else { return [] }
        switch store.mode {
        case .demo:
            return DemoData.workItemDetails(organization: item.organization, id: item.id).map(WorkItemStory.context) ?? []
        case .live:
            let outcome = await WorkItemDetailsStore.read(item, client: store.client)
            guard isCurrentAccount(outcome.account) else { return [] }
            return (try? outcome.result.get()).map(WorkItemStory.context) ?? []
        }
    }

    /// Whether what was read as `account` was read as who's signed in to the Azure CLI, as the pull requests' refresh last
    /// told: when either isn't known, it's taken.
    private func isCurrentAccount(_ account: String?) -> Bool {
        guard let account, let known = self.account else { return true }
        return account == known
    }

    /// Whether what work was sent to Copilot for is done, as last read: a work item that's done, a pull request that's
    /// closed.
    private func isDone(_ ref: ItemRef) -> Bool {
        switch ref.kind {
        case .workItem:
            return workItem(ref)?.isDone ?? false
        case .pullRequest:
            let pullRequest = store.records.first { $0.id.linkRef == ref }?.pullRequest
                ?? read.pullRequests.values.first { $0.key.linkRef == ref }
            return pullRequest.map { $0.status != .active } ?? false
        case .gitHubPullRequest, .session:
            return false
        }
    }

    /// One of the sprint's work items, or one read for what's linked.
    private func workItem(_ ref: ItemRef) -> WorkItem? {
        (sprintItems + read.workItems.values).first { $0.linkRef == ref }
    }

    /// A task sent to Copilot: how it went, without how long it's been at it, which its date says, the pull request it
    /// opened, the model it works with, and the summary it ended with. What Copilot recorded of its work, its notes, comes
    /// from Copilot's own files, when that source is on.
    static func story(of entry: CopilotTaskEntry) -> ItemStory {
        var sentence = entry.sentence(now: nil)
        if entry.status.phase == .finished, entry.action == nil, let url = entry.pullRequest,
           let opened = ItemRef.from(link: url.absoluteString), let number = opened.number {
            sentence = "Opened " + (opened.kind == .gitHubPullRequest ? "#\(number)" : "!\(number)")
        }
        var account: ItemStory.Account?
        if !entry.status.phase.isActive, let detail = entry.status.detail, !detail.isEmpty {
            account = ItemStory.Account(
                source: "Copilot's report", date: entry.status.since, overview: StoryText.paragraph(detail, limit: 700)
            )
        }
        return ItemStory(
            sentence: sentence, date: entry.status.since ?? entry.startedAt, facts: [ItemStory.Fact("Model", entry.options.title)],
            account: account, waits: entry.waits()
        )
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
            open: { AzureDevOps.open(pullRequest.webURL) }, url: pullRequest.webURL
        )
    }

    /// A work item, with how many tasks it has in the sprint, for a story or a bug.
    static func item(_ workItem: WorkItem, tasks: Int = 0) -> LinkedItem {
        LinkedItem(
            ref: .workItem(organization: workItem.organization, id: workItem.id), label: String(workItem.id), title: workItem.title,
            symbol: workItem.typeSymbol, color: workItem.typeColor, status: workItem.state, place: workItem.project,
            date: workItem.changedAt, open: { AzureDevOps.open(workItem.webURL) }, url: workItem.webURL, parts: tasks
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

extension CopilotTaskEntry {
    /// What it was sent for: the pull request it works on, or else its work item.
    var target: ItemRef? {
        onPullRequest.map { ItemRef.pullRequest(organization: $0.organization, number: $0.id) }
            ?? workItem.map { ItemRef.workItem(organization: $0.organization, id: $0.id) }
    }

    /// Copilot, while it goes on; you, once it failed: "Copilot, on task 5103", and on that task itself, "Copilot, working
    /// on it".
    /// - Parameter type: its work item's type, such as "Task", when it's known; or else it's a work item.
    func waits(type: String? = nil) -> [ItemStory.Wait] {
        let on = onPullRequest.map { "!\($0.id)" } ?? workItem.map { "\(type?.lowercased() ?? "work item") \($0.id)" } ?? "its task"
        let session = ItemRef.session(id)
        if status.phase.isActive {
            return [ItemStory.Wait(
                .copilot, "Copilot, on \(on)", about: session, onItself: target.map { .init($0, "Copilot, working on it") }
            )]
        }
        if status.phase == .failed {
            return [ItemStory.Wait(
                .you, "you, to look at Copilot's work on \(on), which failed", about: session,
                onItself: target.map { .init($0, "you, to look at Copilot's work on it, which failed") }
            )]
        }
        return []
    }

    /// Who the work sent to Copilot waits on, as the details and agents say it: Copilot, while each goes on; you, once the
    /// one started last for a work item or a pull request failed, unless that's done since (`isDone`), as you'd send it
    /// again or do it yourself.
    /// - Parameters:
    ///   - entries: the ones to tell of.
    ///   - all: all the work sent to Copilot, to tell whether something was sent again since, such as a pull request a task's
    ///     work went on to; `entries` when nil.
    ///   - type: a work item's type, such as "Task", when it's known.
    static func waits(
        of entries: [CopilotTaskEntry], among all: [CopilotTaskEntry]? = nil, isDone: (ItemRef) -> Bool,
        type: (ItemRef) -> String? = { _ in nil }
    ) -> [ItemStory.Wait] {
        // When each was last sent for.
        var latest: [ItemRef: Date] = [:]
        for entry in all ?? entries {
            guard let target = entry.target else { continue }
            latest[target] = max(latest[target] ?? entry.startedAt, entry.startedAt)
        }
        return entries.sorted { $0.startedAt > $1.startedAt }.flatMap { entry -> [ItemStory.Wait] in
            if entry.status.phase == .failed, let target = entry.target,
               (latest[target] ?? entry.startedAt) > entry.startedAt || isDone(target) {
                return []
            }
            return entry.waits(type: entry.workItem == nil ? nil : entry.target.flatMap(type))
        }
    }
}
