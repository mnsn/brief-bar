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

/// A mission's title, what kind it is, its progress and its sessions: ★ Focus, "Fix the payments bugs · payments-api", a
/// bar with one segment for each pull request, "1 of 5 merged", "2 sessions ⌄", and its menu.
package struct MissionHeader: View {
    let mission: OrderMission
    @ObservedObject var order: PullRequestOrder
    /// Its pull requests' repository, as the page names it.
    let place: String?

    @LocalState private var confirmsForget = false
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
            if !mission.isFamily {
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
    }

    private var title: String {
        OrderText.title(of: mission, name: order.name(of:))
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
        let details = [place, OrderText.kind(of: mission), mission.isStale ? OrderText.stale : nil].compactMap { $0 }
        return HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !details.isEmpty {
                Text("· " + details.joined(separator: " · "))
                    .foregroundStyle(mission.isStale ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
        }
        .truncationMode(.tail)
        .help(OrderText.told(mission, name: order.name(of:)) ?? title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var menu: some View {
        let yours = order.changes(in: mission)
        return Menu {
            Button(mission.isFocused ? "Stop Focusing" : "Focus on It") {
                order.setFocus(mission.isFocused ? nil : mission.key)
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
