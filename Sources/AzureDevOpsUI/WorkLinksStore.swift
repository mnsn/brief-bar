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
/// their work items, and what those stories are when nothing else has them, which the engine reads then. And it tells My
/// Work's Map the dependencies Azure DevOps links the sprint's work items with (`MapDependencies`), and, while My Work shows
/// the Map, has the engine read what the work items the Map can show that no list or sprint has are: those the
/// dependencies, and the lines you and sessions said, name, and those you added. With Parents on, it climbs from your work
/// items to their parents, a level each time a read names them, all the way up (`mapParentLookups`), and tells the Map
/// those parents, with the Related links Azure DevOps has between the sprint's work items and others.
@MainActor
final class WorkLinksStore {
    /// The stories your pull requests are for, while Show Links reads them and Pull Request Order wants them.
    struct Stories: Equatable {
        /// Whether it reads them: Show Links and Pull Request Order are both on.
        var areRead = false
        /// By pull request, its organization lowercased: none for one whose work items aren't read yet.
        var byPullRequest: [PRKey: [OrderStory]] = [:]
        /// Their work items, all of them, by pull request as those stories are, for their missions' names.
        var workItemsByPullRequest: [PRKey: [ItemRef]] = [:]
        /// Those stories and work items, for their titles.
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
    /// The linked work items whose state BriefBar changed, from My Work (`changedState`), as Azure DevOps answered: each shows
    /// so over what the engine read, with the team's category, while the engine reads it in the state it went to, or until
    /// it no longer reads it.
    private var stateChanges: [WorkItemKey: WorkItem] = [:]
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
    /// My Work's Map's dependencies, which it tells what Azure DevOps links.
    weak var dependencies: MapDependencies? {
        didSet { tellMap() }
    }

    /// Whether a window shows My Work on screen (`AzureDevOpsSource.setMyWorkVisible`): what only its Map names is read
    /// only while one does, with the Map chosen.
    private(set) var myWorkIsOnScreen = false

    /// A window started showing My Work on screen, or the last one stopped.
    func setMyWorkOnScreen(_ onScreen: Bool) {
        guard myWorkIsOnScreen != onScreen else { return }
        myWorkIsOnScreen = onScreen
        updateEngine()
    }
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
        // What the rows show, and what's in the sprint, with your work outside it while My Work shows its cards.
        store.$items.map { _ in () }
            .merge(with: sprint.$board.map { _ in () }, sprint.$isShowing.removeDuplicates().map { _ in () })
            .merge(with: sprint.$outside.map { _ in () }, sprint.$showsOutside.removeDuplicates().map { _ in () })
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
        // What My Work's Map names, while it shows: what you and sessions changed of it, whether it shows, the pull requests on
        // its board, and its parents, which climb from your sprint work only while Show shows it.
        if let order {
            order.$mapEdits.map { _ in () }
                .merge(with: order.$mapTold.map { _ in () }, order.$myWorkView.map { _ in () }, order.$myWorkPage.map { _ in () })
                .merge(
                    with: order.$mapShowsParents.map { _ in () }, settings.$myWorkShows.removeDuplicates().map { _ in () },
                    order.$stages.map { _ in () }
                )
                .dropFirst()
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] in MainActor.assumeIsolated { self?.updateEngine() } }
                .store(in: &cancellables)
        }
    }

    func stop() {
        cancellables.removeAll()
        stopEngine()
        lastInputs = nil
        read = WorkLinks()
        stateChanges = [:]
        dependencies?.told([], parents: [:], parentItems: [:], related: [])
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
        stateChanges = [:]
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
        guard engine != nil, number == engines else { return }
        let read = keepingStateChanges(read)
        guard read != self.read else { return }
        self.read = read
        publish()
        // What it read can change what's to read: the parents of tasks, once their parents are read with them.
        updateEngine()
    }

    /// What the engine read, with the linked work items whose state BriefBar changed since in their new state, and, while one
    /// is in the state it went to, in the category the team's process puts that state in (`WorkItemDetailsStore.newest`),
    /// which the engine guesses from its name; those it read in another state since, or no longer reads, as it read them. So
    /// too the parents My Work's Map shows.
    private func keepingStateChanges(_ read: WorkLinks) -> WorkLinks {
        guard !stateChanges.isEmpty else { return read }
        var read = read
        for (key, changed) in stateChanges {
            let linked = Self.show(changed, of: key, in: &read.workItems)
            let parent = Self.show(changed, of: key, in: &read.mapParents)
            if !linked && !parent { stateChanges[key] = nil }
        }
        return read
    }

    /// Shows a work item's state as BriefBar changed it, `changed`, over what's read of it among `items`, while what's read
    /// isn't newer: whether it does.
    private static func show(_ changed: WorkItem, of key: WorkItemKey, in items: inout [WorkItemKey: WorkItem]) -> Bool {
        guard let item = items[key], let newest = WorkItemDetailsStore.newest(changed, item), newest != item else { return false }
        items[key] = newest
        return true
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

    /// A dependency BriefBar just linked in Azure DevOps, or took away, from My Work's Map: it shows so at once, and the sprint
    /// is read again (`LinkEngine.changed`), which says so too once Azure DevOps does; in the demo, its made-up links change.
    func changed(_ dependency: WorkDependency, linked: Bool) {
        if linked { read.dependencies.insert(dependency) } else { read.dependencies.remove(dependency) }
        tellMap()
        guard store.mode == .live, let engine else { return }
        Task { await engine.changed(dependency, linked: linked) }
    }

    /// Reads the sprint's links again, as after a change to a dependency that Azure DevOps may have made though it didn't
    /// say (`LinkEngine.rereadSprint`); nothing in the demo.
    func rereadDependencies() {
        guard store.mode == .live, let engine else { return }
        Task { await engine.rereadSprint() }
    }

    /// A work item BriefBar changed the state of from My Work, or may have, as it didn't hear back (`StateChanges`): one Show
    /// Links read shows in its new state at once, as Azure DevOps answered, with the category the team's process puts it in,
    /// over what the engine read before, until it reads it in another state, and it reads it again now, as it does what a
    /// Copilot session said it changed (`reread`); in the demo, its made-up links change. So too a parent My Work's Map shows.
    /// Nothing for one Show Links doesn't read.
    func changedState(_ key: WorkItemKey, to changed: WorkItem?) {
        guard let item = linkedWorkItem(key) else { return }
        if let changed, let newest = WorkItemDetailsStore.newest(changed, item), newest != item {
            stateChanges[key] = newest
            _ = Self.show(newest, of: key, in: &read.workItems)
            _ = Self.show(newest, of: key, in: &read.mapParents)
            publish()
        }
        reread(pullRequests: [], workItems: [key])
    }

    /// What the engine was told to read last, while it reads.
    var engineInputs: LinkEngine.Inputs? {
        engine == nil ? nil : lastInputs
    }

    /// A linked pull request your lists don't show, as Show Links read it: for My Work, what a work item's pull request off
    /// your board is. Nil for one it hasn't read, or couldn't.
    func linkedPullRequest(_ key: PRKey) -> PullRequest? {
        read.pullRequests[key]
    }

    /// A linked work item the sprint doesn't show, as Show Links read it: for My Work's search, the type and title of one
    /// linked to a pull request of yours, as your task outside the sprint is with Show: Pull Requests; else a parent My Work's
    /// Map shows, as read for it. Of one read both ways, the newer read, as when it was read for the Map since its read with
    /// what stories want failed. Nil for one it hasn't read, or couldn't.
    func linkedWorkItem(_ key: WorkItemKey) -> WorkItem? {
        WorkItemDetailsStore.newest(read.workItems[key], read.mapParents[key])
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
        let lookups = Self.lookups(links.linked([.workItem, .pullRequest]).union(mapNames(listed: listed)), listed: listed)
        let wantsStories = order?.isOn == true
        return LinkEngine.Inputs(
            pullRequests: pullRequests,
            sprintItems: Set(sprintItems.map { WorkItemKey($0.organization, $0.id) }),
            sprintShows: sprint.isShowing,
            workItemLookups: lookups.workItems,
            pullRequestLookups: lookups.pullRequests,
            wantsStories: wantsStories,
            parentLookups: wantsStories ? storyFinder.parents(ofTasksIn: linkedToPullRequests) : [],
            mapParents: mapParentNames()
        )
    }

    /// The work items My Work's Map can show that aren't `listed`, while a window shows it on screen (`mapLookups`); none
    /// otherwise.
    private func mapNames(listed: Set<ItemRef>) -> Set<ItemRef> {
        guard myWorkIsOnScreen, let order, order.showsMyWork, order.myWorkView == .map else { return [] }
        let state = order.mapState
        let said = state.lines.keys.flatMap { [$0.before.ref, $0.after.ref] }.compactMap { $0 }.filter { $0.kind == .workItem }
        let linked = read.dependencies.flatMap { [$0.before.linkRef, $0.after.linkRef] }
        return Self.mapLookups(added: Array(state.items.keys), said: said, linked: linked, listed: listed)
    }

    /// The work items My Work's Map names that your lists and the sprint don't have, the first `most` of them: those you
    /// added, then those the lines you and sessions said name, then those the dependencies Azure DevOps links do, each in
    /// order of their IDs.
    static func mapLookups(
        added: [ItemRef], said: [ItemRef], linked: [ItemRef], listed: Set<ItemRef>, most: Int = mostMapLookups
    ) -> Set<ItemRef> {
        var seen = listed
        let named = added.sorted() + said.sorted() + linked.sorted()
        return Set(named.filter { seen.insert($0).inserted }.prefix(most))
    }

    /// At most how many work items the Map has read for it.
    static let mostMapLookups = 200

    /// The work items My Work's Map wants read with their parent, while a window shows it on screen with Parents on: climbing
    /// from the work items Show Links links to the pull requests on its board, as their cards stand for them, those you added
    /// to it and, while Show shows your work, those My Work has cards for, your work in the sprint, what's left and what's done
    /// (`SprintBoard.myWork`, `myDone`), and outside it, up their parents (`mapParentLookups`): not a story of yours whose tasks
    /// are all someone else's, which has none. Someone else's work adds none. None otherwise.
    private func mapParentNames() -> Set<WorkItemKey> {
        guard myWorkIsOnScreen, let order, order.showsMyWork, order.myWorkView == .map, order.mapShowsParents else { return [] }
        var start: Set<WorkItemKey> = []
        func add(_ ref: ItemRef) {
            if ref.kind == .workItem, let id = ref.number { start.insert(WorkItemKey(ref.scope, id)) }
        }
        for pullRequest in order.refsOnBoard(kinds: PullRequestsByMission.kinds) {
            links.connections(of: pullRequest).forEach { add($0.item.ref) }
        }
        if settings.myWorkShows.showsWork {
            let board = sprint.board
            if let board { start.formUnion((board.myWork + board.myDone).map(\.key)) }
            if sprint.showsOutside, let outside = sprint.outside?.without(board) { start.formUnion(outside.items.map(\.key)) }
        }
        order.mapState.items.keys.forEach(add)
        let known = knownParents()
        return Self.mapParentLookups(from: start, parents: known.parents, known: known.readElsewhere)
    }

    /// The work items to read with their parent for My Work's Map, the first `most` of them: climbing from `start` up the
    /// `parents` known, a level at a time, each level in order, those not read with their parent otherwise, `known`. One read
    /// for the Map already stays among them, so the engine keeps it, rather than forget it and read it again, over and over;
    /// with its parent, it climbs a level more.
    static func mapParentLookups(
        from start: Set<WorkItemKey>, parents: [WorkItemKey: WorkItemKey], known: Set<WorkItemKey>, most: Int = mostMapParents
    ) -> Set<WorkItemKey> {
        var wanted: Set<WorkItemKey> = []
        var seen: Set<WorkItemKey> = []
        var level = start.sorted()
        while !level.isEmpty {
            var next: [WorkItemKey] = []
            for key in level where seen.insert(key).inserted {
                if !known.contains(key) {
                    guard wanted.count < most else { return wanted }
                    wanted.insert(key)
                }
                if let parent = parents[key] { next.append(parent) }
            }
            level = next.sorted()
        }
        return wanted
    }

    /// At most how many work items the Map reads with their parent.
    static let mostMapParents = 200

    /// Each work item's parent, of those read with it: the linked ones read with what stories want, those read for My Work's
    /// Map, and the sprint's, which have the last word while something shows the sprint, as they're read the most often then.
    /// Once nothing does, the sprint is read no more: what was read of it comes first, for what's read since to have the last
    /// word, and the Map reads its work items itself. With the work items read with their parent other than for the Map,
    /// `readElsewhere`, which the Map needn't read.
    private func knownParents() -> (parents: [WorkItemKey: WorkItemKey], readElsewhere: Set<WorkItemKey>) {
        var parents: [WorkItemKey: WorkItemKey] = [:]
        var readElsewhere: Set<WorkItemKey> = []
        func put(_ item: WorkItem, elsewhere: Bool) {
            parents[item.key] = item.parentId.map { WorkItemKey(item.organization, $0) }
            if elsewhere { readElsewhere.insert(item.key) }
        }
        let sprintReads = sprint.isShowing
        if !sprintReads {
            for item in sprintItems { put(item, elsewhere: false) }
        }
        // Without stories, a linked work item is read without its parent; with them, one partly read may be too.
        let withParents = order?.isOn == true
        for item in read.workItems.values where item.parentId != nil || withParents && !read.partlyRead.contains(item.key) {
            put(item, elsewhere: true)
        }
        for item in read.mapParents.values { put(item, elsewhere: false) }
        if sprintReads {
            for item in sprintItems { put(item, elsewhere: true) }
        }
        return (parents, readElsewhere)
    }

    /// The work items linked to your pull requests, as read.
    private var linkedToPullRequests: Set<WorkItemKey> {
        Set(read.workItemsOfPullRequests.flatMap { key, ids in ids.map { WorkItemKey(key.organization, $0) } })
    }

    /// Which stories work items are for, from what's read of them: the sprint's, the linked ones' and their parents'; with no
    /// sprint, by the types your work outside it was read with, as My Work's cards take them; and a linked task read without
    /// its parent, for no story.
    private var storyFinder: WorkItemStories {
        WorkItemStories(
            workItems: sprintItems + Array(read.workItems.values) + Array(read.parents.values), board: sprint.board, outside: sprint.outside,
            partlyRead: read.partlyRead
        )
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
        var workItemsByPullRequest: [PRKey: [ItemRef]] = [:]
        var named: Set<WorkItemKey> = []
        for (key, ids) in read.workItemsOfPullRequests {
            // Until each of its work items is read, or Azure DevOps says it can't be, its stories aren't known: its mission
            // isn't named from half of what it's made of.
            guard !ids.contains(where: { read.pendingWorkItems.contains(WorkItemKey(key.organization, $0)) }) else { continue }
            let found = finder.stories(of: key, workItems: ids)
            let pullRequest = PRKey(key.organization.lowercased(), key.number)
            byPullRequest[pullRequest] = found
            workItemsByPullRequest[pullRequest] = Set(ids).sorted().map { ItemRef.workItem(organization: key.organization, id: $0) }
            for id in ids { named.insert(WorkItemKey(key.organization, id)) }
            for ref in found.flatMap({ [$0.ref, $0.task].compactMap { $0 } }) {
                if let id = ref.number { named.insert(WorkItemKey(ref.scope, id)) }
            }
        }
        // One whose work items couldn't be read: none known, rather than keep every story's mission unseen while it fails.
        for key in read.unreadablePullRequests where read.workItemsOfPullRequests[key] == nil {
            let pullRequest = PRKey(key.organization.lowercased(), key.number)
            byPullRequest[pullRequest] = []
            workItemsByPullRequest[pullRequest] = []
        }
        let stories = Stories(
            areRead: true, byPullRequest: byPullRequest, workItemsByPullRequest: workItemsByPullRequest,
            workItems: named.sorted().compactMap { known[$0] }
        )
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

    /// The sprint's work items, and while My Work shows their cards (+ All My Tasks), your open tasks and bugs outside it:
    /// whose pull requests Show Links reads, as the sprint shows, and which it tells as it tells the sprint's.
    private var sprintItems: [WorkItem] {
        let board = sprint.board?.items ?? []
        guard sprint.showsOutside, let outside = sprint.outside?.without(sprint.board) else { return board }
        return board + outside.items
    }

    // MARK: Telling Show Links

    /// Tells My Work's Map what Show Links read: the dependencies; and, while it reads, the work items' parents, the parents
    /// read for the Map, in the state BriefBar changed them to (`keepingStateChanges`), and the Related links.
    private func tellMap() {
        guard let dependencies else { return }
        let on = links.isOn
        dependencies.told(
            read.dependencies, parents: on ? knownParents().parents : [:], parentItems: on ? read.mapParents : [:],
            related: on ? read.related : []
        )
    }

    private func publish() {
        tellMap()
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
                textColor: item.rowTextColor, state: item.group.state(showToReview: showToReview), status: item.group.title,
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
                    symbol: "paperplane.fill", color: phase.color, textColor: phase.textColor, state: phase.state,
                    status: entry.sentence(now: nil),
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
            stateChanges = [:]
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
        let (status, color, textColor): (String, Color, Color) = switch pullRequest.status {
        case .active: (pullRequest.isDraft ? "Draft" : "Active", .blue, TextTint.blue.color)
        case .completed: ("Completed", Color(nsColor: .systemPurple), TextTint.purple.color)
        case .abandoned: ("Abandoned", .secondary, .secondary)
        case .other: ("Closed", .secondary, .secondary)
        }
        return LinkedItem(
            ref: .pullRequest(organization: pullRequest.key.organization, number: pullRequest.key.number),
            label: "!\(pullRequest.key.number)", title: pullRequest.title,
            symbol: pullRequest.status == .completed ? "arrow.triangle.merge" : "arrow.triangle.pull", color: color,
            textColor: textColor, status: status,
            place: pullRequest.repositoryName, hint: hint(pullRequest), date: pullRequest.closedAt ?? pullRequest.createdAt,
            open: { AzureDevOps.open(pullRequest.webURL) }, url: pullRequest.webURL
        )
    }

    /// A work item, with how many tasks it has in the sprint, for a story or a bug.
    static func item(_ workItem: WorkItem, tasks: Int = 0) -> LinkedItem {
        LinkedItem(
            ref: .workItem(organization: workItem.organization, id: workItem.id), label: String(workItem.id), title: workItem.title,
            symbol: workItem.typeSymbol, color: workItem.typeColor, textColor: WorkItem.typeTextColor(of: workItem.type),
            status: workItem.state, place: workItem.project,
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
