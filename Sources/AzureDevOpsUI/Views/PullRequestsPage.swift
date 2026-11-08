import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The Pull Requests section's page in a window: the popover's groups, each in a card, with room for every detail; or, by
/// date, every open pull request in one; or, with Pull Request Order on, By Mission. A click on one shows its details beside
/// the list, as wide as you drag them, or over it when the window is narrow.
struct PullRequestsPage: View {
    /// The order to list them in, for pictures; nil for the one you chose.
    var order: PROrder? = nil
    /// By Mission's view, for pictures; nil for the one you chose.
    var view: OrderView? = nil
    /// The Board's lanes, for pictures; nil for those you chose.
    var lanes: BoardLanes? = nil

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var details: PullRequestDetailsStore
    @EnvironmentObject private var ordering: PullRequestOrder
    @Environment(\.interfaceOptions) private var options

    @LocalState private var showIdle = false

    private static let shownGroups: [PRGroup] = [.needsYou, .answered, .failing, .ready, .toReview, .waiting, .done]

    /// By Mission's views on this page: List, Map and the Board.
    private static let views = OrderView.offered(for: PullRequestsByMission.kinds)

    /// By Mission only while Pull Request Order is on: by status otherwise.
    private var shownOrder: PROrder {
        let chosen = order ?? settings.pullRequestOrder
        return chosen == .byMission && !ordering.isOn ? .status : chosen
    }

    /// By Mission's view, as you chose it, or a picture's.
    private var shownView: OrderView {
        view ?? ordering.view(offering: Self.views)
    }

    /// It shows the Board.
    private var showsBoard: Bool {
        shownOrder == .byMission && shownView == .board
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Pull Requests", subtitle: subtitle) {
                PageRefreshStatus(page: .pullRequests)
                PullRequestOrderMenu(order: shownOrder, showsTitle: true, offersByMission: ordering.isOn)
                    .menuStyle(.button)
                    .glassButtonStyle()
                    .fixedSize()
                if shownOrder == .byMission {
                    OrderViewPicker(order: ordering, views: Self.views, shown: view)
                }
                if showsBoard {
                    BoardLanesPicker(order: ordering, shown: lanes)
                }
                Button {
                    store.openPullRequestsPage()
                } label: {
                    ControlLabel("Open in Azure DevOps", systemImage: "arrow.up.forward.app")
                }
                .glassButtonStyle()
                .help("Open in Azure DevOps")
            }
            DetailsSplit(
                showsDetails: details.selected != nil, preferredWidth: $settings.pullRequestDetailsWidth, listRoomGrowsWithText: true
            ) {
                list
            } details: {
                PullRequestDetailsPanel()
            }
        }
    }

    /// The Board, Up Next and each mission's next steps, worked out once each time the page draws: a lane for each mission,
    /// or, on the Board, as you chose its lanes. Nil while Pull Request Order is off.
    private var board: PullRequestBoard? {
        guard ordering.isOn else { return nil }
        return ordering.board(kinds: PullRequestsByMission.kinds, lanes: showsBoard ? lanes ?? ordering.lanes : .missions)
    }

    private var list: some View {
        let board = self.board
        return PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                notices
                // By Mission has no group to put a compact brief in: it shows above the missions.
                if store.showsBrief, !options.compactBriefs || shownOrder == .byMission {
                    BriefView()
                        .padding(.horizontal, -4)
                }
                // What's next, in every order: it changes no group or count.
                if let board, store.hasLoaded, !store.items.isEmpty {
                    UpNextView(upNext: board.upNext, order: ordering, select: showDetails(of:)) { stage in
                        Self.showColumn(stage, settings: settings, ordering: ordering)
                    }
                }
                if shownOrder == .byMission {
                    PullRequestsByMission(
                        view: shownView, ordering: ordering, items: store.items, row: { AnyView(row($0, order: $1)) },
                        card: boardCard, isSelected: isSelected, select: select, shownOnTop: details.shownOnTop,
                        rest: { AnyView(groups($0, showsBrief: false)) }, board: board,
                        showByStatus: { settings.pullRequestOrder = .status }, now: store.now
                    )
                } else {
                    // What you changed last of a mission, from a row's Mission menu: By Status has no mission's card to say it.
                    if ordering.isOn, !ordering.said.isEmpty {
                        OrderUndoLine(order: ordering)
                            .padding(.horizontal, 4)
                    }
                    if shownOrder.isByDate {
                        byDate
                    } else {
                        groups(store.items)
                    }
                }
                // The Board has your own idle ones among its cards, and counts the rest.
                if !showsBoard {
                    idle
                }
            }
        }
    }

    /// Shows a pull request's details from Up Next, which shows only those the list has.
    private func showDetails(of ref: ItemRef) {
        if let item = store.items.first(where: { $0.key.linkRef == ref }) { select(item) }
    }

    /// Up Next's "2 more ›", from any order: By Mission's Board, at that column, which the page scrolls to.
    static func showColumn(_ stage: PullRequestStage, settings: AppSettings, ordering: PullRequestOrder) {
        settings.pullRequestOrder = .byMission
        ordering.revealColumn(stage)
    }

    /// A pull request's card on the Board: what it shows, its menu as its row's, and what VoiceOver says of it. With a lane
    /// for every card, Undo shows at the top.
    private func boardCard(_ item: PRSnapshot, _ card: BoardCard) -> BoardCardContent {
        let order = card.step.map {
            OrderRowContext(step: $0, mission: card.mission, isReady: item.group == .ready, names: ordering.names)
        }
        let mission = missionMenu(item, in: card.mission, undo: .onBoard(lanes ?? ordering.lanes))
        return BoardCardContent(
            view: AnyView(PullRequestBoardCard(item: item, card: card, order: order, ordering: ordering, now: store.now)),
            menu: AnyView(Group {
                Button("Show Details") { select(item) }
                Button("Open in Azure DevOps") { store.open(item) }
                PullRequestMenuItems(
                    item: item, openSource: source(item), dismiss: dismissing(item), stopWatching: watching(item),
                    mission: mission, ordering: ordering
                )
            }),
            label: "!\(item.key.number) \(item.title)",
            details: PullRequestBoardCard.details(item, reading: card.reading, order: order, ordering: ordering),
            mission: mission
        )
    }

    /// The groups, each in a card: every pull request By Status, or those in no mission By Mission.
    /// - Parameter showsBrief: a compact brief goes after the first, unless the page shows it already.
    private func groups(_ items: [PRSnapshot], showsBrief: Bool = true) -> some View {
        let shown = Self.shownGroups.filter { group in items.contains { $0.group == group } }
        return ForEach(shown, id: \.self) { group in
            section(group, items.filter { $0.group == group })
            if showsBrief, options.compactBriefs, store.showsBrief, group == shown.first {
                BriefView().padding(.horizontal, -4)
            }
        }
    }

    /// Where a pull request stands in its mission, for its capsule, while Pull Request Order is on: from another list, a
    /// click on it shows the mission By Mission.
    private func rowOrder(_ item: PRSnapshot) -> OrderRowContext? {
        guard ordering.isOn else { return nil }
        let byMission = shownOrder == .byMission
        let open: ((MissionKey) -> Void)? = byMission ? nil : { key in
            settings.pullRequestOrder = .byMission
            ordering.reveal(key, kinds: PullRequestsByMission.kinds)
        }
        return OrderRowContext.of(item.key.linkRef, in: ordering.missions, isReady: item.group == .ready, open: open, names: ordering.names)
    }

    /// A row's Mission menu, while Pull Request Order is on: from the mission whose card it's in, By Mission.
    /// - Parameter undo: where its Undo shows; nil for where the page's list shows it.
    private func missionMenu(_ item: PRSnapshot, in mission: MissionKey? = nil, undo: MissionMenuContext.UndoPlace? = nil)
        -> MissionMenuContext? {
        MissionMenuContext.of(
            item.key.linkRef, order: ordering, mission: mission, undo: undo ?? (shownOrder == .byMission ? .byMission : .top)
        )
    }

    /// Shows a pull request's details, which sees it, as opening it does.
    private func select(_ item: PRSnapshot) {
        withAnimation(.easeOut(duration: 0.2)) { details.show(item) }
    }

    private func isSelected(_ item: PRSnapshot) -> Bool {
        details.selected?.key == item.key
    }

    private var subtitle: String {
        let counts = store.counts
        let parts = [PRGroup.needsYou, .failing, .ready, .toReview].filter { counts[$0] > 0 }.map { "\(counts[$0]) \($0.countLabel)" }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return store.hasLoaded ? "Nothing needs you" : "Your pull requests, and the ones you review"
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
        } else if store.hasLoaded && store.activeItems.isEmpty && store.problem == nil {
            QuietView(idleCount: store.counts.idle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    private func section(_ group: PRGroup, _ items: [PRSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                    .foregroundStyle(group.color)
                Text(group.title)
                    .foregroundStyle(.primary)
                Text("\(items.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if group == .done || group == .needsYou && items.contains(where: \.hasNews) {
                    Button(group == .needsYou ? "Mark as Seen" : "Clear") { store.clear(group) }
                        .buttonStyle(.borderless)
                        .font(size: 11)
                        .help(group == .needsYou ? MenuPanelView.markAsSeenHelp : "Remove these from the list")
                }
            }
            .font(size: 12, weight: .semibold)
            .padding(.horizontal, 4)
            card(items)
        }
    }

    /// Every open pull request in one card, by when each was created, each saying where it stands; then Done's.
    @ViewBuilder
    private var byDate: some View {
        let listed = store.dateList(shownOrder)
        if !listed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                    Text(shownOrder.title)
                        .foregroundStyle(.primary)
                    Text("\(listed.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if listed.contains(where: { $0.group == .needsYou && $0.hasNews }) {
                        Button("Mark as Seen") { store.clear(.needsYou) }
                            .buttonStyle(.borderless)
                            .font(size: 11)
                            .help(MenuPanelView.markAsSeenHelp)
                    }
                }
                .font(size: 12, weight: .semibold)
                .padding(.horizontal, 4)
                card(listed, showsCreated: true)
            }
            if options.compactBriefs, store.showsBrief {
                BriefView().padding(.horizontal, -4)
            }
        }
        let done = store.items(in: .done)
        if !done.isEmpty {
            section(.done, done)
        }
    }

    /// The rows, in a card.
    private func card(_ items: [PRSnapshot], showsCreated: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().padding(.leading, 44).padding(.trailing, 12)
                }
                row(item, showsCreated: showsCreated)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 4)
        .background(GlassCard(cornerRadius: 18))
    }

    /// - Parameter order: where it stands in the mission whose card it's in; nil elsewhere, for the one its capsule speaks
    ///   for.
    private func row(_ item: PRSnapshot, showsCreated: Bool = false, order: OrderRowContext? = nil) -> PRRowView {
        let stage = ordering.isOn ? ordering.stage(of: item.key.linkRef) : nil
        return PRRowView(
            item: item, now: store.now, showsActions: true, showsCreated: showsCreated, isSelected: isSelected(item),
            openSource: source(item), stopWatching: watching(item), dismiss: dismissing(item), showDetails: { select(item) },
            order: order ?? rowOrder(item), mission: missionMenu(item, in: order?.mission), stage: stage,
            ordering: ordering.isOn ? ordering : nil
        ) { store.open(item) }
    }

    @ViewBuilder
    private var idle: some View {
        let idle = store.items(by: shownOrder).filter { item in
            item.group == .idle && !(shownOrder == .byMission && PullRequestsByMission.isIn(missions, item))
        }
        if !idle.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showIdle.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(size: 9, weight: .bold)
                            .rotationEffect(.degrees(showIdle ? 90 : 0))
                        Text("Idle")
                        Text("\(idle.count)").monospacedDigit()
                    }
                    .font(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .help("Drafts, pull requests without recent activity, and reviews you've approved or declined")
                if showIdle {
                    VStack(spacing: 0) {
                        ForEach(idle) { item in
                            PRRowView(item: item, now: store.now, compact: true, showsActions: true, showsCreated: shownOrder.isByDate,
                                      isSelected: isSelected(item), openSource: source(item), stopWatching: watching(item),
                                      showDetails: { select(item) }, order: rowOrder(item), mission: missionMenu(item)) { store.open(item) }
                                .padding(.horizontal, 6)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(GlassCard(cornerRadius: 18))
                }
            }
        }
    }

    /// The missions with its pull requests, By Mission.
    private var missions: [OrderMission] {
        PullRequestsByMission.missions(ordering.missions)
    }

    private func source(_ item: PRSnapshot) -> (() -> Void)? {
        item.chatSource == nil ? nil : { store.openSource(item) }
    }

    private func watching(_ item: PRSnapshot) -> (() -> Void)? {
        item.isWatched ? { store.stopWatching(item) } : nil
    }

    private func dismissing(_ item: PRSnapshot) -> (() -> Void)? {
        item.group == .needsYou ? { store.dismiss(item) } : nil
    }
}
