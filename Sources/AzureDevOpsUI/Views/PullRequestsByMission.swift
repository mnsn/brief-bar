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
    /// Your sprint work on the Board, on My Work with + Sprint Tasks.
    var work: BoardWorkContent? = nil
    /// Its foot says that stories need Show Links while it's off; not where the page says it itself, as My Work does.
    var saysStoriesNeedShowLinks = true

    @EnvironmentObject private var services: AppServices

    static let kinds: Set<ItemRef.Kind> = [.pullRequest]

    var body: some View {
        let byRef = Dictionary(items.map { ($0.key.linkRef, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = items.filter { $0.group != .idle }.map(\.key.linkRef)
        let apart = items.filter { $0.group == .idle }.map(\.key.linkRef)
        VStack(alignment: .leading, spacing: 18) {
            missions(byRef: byRef, listed: listed, apart: apart)
            if saysStoriesNeedShowLinks {
                StoriesNeedShowLinks(links: services.links)
            }
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
            setAsNext: Self.setAsNext(ordering), work: work,
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
    /// The work items of yours it's for, on My Work with + Sprint Tasks or + All My Tasks, which have no cards of their own:
    /// "Task 5112", and for one outside the sprint where it is, "Task 5181 (Sprint 41)".
    var work: [String] = []
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
            if !work.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "checklist")
                    Text(work.joined(separator: " · "))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .help("Your work items it's for, through Show Links' links")
            }
            // Why alone: its flags are its marks, below.
            Text(StageText.reason(reading, name: name))
                .font(size: 11.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let flags = Self.flags(item, reading: reading, name: name)
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
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                }
            }
            if card.stage == .yourReview {
                FinishedReviewButton(ref: card.ref, order: ordering)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Its card on the Board, on the Pull Requests page and on My Work: what it shows, its menu as its row's, with Make Next,
    /// and what VoiceOver says of it. With a lane for every card, Undo shows at the top.
    /// - Parameters:
    ///   - lanes: the Board's lanes, for where Undo shows.
    ///   - work: the work items of yours it's for, on My Work with + Sprint Tasks: "Task 5112".
    ///   - select: shows its details.
    @MainActor
    static func content(
        _ item: PRSnapshot, _ card: BoardCard, store: PRStore, ordering: PullRequestOrder, lanes: BoardLanes, work: [String] = [],
        select: @escaping () -> Void
    ) -> BoardCardContent {
        let order = card.step.map {
            OrderRowContext(step: $0, mission: card.mission, isReady: item.group == .ready, names: ordering.names)
        }
        let mission = MissionMenuContext.of(item.key.linkRef, order: ordering, mission: card.mission, undo: .onBoard(lanes))
        return BoardCardContent(
            view: AnyView(PullRequestBoardCard(item: item, card: card, order: order, ordering: ordering, work: work, now: store.now)),
            menu: AnyView(Group {
                Button("Show Details", action: select)
                Button("Open in Azure DevOps") { store.open(item) }
                MakeNextToggle(card: card, order: ordering)
                PullRequestMenuItems(
                    item: item, openSource: item.chatSource == nil ? nil : { store.openSource(item) },
                    dismiss: item.group == .needsYou ? { store.dismiss(item) } : nil,
                    stopWatching: item.isWatched ? { store.stopWatching(item) } : nil, mission: mission, ordering: ordering
                )
            }),
            label: "!\(item.key.number) \(item.title)",
            details: details(item, reading: card.reading, order: order, ordering: ordering)
                + (work.isEmpty ? [] : ["for " + work.joined(separator: ", ")]),
            mission: mission
        )
    }

    struct Flag {
        var symbol: String
        var text: String
        var color: Color
    }

    /// What it shows whatever its stage, as marks under why it's there: on yours, its flags, which never move it
    /// (`StageReading.flags`): a session that asks you, one that writes it, what fails, ✋ changes someone wants; then the
    /// rest (`others`).
    static func flags(_ item: PRSnapshot, reading: StageReading, name: (ItemRef) -> String? = { _ in nil }) -> [Flag] {
        reading.saidFlags.map { mark($0, name: name) } + others(item, reading: reading)
    }

    /// A flag of yours as a mark: "‘Cart’ asks you", "‘Cart’ is writing it", "Build failed", "Priya wants changes".
    static func mark(_ flag: StageFlag, name: (ItemRef) -> String?) -> Flag {
        let text = StageText.mark(flag, name: name)
        return switch flag {
        case .asksYou: Flag(symbol: "bubble.left.fill", text: text, color: PullRequestStage.inProgress.textColor)
        case .working: Flag(symbol: PullRequestStage.inProgress.symbol, text: text, color: PullRequestStage.inProgress.textColor)
        case .failing: Flag(symbol: "xmark.circle.fill", text: text, color: PRGroup.failing.color)
        case .changesWanted: Flag(symbol: "hand.raised.fill", text: text, color: PRGroup.needsYou.color)
        }
    }

    /// Its marks besides its flags, as its row says them: what needs you, but changes someone wants, which ✋ says already;
    /// what failed; a draft; each only where its stage's words don't say it already.
    static func others(_ item: PRSnapshot, reading: StageReading) -> [Flag] {
        let says = { (isIt: (StageFlag) -> Bool, why: Bool) in why || reading.flags.contains(where: isIt) }
        let wantsChanges = says({ if case .changesWanted = $0 { true } else { false } }, {
            if case .changesWanted = reading.why { true } else { false }
        }())
        let failing = says({ if case .failing = $0 { true } else { false } }, {
            if case .failing = reading.why { true } else { false }
        }())
        var flags: [Flag] = []
        if item.group == .needsYou, !(wantsChanges && [.changesRequested, .rejected].contains(item.reason)) {
            flags.append(Flag(symbol: "hand.raised.fill", text: item.headline, color: PRGroup.needsYou.color))
        }
        if item.group == .failing, !failing {
            flags.append(Flag(symbol: "xmark.circle.fill", text: item.headline, color: PRGroup.failing.color))
        }
        if item.isDraft, reading.why != .draft {
            flags.append(Flag(symbol: "pencil.circle", text: "Draft", color: .secondary))
        }
        return flags
    }

    /// What VoiceOver says of it, after its stage, whose words say its flags: its other marks, where it stands in its order,
    /// who works on it, and where it is.
    @MainActor
    static func details(_ item: PRSnapshot, reading: StageReading, order: OrderRowContext?, ordering: PullRequestOrder) -> [String] {
        var details = others(item, reading: reading).map(\.text)
        if let sentence = order?.sentence, order?.isSaid(by: reading.stage) == false { details.append(sentence) }
        if let worker = worker(on: item.key.linkRef, besides: reading, ordering: ordering) {
            details.append(SpokenText.unquoted("‘\(worker.label)’ works on it"))
        }
        details.append(item.repository)
        return details
    }

    /// The first Copilot session that told BriefBar it works on it (`SessionUpdates`), unless its stage names it already,
    /// as "‘Cart’ is writing it" does, as why or a flag, and "‘Cart’ is on it" does of the session that set it
    /// (`StageText.namesWhoSetIt`).
    @MainActor
    static func worker(on ref: ItemRef, besides reading: StageReading, ordering: PullRequestOrder) -> LinkedItem? {
        let byWhy: ItemRef? = switch reading.why {
        case .working(let session), .asksYou(let session), .finished(let session), .preReviewing(let session): session.ref
        default: StageText.namesWhoSetIt(reading) ? reading.mark?.by : nil
        }
        let byFlags = reading.flags.compactMap { flag -> ItemRef? in
            switch flag {
            case .asksYou(let session), .working(let session): session.ref
            case .failing, .changesWanted: nil
            }
        }
        let named = Set([byWhy].compactMap { $0 } + byFlags)
        return ordering.sessionsWorking(on: ref).filter { !named.contains($0) }.lazy.compactMap(ordering.describe).first
    }
}

extension PullRequestsByMission {
    /// For `--render`, with Pull Request Order on and a mission to show: the page By Mission, in List, on the Map and
    /// on the Board, Up Next above each, also with text at 150%, and in a narrow window, its header's controls their
    /// symbols alone, also all the way down to a mission of your own; every mission, a story's among them, with the
    /// split Apple Intelligence suggests for it, wide, narrow and at 150%, in the List and on the Board; the Board with
    /// Lanes: None, and at about a window's size, for the README, down to its first mission; and By Status, Up Next above
    /// it, with the order's capsules on the rows, also narrow and with text at 150%, where Up Next's slots wrap. And the
    /// line at By Mission's foot while Show Links is off.
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
            ("pull-requests-board-all", .byMission, .board, .missions, nil, CGSize(width: 1_200, height: 1_800)),
            ("pull-requests-board-all-narrow", .byMission, .board, .missions, nil, CGSize(width: 560, height: 2_100)),
            ("pull-requests-board-all-150", .byMission, .board, .missions, 1.5, CGSize(width: 1_200, height: 2_600)),
            ("pull-requests-board-lanes-none", .byMission, .board, BoardLanes.none, nil, CGSize(width: 1_200, height: 900)),
            ("pull-requests-board-window", .byMission, .board, .missions, nil, CGSize(width: 1_080, height: 750)),
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
