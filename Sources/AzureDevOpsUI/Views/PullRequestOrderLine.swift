import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// A pull request's mission in its details, under its session's line, while Pull Request Order is on: "Fix the payments
/// bugs · 1st of 4 · ✎ Next to merge", with what you changed and who changed it since, and its Mission menu; "Not in a
/// mission" when it's in none. The mission's name shows it By Mission. Put Yours Back once an order changed its place after
/// you did, and what you changed last of it, with Undo.
struct PullRequestOrderLine: View {
    let item: PRSnapshot

    @EnvironmentObject private var services: AppServices

    var body: some View {
        OrderLineContent(item: item, order: services.pullRequestOrder)
    }
}

private struct OrderLineContent: View {
    let item: PRSnapshot
    @ObservedObject var order: PullRequestOrder

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if order.isOn {
            let ref = item.key.linkRef
            let mission = OrderBoard.mission(of: ref, in: order.missions)
            let step = mission.flatMap { mission in (mission.steps + mission.attached).first { $0.ref == ref } }
            let names = order.names
            // What your changes say, and an order's later one; that one too where it took it out of every mission.
            let notes = step.map { step in step.notes.filter(\.isAboutChanges).map { OrderText.note($0, of: ref, names: names) } }
                ?? order.changes[ref]?.overridden(in: order.orders).map { [OrderText.overridden($0, of: ref, names: names)] } ?? []
            let canPutBack = order.changes[ref] != nil && order.choices(for: ref, in: mission?.key).canPutBack
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: step?.isYours == true ? "pencil" : "point.3.connected.trianglepath.dotted")
                        .font(size: 12, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        headline(mission: mission, step: step, names: names)
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            Text(note)
                                .font(size: 11.5)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if canPutBack {
                            Button("Put Yours Back") {
                                MissionMenuContext(order: order, mission: mission?.key, undo: .details).change(.putBack(ref))
                            }
                            .buttonStyle(.borderless)
                            .font(size: 11.5)
                            .help("Your change holds again, over the later one of its order")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let context = MissionMenuContext.of(ref, order: order, mission: mission?.key, undo: .details) {
                        MissionMenu(ref, context: context)
                            .menuStyle(.button)
                            .buttonStyle(.borderless)
                            .font(size: 11.5)
                            .fixedSize()
                            .help("Set it as next to merge, choose what it merges after, or move it to another mission")
                    }
                }
                OrderUndoLine(order: order, about: [ref])
                    .padding(.leading, 24)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 7)
            .background(GlassCard(cornerRadius: 10, raised: true))
            .accessibilityElement(children: .contain)
        }
    }

    /// "Fix the payments bugs · 1st of 4 · Next to merge" on one line where it fits, else its name, then where it stands; its
    /// mission's name showing it By Mission. Or "Not in a mission".
    @ViewBuilder
    private func headline(mission: OrderMission?, step: OrderStep?, names: OrderNames) -> some View {
        if let mission {
            let title = OrderText.title(of: mission, name: order.name(of:))
            let numbered = mission.steps.filter { $0.number != nil }.count
            let place = step?.number.map { "\(Self.ordinal($0)) of \(numbered)" }
            let rest = [place, step.flatMap { OrderText.capsule($0) }].compactMap { $0 }.joined(separator: " · ")
            let button = Button(title) {
                settings.pullRequestOrder = .byMission
                order.reveal(mission.key)
            }
            .buttonStyle(.plain)
            .font(size: 12.5, weight: .semibold)
            .lineLimit(1)
            .help("Show its mission By Mission")
            .accessibilityHint("Shows its mission By Mission")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    button
                    if !rest.isEmpty {
                        Text("· " + rest)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    button
                    if !rest.isEmpty {
                        Text(rest)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(size: 12.5)
            .help(step.flatMap { OrderText.sentence(of: $0, names: names) } ?? title)
        } else {
            Text("Not in a mission")
                .font(size: 12.5)
                .foregroundStyle(.secondary)
        }
    }

    /// "1st", "2nd", "3rd", "4th".
    static func ordinal(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}

extension OrderNote {
    /// Whether it's about your changes, or about an order's later change or a stacked branch going against one of yours: what
    /// the details' order line says.
    var isAboutChanges: Bool {
        switch self {
        case .yourNext, .yourAfter, .tookAway, .moved, .placementGone, .afterYourNext, .setAside, .yoursDoesntHold, .nextDoesntHold,
             .orderChangedIt:
            return true
        case .showsAgainst, .orderDisagrees, .alsoIn, .stackedWith, .goesRound:
            return false
        }
    }
}
