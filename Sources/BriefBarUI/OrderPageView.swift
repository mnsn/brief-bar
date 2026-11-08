import AppKit
import BriefBarCore
import SwiftUI

/// A Pull Requests page By Mission, the same on both pages, with each page's own rows: the missions with the page's pull
/// requests, each a card in List or a band of the Map, the one you focus on first; then, in List, the pull requests in no
/// mission, by status, as the page lists them. A row's capsule elsewhere asks it to show a mission (`PullRequestOrder.reveal`),
/// and it scrolls there.
package struct MissionsBody: View {
    let view: OrderView
    @ObservedObject var ordering: PullRequestOrder
    /// The kinds of pull request the page lists.
    let kinds: Set<ItemRef.Kind>
    /// The page that lists the missions' other pull requests, "GitHub", and opening it; nil when it can't open.
    let elsewhere: String
    let openElsewhere: (() -> Void)?
    /// The pull requests the page lists here, in its order: all but those it keeps apart, such as Idle's.
    let listed: [ItemRef]
    /// Those the page lists apart, such as Idle's, which the Map counts too when it doesn't draw them.
    let apart: [ItemRef]
    /// A pull request's row in a mission's card, as the page draws it, with where it stands in that mission, which can
    /// differ from where it stands in another; nil for one the page doesn't list.
    let row: (OrderStep, MissionKey) -> AnyView?
    /// The repository a pull request is in, as the page names it.
    let place: (ItemRef) -> String?
    let isSelected: (ItemRef) -> Bool
    /// What clicking one of its pull requests' node does: what clicking its row does. False for one the page doesn't
    /// list, which then opens where it lives.
    let select: (ItemRef) -> Bool
    /// The pull request whose own details show, with nothing over them, such as a linked item's page or a file's: while
    /// they cover the Board, its card is the one ⌘→ and ⌘← move. Nil on a page that has no Board.
    let shownOnTop: ItemRef?
    /// The pull requests in no mission, as the page groups them by status.
    let rest: ([ItemRef]) -> AnyView
    /// The Board, with Up Next and each mission's next steps, which the page works out once as it draws: a lane for each
    /// mission, but on the Board with Lanes: None. Nil on a page whose pull requests have no stages, which offers no Board and
    /// shows no next steps.
    let board: PullRequestBoard?
    /// A card's content on the Board, as the page draws it.
    let card: ((BoardCard) -> BoardCardContent?)?
    /// Set as Next to Merge in a mission, for a card dropped from Waits onto Can merge: nil where you can't change missions
    /// yourself.
    let setAsNext: ((ItemRef, MissionKey, MissionMenuContext.UndoPlace) -> Void)?
    /// Lists the page By Status, for what isn't on the Board.
    let showByStatus: (() -> Void)?
    let now: Date

    @EnvironmentObject private var services: AppServices

    package init(
        view: OrderView, ordering: PullRequestOrder, kinds: Set<ItemRef.Kind>, elsewhere: String, openElsewhere: (() -> Void)?,
        listed: [ItemRef], apart: [ItemRef] = [], row: @escaping (OrderStep, MissionKey) -> AnyView?,
        place: @escaping (ItemRef) -> String?,
        isSelected: @escaping (ItemRef) -> Bool, select: @escaping (ItemRef) -> Bool, shownOnTop: ItemRef? = nil,
        rest: @escaping ([ItemRef]) -> AnyView,
        board: PullRequestBoard? = nil, card: ((BoardCard) -> BoardCardContent?)? = nil,
        setAsNext: ((ItemRef, MissionKey, MissionMenuContext.UndoPlace) -> Void)? = nil,
        showByStatus: (() -> Void)? = nil, now: Date = Date()
    ) {
        self.view = view
        self.ordering = ordering
        self.kinds = kinds
        self.elsewhere = elsewhere
        self.openElsewhere = openElsewhere
        self.listed = listed
        self.apart = apart
        self.row = row
        self.place = place
        self.isSelected = isSelected
        self.select = select
        self.shownOnTop = shownOnTop
        self.rest = rest
        self.board = board
        self.card = card
        self.setAsNext = setAsNext
        self.showByStatus = showByStatus
        self.now = now
    }

    /// The missions whose card, or lane on the Board, shows what you changed last in them, and why BriefBar didn't make a
    /// change there: the rest show at the top of the page.
    /// - Parameter board: the Board, as it shows; nil in List and on the Map.
    package static func showingTheirChanges(_ missions: [OrderMission], board: PullRequestBoard?) -> Set<MissionKey> {
        board.map { Set($0.lanes.compactMap(\.mission)) } ?? Set(missions.map(\.key))
    }

    /// The missions a page of these kinds shows.
    package static func missions(_ all: [OrderMission], kinds: Set<ItemRef.Kind>) -> [OrderMission] {
        all.filter { $0.shows(kinds) }
    }

    /// Whether a pull request is in one of the missions.
    package static func isIn(_ missions: [OrderMission], _ ref: ItemRef) -> Bool {
        missions.contains { $0.contains(ref) }
    }

    /// Where the Board starts, which Up Next's "2 more ›" scrolls to.
    private static let boardTop = "board"

    package var body: some View {
        let missions = Self.missions(ordering.missions, kinds: kinds)
        let rest = listed.filter { !Self.isIn(missions, $0) }
        // Each mission's next steps, as its lane on the Board has them, where its pull requests have stages.
        let missionLanes = board?.mode == .missions ? board : nil
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 18) {
                // What you changed last of a mission, and why BriefBar didn't make a change, when no mission's card or lane
                // here shows it, such as one you moved out of missions.
                let shown = Self.showingTheirChanges(missions, board: view == .board ? board : nil)
                if ordering.said.contains(where: { OrderUndoLine.shows($0, about: nil, in: nil, outside: shown) }) {
                    OrderUndoLine(order: ordering, outside: shown)
                        .padding(.horizontal, 4)
                }
                if missions.isEmpty, view != .board {
                    noMissions
                }
                switch view {
                case .list:
                    ForEach(missions) { mission in
                        missionCard(mission, lane: missionLanes?.lane(for: mission.key))
                    }
                    if !rest.isEmpty {
                        Text("Not in a mission")
                            .font(size: 15, weight: .semibold)
                            .padding(.horizontal, 4)
                            .padding(.top, missions.isEmpty ? 0 : 6)
                            .accessibilityAddTraits(.isHeader)
                        self.rest(rest)
                    }
                case .map:
                    ForEach(missions) { mission in
                        MissionBand(
                            mission: mission, place: place(of: mission), links: services.links, order: ordering,
                            lane: missionLanes?.lane(for: mission.key), isSelected: isSelected, select: open,
                            list: { AnyView(missionCard(mission, lane: missionLanes?.lane(for: mission.key))) }
                        )
                    }
                    let undrawn = OrderMap.undrawn(listed + apart, in: missions)
                    NotInAMissionLine(inNoMission: undrawn.inNoMission, notInOrder: undrawn.notInOrder) { ordering.setView(.list) }
                case .board:
                    if let board, let card {
                        OrderBoardView(
                            board: board, missions: missions, order: ordering, elsewhere: elsewhere, openElsewhere: openElsewhere,
                            place: place(of:), card: card, isSelected: isSelected, select: { ref in _ = select(ref) },
                            shownOnTop: shownOnTop, setAsNext: setAsNext, notOnBoard: board.notOnBoard(listed + apart),
                            showByStatus: showByStatus, now: now
                        )
                        .id(Self.boardTop)
                    }
                }
            }
            .onChange(of: ordering.revealed) { _, key in reveal(key, with: proxy) }
            .onAppear {
                reveal(ordering.revealed, with: proxy)
                revealBoard(ordering.revealedColumn, with: proxy)
            }
            .onChange(of: ordering.revealedColumn) { _, stage in revealBoard(stage, with: proxy) }
        }
    }

    private func missionCard(_ mission: OrderMission, lane: BoardLane?) -> MissionCard {
        MissionCard(
            mission: mission, kinds: kinds, place: place(of: mission), elsewhere: elsewhere, openElsewhere: openElsewhere,
            order: ordering, lane: lane, select: { ref in _ = select(ref) }
        ) { step in
            row(step, mission.key)
        }
    }

    private var noMissions: some View {
        Text("""
            No pull requests go together yet. By Mission shows the ones stacked on each other's branches or in a GitHub \
            stack, and the orders Copilot sessions tell BriefBar.
            """)
            .font(size: 12.5)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    /// The repository most of its pull requests on the page are in.
    private func place(of mission: OrderMission) -> String? {
        let places = mission.steps(of: kinds).compactMap { place($0.ref) }
        let counts = Dictionary(places.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// A node's click: what its row's does, for one the page lists; otherwise where it lives.
    private func open(_ ref: ItemRef) {
        guard !select(ref) else { return }
        if let described = ordering.describe(ref) {
            if described.show?() != true { described.open?() }
        } else if ref.kind == .gitHubPullRequest, let url = URL(string: "https://github.com/\(ref.scope)/pull/\(ref.id)") {
            ThisMac.open(url)
        }
    }

    private func reveal(_ key: MissionKey?, with proxy: ScrollViewProxy) {
        // The Board shows it itself, once its lane is laid out.
        guard let key, view != .board else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(key, anchor: .top) }
            ordering.revealed = nil
        }
    }

    /// Up Next's "2 more ›": the page scrolls to the Board, which scrolls sideways to the column.
    private func revealBoard(_ stage: PullRequestStage?, with proxy: ScrollViewProxy) {
        guard stage != nil, view == .board else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.boardTop, anchor: .top) }
        }
    }
}
