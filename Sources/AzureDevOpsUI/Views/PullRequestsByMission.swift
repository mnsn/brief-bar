import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The window's Pull Requests page By Mission, with Pull Request Order on (`MissionsBody`): the missions with Azure DevOps'
/// pull requests, each a card of its rows in their order with the graph beside them, or a band of the Map; then, in List,
/// the pull requests in no mission, by status. A row or a node shows its details beside the list, as a click on a row does
/// By Status. Idle's keep their own section. While Show Links is off, its foot says that stories need it.
struct PullRequestsByMission: View {
    let view: OrderView
    @ObservedObject var ordering: PullRequestOrder
    /// The pull requests the list has, in its order.
    let items: [PRSnapshot]
    /// A pull request's row in a mission's card, as the page draws it, with where it stands in that mission.
    let row: (PRSnapshot, OrderRowContext) -> AnyView
    let isSelected: (PRSnapshot) -> Bool
    let select: (PRSnapshot) -> Void
    /// The pull requests in no mission, by status, as the page groups them.
    let rest: ([PRSnapshot]) -> AnyView

    @EnvironmentObject private var services: AppServices

    static let kinds: Set<ItemRef.Kind> = [.pullRequest]

    var body: some View {
        let byRef = Dictionary(items.map { ($0.key.linkRef, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = items.filter { $0.group != .idle }.map(\.key.linkRef)
        let apart = items.filter { $0.group == .idle }.map(\.key.linkRef)
        VStack(alignment: .leading, spacing: 18) {
            missions(byRef: byRef, listed: listed, apart: apart)
            StoriesNeedShowLinks(links: services.links)
        }
    }

    private func missions(byRef: [ItemRef: PRSnapshot], listed: [ItemRef], apart: [ItemRef]) -> some View {
        MissionsBody(
            view: view, ordering: ordering, kinds: Self.kinds, elsewhere: "GitHub",
            openElsewhere: services.hasPage(.githubPullRequests) ? { services.openWindow(.githubPullRequests) } : nil,
            listed: listed, apart: apart,
            row: { step, mission in
                byRef[step.ref].map { item in row(item, OrderRowContext(step: step, mission: mission, isReady: item.group == .ready)) }
            },
            place: { byRef[$0]?.repository },
            isSelected: { ref in byRef[ref].map(isSelected) ?? false },
            select: { ref in
                guard let item = byRef[ref] else { return false }
                select(item)
                return true
            },
            rest: { refs in rest(refs.compactMap { byRef[$0] }) }
        )
    }

    /// The missions with Azure DevOps' pull requests.
    static func missions(_ all: [OrderMission]) -> [OrderMission] {
        MissionsBody.missions(all, kinds: kinds)
    }

    static func isIn(_ missions: [OrderMission], _ item: PRSnapshot) -> Bool {
        MissionsBody.isIn(missions, item.key.linkRef)
    }
}

/// By Mission's foot while Show Links is off: Pull Request Order puts each story's pull requests together only with it,
/// as Show Links reads your pull requests' work items. Turn On… shows its setting.
private struct StoriesNeedShowLinks: View {
    @ObservedObject var links: Links

    @LocalState private var showsSetting = false

    var body: some View {
        if !links.isOn {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(OrderText.storiesNeedShowLinks)
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
}

extension PullRequestsByMission {
    /// For `--render`, with Pull Request Order on and a mission to show: the page By Mission, in List and on the Map, also
    /// with text at 150%, and in a narrow window, its header's controls their symbols alone; every mission, a story's among
    /// them, wide, narrow and at 150%; and By Status, with the order's capsules on the rows. And the line at By Mission's
    /// foot while Show Links is off.
    @MainActor
    static func renderings(
        store: PRStore, services: AppServices, environment: (AnyView) -> AnyView
    ) -> [(name: String, view: AnyView)] {
        let ordering = services.pullRequestOrder
        guard ordering.isOn, !missions(ordering.missions).isEmpty else { return [] }
        let shown: [(name: String, order: PROrder, view: OrderView, scale: CGFloat?, size: CGSize)] = [
            ("pull-requests-by-mission", .byMission, .list, nil, CGSize(width: 1_000, height: 1_000)),
            ("pull-requests-by-mission-map", .byMission, .map, nil, CGSize(width: 1_000, height: 720)),
            ("pull-requests-by-mission-150", .byMission, .list, 1.5, CGSize(width: 1_000, height: 1_000)),
            ("pull-requests-by-mission-narrow", .byMission, .list, nil, CGSize(width: 560, height: 720)),
            ("pull-requests-by-mission-all", .byMission, .list, nil, CGSize(width: 1_000, height: 2_000)),
            ("pull-requests-by-mission-all-narrow", .byMission, .list, nil, CGSize(width: 560, height: 2_800)),
            ("pull-requests-by-mission-all-150", .byMission, .list, 1.5, CGSize(width: 1_000, height: 3_000)),
            ("pull-requests-by-mission-map-all", .byMission, .map, nil, CGSize(width: 1_000, height: 1_600)),
            ("pull-requests-by-status-order", .status, .list, nil, CGSize(width: 1_000, height: 2_400)),
        ]
        let showLinksOff = StoriesNeedShowLinks(links: Links(defaults: MemoryDefaults(), isDemo: false))
            .padding(16)
            .frame(width: 700, alignment: .leading)
            .background(WindowBackdrop())
            .environment(\.isRendering, true)
        return [(name: "pull-requests-by-mission-show-links-off", view: environment(AnyView(showLinksOff)))] + shown.map { name, order, view, scale, size in
            let page = PullRequestsPage(order: order, view: view)
                .environment(\.panelStyle, .page)
            let scaled: AnyView = if let scale {
                AnyView(page.environment(\.textScale, scale))
            } else {
                AnyView(page.textSize(from: services))
            }
            let framed = scaled
                .frame(width: size.width, height: size.height)
                .background(WindowBackdrop())
                .environment(\.isRendering, true)
            return (name: name, view: environment(AnyView(framed)))
        }
    }
}
