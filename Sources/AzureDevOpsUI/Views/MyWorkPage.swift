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
}

/// Your sprint work as My Work's Board takes it (`SprintWork`), from what BriefBar reads already: the sprint, Show Links'
/// links, your lists and the linked pull requests they don't have, and the tasks you sent to Copilot.
enum MyWorkFacts {
    /// What's known of an Azure DevOps pull request: as your lists have it, with whether it's yours, else as Show Links read
    /// it.
    typealias KnownPullRequest = (pullRequest: PullRequest, isYours: Bool)

    /// Your work items in the sprint that aren't done (`SprintBoard.myWork`), in its order, each with the story it's for,
    /// how far along it is, the pull requests Show Links links it to, and whether a task you sent to Copilot works on it.
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
        return board.myWork.map { item in
            let story: ItemRef? = if alone.contains(item.id) {
                item.linkRef
            } else if let parent = parents[item.id] {
                parent.linkRef
            } else {
                item.parentId.map { .workItem(organization: item.organization, id: $0) }
            }
            let progress: SprintWork.Progress = switch item.category {
            case .proposed: .toDo
            case .resolved: .resolved
            default: .inProgress
            }
            let pullRequests = linked(item.linkRef).filter(\.kind.isPullRequest).map { ref in
                LinkedPullRequest(ref: ref, state: state(of: ref, pullRequest: pullRequest))
            }
            return SprintWork(
                ref: item.linkRef, story: story, progress: progress, pullRequests: pullRequests, copilotWorks: copilotWorks(item)
            )
        }
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
    /// window, and with Lanes: None; with Pull Requests; and what + Sprint Tasks says while Show Links is off.
    static func renderings(
        services: AppServices, linkedPullRequest: @escaping (PRKey) -> PullRequest?, environment: (AnyView) -> AnyView
    ) -> [(name: String, view: AnyView)] {
        guard services.pullRequestOrder.isOn else { return [] }
        let shown: [(name: String, shows: MyWorkShows, lanes: BoardLanes, size: CGSize)] = [
            ("my-work-sprint-tasks", .sprintTasks, .missions, CGSize(width: 1_400, height: 2_050)),
            ("my-work-sprint-tasks-narrow", .sprintTasks, .missions, CGSize(width: 560, height: 2_250)),
            ("my-work-sprint-tasks-lanes-none", .sprintTasks, BoardLanes.none, CGSize(width: 1_400, height: 950)),
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

    /// What the Board shows: your pull requests, or your sprint work with them.
    private var shown: MyWorkShows {
        shows ?? settings.myWorkShows
    }

    /// The sprint's work goes on the Board: + Sprint Tasks, with Show Links on, which is how it goes with pull requests.
    private var showsWork: Bool {
        shown == .sprintTasks && links.isOn
    }

    /// The work item whose details show, rather than a pull request's.
    private var shownWorkItem: WorkItem? {
        guard let item = workItemDetails.selected, showsWorkItem || pullRequestDetails.selected == nil else { return nil }
        return item
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "My Work", subtitle: subtitle) {
                PageRefreshStatus(page: .pullRequests, withSprint: showsWork)
                SegmentedPicker("Show", selection: Binding(get: { shown }, set: { settings.myWorkShows = $0 }), segments: [
                    .init(MyWorkShows.pullRequests, title: "Pull Requests"),
                    .init(MyWorkShows.sprintTasks, title: "+ Sprint Tasks"),
                ])
                .fixedSize()
                .help("+ Sprint Tasks: your sprint work on the Board too, what hasn't started in To start. It needs Show Links.")
                BoardLanesPicker(order: ordering, shown: lanes)
            }
            // One split, whichever details show, so that the Board keeps its place as you click from one kind to the other.
            let workItem = shownWorkItem
            DetailsSplit(
                showsDetails: workItem != nil || pullRequestDetails.selected != nil,
                preferredWidth: workItem != nil ? $settings.sprintDetailsWidth : $settings.pullRequestDetailsWidth,
                listRoomGrowsWithText: true
            ) {
                content
            } details: {
                // A pull request's, or one linked to a work item's, shows its mission's lane here.
                Group {
                    if workItem != nil {
                        WorkItemDetailsPanel()
                    } else {
                        PullRequestDetailsPanel()
                    }
                }
                .environment(\.isOnMyWork, true)
            }
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
    /// while it shows it. Nil while Pull Request Order is off, as My Work is then.
    private var board: PullRequestBoard? {
        guard ordering.isOn else { return nil }
        let board = ordering.board(kinds: PullRequestsByMission.kinds, lanes: lanes ?? ordering.lanes)
        guard showsWork, let sprintBoard = sprint.board else { return board }
        return board.withWork(
            work(in: sprintBoard), missions: PullRequestsByMission.missions(ordering.missions),
            stories: sprintBoard.rows.compactMap(\.parent?.linkRef)
        )
    }

    /// Your sprint work, as Show Links links it to pull requests.
    private func work(in board: SprintBoard) -> [SprintWork] {
        MyWorkFacts.work(
            in: board, linked: { ref in links.connections(of: ref).map(\.item.ref) },
            pullRequest: { key in
                if let record = store.record(for: key) { return (record.pullRequest, record.role == .author) }
                return linkedPullRequest(key).map { ($0, !board.me.isEmpty && $0.author.id == board.me.lowercased()) }
            },
            copilotWorks: { item in copilot.isOn && copilot.working(on: item) != nil }
        )
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
                if shown == .sprintTasks {
                    sprintLines
                }
                if let board {
                    PullRequestsByMission(
                        view: .board, ordering: ordering, items: store.items, row: { _, _ in AnyView(EmptyView()) },
                        card: { item, card in boardCard(item, card, board: board) }, isSelected: isSelected, select: select,
                        shownOnTop: pullRequestDetails.shownOnTop, rest: { _ in AnyView(EmptyView()) }, board: board,
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

    /// A pull request's card, naming the work items of yours it's for while the Board shows your sprint work.
    private func boardCard(_ item: PRSnapshot, _ card: BoardCard, board: PullRequestBoard) -> BoardCardContent {
        let work = (board.workOfPullRequests[card.ref] ?? []).map { ref in
            sprintItem(ref).map { "\($0.type) \($0.id)" } ?? ref.shortOrderLabel
        }
        return PullRequestBoardCard.content(item, card, store: store, ordering: ordering, lanes: lanes ?? ordering.lanes, work: work) {
            select(item)
        }
    }

    // MARK: Your sprint work

    private var workContent: BoardWorkContent {
        BoardWorkContent(
            card: { task in sprintItem(task.ref).map { taskCard(task, item: $0) } },
            story: { ref in AnyView(storyHeader(ref)) },
            isSelected: { ref in shownWorkItem?.linkRef == ref },
            select: { ref in if let item = sprintItem(ref) { showDetails(of: item) } }
        )
    }

    /// A work item in the sprint.
    private func sprintItem(_ ref: ItemRef) -> WorkItem? {
        sprint.board?.rows.lazy.flatMap { ($0.parent.map { [$0] } ?? []) + $0.tasks }.first { $0.linkRef == ref }
    }

    /// A work item's card: its menu as on the Sprint page.
    private func taskCard(_ task: BoardTask, item: WorkItem) -> BoardCardContent {
        BoardCardContent(
            view: AnyView(MyWorkTaskCard(item: item, task: task)),
            menu: AnyView(Group {
                Button("Show Details") { showDetails(of: item) }
                Button("Open in Azure DevOps") { sprint.open(item) }
                CopilotSendMenuItems(item: item)
                LinkMenuItems(item.linkRef)
            }),
            label: "\(item.type) \(item.id) \(item.title)",
            details: [BoardText.why(task, state: item.state, type: item.type)]
        )
    }

    /// A story's lane's header, for a story with no mission: its type, title and number, which show its details.
    private func storyHeader(_ ref: ItemRef) -> some View {
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
                Text(verbatim: "\(story.type) \(story.id) · no pull requests on your board yet")
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

    /// What + Sprint Tasks needs, or what's in the way: Show Links, which puts work items with their pull requests; and the
    /// sprint, while it's read, when it can't be, above the cards read before, as on the Sprint page, or when there's none.
    @ViewBuilder
    private var sprintLines: some View {
        if !links.isOn {
            SprintTasksNeedShowLinks(links: links)
        } else if let problem = sprint.problem {
            ProblemView(problem: problem) { store.signIn(for: problem) }
        } else if sprint.board == nil {
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
        shownWorkItem == nil && pullRequestDetails.selected?.key == item.key
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

/// + Sprint Tasks while Show Links is off: BriefBar puts your sprint work with its pull requests only through their links,
/// never by their states, so it shows none of it until then. Turn On… shows its setting.
private struct SprintTasksNeedShowLinks: View {
    @ObservedObject var links: Links

    @LocalState private var showsSetting = false

    static let text = "Your sprint tasks show here with Show Links: BriefBar puts each with its pull requests only through their links."

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

/// A work item's card on My Work's Board: its type and number, its title, on two lines at most, why it's where it is, and
/// the task you sent to Copilot on it.
struct MyWorkTaskCard: View {
    let item: WorkItem
    let task: BoardTask

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
            // The send that works on it, which its why line names, else the latest.
            if copilot.isOn, let entry = copilot.working(on: item) ?? copilot.latest(for: item) {
                CopilotRunBadge(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
