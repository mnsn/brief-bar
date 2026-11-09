import AppKit
import BriefBarCore
import SwiftUI

// By Mission's shared views, which both Pull Requests pages draw with their own rows: a mission's card in List, its header,
// the order capsule on a row, the marks in the graph, and the List | Map switch. Everything scales with the text size of
// windows' pages.

// MARK: - A row's order

/// Where a row's pull request stands in its mission, for its capsule and its words to VoiceOver.
package struct OrderRowContext {
    package let step: OrderStep
    /// The mission it speaks for; nil for a row that only says where it stands.
    package let mission: MissionKey?
    /// Its source says it's ready to complete: "After !4102" turns orange.
    package let isReady: Bool
    /// Shows its mission in By Mission, from another list; nil where it shows already.
    package let open: (() -> Void)?
    /// What names sessions and missions in what it says, and the time, for what your changes and orders' later ones say.
    package let names: OrderNames

    package init(step: OrderStep, mission: MissionKey? = nil, isReady: Bool, open: (() -> Void)? = nil, names: OrderNames = .none) {
        self.step = step
        self.mission = mission
        self.isReady = isReady
        self.open = open
        self.names = names
    }

    /// What its capsule says in full.
    package var sentence: String? {
        OrderText.sentence(of: step, isReady: isReady, names: names)
    }

    /// Whether this stage's words already say where its order puts it, so that its capsule would only repeat them: Can merge
    /// and Waits, for one its order places. Never where a change of yours speaks of it, such as that you set it as next, with
    /// ✎, or that an order went against yours, in its tooltip and to VoiceOver, which no stage says; nor for one with no
    /// order known, whose quiet ✎ says what a change of yours says of it.
    package func isSaid(by stage: PullRequestStage) -> Bool {
        guard stage == .canMerge || stage == .waits else { return false }
        return step.standing != .unordered && !step.notes.contains(where: \.isAboutYourChanges)
    }

    /// The row of a pull request in the missions, if one has it in its order or is stacked with it.
    /// - Parameter open: shows the mission in By Mission; nil where it shows already.
    package static func of(
        _ ref: ItemRef, in missions: [OrderMission], isReady: Bool, open: ((MissionKey) -> Void)? = nil, names: OrderNames = .none
    ) -> OrderRowContext? {
        guard let (mission, step) = OrderBoard.step(for: ref, in: missions) else { return nil }
        let key = mission.key
        return OrderRowContext(step: step, mission: key, isReady: isReady, open: open.map { open in { open(key) } }, names: names)
    }
}

extension OrderCapsuleTone {
    var color: Color {
        switch self {
        case .quiet: return .secondary
        case .next: return .accentColor
        case .waiting: return .secondary
        case .warning: return .orange
        }
    }
}

/// A row's order capsule, beside its links: "Next to merge", "After !4103 · stacked", "Any time", "Check the order"; with ✎
/// where a change of yours decides it. It says the rest in its tooltip. From another list, a click shows its mission in By
/// Mission. With no order known, a quiet ✎ alone, where a change of yours says something of it, such as that you moved it
/// there, in its tooltip.
package struct OrderCapsule: View {
    private let context: OrderRowContext

    package init(_ context: OrderRowContext) {
        self.context = context
    }

    package var body: some View {
        if let text = OrderText.capsule(context.step) {
            let tone = OrderText.tone(of: context.step, isReady: context.isReady)
            let help: String = (context.sentence ?? text) + (context.open == nil ? "" : "\nClick to show it By Mission")
            let symbol = tone == .warning ? "exclamationmark.triangle.fill"
                : context.step.isYours ? "pencil" : "point.3.connected.trianglepath.dotted"
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
                Text(text)
            }
            .font(size: 10, weight: .semibold)
            .lineLimit(1)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tone.color.opacity(tone == .quiet ? 0.10 : 0.14)))
            .contentShape(Capsule())
            .fixedSize()
            .help(help)
            .accessibilityLabel(context.sentence ?? text)
            .highPriorityGesture(TapGesture().onEnded { context.open?() }, including: context.open == nil ? .subviews : .all)
        } else if context.step.notes.contains(where: \.isAboutYourChanges), let sentence = context.sentence {
            Image(systemName: "pencil")
                .font(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                .contentShape(Capsule())
                .fixedSize()
                .help(sentence + (context.open == nil ? "" : "\nClick to show it By Mission"))
                .accessibilityLabel(sentence)
                .highPriorityGesture(TapGesture().onEnded { context.open?() }, including: context.open == nil ? .subviews : .all)
        }
    }
}

// MARK: - The graph's marks

/// A pull request's node in the graph, for where it stands: filled for next to merge, outlined while it waits, dotted for
/// any time, ✓ once merged, an orange ! when its order needs checking. With a stage, it's in the stage's color, and its
/// shape still says where it stands.
package struct OrderNodeMark: View {
    let marker: OrderMarker
    /// Its diameter, before the text size scales it.
    var size: CGFloat = 9
    /// Dimmed while hovering lights up others.
    var isDimmed = false
    /// Its stage, whose color it takes; nil for one with none.
    var stage: PullRequestStage?

    @Environment(\.textScale) private var textScale

    package init(_ marker: OrderMarker, size: CGFloat = 9, isDimmed: Bool = false, stage: PullRequestStage? = nil) {
        self.marker = marker
        self.size = size
        self.isDimmed = isDimmed
        self.stage = stage
    }

    package var body: some View {
        let diameter = size * textScale
        mark(diameter)
            .frame(width: diameter, height: diameter)
            .opacity(isDimmed ? 0.3 : 1)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func mark(_ diameter: CGFloat) -> some View {
        switch marker {
        case .next:
            Circle().fill(stage?.color ?? Color.accentColor)
        case .waiting:
            Circle().strokeBorder(stage?.color ?? Color.secondary, lineWidth: max(1.2, diameter / 7))
        case .anyTime:
            Circle().strokeBorder(stage?.color ?? Color.secondary, style: StrokeStyle(lineWidth: max(1.2, diameter / 7), dash: [1.6, 1.6]))
        case .merged:
            symbol("checkmark", on: stage?.color ?? .green)
        case .closed:
            symbol("xmark", on: .gray)
        case .check:
            symbol("exclamationmark", on: .orange)
        case .unseen:
            Circle().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [1.5, 2]))
        case .none:
            Color.clear
        }
    }

    private func symbol(_ name: String, on color: Color) -> some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: name)
                .font(size: size * 0.58, weight: .heavy)
                .foregroundStyle(.white)
        }
    }
}

// MARK: - A mission's header

/// A mission's title, the story it's for, what kind it is, its progress and its sessions: ★ Focus, "Checkout coupons · User
/// Story 5101 · No order known · shop-web", a bar with one segment for each pull request, "1 of 5 merged", "2 sessions ⌄",
/// and its menu, where Rename… makes its title a field, as Finder renames.
package struct MissionHeader: View {
    let mission: OrderMission
    @ObservedObject var order: PullRequestOrder
    /// Its pull requests' repository, as the page names it.
    let place: String?

    @LocalState private var confirmsForget = false
    @LocalState private var isRenaming = false
    @LocalState private var draft = ""
    /// What the rename field started with.
    @LocalState private var original = ""
    @LocalState private var isFull = false
    @LocalState private var confirmsUndo = false

    package init(mission: OrderMission, order: PullRequestOrder, place: String?) {
        self.mission = mission
        self.order = order
        self.place = place
    }

    package var body: some View {
        HStack(spacing: 6) {
            focusButton
            titleLine
            Spacer(minLength: 8)
            if mission.showsProgress {
                OrderProgressBar(mission: mission, stage: order.drawnStage(of:))
                Text(OrderText.progress(mission))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            if !mission.sessions.isEmpty {
                OrderSessionsMenu(sessions: mission.sessions, order: order)
            }
            menu
        }
        .font(size: 12, weight: .semibold)
        .padding(.horizontal, 4)
        .confirmationDialog("Forget this order?", isPresented: $confirmsForget) {
            Button("Forget This Order", role: .destructive) { forget() }
        } message: {
            Text("""
                BriefBar no longer shows it, and tells a session that names it that it forgot it. Its pull requests stay in your \
                lists, and those you put in it stay together, as a mission of yours.
                """)
        }
        .confirmationDialog("Undo your changes to this mission?", isPresented: $confirmsUndo) {
            Button("Undo Your Changes") {
                MissionMenuContext(order: order, mission: mission.key).change(.undoMission(mission.key))
            }
        } message: {
            Text("""
                Its pull requests go back to where their order and BriefBar put them, those you put in it go back to where they \
                were, and those you moved out of it come back. Undo, after it, takes this back too.
                """)
        }
        .alert("BriefBar can't keep another name", isPresented: $isFull) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(OrderText.namesAtTheCap)
        }
    }

    private var title: String {
        order.title(of: mission)
    }

    private var focusButton: some View {
        Button {
            order.setFocus(mission.isFocused ? nil : mission.key)
        } label: {
            Image(systemName: mission.isFocused ? "star.fill" : "star")
                .foregroundStyle(mission.isFocused ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(mission.isFocused ? "Focused: it comes first. Click to stop" : "Focus on it: it comes first")
        .accessibilityLabel(mission.isFocused ? "Stop Focusing on \(title)" : "Focus on \(title)")
    }

    private var titleLine: some View {
        let title = title
        let story = OrderText.story(of: mission, title: title)
        let details = [place, OrderText.kind(of: mission), mission.isStale ? OrderText.stale : nil].compactMap { $0 }
        let storyItem = mission.story.flatMap { order.describe($0.ref) }
        return HStack(spacing: 4) {
            if isRenaming {
                MissionNameField(draft: $draft, keep: commit, cancel: cancel) {
                    if isRenaming { stopRenaming() }
                }
            } else {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            if let story {
                storyButton(story, item: storyItem)
            }
            if !details.isEmpty {
                Text("· " + details.joined(separator: " · "))
                    .foregroundStyle(mission.isStale ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
        }
        .truncationMode(.tail)
        .help(help(title))
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(order.splitBox(for: mission) == nil ? "" : OrderText.splitSuggested)
        .accessibilityAction(named: "Rename") { rename() }
        .accessibilityActions {
            // Only where the story can show, as its button is.
            if let story, let open = storyItem?.open {
                Button("Show \(story)", action: open)
            }
            // The suggested split's buttons, as its box has them.
            if let box = order.splitBox(for: mission) {
                Button(box.button) {
                    if let said = order.split(mission) { SpokenText.announce(SpokenText.unquoted(said)) }
                }
                Button(OrderText.keepTogether) { SpokenText.announce(order.keepTogether(mission)) }
            }
        }
    }

    /// Who named it, who told its order or what it was opened under, and what a story's mission is.
    private func help(_ title: String) -> String {
        var lines: [String] = []
        switch order.naming(of: mission) {
        case .you: lines.append(OrderText.namedByYou)
        case .appleIntelligence: lines.append(OrderText.namedByAppleIntelligence)
        case .briefBar: break
        }
        if let told = OrderText.told(mission, name: order.name(of:)) {
            lines.append(told)
        }
        if order.naming(of: mission) != .briefBar, let opened = OrderText.openedUnder(mission, name: order.name(of:)) {
            lines.append(opened)
        }
        if let story = OrderText.storyHelp(mission, title: mission.story.flatMap { order.name(of: $0.ref) }) {
            lines.append(story)
        }
        return ([title] + lines).joined(separator: "\n")
    }

    /// "· User Story 5101": shows the story in BriefBar's window, or opens it in Azure DevOps, as Show Links' rows do.
    @ViewBuilder
    private func storyButton(_ story: String, item: LinkedItem?) -> some View {
        if let item, let open = item.open {
            Button(action: open) {
                Text("· \(story)")
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(story) “\(item.title)”: click to show it")
        } else {
            Text("· \(story)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func rename() {
        guard order.canRename(mission.key) else {
            isFull = true
            return
        }
        draft = title
        original = title
        isRenaming = true
        order.renaming = mission.key
    }

    private func commit() {
        guard isRenaming else { return }
        stopRenaming()
        if order.rename(mission, to: draft, from: original) == .full { isFull = true }
    }

    private func cancel() {
        stopRenaming()
    }

    private func stopRenaming() {
        isRenaming = false
        if order.renaming == mission.key { order.renaming = nil }
    }

    private var menu: some View {
        let yours = order.changes(in: mission)
        return Menu {
            Button(mission.isFocused ? "Stop Focusing" : "Focus on It") {
                order.setFocus(mission.isFocused ? nil : mission.key)
            }
            Divider()
            Button("Rename…") { rename() }
            if order.naming(of: mission) == .you {
                Button("Use BriefBar's Name") { order.useBriefBarsName(mission.key) }
            }
            if order.offersSuggestedSplit(mission) {
                Button(OrderText.suggestedSplit) { order.showSuggestedSplit(mission) }
            }
            if yours > 0 || mission.kind.isDeclared {
                Divider()
            }
            if yours > 0 {
                Button("Undo Your Changes to This Mission… (\(yours))") { confirmsUndo = true }
            }
            if mission.kind.isDeclared {
                Button("Forget This Order…") { confirmsForget = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(size: 13)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More for this mission")
        .accessibilityLabel("More for \(title)")
    }

    private func forget() {
        if case .declared(let id, _, _, _) = mission.kind { order.forget(order: id) }
    }
}

extension OrderMission.Kind {
    /// A session's order.
    var isDeclared: Bool {
        if case .declared = self { return true }
        return false
    }
}

/// A mission's progress: one segment for each of its pull requests, in its order, merged ones first, green once merged,
/// grey once closed; where they have stages, each in its stage's color, and its tooltip counts them.
package struct OrderProgressBar: View {
    let mission: OrderMission
    /// The stage a pull request's segment takes the color of; nil for one with none.
    let stage: (OrderStep) -> PullRequestStage?

    @Environment(\.textScale) private var textScale

    package init(mission: OrderMission, stage: @escaping (OrderStep) -> PullRequestStage? = { _ in nil }) {
        self.mission = mission
        self.stage = stage
    }

    /// At most this wide, at 100% text, whatever its count: past 11 pull requests its parts narrow to fit, and past about
    /// 40, it's one bar, filled as far as they merged.
    package static let widest: CGFloat = 120

    /// Each part's width and the gap between them, at 100% text, for this many pull requests; nil when they'd be too
    /// thin to tell apart, and it's one bar.
    package static func parts(_ count: Int) -> (width: CGFloat, gap: CGFloat)? {
        let gap: CGFloat = count > 11 ? 1 : 2
        let width = min(9, (widest - CGFloat(max(count - 1, 0)) * gap) / CGFloat(max(count, 1)))
        return width >= 2 ? (width, gap) : nil
    }

    package var body: some View {
        let steps = Self.inOrder(mission.steps)
        let stages = steps.map(stage)
        let widest = Self.widest * textScale
        let counts = StageText.counts(stages.compactMap { $0 })
        Group {
            if let parts = Self.parts(steps.count) {
                HStack(spacing: parts.gap * textScale) {
                    ForEach(Array(zip(steps, stages).enumerated()), id: \.offset) { _, segment in
                        Capsule()
                            .fill(color(segment.0, stage: segment.1))
                            .frame(width: parts.width * textScale, height: 4 * textScale)
                    }
                }
            } else {
                let merged = CGFloat(steps.filter { $0.status == .merged }.count) / CGFloat(steps.count)
                let closed = CGFloat(steps.filter { $0.status == .closed }.count) / CGFloat(steps.count)
                let mergedColor = stages.contains(.merged) ? PullRequestStage.merged.color : Color.green
                HStack(spacing: 0) {
                    Rectangle().fill(mergedColor).frame(width: widest * merged)
                    Rectangle().fill(Color.gray.opacity(0.6)).frame(width: widest * closed)
                    Rectangle().fill(Color.secondary.opacity(0.25))
                }
                .frame(width: widest, height: 4 * textScale)
                .clipShape(Capsule())
            }
        }
        .help(counts ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stages")
        .accessibilityValue(counts ?? "")
        .accessibilityHidden(counts == nil)
    }

    /// Its pull requests as its segments show them: those that merged first, so it fills from the left, then the rest in
    /// their order.
    package static func inOrder(_ steps: [OrderStep]) -> [OrderStep] {
        steps.filter { $0.status == .merged } + steps.filter { $0.status != .merged }
    }

    private func color(_ step: OrderStep, stage: PullRequestStage?) -> Color {
        if let stage { return stage.color }
        switch step.status {
        case .merged: return .green
        case .closed: return .gray.opacity(0.6)
        default: return .secondary.opacity(0.25)
        }
    }
}

/// "2 sessions ⌄": the sessions a mission goes with, each opening in the Copilot app.
struct OrderSessionsMenu: View {
    let sessions: [ItemRef]
    @ObservedObject var order: PullRequestOrder

    var body: some View {
        Menu {
            ForEach(sessions, id: \.self) { session in
                Button(order.name(of: session) ?? "Copilot session") { open(session) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(OrderText.sessions(sessions.count))
                Image(systemName: "chevron.down")
                    .font(size: 8, weight: .bold)
            }
            .font(size: 12, weight: .semibold)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The Copilot sessions it goes with: the one that told its order, or that its pull requests were opened under, first")
    }

    private func open(_ session: ItemRef) {
        if let open = order.describe(session)?.open {
            open()
        } else if let url = URL(string: "ghapp://sessions/\(session.id)") {
            ThisMac.open(url)
        }
    }
}

// MARK: - A mission's next steps

/// A mission's next steps that are yours, under its header in List, on the Map and on the Board: "Next for you:" and a chip
/// for each, in its stage's color, which shows that pull request: "Review !4093", "Find a reviewer: !4079". With none, what
/// it waits for, quietly: "Waiting for Priya (!4091)".
package struct MissionNextStepsLine: View {
    let lane: BoardLane
    @ObservedObject var order: PullRequestOrder
    let select: (ItemRef) -> Void

    @Environment(\.textScale) private var textScale

    package init(lane: BoardLane, order: PullRequestOrder, select: @escaping (ItemRef) -> Void) {
        self.lane = lane
        self.order = order
        self.select = select
    }

    package var body: some View {
        let steps = lane.nextSteps
        if !steps.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 4) {
                Text("Next for you:")
                    .font(size: 11.5, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
                ForEach(steps) { step in
                    chip(step)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Next for you")
        } else if let waiting = lane.waiting(name: order.name(of:)) {
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                Text(waiting)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(Self.spokenWaiting(lane, order: order) ?? waiting)
            }
            .font(size: 11.5)
            .foregroundStyle(.secondary)
            .help(waiting)
            .accessibilityElement(children: .combine)
        }
    }

    private func chip(_ step: MissionNextStep) -> some View {
        let reading = lane.cards.first { $0.ref == step.ref }?.reading
        let why = reading.map { StageText.why($0, name: order.name(of:)) }
        return Button {
            select(step.ref)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(step.stage.color)
                    .frame(width: 7 * textScale, height: 7 * textScale)
                Text(step.title)
                    .lineLimit(1)
            }
            .font(size: 11.5, weight: .medium)
            .foregroundStyle(step.stage.textColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(step.stage.color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(step.stage.color.opacity(0.5), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help([[step.title, order.name(of: step.ref)].compactMap { $0 }.joined(separator: " "), why, "Click to see its details"]
            .compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel(step.title)
        .accessibilityValue(Self.spoken(step, in: lane, order: order))
        .accessibilityHint("Shows its details")
    }

    /// What VoiceOver hears after a chip's title: its pull request's name, and why, a second reason after a pause,
    /// "Cart asks you, build failed", where its tooltip says "‘Cart’ asks you · build failed".
    package static func spoken(_ step: MissionNextStep, in lane: BoardLane, order: PullRequestOrder) -> String {
        let reading = lane.cards.first { $0.ref == step.ref }?.reading
        let why = reading.map { StageText.why($0, name: order.name(of:), then: ", ") }
        return SpokenText.unquoted([order.name(of: step.ref), why].compactMap { $0 }.joined(separator: ", "))
    }

    /// What VoiceOver hears of what a mission waits for, with a second reason after a pause: "Cart is writing it, build
    /// failed (!4093)".
    package static func spokenWaiting(_ lane: BoardLane, order: PullRequestOrder) -> String? {
        lane.waiting(name: order.name(of:), then: ", ").map(SpokenText.unquoted)
    }
}

// MARK: - List, Map and the Board

/// List | Map | Board, in the page's header while it lists By Mission: the views the page offers, the Board on Azure DevOps'
/// page only. A page that shows List where you chose a view it doesn't offer saves nothing until you pick one there.
package struct OrderViewPicker: View {
    @ObservedObject var order: PullRequestOrder
    /// The views the page offers.
    let views: [OrderView]
    /// The view a picture shows; nil for the one you chose.
    let shown: OrderView?

    package init(order: PullRequestOrder, views: [OrderView] = [.list, .map], shown: OrderView? = nil) {
        self.order = order
        self.views = views
        self.shown = shown
    }

    package var body: some View {
        let current = shown ?? order.view(offering: views)
        SegmentedPicker("By Mission View", selection: Binding(get: { current }, set: { view in
            Self.choose(view, showing: current, order: order)
        }), segments: views.map { view in
            SegmentedPicker<OrderView>.Segment(view, title: view.title, systemImage: Self.symbol(view))
        })
        .fixedSize()
        .help(views.contains(.board)
            ? "List: each mission's pull requests in their order, with the graph beside them. Map: each mission in merge waves. Board: a column for each stage, a lane for each mission"
            : "List: each mission's pull requests in their order, with the graph beside them. Map: each mission in merge waves")
    }

    /// A view you pick, while the page shows `current`: what the page shows already saves nothing, so picking GitHub's List,
    /// which it shows where you chose the Board, leaves the Board for Azure DevOps' page.
    package static func choose(_ view: OrderView, showing current: OrderView, order: PullRequestOrder) {
        if view != current { order.setView(view) }
    }

    static func symbol(_ view: OrderView) -> String {
        switch view {
        case .list: "list.bullet"
        case .map: "map"
        case .board: "rectangle.split.3x1"
        }
    }
}

/// Lanes: Missions | None, in the page's header while it shows the Board: a lane for each mission, or every card in one.
package struct BoardLanesPicker: View {
    @ObservedObject var order: PullRequestOrder
    /// The lanes a picture shows; nil for those you chose.
    let shown: BoardLanes?

    @Environment(\.showsSymbolsAlone) private var showsSymbolsAlone

    package init(order: PullRequestOrder, shown: BoardLanes? = nil) {
        self.order = order
        self.shown = shown
    }

    package var body: some View {
        HStack(spacing: 6) {
            if !showsSymbolsAlone {
                Text("Lanes")
                    .font(size: 12)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            SegmentedPicker("Board Lanes", selection: Binding(get: { shown ?? order.lanes }, set: { order.setLanes($0) }), segments: [
                .init(.missions, title: BoardLanes.missions.title, systemImage: "rectangle.stack"),
                .init(.none, title: BoardLanes.none.title, systemImage: "rectangle"),
            ])
            .fixedSize()
        }
        .help("Lanes: one for each mission, or None, every card in one")
    }
}
