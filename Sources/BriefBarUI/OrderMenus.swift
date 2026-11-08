import BriefBarCore
import SwiftUI

// Changing a mission yourself (`OrderChanges`): a pull request's Mission menu, in its row's menu, its details', a Map node's
// and a Board card's, with the same as VoiceOver's actions; and the line that says what you did, with Undo. Azure DevOps'
// pull requests only for now: GitHub's show as they always have.

/// Where a pull request's Mission menu speaks from: the order, the mission whose card it's in, and where the Undo line
/// shows once you changed something, for VoiceOver to say.
package struct MissionMenuContext {
    /// Where the Undo line shows.
    package enum UndoPlace {
        /// By Mission: in the mission's card, or its lane on the Board, or at the top of the list when none has it.
        case byMission
        /// At the top of the list, as By Status shows it, and the Board with a lane for every card.
        case top
        /// In the pull request's details, beside its mission.
        case details

        /// Where the Board shows the Undo of a change to a mission: in its mission's lane, or at the top with a lane for
        /// every card, which shows no mission's.
        package static func onBoard(_ lanes: BoardLanes) -> UndoPlace {
            lanes == .none ? .top : .byMission
        }
    }

    package let order: PullRequestOrder
    /// The mission whose card it's in, where it's in two; nil for the first that has it.
    package let mission: MissionKey?
    package let undo: UndoPlace

    package init(order: PullRequestOrder, mission: MissionKey? = nil, undo: UndoPlace = .byMission) {
        self.order = order
        self.mission = mission
        self.undo = undo
    }

    /// Only for a pull request of Azure DevOps, while Pull Request Order is on.
    @MainActor
    package static func of(_ ref: ItemRef, order: PullRequestOrder, mission: MissionKey? = nil, undo: UndoPlace = .byMission)
        -> MissionMenuContext? {
        guard order.isOn, ref.kind == .pullRequest else { return nil }
        return MissionMenuContext(order: order, mission: mission, undo: undo)
    }

    /// Makes a change, and says it to VoiceOver.
    @MainActor
    package func change(_ edit: OrderEdit) {
        guard let done = order.change(edit) else { return }
        AccessibilityNotification.Announcement(spoken(done, of: edit)).post()
    }

    /// What VoiceOver hears of a change you made: what it did, and where its Undo is; and, for a pull request set as next
    /// to merge in one of two missions whose orders held it, where it still waits.
    @MainActor
    package func spoken(_ done: OrderLastChange, of edit: OrderEdit) -> String {
        let spoken = OrderText.spoken(done.said, undo: done.canUndo ? undoPlace(of: edit, in: done.mission) : nil)
        guard case .setNext(let ref, let mission, true) = edit,
              let still = BoardText.stillWaits(ref, besides: mission, in: order.missions, names: order.names) else { return spoken }
        return spoken + " " + OrderText.spoken(SpokenText.unquoted(still), undo: nil) + "."
    }

    /// Where VoiceOver says a change's Undo is: in the mission's card or lane, or at the top of the list where none shows
    /// it.
    /// - Parameter mission: the mission whose card shows the Undo line; nil for none.
    package func undoPlace(of edit: OrderEdit, in mission: MissionKey?) -> String {
        switch undo {
        case .byMission:
            if mission == nil {
                "at the top of the list"
            } else if case .move = edit {
                "in the mission you moved it from"
            } else {
                "in its mission"
            }
        case .top: "at the top of the list"
        case .details: "beside it"
        }
    }
}

extension MissionMenuContext {
    /// Set as Next to Merge in a mission, as dropping a card from Waits onto Can merge on the Board does, and says so to
    /// VoiceOver, with where its Undo is: in its mission's lane, at the top with a lane for every card, or beside its
    /// mission in the details, while they cover the Board.
    @MainActor
    package static func setAsNext(_ ref: ItemRef, in mission: MissionKey, order: PullRequestOrder, undo: UndoPlace = .byMission) {
        of(ref, order: order, mission: mission, undo: undo)?.change(.setNext(ref, in: mission, true))
    }
}

/// Mission ▸ in a pull request's menu: Set as Next to Merge, Merge After ▸, Move to Mission ▸, Put Yours Back and Undo Your
/// Changes to It. In no mission, only Move to Mission.
package struct MissionMenu: View {
    private let ref: ItemRef
    private let context: MissionMenuContext

    package init(_ ref: ItemRef, context: MissionMenuContext) {
        self.ref = ref
        self.context = context
    }

    package var body: some View {
        Menu("Mission") {
            MissionMenuItems(ref, context: context, order: context.order)
        }
    }
}

/// The Mission menu's items, as it opens: what it offers is read then.
struct MissionMenuItems: View {
    let ref: ItemRef
    let context: MissionMenuContext
    @ObservedObject var order: PullRequestOrder

    init(_ ref: ItemRef, context: MissionMenuContext, order: PullRequestOrder) {
        self.ref = ref
        self.context = context
        self.order = order
    }

    var body: some View {
        let choices = order.choices(for: ref, in: context.mission)
        if let mission = choices.mission, let next = choices.next {
            switch next {
            case .offered, .isSet:
                Toggle("Set as Next to Merge", isOn: Binding(get: { next == .isSet }, set: { on in
                    context.change(.setNext(ref, in: mission, on))
                }))
            case .stacked(let other):
                Button("Set as Next to Merge: Stacked on \(other.shortOrderLabel)") {}
                    .disabled(true)
            case .retarget(let merged, _):
                Button("Set as Next to Merge: \(merged.shortOrderLabel) Merged, Retarget It First") {}
                    .disabled(true)
            case .ended:
                EmptyView()
            }
            if !choices.prerequisites.isEmpty {
                Menu("Merge After") {
                    ForEach(choices.prerequisites, id: \.ref) { prerequisite in
                        prerequisiteItem(prerequisite, in: mission)
                    }
                }
            }
        }
        Menu("Move to Mission") {
            // Those with Azure DevOps' pull requests, which this page lists.
            let targets = choices.targets.filter { key in
                key == choices.mission || order.missions.first { $0.key == key }?.shows([.pullRequest]) == true
            }
            ForEach(targets, id: \.self) { key in
                Toggle(targetTitle(key), isOn: Binding(get: { choices.mission == key }, set: { on in
                    guard on else { return }
                    context.change(.move([ref], to: .into(key), from: choices.mission))
                }))
            }
            if !targets.isEmpty {
                Divider()
            }
            Button("New Mission") {
                context.change(.move([ref], to: .into(.mine(UUID())), from: choices.mission))
            }
            Toggle("Not in a Mission", isOn: Binding(get: { choices.mission == nil }, set: { on in
                guard on else { return }
                context.change(.move([ref], to: .outside, from: choices.mission))
            }))
        }
        if choices.canPutBack || choices.canUndo {
            Divider()
        }
        if choices.canPutBack {
            Button("Put Yours Back") { context.change(.putBack(ref)) }
        }
        if choices.canUndo {
            Button("Undo Your Changes to It") { context.change(.undo(ref)) }
        }
    }

    @ViewBuilder
    private func prerequisiteItem(_ prerequisite: MissionChoices.Prerequisite, in mission: MissionKey) -> some View {
        let label = [prerequisite.ref.orderLabel(near: ref), order.name(of: prerequisite.ref)].compactMap { $0 }.joined(separator: " ")
        switch prerequisite.state {
        case .unchecked, .checked:
            Toggle(label, isOn: Binding(get: { prerequisite.state == .checked }, set: { on in
                context.change(.mergeAfter(ref, prerequisite.ref, in: mission, on))
            }))
        case .stacked:
            Toggle("\(label): Stacked, Retarget It to Change That", isOn: .constant(true))
                .disabled(true)
        case .waitsForIt:
            Button("\(label): Waits for It") {}
                .disabled(true)
        }
    }

    /// A mission as Move to Mission names it: by the name its header shows, with its kind but for a session's order.
    private func targetTitle(_ key: MissionKey) -> String {
        guard let mission = order.missions.first(where: { $0.key == key }) else { return key.description }
        let title = order.title(of: mission)
        let kind: String? = switch mission.kind {
        case .declared: nil
        default: OrderText.kind(of: mission)
        }
        return [title, kind].compactMap { $0 }.joined(separator: " · ")
    }
}

extension View {
    /// A pull request's Mission menu's main items as VoiceOver's actions: Set as Next to Merge, Put Yours Back and Undo
    /// Your Changes to It. The rest is in its menu, which works out Merge After's as it opens.
    /// - Parameter offersNext: Set as Next to Merge and Not Next to Merge are among them; false where the view offers its
    ///   own, as a Board card that waits does.
    @MainActor
    package func missionActions(_ ref: ItemRef, context: MissionMenuContext?, offersNext: Bool = true) -> some View {
        accessibilityActions {
            if let context {
                let choices = context.order.choices(for: ref, in: context.mission, withPrerequisites: false)
                if offersNext, let mission = choices.mission, let next = choices.next, next == .offered || next == .isSet {
                    Button(next == .isSet ? "Not Next to Merge" : "Set as Next to Merge") {
                        context.change(.setNext(ref, in: mission, next != .isSet))
                    }
                }
                if choices.canPutBack {
                    Button("Put Yours Back") { context.change(.putBack(ref)) }
                }
                if choices.canUndo {
                    Button("Undo Your Changes to It") { context.change(.undo(ref)) }
                }
            }
        }
    }
}

/// What you did last, with Undo and ×: "You set !4079 as next to merge.  Undo  ×"; and above it, why BriefBar didn't make the
/// change you asked for after that, with its own ×. Each until your next change, or until you dismiss it.
package struct OrderUndoLine: View {
    @ObservedObject var order: PullRequestOrder
    /// Only what's about these, such as a pull request's in its details; nil for any.
    let refs: Set<ItemRef>?
    /// Only what shows in this mission's card; nil for any.
    let mission: MissionKey?
    /// Only what no card of these missions shows; nil for any.
    let outside: Set<MissionKey>?

    package init(order: PullRequestOrder, about refs: Set<ItemRef>? = nil, in mission: MissionKey? = nil, outside: Set<MissionKey>? = nil) {
        self.order = order
        self.refs = refs
        self.mission = mission
        self.outside = outside
    }

    /// Whether one shows here.
    static func shows(_ last: OrderLastChange, about refs: Set<ItemRef>?, in mission: MissionKey?, outside: Set<MissionKey>?) -> Bool {
        guard refs.map({ !$0.isDisjoint(with: last.refs) }) ?? true, mission.map({ $0 == last.mission }) ?? true else { return false }
        guard let outside, let shown = last.mission else { return true }
        return !outside.contains(shown)
    }

    package var body: some View {
        // Each slot in its place: why BriefBar didn't make the change you asked for last, above what you did before it.
        let refusal = order.refusal.flatMap { Self.shows($0, about: refs, in: mission, outside: outside) ? $0 : nil }
        let last = order.lastOrderChange.flatMap { Self.shows($0, about: refs, in: mission, outside: outside) ? $0 : nil }
        if refusal != nil || last != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let refusal {
                    line(refusal)
                }
                if let last {
                    line(last)
                }
            }
        }
    }

    private func line(_ last: OrderLastChange) -> some View {
        HStack(spacing: 8) {
            Image(systemName: last.canUndo ? "pencil" : "exclamationmark.circle")
                .foregroundStyle(last.canUndo ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
            Text(last.said + ".")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if last.canUndo {
                Button("Undo") { undo() }
                    .buttonStyle(.borderless)
                    .help("Put back what this change did")
            }
            Spacer(minLength: 4)
            Button {
                if last.canUndo {
                    order.dismissLastChange()
                } else {
                    order.dismissRefusal()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(size: 9, weight: .bold)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(last.canUndo ? "Hide this: your change stays" : "Hide this")
            .accessibilityLabel(last.canUndo ? "Hide, keeping the change" : "Hide")
        }
        .font(size: 11.5)
        .accessibilityElement(children: .contain)
    }

    private func undo() {
        guard order.undo() else { return }
        AccessibilityNotification.Announcement("Undone").post()
    }
}
