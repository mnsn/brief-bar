import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The window's Pull Requests page By Mission, with Pull Request Order on (`MissionsBody`): the missions with Azure DevOps'
/// pull requests, each a card of its rows in their order with the graph beside them, a band of the Map, or a lane of the
/// Board, with a card for each pull request in a column for its stage; then, in List, the pull requests in no mission, by
/// status, and on the Board, their lane. A row, a node or a card shows its details beside the list, as a click on a row does
/// By Status. Idle's keep their own section, but on the Board, which has your own among its cards. While Show Links is off,
/// its foot says that stories need it.
struct PullRequestsByMission: View {
    let view: OrderView
    @ObservedObject var ordering: PullRequestOrder
    /// The pull requests the list has, in its order.
    let items: [PRSnapshot]
    /// A pull request's row in a mission's card, as the page draws it, with where it stands in that mission.
    let row: (PRSnapshot, OrderRowContext) -> AnyView
    /// A pull request's card on the Board, as the page draws it.
    let card: (PRSnapshot, BoardCard) -> BoardCardContent
    let isSelected: (PRSnapshot) -> Bool
    let select: (PRSnapshot) -> Void
    /// The pull request whose own details show, with nothing over them: while they cover the Board, its card is the one ⌘→
    /// and ⌘← move.
    let shownOnTop: ItemRef?
    /// The pull requests in no mission, by status, as the page groups them.
    let rest: ([PRSnapshot]) -> AnyView
    /// The Board, Up Next and each mission's next steps, as the page works them out once as it draws.
    let board: PullRequestBoard?
    /// Lists the page By Status, for what isn't on the Board.
    let showByStatus: () -> Void
    let now: Date

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
                byRef[step.ref].map { item in
                    row(item, OrderRowContext(step: step, mission: mission, isReady: item.group == .ready, names: ordering.names))
                }
            },
            place: { byRef[$0]?.repository },
            isSelected: { ref in byRef[ref].map(isSelected) ?? false },
            select: { ref in
                guard let item = byRef[ref] else { return false }
                select(item)
                return true
            },
            shownOnTop: shownOnTop,
            rest: { refs in rest(refs.compactMap { byRef[$0] }) },
            board: board, card: { boardCard in byRef[boardCard.ref].map { card($0, boardCard) } },
            setAsNext: Self.setAsNext(ordering),
            showByStatus: showByStatus, now: now
        )
    }

    /// The Board's Set as Next to Merge, as dropping a card from Waits onto Can merge does it: VoiceOver hears its Undo is
    /// where the Board says, in its mission's lane, at the top with a lane for every card, or beside its mission in the
    /// details while they cover the Board.
    static func setAsNext(_ ordering: PullRequestOrder) -> (ItemRef, MissionKey, MissionMenuContext.UndoPlace) -> Void {
        { ref, mission, undo in
            MissionMenuContext.setAsNext(ref, in: mission, order: ordering, undo: undo)
        }
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

/// A pull request's card on the Board: its number and title, on two lines at most; why it's in its stage; what needs you on
/// it, what failed and a draft, unless its stage says so already; where it stands in its order, unless its stage says that,
/// as Can merge and Waits do; its stage's pill, whose menu changes it, and who set it; Copilot's work on it; and Finished My
/// Review in Your review. It grows with the text: only its title is ever cut short.
struct PullRequestBoardCard: View {
    let item: PRSnapshot
    let card: BoardCard
    /// Where it stands in its lane's mission, for its capsule.
    let order: OrderRowContext?
    @ObservedObject var ordering: PullRequestOrder
    let now: Date

    var body: some View {
        let reading = card.reading
        let name = { (ref: ItemRef) in ordering.name(of: ref) }
        VStack(alignment: .leading, spacing: 5) {
            Text(card.ref.shortOrderLabel)
                .font(size: 11.5, weight: .semibold)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(item.title)
                .font(size: 13, weight: .semibold)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Text(StageText.why(reading, name: name))
                .font(size: 11.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let flags = Self.flags(item, reading: reading)
            if !flags.isEmpty || order?.isSaid(by: card.stage) == false {
                FlowLayout(spacing: 5, lineSpacing: 4) {
                    ForEach(flags, id: \.text) { flag in
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Image(systemName: flag.symbol)
                            Text(flag.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(size: 11, weight: .semibold)
                        .foregroundStyle(flag.color)
                    }
                    if let order, !order.isSaid(by: card.stage) {
                        OrderCapsule(order)
                    }
                }
            }
            PullRequestCopilotStatus(key: item.key)
            if let worker = Self.worker(on: card.ref, besides: reading, ordering: ordering) {
                HStack(spacing: 3) {
                    Image(systemName: "waveform.path.ecg")
                    Text("‘\(worker.label)’ works on it")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(size: 11, weight: .semibold)
                .foregroundStyle(worker.color)
                .help("‘\(worker.label)’ told BriefBar it works on it")
            }
            FlowLayout(spacing: 6, lineSpacing: 4) {
                PullRequestStagePill(ref: card.ref, reading: reading, order: ordering, now: now)
                if let who = BoardText.setter(reading, now: now, name: name) {
                    Text(who)
                        .font(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.vertical, 2)
                }
            }
            if card.stage == .yourReview {
                FinishedReviewButton(ref: card.ref, order: ordering)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct Flag {
        var symbol: String
        var text: String
        var color: Color
    }

    /// What it shows whatever its stage, as its row does: what needs you, what failed, a draft; each only where its stage's
    /// words don't say it already, as its why or after it, "‘Cart’ is writing it · build failed".
    static func flags(_ item: PRSnapshot, reading: StageReading) -> [Flag] {
        var flags: [Flag] = []
        if item.group == .needsYou {
            flags.append(Flag(symbol: "hand.raised.fill", text: item.headline, color: PRGroup.needsYou.color))
        }
        if item.group == .failing, reading.fixRank == nil, reading.alsoFailing == nil {
            flags.append(Flag(symbol: "xmark.circle.fill", text: item.headline, color: PRGroup.failing.color))
        }
        if item.isDraft, reading.why != .draft {
            flags.append(Flag(symbol: "pencil.circle", text: "Draft", color: .secondary))
        }
        return flags
    }

    /// What VoiceOver says of it, after its stage: its flags, where it stands in its order, who works on it, and where it is.
    @MainActor
    static func details(_ item: PRSnapshot, reading: StageReading, order: OrderRowContext?, ordering: PullRequestOrder) -> [String] {
        var details = flags(item, reading: reading).map(\.text)
        if let sentence = order?.sentence, order?.isSaid(by: reading.stage) == false { details.append(sentence) }
        if let worker = worker(on: item.key.linkRef, besides: reading, ordering: ordering) {
            details.append(SpokenText.unquoted("‘\(worker.label)’ works on it"))
        }
        details.append(item.repository)
        return details
    }

    /// The first Copilot session that told BriefBar it works on it (`SessionUpdates`), unless its stage names it already,
    /// as "‘Cart’ is writing it" does.
    @MainActor
    static func worker(on ref: ItemRef, besides reading: StageReading, ordering: PullRequestOrder) -> LinkedItem? {
        let named: ItemRef? = switch reading.why {
        case .working(let session), .asksYou(let session), .finished(let session), .preReviewing(let session): session.ref
        default: nil
        }
        return ordering.sessionsWorking(on: ref).filter { $0 != named }.lazy.compactMap(ordering.describe).first
    }
}

extension PullRequestsByMission {
    /// For `--render`, with Pull Request Order on and a mission to show: the page By Mission, in List, on the Map and on the
    /// Board, Up Next above each, also with text at 150%, and in a narrow window, its header's controls their symbols alone,
    /// also all the way down to a mission of your own; every mission, a story's among them, wide, narrow and at 150%; the
    /// Board with Lanes: None; and By Status, Up Next above it, with the order's capsules on the rows, also narrow and with
    /// text at 150%, where Up Next's slots wrap. And the line at By Mission's foot while Show Links is off.
    @MainActor
    static func renderings(
        store: PRStore, services: AppServices, environment: (AnyView) -> AnyView
    ) -> [(name: String, view: AnyView)] {
        let ordering = services.pullRequestOrder
        guard ordering.isOn, !missions(ordering.missions).isEmpty else { return [] }
        typealias Shown = (name: String, order: PROrder, view: OrderView, lanes: BoardLanes?, scale: CGFloat?, size: CGSize)
        let shown: [Shown] = [
            ("pull-requests-by-mission", .byMission, .list, nil, nil, CGSize(width: 1_000, height: 1_000)),
            ("pull-requests-by-mission-narrow-tall", .byMission, .list, nil, nil, CGSize(width: 560, height: 1_400)),
            ("pull-requests-by-mission-map", .byMission, .map, nil, nil, CGSize(width: 1_000, height: 720)),
            ("pull-requests-by-mission-150", .byMission, .list, nil, 1.5, CGSize(width: 1_000, height: 1_000)),
            ("pull-requests-by-mission-narrow", .byMission, .list, nil, nil, CGSize(width: 560, height: 720)),
            ("pull-requests-by-mission-all", .byMission, .list, nil, nil, CGSize(width: 1_000, height: 2_000)),
            ("pull-requests-by-mission-all-narrow", .byMission, .list, nil, nil, CGSize(width: 560, height: 2_800)),
            ("pull-requests-by-mission-all-150", .byMission, .list, nil, 1.5, CGSize(width: 1_000, height: 3_000)),
            ("pull-requests-by-mission-map-all", .byMission, .map, nil, nil, CGSize(width: 1_000, height: 1_600)),
            ("pull-requests-board", .byMission, .board, .missions, nil, CGSize(width: 1_200, height: 1_250)),
            ("pull-requests-board-150", .byMission, .board, .missions, 1.5, CGSize(width: 1_200, height: 1_400)),
            ("pull-requests-board-narrow", .byMission, .board, .missions, nil, CGSize(width: 560, height: 1_100)),
            ("pull-requests-board-lanes-none", .byMission, .board, BoardLanes.none, nil, CGSize(width: 1_200, height: 900)),
            ("pull-requests-by-status-order", .status, .list, nil, nil, CGSize(width: 1_000, height: 2_400)),
            ("pull-requests-up-next-narrow", .status, .list, nil, nil, CGSize(width: 560, height: 900)),
            ("pull-requests-up-next-150", .status, .list, nil, 1.5, CGSize(width: 1_000, height: 900)),
        ]
        let showLinksOff = StoriesNeedShowLinks(links: Links(defaults: MemoryDefaults(), isDemo: false))
            .padding(16)
            .frame(width: 700, alignment: .leading)
            .background(WindowBackdrop())
            .environment(\.isRendering, true)
        let foot = (name: "pull-requests-by-mission-show-links-off", view: environment(AnyView(showLinksOff)))
        return [foot] + shown.map { name, order, view, lanes, scale, size in
            let page = PullRequestsPage(order: order, view: view, lanes: lanes)
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
