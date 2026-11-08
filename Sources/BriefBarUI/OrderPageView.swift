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
    /// The pull requests in no mission, as the page groups them by status.
    let rest: ([ItemRef]) -> AnyView

    @EnvironmentObject private var services: AppServices
    /// The section and window whose page this is, when it's on one: its missions are named only while that page is on
    /// screen.
    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window
    /// Who shows the missions, for Apple Intelligence to name them while they're on screen.
    @LocalState private var viewer = MissionsViewer()
    /// The missions whose card or band is in the scroll view's sight now: Apple Intelligence names only those.
    @LocalState private var inSight: Set<MissionKey> = []

    package init(
        view: OrderView, ordering: PullRequestOrder, kinds: Set<ItemRef.Kind>, elsewhere: String, openElsewhere: (() -> Void)?,
        listed: [ItemRef], apart: [ItemRef] = [], row: @escaping (OrderStep, MissionKey) -> AnyView?,
        place: @escaping (ItemRef) -> String?,
        isSelected: @escaping (ItemRef) -> Bool, select: @escaping (ItemRef) -> Bool, rest: @escaping ([ItemRef]) -> AnyView
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
        self.rest = rest
    }

    /// The missions a page of these kinds shows.
    package static func missions(_ all: [OrderMission], kinds: Set<ItemRef.Kind>) -> [OrderMission] {
        all.filter { $0.shows(kinds) }
    }

    /// Whether a pull request is in one of the missions.
    package static func isIn(_ missions: [OrderMission], _ ref: ItemRef) -> Bool {
        missions.contains { $0.contains(ref) }
    }

    package var body: some View {
        let missions = Self.missions(ordering.missions, kinds: kinds)
        let rest = listed.filter { !Self.isIn(missions, $0) }
        // Apple Intelligence names only the missions on screen: those scrolled out of sight wait.
        let onScreen = missions.map(\.key).filter(inSight.contains)
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 18) {
                if missions.isEmpty {
                    noMissions
                }
                switch view {
                case .list:
                    ForEach(missions) { mission in
                        card(mission)
                            .onSightChange { see(mission.key, $0) }
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
                            mission: mission, place: place(of: mission), links: services.links,
                            order: ordering, isSelected: isSelected, select: open, list: { AnyView(card(mission)) }
                        )
                        .onSightChange { see(mission.key, $0) }
                    }
                    let undrawn = OrderMap.undrawn(listed + apart, in: missions)
                    NotInAMissionLine(inNoMission: undrawn.inNoMission, notInOrder: undrawn.notInOrder) { ordering.setView(.list) }
                }
            }
            .onChange(of: ordering.revealed) { _, key in reveal(key, with: proxy) }
            .onAppear {
                reveal(ordering.revealed, with: proxy)
                ordering.showing(onScreen, in: viewer, on: page)
            }
            .onChange(of: onScreen) { _, keys in ordering.showing(keys, in: viewer, on: page) }
            .onDisappear { ordering.stopShowing(in: viewer) }
        }
    }

    /// The window's page this is, when it's on one, for Pull Request Order to know when it's on screen.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestOrder.page(section, window: window)
    }

    /// A mission's card or band came into the scroll view's sight, or left it.
    private func see(_ key: MissionKey, _ isInSight: Bool) {
        if isInSight { inSight.insert(key) } else { inSight.remove(key) }
    }

    private func card(_ mission: OrderMission) -> MissionCard {
        MissionCard(
            mission: mission, kinds: kinds, place: place(of: mission), elsewhere: elsewhere, openElsewhere: openElsewhere,
            order: ordering
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
            NSWorkspace.shared.open(url)
        }
    }

    private func reveal(_ key: MissionKey?, with proxy: ScrollViewProxy) {
        guard let key else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(key, anchor: .top) }
            ordering.revealed = nil
        }
    }
}

/// A page that shows missions, as Pull Request Order knows it while it does.
final class MissionsViewer {}

private extension View {
    /// Says whether it's in its scroll view's sight, as it comes in or leaves it; outside a scroll view, it is.
    func onSightChange(_ action: @escaping (Bool) -> Void) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            proxy.bounds(of: .scrollView).map { $0.intersects(CGRect(origin: .zero, size: proxy.size)) } ?? true
        } action: { action($0) }
    }
}
