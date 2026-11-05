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

    package init(step: OrderStep, mission: MissionKey? = nil, isReady: Bool, open: (() -> Void)? = nil) {
        self.step = step
        self.mission = mission
        self.isReady = isReady
        self.open = open
    }

    /// What its capsule says in full.
    package var sentence: String? {
        OrderText.sentence(of: step, isReady: isReady)
    }

    /// The row of a pull request in the missions, if one has it in its order or is stacked with it.
    /// - Parameter open: shows the mission in By Mission; nil where it shows already.
    package static func of(
        _ ref: ItemRef, in missions: [OrderMission], isReady: Bool, open: ((MissionKey) -> Void)? = nil
    ) -> OrderRowContext? {
        guard let (mission, step) = OrderBoard.step(for: ref, in: missions) else { return nil }
        let key = mission.key
        return OrderRowContext(step: step, mission: key, isReady: isReady, open: open.map { open in { open(key) } })
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

/// A row's order capsule, beside its links: "Next to merge", "After !4103 · stacked", "Any time", "Check the order". It
/// says the rest in its tooltip. From another list, a click shows its mission in By Mission.
package struct OrderCapsule: View {
    private let context: OrderRowContext

    package init(_ context: OrderRowContext) {
        self.context = context
    }

    package var body: some View {
        if let text = OrderText.capsule(context.step) {
            let tone = OrderText.tone(of: context.step, isReady: context.isReady)
            let help: String = (context.sentence ?? text) + (context.open == nil ? "" : "\nClick to show it By Mission")
            HStack(spacing: 3) {
                Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "point.3.connected.trianglepath.dotted")
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
        }
    }
}

// MARK: - The graph's marks

/// A pull request's node in the graph, for where it stands: filled for next to merge, outlined while it waits, dotted for
/// any time, ✓ once merged, an orange ! when its order needs checking.
package struct OrderNodeMark: View {
    let marker: OrderMarker
    /// Its diameter, before the text size scales it.
    var size: CGFloat = 9
    /// Dimmed while hovering lights up others.
    var isDimmed = false

    @Environment(\.textScale) private var textScale

    package init(_ marker: OrderMarker, size: CGFloat = 9, isDimmed: Bool = false) {
        self.marker = marker
        self.size = size
        self.isDimmed = isDimmed
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
            Circle().fill(Color.accentColor)
        case .waiting:
            Circle().strokeBorder(Color.secondary, lineWidth: max(1.2, diameter / 7))
        case .anyTime:
            Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: max(1.2, diameter / 7), dash: [1.6, 1.6]))
        case .merged:
            symbol("checkmark", on: .green)
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
    @LocalState private var isFull = false
    @FocusState private var isEditing: Bool
    @Environment(\.textScale) private var textScale

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
            if mission.hasOrder {
                OrderProgressBar(mission: mission)
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
            Text("BriefBar no longer shows it, and tells a session that names it that it forgot it. Its pull requests stay in your lists.")
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
                renameField
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
        .accessibilityAction(named: "Rename") { rename() }
        .accessibilityAction(named: story.map { "Show \($0)" } ?? "Show Its Story") { storyItem?.open?() }
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
        } else if order.naming(of: mission) != .briefBar, let opened = OrderText.openedUnder(mission, name: order.name(of:)) {
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

    /// Its title as a field, as Finder renames: Return keeps it, Escape doesn't, and an empty one goes back to BriefBar's.
    private var renameField: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(size: 12, weight: .semibold)
            .focused($isEditing)
            .frame(minWidth: 140 * textScale, maxWidth: 320 * textScale)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor).opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onChange(of: isEditing) { _, editing in
                // Clicking elsewhere keeps it, as in Finder.
                if !editing, isRenaming { commit() }
            }
            .onAppear {
                Task { @MainActor in isEditing = true }
            }
            .onDisappear {
                if isRenaming { stopRenaming() }
            }
            .accessibilityLabel("Mission's Name")
            .accessibilityHint("Return keeps it, and Escape doesn't. An empty name gives it BriefBar's name again.")
    }

    private func rename() {
        guard order.canRename(mission.key) else {
            isFull = true
            return
        }
        draft = title
        isRenaming = true
        order.renaming = mission.key
    }

    private func commit() {
        guard isRenaming else { return }
        stopRenaming()
        if order.rename(mission, to: draft) == .full { isFull = true }
    }

    private func cancel() {
        stopRenaming()
    }

    private func stopRenaming() {
        isRenaming = false
        if order.renaming == mission.key { order.renaming = nil }
    }

    private var menu: some View {
        Menu {
            Button(mission.isFocused ? "Stop Focusing" : "Focus on It") {
                order.setFocus(mission.isFocused ? nil : mission.key)
            }
            Divider()
            Button("Rename…") { rename() }
            if order.naming(of: mission) == .you {
                Button("Use BriefBar's Name") { order.useBriefBarsName(mission.key) }
            }
            if case .plan = mission.key {
                Divider()
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
        if case .plan(let id) = mission.key { order.forget(order: id) }
    }
}

/// A mission's progress: one segment for each of its pull requests, green once merged, grey once closed.
package struct OrderProgressBar: View {
    let mission: OrderMission

    @Environment(\.textScale) private var textScale

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
        let steps = mission.steps
        let widest = Self.widest * textScale
        Group {
            if let parts = Self.parts(steps.count) {
                HStack(spacing: parts.gap * textScale) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Capsule()
                            .fill(color(step))
                            .frame(width: parts.width * textScale, height: 4 * textScale)
                    }
                }
            } else {
                let merged = CGFloat(steps.filter { $0.status == .merged }.count) / CGFloat(steps.count)
                let closed = CGFloat(steps.filter { $0.status == .closed }.count) / CGFloat(steps.count)
                HStack(spacing: 0) {
                    Rectangle().fill(Color.green).frame(width: widest * merged)
                    Rectangle().fill(Color.gray.opacity(0.6)).frame(width: widest * closed)
                    Rectangle().fill(Color.secondary.opacity(0.25))
                }
                .frame(width: widest, height: 4 * textScale)
                .clipShape(Capsule())
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ step: OrderStep) -> Color {
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
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - List and Map

/// List | Map, in the page's header while it lists By Mission.
package struct OrderViewPicker: View {
    @ObservedObject var order: PullRequestOrder
    /// The view a picture shows; nil for the one you chose.
    let shown: OrderView?

    package init(order: PullRequestOrder, shown: OrderView? = nil) {
        self.order = order
        self.shown = shown
    }

    package var body: some View {
        SegmentedPicker("By Mission View", selection: Binding(get: { shown ?? order.view }, set: { order.setView($0) }), segments: [
            .init(.list, title: OrderView.list.title, systemImage: "list.bullet"),
            .init(.map, title: OrderView.map.title, systemImage: "map"),
        ])
        .fixedSize()
        .help("List: each mission's pull requests in their order, with the graph beside them. Map: each mission in merge waves")
    }
}
