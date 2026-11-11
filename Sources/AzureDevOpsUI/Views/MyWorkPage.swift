import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// What My Work's Board shows, with My Work Page on.
enum MyWorkShows: String, CaseIterable, Sendable {
    /// Your pull requests, as the Board did on the Pull Requests page.
    case pullRequests
    /// Your sprint work with them: + Sprint Tasks.
    case sprintTasks
    /// Your sprint work, and your open tasks and bugs outside the sprint, with them: + All My Tasks.
    case allTasks

    /// Whether it shows your work: the sprint's, and with + All My Tasks, yours outside it.
    var showsWork: Bool {
        self != .pullRequests
    }

    /// What it wants of your open tasks and bugs outside the sprint: how many there are, for + Sprint Tasks' line, or their
    /// cards too.
    var outside: OutsideWanted? {
        switch self {
        case .pullRequests: nil
        case .sprintTasks: .count
        case .allTasks: .cards
        }
    }
}

/// What My Work wants of your open tasks and bugs outside the sprint, which are read only while it wants either: how many
/// there are, for its line; or their cards too, which have Show Links read their pull requests.
enum OutsideWanted: Sendable {
    case count
    case cards
}

/// Your sprint work as My Work's Board takes it (`SprintWork`), from what BriefBar reads already: the sprint, Show Links'
/// links, your lists and the linked pull requests they don't have, the tasks you sent to Copilot, and the pipelines after your
/// merges; and, with + All My Tasks, your open tasks and bugs outside the sprint, as it reads them for My Work, the same way.
enum MyWorkFacts {
    /// What's known of an Azure DevOps pull request: as your lists have it, with whether it's yours, else as Show Links read
    /// it.
    typealias KnownPullRequest = (pullRequest: PullRequest, isYours: Bool)

    /// Your work items in the sprint, what's left (`SprintBoard.myWork`) then what's done (`SprintBoard.myDone`), each in its
    /// order, with the story it's for, how far along it is, the pull requests Show Links links it to, and whether a task you
    /// sent to Copilot works on it.
    /// - Parameters:
    ///   - linked: what Show Links links a work item to; nothing while it's off.
    ///   - pullRequest: what's known of an Azure DevOps pull request; nil for one BriefBar hasn't read, or couldn't.
    ///   - copilotWorks: whether a task you sent to Copilot works on a work item now.
    static func work(
        in board: SprintBoard, linked: (ItemRef) -> [ItemRef], pullRequest: (PRKey) -> KnownPullRequest?,
        copilotWorks: (WorkItem) -> Bool
    ) -> [SprintWork] {
        let alone = Set(board.rows.filter(\.tasks.isEmpty).compactMap(\.parent?.id))
        var parents: [Int: WorkItem] = [:]
        for row in board.rows {
            guard let parent = row.parent else { continue }
            for task in row.tasks where parents[task.id] == nil { parents[task.id] = parent }
        }
        return (board.myWork + board.myDone).map { item in
            let story: ItemRef? = if alone.contains(item.id) {
                item.linkRef
            } else if let parent = parents[item.id] {
                parent.linkRef
            } else {
                item.parentId.map { .workItem(organization: item.organization, id: $0) }
            }
            return work(item, story: story, linked: linked, pullRequest: pullRequest, copilotWorks: copilotWorks)
        }
    }

    /// Your open tasks and bugs outside the sprint (`OutsideWork`), in their order, as the sprint's: each with the story it's
    /// for, its parent for a task and itself for a bug, how far along it is, the pull requests Show Links links it to, and
    /// whether a task you sent to Copilot works on it.
    static func work(
        outside: OutsideWork, linked: (ItemRef) -> [ItemRef], pullRequest: (PRKey) -> KnownPullRequest?, copilotWorks: (WorkItem) -> Bool
    ) -> [SprintWork] {
        outside.items.map { item in
            work(item, story: outside.story(of: item), linked: linked, pullRequest: pullRequest, copilotWorks: copilotWorks)
        }
    }

    /// Your sprint work, then your work outside the sprint, for + All My Tasks: but for a story or bug of yours in the sprint
    /// with no tasks there, a card of its own, when tasks of yours under it are outside the sprint. As on the Sprint page,
    /// where a story with tasks is no card, the tasks are the work, and it's their lane's.
    static func work(sprint: [SprintWork], outside: [SprintWork]) -> [SprintWork] {
        let storiesOfTasks = Set(outside.compactMap { $0.story == $0.ref ? nil : $0.story })
        return sprint.filter { $0.story != $0.ref || !storiesOfTasks.contains($0.ref) } + outside
    }

    /// Where Show Them takes the Board: the first card of what the line counts, yours outside the sprint's iteration
    /// (`OutsideWork.notInSprint`), not one in it that its board doesn't have.
    static func card(of outside: OutsideWork, on board: PullRequestBoard) -> ItemRef? {
        card(of: Set(outside.notInSprint.map(\.linkRef)), on: board)
    }

    /// Where Show Them takes the Board: the first card of its own of your work outside the sprint, lanes from the top, columns
    /// from the left; else the first pull request's card that names one; nil with neither.
    static func card(of outside: Set<ItemRef>, on board: PullRequestBoard) -> ItemRef? {
        for lane in board.lanes {
            for column in board.columns {
                if let task = lane.tasks.first(where: { BoardColumn($0.column) == column && outside.contains($0.ref) }) {
                    return task.ref
                }
            }
        }
        let names = { (card: BoardCard) in !outside.isDisjoint(with: board.workOfPullRequests[card.ref] ?? []) }
        for lane in board.lanes {
            for column in board.columns {
                if let card = lane.cards(in: column).first(where: names) { return card.ref }
            }
        }
        return nil
    }

    /// One of your work items, for its story.
    private static func work(
        _ item: WorkItem, story: ItemRef?, linked: (ItemRef) -> [ItemRef], pullRequest: (PRKey) -> KnownPullRequest?,
        copilotWorks: (WorkItem) -> Bool
    ) -> SprintWork {
        let progress: SprintWork.Progress = switch item.category {
        case .proposed: .toDo
        case .resolved: .resolved
        case .completed: .completed
        case .inProgress, .removed: .inProgress
        }
        let pullRequests = linked(item.linkRef).filter(\.kind.isPullRequest).map { ref in
            LinkedPullRequest(ref: ref, state: state(of: ref, pullRequest: pullRequest))
        }
        return SprintWork(ref: item.linkRef, story: story, progress: progress, pullRequests: pullRequests, copilotWorks: copilotWorks(item))
    }

    /// What a linked pull request is, for a work item whose pull requests aren't on the board: one on GitHub, linked in
    /// BriefBar, counts as open, as BriefBar reads nothing more of it; one closed without merging as abandoned.
    static func state(of ref: ItemRef, pullRequest: (PRKey) -> KnownPullRequest?) -> LinkedPullRequest.State {
        guard ref.kind == .pullRequest else { return .open(author: nil) }
        guard let number = ref.number, let known = pullRequest(PRKey(ref.scope, number)) else { return .unknown }
        switch known.pullRequest.status {
        case .active: return .open(author: known.isYours ? nil : known.pullRequest.author.firstName)
        case .completed: return .merged
        case .abandoned, .other: return .abandoned
        }
    }

    /// Whether one of your merged pull requests is out, for Completed: BriefBar follows its pipelines after the merge no
    /// more, and none of them failed or waits, as they passed or one was canceled, which Done counts as finished too; or it
    /// follows none, with Follow Pipelines After You Merge off. While it follows them, it isn't: for half an hour after the
    /// merge until a run starts, while one runs or waits, a little while after the last one finished, as more may start
    /// (`MergeChain`); nor once one failed.
    /// - Parameter followsMerges: Follow Pipelines After You Merge is on.
    static func isOut(_ record: PRRecord?, followsMerges: Bool, now: Date) -> Bool {
        guard followsMerges, let record, record.pullRequest.status == .completed else { return true }
        if let merge = record.merge {
            if merge.isFollowing { return false }
            return merge.summary.map { $0.outcome == .passed || $0.outcome == .canceled } ?? true
        }
        // No run found yet: they're looked for a while after the merge.
        guard record.pullRequest.mergeCommit != nil, let mergedAt = record.pullRequest.closedAt else { return true }
        return !MergeChain.isFollowing(mergedAt: mergedAt, runs: [], at: now)
    }

    /// What keeps one of your merged pull requests in Merged, after "Merged" on its card: what its pipelines after the merge
    /// do while it isn't out, "Production waits for approval", "1 pipeline running", "No pipeline has started yet", "Its
    /// pipelines finished · more may start", but one that failed, whose mark says so; then the work items of yours it names
    /// that aren't done, "Task 5112 still open". Nil for none.
    /// - Parameter open: the work items of yours it names that aren't done, as its card names them: "Task 5112".
    static func held(_ record: PRRecord?, open: [String], followsMerges: Bool, now: Date) -> String? {
        var parts: [String] = []
        if let record, !isOut(record, followsMerges: followsMerges, now: now) {
            switch record.merge?.summary {
            case nil: parts.append("No pipeline has started yet")
            case let summary?:
                switch summary.outcome {
                case .waiting: parts.append("\(summary.stage ?? summary.pipeline ?? "A stage") waits for approval")
                case .running: parts.append(summary.running == 1 ? "1 pipeline running" : "\(summary.running) pipelines running")
                case .passed, .canceled: parts.append("Its pipelines finished · more may start")
                case .failed: break
                }
            }
        }
        if !open.isEmpty { parts.append(open.joined(separator: ", ") + " still open") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct OnMyWorkKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A pull request's details show on My Work, where its mission's name shows its lane on the Board, rather than By Mission
    /// on the Pull Requests page.
    var isOnMyWork: Bool {
        get { self[OnMyWorkKey.self] }
        set { self[OnMyWorkKey.self] = newValue }
    }
}

/// My Work, with My Work Page on: Up Next and the Board, which leave Azure DevOps' Pull Requests page for it, with your pull
/// requests and, with + Sprint Tasks, your sprint work. A click on a pull request's card shows its details beside the Board,
/// and on a work item's, the work item's, as on the Sprint page; over the Board in a narrow window.
struct MyWorkPage: View {
    /// A linked pull request your lists don't show, as Show Links read it.
    let linkedPullRequest: (PRKey) -> PullRequest?
    /// What it shows, for pictures; nil for what you chose.
    var shows: MyWorkShows? = nil
    /// The Board's lanes, for pictures; nil for those you chose.
    var lanes: BoardLanes? = nil

    @EnvironmentObject private var services: AppServices

    var body: some View {
        MyWorkContent(links: services.links, linkedPullRequest: linkedPullRequest, shows: shows, lanes: lanes)
    }
}

extension MyWorkPage {
    /// My Work's pictures, while Pull Request Order is on: with + Sprint Tasks, wide enough for every column, in a narrow
    /// window, and with Lanes: None; with + All My Tasks; with Pull Requests; and what + Sprint Tasks says while Show Links
    /// is off.
    static func renderings(
        services: AppServices, linkedPullRequest: @escaping (PRKey) -> PullRequest?, environment: (AnyView) -> AnyView
    ) -> [(name: String, view: AnyView)] {
        guard services.pullRequestOrder.isOn else { return [] }
        let shown: [(name: String, shows: MyWorkShows, lanes: BoardLanes, size: CGSize)] = [
            ("my-work-sprint-tasks", .sprintTasks, .missions, CGSize(width: 1_600, height: 2_050)),
            ("my-work-sprint-tasks-narrow", .sprintTasks, .missions, CGSize(width: 560, height: 2_250)),
            ("my-work-sprint-tasks-lanes-none", .sprintTasks, BoardLanes.none, CGSize(width: 1_600, height: 950)),
            ("my-work-all-tasks", .allTasks, .missions, CGSize(width: 1_600, height: 2_150)),
            ("my-work-pull-requests", .pullRequests, .missions, CGSize(width: 1_200, height: 1_250)),
        ]
        let showLinksOff = SprintTasksNeedShowLinks(links: Links(defaults: MemoryDefaults(), isDemo: false))
            .padding(16)
            .frame(width: 700, alignment: .leading)
            .background(WindowBackdrop())
            .environment(\.isRendering, true)
        let foot = (name: "my-work-show-links-off", view: environment(AnyView(showLinksOff)))
        return [foot] + shown.map { name, shows, lanes, size in
            let page = MyWorkPage(linkedPullRequest: linkedPullRequest, shows: shows, lanes: lanes)
                .environment(\.panelStyle, .page)
                .textSize(from: services)
                .frame(width: size.width, height: size.height)
                .background(WindowBackdrop())
                .environment(\.isRendering, true)
            return (name: name, view: environment(AnyView(page)))
        }
    }
}

/// Whose details show beside My Work's Board, a work item's or a pull request's, of those the source's stores hold, which its
/// other pages and windows show theirs in too: the work item's while you clicked one last here, or while no pull request's
/// show; else the pull request's. The Board marks the card of whichever show; and while they cover the Board, its ⌘→ and ⌘←
/// move only a pull request whose own details those are, never one the store holds behind a work item's details.
struct MyWorkDetails {
    /// The work item whose details show, rather than a pull request's.
    let workItem: WorkItem?
    /// The pull request whose details show, rather than a work item's.
    let pullRequest: PRSnapshot?
    /// The pull request whose own details show, with nothing over them, whose card the Board's keys move (`shownOnTop`).
    let pullRequestOnTop: ItemRef?

    /// - Parameter showsWorkItem: whether you clicked a work item's card last, rather than a pull request's.
    @MainActor
    init(workItem: WorkItem?, showsWorkItem: Bool, pullRequest details: PullRequestDetailsStore) {
        if let workItem, showsWorkItem || details.selected == nil {
            self.workItem = workItem
            pullRequest = nil
            pullRequestOnTop = nil
        } else {
            self.workItem = nil
            pullRequest = details.selected
            pullRequestOnTop = details.shownOnTop
        }
    }

    var showsAny: Bool {
        workItem != nil || pullRequest != nil
    }
}

/// My Work's page, as Show Links links your sprint work to your pull requests.
private struct MyWorkContent: View {
    @ObservedObject var links: Links
    let linkedPullRequest: (PRKey) -> PullRequest?
    let shows: MyWorkShows?
    let lanes: BoardLanes?

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sprint: SprintStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var workItemDetails: WorkItemDetailsStore
    @EnvironmentObject private var pullRequestDetails: PullRequestDetailsStore
    @EnvironmentObject private var ordering: PullRequestOrder

    /// The work item's details show rather than a pull request's: you clicked a work item's card last.
    @LocalState private var showsWorkItem = false

    /// What the Board shows: your pull requests, or your sprint work with them, and your work outside the sprint too.
    private var shown: MyWorkShows {
        shows ?? settings.myWorkShows
    }

    /// The sprint's work goes on the Board: + Sprint Tasks or + All My Tasks, with Show Links on, which is how it goes with
    /// pull requests.
    private var showsWork: Bool {
        shown.showsWork && links.isOn
    }

    /// Your open tasks and bugs outside the sprint, as last read, without what the sprint's board has now: on the Board with
    /// + All My Tasks, and counted by the line under the header with + Sprint Tasks too. Nil while it shows neither.
    private var outside: OutsideWork? {
        guard showsWork else { return nil }
        return sprint.outside?.without(sprint.board)
    }

    /// Whose details show, a work item's or a pull request's.
    private var shownDetails: MyWorkDetails {
        MyWorkDetails(workItem: workItemDetails.selected, showsWorkItem: showsWorkItem, pullRequest: pullRequestDetails)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "My Work", subtitle: subtitle) {
                PageRefreshStatus(page: .pullRequests, withSprint: showsWork)
                BoardLanesPicker(order: ordering, shown: lanes)
            }
            showPicker
            // One split, whichever details show, so that the Board keeps its place as you click from one kind to the other.
            let detailsShown = shownDetails
            DetailsSplit(
                showsDetails: detailsShown.showsAny,
                preferredWidth: detailsShown.workItem != nil ? $settings.sprintDetailsWidth : $settings.pullRequestDetailsWidth,
                listRoomGrowsWithText: true
            ) {
                content
            } details: {
                // A pull request's, or one linked to a work item's, shows its mission's lane here.
                Group {
                    if detailsShown.workItem != nil {
                        WorkItemDetailsPanel()
                    } else {
                        PullRequestDetailsPanel()
                    }
                }
                .environment(\.isOnMyWork, true)
            }
        }
    }

    /// What the Board shows, on a row of its own under the header: in the header, its three choices, which have no symbols
    /// to shrink to, took the title's and the subtitle's room in a narrow window. Where the row is too narrow for its label,
    /// as in the narrowest window with larger text, it goes without, then with a smaller control, which keeps every word.
    private var showPicker: some View {
        ViewThatFits(in: .horizontal) {
            showRow(label: true)
            showRow(label: false)
            showRow(label: false).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 18)
        .padding(.trailing, 24)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    /// Show's control, after its label or not.
    private func showRow(label: Bool) -> some View {
        HStack(spacing: 6) {
            if label {
                Text("Show")
                    .font(size: 12)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            SegmentedPicker("Show", selection: Binding(get: { shown }, set: { settings.myWorkShows = $0 }), segments: [
                .init(MyWorkShows.pullRequests, title: "Pull Requests"),
                .init(MyWorkShows.sprintTasks, title: "+ Sprint Tasks"),
                .init(MyWorkShows.allTasks, title: "+ All My Tasks"),
            ])
            .fixedSize()
            .help(MyWorkText.showHelp)
        }
    }

    private var subtitle: String {
        let counts = store.counts
        var parts = [PRGroup.needsYou, .failing, .ready, .toReview].filter { counts[$0] > 0 }.map { "\(counts[$0]) \($0.countLabel)" }
        if showsWork, let board = sprint.board {
            let left = board.myWork.count
            parts.append(left == 0 ? "Nothing of yours left in \(board.sprint.name)" : "\(left) of yours left in \(board.sprint.name)")
        }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return store.hasLoaded ? "Nothing needs you" : "Your pull requests by stage, and what's next"
    }

    // MARK: The Board

    /// The Board, Up Next and each mission's next steps, worked out once each time the page draws, with your sprint work
    /// while it shows it, and your work outside the sprint with + All My Tasks, after the sprint's, even with no sprint
    /// going on. Nil while Pull Request Order is off, as My Work is then.
    private var board: PullRequestBoard? {
        board(showing: shown)
    }

    /// The Board as a choice of Show's has it.
    private func board(showing shown: MyWorkShows) -> PullRequestBoard? {
        guard ordering.isOn else { return nil }
        let board = ordering.board(kinds: PullRequestsByMission.kinds, lanes: lanes ?? ordering.lanes)
        guard shown.showsWork, links.isOn else { return board }
        let sprintBoard = sprint.board
        let outside = shown == .allTasks ? self.outside : nil
        guard sprintBoard != nil || outside?.items.isEmpty == false else { return board }
        let follows = settings.followMerges, now = store.now
        return board.withWork(
            work(in: sprintBoard, outside: outside), missions: PullRequestsByMission.missions(ordering.missions),
            stories: sprintBoard?.rows.compactMap(\.parent?.linkRef) ?? [],
            isOut: { ref in MyWorkFacts.isOut(record(of: ref), followsMerges: follows, now: now) }
        )
    }

    /// One of the list's pull requests, as the engine read it.
    private func record(of ref: ItemRef) -> PRRecord? {
        ref.number.flatMap { store.record(for: PRKey(ref.scope, $0)) }
    }

    /// Your sprint work, then your work outside it, as Show Links links them to pull requests.
    private func work(in board: SprintBoard?, outside: OutsideWork?) -> [SprintWork] {
        let me = board?.me ?? ""
        let linked = { (ref: ItemRef) in links.connections(of: ref).map(\.item.ref) }
        let pullRequest = { (key: PRKey) -> MyWorkFacts.KnownPullRequest? in
            if let record = store.record(for: key) { return (record.pullRequest, record.role == .author) }
            return linkedPullRequest(key).map { ($0, !me.isEmpty && $0.author.id == me.lowercased()) }
        }
        let copilotWorks = { (item: WorkItem) in copilot.isOn && copilot.working(on: item) != nil }
        let sprintWork = board.map { MyWorkFacts.work(in: $0, linked: linked, pullRequest: pullRequest, copilotWorks: copilotWorks) } ?? []
        let outsideWork = outside.map {
            MyWorkFacts.work(outside: $0, linked: linked, pullRequest: pullRequest, copilotWorks: copilotWorks)
        } ?? []
        return MyWorkFacts.work(sprint: sprintWork, outside: outsideWork)
    }

    private var content: some View {
        let board = self.board
        return PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                notices
                if let board, store.hasLoaded, !store.items.isEmpty {
                    // "2 more ›" scrolls the Board here to its column.
                    UpNextView(upNext: board.upNext, order: ordering, select: showDetails(of:)) { stage in
                        ordering.revealedColumn = stage
                    }
                }
                if shown.showsWork {
                    workLines
                }
                if let board {
                    PullRequestsByMission(
                        view: .board, ordering: ordering, items: store.items, row: { _, _ in AnyView(EmptyView()) },
                        card: { item, card in boardCard(item, card, board: board) }, isSelected: isSelected, select: select,
                        shownOnTop: shownDetails.pullRequestOnTop, rest: { _ in AnyView(EmptyView()) }, board: board,
                        showByStatus: {
                            settings.pullRequestOrder = .status
                            services.openWindow(.azureDevOpsPullRequests)
                        },
                        now: store.now, work: showsWork ? workContent : nil, saysStoriesNeedShowLinks: shown == .pullRequests
                    )
                }
            }
        }
    }

    /// A pull request's card, naming the work items of yours it's for while the Board shows your sprint work; in Merged then,
    /// what keeps it there.
    private func boardCard(_ item: PRSnapshot, _ card: BoardCard, board: PullRequestBoard) -> BoardCardContent {
        let items = (board.workOfPullRequests[card.ref] ?? []).map { ref in (ref: ref, item: workItem(ref)) }
        let work = items.map { named in
            named.item.map { MyWorkText.mention($0, place: outside?.place(of: $0)) } ?? named.ref.shortOrderLabel
        }
        var held: String?
        if board.showsWork, card.stage == .merged, !board.completed.contains(card.ref) {
            let open = zip(items, work).filter { named, _ in named.item?.isDone != true }.map { _, name in name }
            held = MyWorkFacts.held(store.record(for: item.key), open: open, followsMerges: settings.followMerges, now: store.now)
        }
        return PullRequestBoardCard.content(
            item, card, store: store, ordering: ordering, lanes: lanes ?? ordering.lanes, work: work, held: held
        ) {
            select(item)
        }
    }

    // MARK: Your sprint work

    private var workContent: BoardWorkContent {
        BoardWorkContent(
            card: { task in workItem(task.ref).map { taskCard(task, item: $0) } },
            story: { ref, isFinished in AnyView(storyHeader(ref, isFinished: isFinished)) },
            isSelected: { ref in shownDetails.workItem?.linkRef == ref },
            select: { ref in if let item = workItem(ref) { showDetails(of: item) } }
        )
    }

    /// A work item in the sprint.
    private func sprintItem(_ ref: ItemRef) -> WorkItem? {
        sprint.board?.rows.lazy.flatMap { ($0.parent.map { [$0] } ?? []) + $0.tasks }.first { $0.linkRef == ref }
    }

    /// A work item in the sprint, or one of yours outside it while it shows them.
    private func workItem(_ ref: ItemRef) -> WorkItem? {
        sprintItem(ref) ?? outside?.items.first { $0.linkRef == ref }
    }

    /// A work item's card: its menu as on the Sprint page. One outside the sprint says where it is.
    private func taskCard(_ task: BoardTask, item: WorkItem) -> BoardCardContent {
        let place = outside?.place(of: item)
        return BoardCardContent(
            view: AnyView(MyWorkTaskCard(item: item, task: task, place: place)),
            menu: AnyView(Group {
                Button("Show Details") { showDetails(of: item) }
                Button("Open in Azure DevOps") { sprint.open(item) }
                CopilotSendMenuItems(item: item)
                LinkMenuItems(item.linkRef)
            }),
            label: "\(item.type) \(item.id) \(item.title)",
            details: [BoardText.why(task, state: item.state, type: item.type)] + (place.map { [$0] } ?? [])
        )
    }

    /// A story's lane's header, for a story with no mission: its type, title and number, which show its details, and, until
    /// its work is all resolved or done (`BoardLane.isFinishedStory`), that its pull requests aren't on your board yet.
    private func storyHeader(_ ref: ItemRef, isFinished: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let story = sprintItem(ref) {
                TypeBadge(item: story, size: 18)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                Button { showDetails(of: story) } label: {
                    Text(story.title)
                        .font(size: 15, weight: .semibold)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("Show its details")
                .accessibilityAddTraits(.isHeader)
                Text(verbatim: "\(story.type) \(story.id)" + (isFinished ? "" : " · no pull requests on your board yet"))
                    .font(size: 12)
                    .foregroundStyle(.secondary)
            } else {
                Text(ref.shortOrderLabel)
                    .font(size: 15, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.horizontal, 4)
    }

    /// What + Sprint Tasks and + All My Tasks need, or what's in the way: Show Links, which puts work items with their pull
    /// requests; and the sprint, while it's read, when it can't be, above the cards read before, as on the Sprint page, or
    /// when there's none. Then how many of your tasks and bugs aren't in the sprint: under the sprint's problem too, and with
    /// no sprint going on, once they've been looked for, as they are for a team you chose.
    @ViewBuilder
    private var workLines: some View {
        if !links.isOn {
            SprintTasksNeedShowLinks(links: links)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let problem = sprint.problem {
                    ProblemView(problem: problem) { store.signIn(for: problem) }
                } else if sprint.board == nil {
                    noSprintLine
                }
                if let board = sprint.board {
                    outsideLine(sprint: board.sprint.name)
                } else if let outside, outside.readAt != nil || outside.problem != nil {
                    outsideLine(sprint: nil)
                }
            }
        }
    }

    /// While the sprint is read, or when there's none.
    private var noSprintLine: some View {
        HStack(spacing: 8) {
            if sprint.isRefreshing || !sprint.hasLoaded {
                ProgressView().controlSize(.small)
                Text("Reading your sprint…")
            } else {
                Image(systemName: "calendar.badge.exclamationmark")
                Text(sprint.teams.isEmpty
                    ? "No sprint to show: you're not on a team in the organizations BriefBar watches."
                    : "No sprint to show: this team has none with today's date. Choose another on the Sprint page.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(size: 12)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    /// How many of your tasks and bugs aren't in the sprint, or are open with none going on.
    private func outsideLine(sprint name: String?) -> some View {
        OutsideSprintLine(outside: outside, sprint: name, showsThem: shown == .allTasks) {
            showOutside()
        }
    }

    /// Show Them: + All My Tasks, with the Board at the first of them, which takes the keyboard's focus, its column opened for
    /// the moment where it's folded.
    private func showOutside() {
        let card = outside.flatMap { outside in board(showing: .allTasks).flatMap { MyWorkFacts.card(of: outside, on: $0) } }
        settings.myWorkShows = .allTasks
        if let card { ordering.revealedCard = card }
    }

    // MARK: Selection

    /// Shows a pull request's details from Up Next, which shows only those the list has.
    private func showDetails(of ref: ItemRef) {
        if let item = store.items.first(where: { $0.key.linkRef == ref }) { select(item) }
    }

    /// Shows a pull request's details, in place of a work item's.
    private func select(_ item: PRSnapshot) {
        withAnimation(.easeOut(duration: 0.2)) {
            showsWorkItem = false
            workItemDetails.close()
            pullRequestDetails.show(item)
        }
    }

    /// Shows a work item's details, in place of a pull request's.
    private func showDetails(of item: WorkItem) {
        withAnimation(.easeOut(duration: 0.2)) {
            showsWorkItem = true
            pullRequestDetails.close()
            workItemDetails.show(item)
        }
    }

    private func isSelected(_ item: PRSnapshot) -> Bool {
        shownDetails.pullRequest?.key == item.key
    }

    @ViewBuilder
    private var notices: some View {
        if let problem = store.problem {
            ProblemView(problem: problem) { store.signIn() }
        }
        if store.mode == .live && settings.organizations.isEmpty && store.items.isEmpty {
            OrganizationsPlaceholder()
        } else if store.isLoading && store.problem == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your pull requests…")
                    .font(style: .body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }
}

/// + Sprint Tasks or + All My Tasks while Show Links is off: BriefBar puts your work with its pull requests only through
/// their links, never by their states, so it shows none of it until then. Turn On… shows its setting.
private struct SprintTasksNeedShowLinks: View {
    @ObservedObject var links: Links

    @LocalState private var showsSetting = false

    static let text = "Your tasks show here with Show Links: BriefBar puts each with its pull requests only through their links."

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On…") { showsSetting = true }
                .buttonStyle(.borderless)
                .popover(isPresented: $showsSetting, arrowEdge: .bottom) {
                    LinksSetting(links: links, isBrief: true)
                        .padding(16)
                        .frame(width: 320)
                }
        }
        .font(size: 12)
        .padding(.horizontal, 4)
    }
}

/// How many of your open tasks and bugs aren't in the sprint, under My Work's header with + Sprint Tasks or + All My Tasks, so
/// that one left in an older sprint, or in none, is noticed: with + Sprint Tasks, Show Them shows them, with + All My Tasks,
/// whose cards say where each is. With no sprint going on, how many are open. While they're read for the first time, it says
/// so; when they can't be, why.
private struct OutsideSprintLine: View {
    let outside: OutsideWork?
    /// The sprint's name; nil with none going on.
    let sprint: String?
    /// + All My Tasks shows them on the Board.
    let showsThem: Bool
    /// Shows them: + All My Tasks, with the Board at the first of them.
    let show: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let outside, let problem = outside.problem {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(MyWorkText.outsideProblem(problem, sprint: sprint))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let outside, outside.readAt != nil {
                Image(systemName: outside.count == 0 ? "checkmark.circle" : "calendar")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(MyWorkText.outside(
                    tasks: outside.count - outside.bugCount, bugs: outside.bugCount, sprint: sprint, partial: outside.isPartial
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if !showsThem, outside.count > 0 {
                    Button("Show Them", action: show)
                        .buttonStyle(.borderless)
                        .help("Show them on the Board: + All My Tasks")
                        .accessibilityHint("Shows them on the Board: + All My Tasks")
                }
            } else {
                ProgressView().controlSize(.small)
                Text(MyWorkText.lookingOutside(sprint: sprint))
                    .foregroundStyle(.secondary)
            }
        }
        .font(size: 12)
        .padding(.horizontal, 4)
    }
}

/// What My Work says of your work outside the sprint.
enum MyWorkText {
    /// Show's tooltip.
    static let showHelp = "+ Sprint Tasks: your sprint work on the Board too, what hasn't started in To start. + All My Tasks: your "
        + "open tasks and bugs outside the sprint too, each saying where it is. They need Show Links."

    /// How many of your open tasks and bugs aren't in the sprint, by their types: "5 tasks and 1 bug of yours aren't in Sprint
    /// 42.", "1 task of yours isn't in Sprint 42.", "All your open tasks and bugs are in Sprint 42."; with no sprint going on
    /// (nil), how many are open: "5 tasks and 1 bug of yours are open.", "You have no open tasks or bugs."; "At least" before a
    /// count when Azure DevOps listed only some of what's assigned to you.
    static func outside(tasks: Int, bugs: Int, sprint: String?, partial: Bool) -> String {
        guard tasks + bugs > 0 else {
            if partial {
                let found = sprint.map { "is outside \($0)" } ?? "is an open task or bug"
                return "None of the work items Azure DevOps listed as yours \(found): it lists 500 at most."
            }
            return sprint.map { "All your open tasks and bugs are in \($0)." } ?? "You have no open tasks or bugs."
        }
        let counts = [(tasks, "task", "tasks"), (bugs, "bug", "bugs")].filter { $0.0 > 0 }.map { count, one, many in
            "\(count) \(count == 1 ? one : many)"
        }
        let one = tasks + bugs == 1
        let verb = if let sprint { "\(one ? "isn't" : "aren't") in \(sprint)" } else { one ? "is open" : "are open" }
        return "\(partial ? "At least " : "")\(counts.joined(separator: " and ")) of yours \(verb)."
    }

    /// A work item of yours on a pull request's card: "Task 5112"; with where it is, for one outside the sprint, "Task 5181
    /// (Sprint 41)" or "Task 4870 (no sprint)".
    static func mention(_ item: WorkItem, place: String?) -> String {
        let name = "\(item.type) \(item.id)"
        guard let place else { return name }
        return "\(name) (\(place == OutsideWork.noSprint ? "no sprint" : place))"
    }

    /// While your work outside the sprint is read for the first time: "Looking for your tasks and bugs outside Sprint 42…".
    static func lookingOutside(sprint: String?) -> String {
        sprint.map { "Looking for your tasks and bugs outside \($0)…" } ?? "Looking for your open tasks and bugs…"
    }

    /// Why your work outside the sprint couldn't be read: "Couldn't look for your tasks and bugs outside Sprint 42. Azure
    /// DevOps answered with HTTP 500."
    static func outsideProblem(_ problem: String, sprint: String?) -> String {
        let what = sprint.map { "your tasks and bugs outside \($0)" } ?? "your open tasks and bugs"
        return "Couldn't look for \(what). \(problem)"
    }
}

/// A work item's card on My Work's Board: its type and number, its title, on two lines at most, why it's where it is, where it
/// is when it's outside the sprint, and the task you sent to Copilot on it.
struct MyWorkTaskCard: View {
    let item: WorkItem
    let task: BoardTask
    /// Its iteration, such as "Sprint 38", or "No sprint", for one of yours outside the sprint (`OutsideWork.place`).
    var place: String? = nil

    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: item.typeSymbol)
                    .foregroundStyle(item.typeColor)
                Text(verbatim: "\(item.type) \(item.id)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(size: 11.5, weight: .semibold)
            Text(item.title)
                .font(size: 13, weight: .semibold)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Text(BoardText.why(task, state: item.state, type: item.type))
                .font(size: 11.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let place {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "calendar")
                    Text(place)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(size: 11.5)
                .foregroundStyle(.secondary)
            }
            // The send that works on it, which its why line names, else the latest.
            if copilot.isOn, let entry = copilot.working(on: item) ?? copilot.latest(for: item) {
                CopilotRunBadge(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
