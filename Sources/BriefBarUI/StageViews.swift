import AppKit
import BriefBarCore
import SwiftUI

// MARK: How a stage looks

extension PullRequestStage {
    /// Its color, as the group or state it's closest to reads: Copilot's pink while its work goes on, Needs You's orange for
    /// your review, Waiting's blue for a teammate's, Ready to Complete's green, grey while it waits, Done's purple.
    package var nsColor: NSColor {
        switch self {
        case .inProgress: .systemPink
        case .yourReview: .systemOrange
        case .teammateReview: .systemBlue
        case .canMerge: .systemGreen
        case .waits: .systemGray
        case .merged: .systemPurple
        }
    }

    package var color: Color { Color(nsColor: nsColor) }

    /// Its color for words, such as its pill's name: `color` is for symbols and fills, and too light for words on a light
    /// background, so in light mode it's darker, and in dark mode lighter, to read on its own fill.
    package var textColor: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            switch self {
            case .inProgress: return isDark ? NSColor(srgbRed: 1, green: 0.56, blue: 0.70, alpha: 1)
                : NSColor(srgbRed: 0.70, green: 0.08, blue: 0.34, alpha: 1)
            case .yourReview: return isDark ? .systemOrange : NSColor(srgbRed: 0.71, green: 0.28, blue: 0.03, alpha: 1)
            case .teammateReview: return isDark ? NSColor(srgbRed: 0.42, green: 0.71, blue: 1, alpha: 1)
                : NSColor(srgbRed: 0.04, green: 0.35, blue: 0.79, alpha: 1)
            case .canMerge: return isDark ? .systemGreen : NSColor(srgbRed: 0.12, green: 0.48, blue: 0.21, alpha: 1)
            case .waits: return isDark ? NSColor(srgbRed: 0.76, green: 0.76, blue: 0.79, alpha: 1)
                : NSColor(srgbRed: 0.33, green: 0.33, blue: 0.36, alpha: 1)
            case .merged: return isDark ? NSColor(srgbRed: 0.80, green: 0.63, blue: 1, alpha: 1)
                : NSColor(srgbRed: 0.47, green: 0.20, blue: 0.66, alpha: 1)
            }
        })
    }
}

/// A stage, as a pill: its symbol and name in its color, on its color, with ⌄ where a click opens its menu. Only how it
/// looks: `PullRequestStagePill` opens the menu, and a row that's a button puts the menu over it (`stageControls`).
package struct StagePillLabel: View {
    private let stage: PullRequestStage
    private let opensMenu: Bool

    package init(_ stage: PullRequestStage, opensMenu: Bool = true) {
        self.stage = stage
        self.opensMenu = opensMenu
    }

    package var body: some View {
        HStack(spacing: 3) {
            Image(systemName: stage.symbol)
                .font(size: 9, weight: .bold)
            Text(stage.title)
            if opensMenu {
                Image(systemName: "chevron.down")
                    .font(size: 7, weight: .bold)
                    .opacity(0.7)
            }
        }
        .font(size: 10.5, weight: .semibold)
        .lineLimit(1)
        .foregroundStyle(stage.textColor)
        .padding(.leading, 5)
        .padding(.trailing, opensMenu ? 5 : 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(stage.color.opacity(0.17)))
        .overlay(Capsule().strokeBorder(stage.color.opacity(0.7), lineWidth: 1))
        .fixedSize()
    }
}

/// A pull request's stage, where its pill can open its own menu, because what it's on isn't a button, such as its details.
/// (AzureDevOpsUI's `StagePill` is a pipeline's stage's.)
/// Merged's doesn't open: nothing changes it.
package struct PullRequestStagePill: View {
    private let ref: ItemRef
    private let reading: StageReading
    @ObservedObject private var order: PullRequestOrder
    private let now: Date

    package init(ref: ItemRef, reading: StageReading, order: PullRequestOrder, now: Date = Date()) {
        self.ref = ref
        self.reading = reading
        self.order = order
        self.now = now
    }

    package var body: some View {
        if reading.stage == .merged {
            StagePillLabel(.merged, opensMenu: false)
                .help(StageText.sentence(reading, now: now, name: order.name(of:)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Stage: Merged")
        } else {
            Menu {
                StageMenuItems(ref: ref, order: order, now: now)
            } label: {
                StagePillLabel(reading.stage)
            }
            .labelMenuStyle()
            .fixedSize()
            .help(StageText.sentence(reading, now: now, name: order.name(of:)) + "\nClick to change it")
            .stageAccessibility(reading, order: order, now: now)
        }
    }
}

extension View {
    /// What VoiceOver says of a stage's pill, a menu button: its stage, then why and who set it.
    fileprivate func stageAccessibility(_ reading: StageReading, order: PullRequestOrder, now: Date) -> some View {
        accessibilityLabel("Stage: \(reading.stage.title)")
            .accessibilityValue(StageWords.spokenWhy(reading, order: order, now: now))
            .accessibilityHint("Opens a menu to change it")
    }
}

/// What a stage says, as VoiceOver hears it.
package enum StageWords {
    /// "‘Cart’ finished, worked out by BriefBar", without the quotes VoiceOver would read.
    @MainActor
    package static func spokenWhy(_ reading: StageReading, order: PullRequestOrder, now: Date) -> String {
        SpokenText.unquoted(StageText.why(reading, name: order.name(of:)) + ", " + StageText.spokenWho(reading, now: now, name: order.name(of:)))
    }

    /// For a row's or a card's value: "Your review, ‘Cart’ finished, worked out by BriefBar".
    @MainActor
    package static func spoken(_ reading: StageReading, order: PullRequestOrder, now: Date) -> String {
        reading.stage.title + ", " + spokenWhy(reading, order: order, now: now)
    }
}

// MARK: Its menu

/// A pull request's stage's menu, its pill's and Stage ▸ in its row's menus: what it is and why, the three stages you can
/// set, checked as it's in one, the two only BriefBar sets, dimmed with why, then Finished My Review, Put Yours Back and Let
/// BriefBar Decide, as they apply. Undo heads it while your last change was to it.
package struct StageMenuItems: View {
    private let ref: ItemRef
    @ObservedObject private var order: PullRequestOrder
    private let now: Date

    package init(ref: ItemRef, order: PullRequestOrder, now: Date = Date()) {
        self.ref = ref
        self.order = order
        self.now = now
    }

    package var body: some View {
        if let reading = order.stage(of: ref) {
            if let change = order.lastChange, change.ref == ref {
                Button("Undo: \(change.words)") { StageCommand.undo(order) }
                Divider()
            }
            Text(StageText.sentence(reading, now: now, name: order.name(of:)))
            Divider()
            ForEach(PullRequestStage.settable, id: \.self) { stage in
                Toggle(isOn: Binding(
                    get: { reading.stage == stage && reading.isOnBoard },
                    set: { isOn in if isOn { StageCommand.set(stage, of: ref, order: order) } }
                )) {
                    Label(stage.title, systemImage: stage.symbol)
                }
            }
            ForEach([PullRequestStage.canMerge, .waits], id: \.self) { stage in
                Button {} label: {
                    Label(stage.title, systemImage: stage.symbol)
                    if let why = StageText.whyNotSettable(stage) { Text(why) }
                }
                .disabled(true)
            }
            if reading.stage == .yourReview || reading.replaced != nil || reading.isSetByYou {
                Divider()
            }
            if reading.stage == .yourReview {
                Button("Finished My Review → Teammate's Review") { StageCommand.finishedReview(ref, order: order) }
            }
            if let yours = reading.replaced {
                Button(StageText.putBack(yours, now: now)) { StageCommand.putYoursBack(ref, order: order) }
            }
            if reading.isSetByYou {
                Button("Let BriefBar Decide") { StageCommand.letBriefBarDecide(ref, order: order) }
            }
        }
    }
}

/// What VoiceOver offers on a row or a card to change its stage, in its rotor: Finished My Review, each stage you can move
/// it to, Put Yours Back and Let BriefBar Decide, as they apply.
package struct StageAccessibilityActions: View {
    private let ref: ItemRef
    @ObservedObject private var order: PullRequestOrder

    package init(ref: ItemRef, order: PullRequestOrder) {
        self.ref = ref
        self.order = order
    }

    package var body: some View {
        if let reading = order.stage(of: ref), reading.stage != .merged {
            if reading.stage == .yourReview {
                Button("Finished My Review") { StageCommand.finishedReview(ref, order: order) }
            }
            ForEach(PullRequestStage.settable.filter { $0 != reading.stage || !reading.isOnBoard }, id: \.self) { stage in
                Button("Move to \(stage.menuTitle)") { StageCommand.set(stage, of: ref, order: order) }
            }
            if reading.replaced != nil {
                Button("Put Yours Back") { StageCommand.putYoursBack(ref, order: order) }
            }
            if reading.isSetByYou {
                Button("Let BriefBar Decide") { StageCommand.letBriefBarDecide(ref, order: order) }
            }
        }
    }
}

/// Changes a stage as you ask, and says what became of it to VoiceOver: where it is now and where Undo is, or why it
/// couldn't be, with a beep.
@MainActor
package enum StageCommand {
    package static func set(_ stage: PullRequestStage, of ref: ItemRef, order: PullRequestOrder) {
        tell(order.setStage(stage, of: ref), ref: ref, order: order)
    }

    package static func finishedReview(_ ref: ItemRef, order: PullRequestOrder) {
        tell(order.finishedReview(ref), ref: ref, order: order)
    }

    package static func putYoursBack(_ ref: ItemRef, order: PullRequestOrder) {
        tell(order.putYoursBack(ref), ref: ref, order: order)
    }

    package static func letBriefBarDecide(_ ref: ItemRef, order: PullRequestOrder) {
        order.letBriefBarDecide(ref)
        tell(.done, ref: ref, order: order)
    }

    package static func undo(_ order: PullRequestOrder) {
        guard let ref = order.lastChange?.ref else { return }
        order.undo()
        let stage = order.stage(of: ref)?.stage.title.lowercased()
        SpokenText.announce("Undone" + (stage.map { ": \(ref.shortOrderLabel) is in \($0) again" } ?? ""))
    }

    private static func tell(_ outcome: StageChange.Outcome, ref: ItemRef, order: PullRequestOrder) {
        switch outcome {
        case .done:
            guard let reading = order.stage(of: ref) else { return }
            let place = reading.isOnBoard ? "is in \(reading.stage.title) now" : "is off your board now"
            SpokenText.announce("\(ref.shortOrderLabel) \(place). Undo is in its stage's menu.")
        case .unchanged:
            break
        case .refused(let why):
            NSSound.beep()
            SpokenText.announce(why)
        }
    }
}

// MARK: Finished My Review

/// Finished My Review, as a button follows the pill of a pull request in Your review: only how it looks, for a row that's
/// a button, which puts the button over it (`stageControls`).
package struct FinishedReviewLabel: View {
    package init() {}

    package var body: some View {
        HStack(spacing: 3) {
            Text("Finished My Review")
            Image(systemName: "arrow.right")
                .font(size: 8.5, weight: .bold)
        }
        .font(size: 10.5, weight: .semibold)
        .lineLimit(1)
        .foregroundStyle(PullRequestStage.teammateReview.textColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(PullRequestStage.teammateReview.color.opacity(0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(PullRequestStage.teammateReview.color.opacity(0.55), lineWidth: 1)
        )
        .fixedSize()
    }
}

/// Finished My Review, where what it's on isn't a button: it's your teammates' turn now.
package struct FinishedReviewButton: View {
    private let ref: ItemRef
    private let order: PullRequestOrder

    package init(ref: ItemRef, order: PullRequestOrder) {
        self.ref = ref
        self.order = order
    }

    package var body: some View {
        Button {
            StageCommand.finishedReview(ref, order: order)
        } label: {
            FinishedReviewLabel()
        }
        .buttonStyle(.plain)
        .help(Self.help)
    }

    package static let help = "You reviewed it: it's your teammates' turn. Moves it to Teammate's review"
}

// MARK: Over a row that's a button

/// The parts of a stage line that are controls of their own.
package enum StageSpot: Hashable, Sendable {
    case pill
    case finishedReview
}

/// Where a row's stage pill and Finished My Review are, for their own controls over a row that's a button, which takes
/// every click on its label, as `ParentTag` does.
package struct StageSpots: PreferenceKey {
    package static var defaultValue: [StageSpot: Anchor<CGRect>] { [:] }

    package static func reduce(value: inout [StageSpot: Anchor<CGRect>], nextValue: () -> [StageSpot: Anchor<CGRect>]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

extension View {
    /// Marks where a stage line's control is, inside a row that's a button: `stageControls` on the row puts the control there.
    package func stageSpot(_ spot: StageSpot) -> some View {
        anchorPreference(key: StageSpots.self, value: .bounds) { [spot: $0] }
    }

    /// Over a row that's a button: the stage pill's menu and Finished My Review, each where its spot is in the row; nothing
    /// without Pull Request Order.
    package func stageControls(ref: ItemRef, order: PullRequestOrder?, now: Date) -> some View {
        overlayPreferenceValue(StageSpots.self) { spots in
            if let order, !spots.isEmpty {
                StageControlsOverRow(spots: spots, ref: ref, order: order, now: now)
            }
        }
    }
}

private struct StageControlsOverRow: View {
    let spots: [StageSpot: Anchor<CGRect>]
    let ref: ItemRef
    @ObservedObject var order: PullRequestOrder
    let now: Date

    var body: some View {
        if let reading = order.stage(of: ref) {
            GeometryReader { proxy in
                if let pill = spots[.pill], reading.stage != .merged {
                    let frame = proxy[pill]
                    Menu {
                        StageMenuItems(ref: ref, order: order, now: now)
                    } label: {
                        Color.clear.contentShape(Capsule())
                            .frame(width: frame.width, height: frame.height)
                    }
                    .labelMenuStyle()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .help(StageText.sentence(reading, now: now, name: order.name(of:)) + "\nClick to change it")
                    .stageAccessibility(reading, order: order, now: now)
                }
                if let finished = spots[.finishedReview], reading.stage == .yourReview {
                    let frame = proxy[finished]
                    Button {
                        StageCommand.finishedReview(ref, order: order)
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .help(FinishedReviewButton.help)
                    .accessibilityLabel("Finished My Review")
                }
            }
        }
    }
}

// MARK: Undo

/// What your last change to a stage was, with Undo and ✕, under what shows the pull requests it's about: a mission's card
/// or its details. Nothing once you change something else, dismiss it, or Undo.
package struct StageUndoLine: View {
    private let refs: Set<ItemRef>
    @ObservedObject private var order: PullRequestOrder

    /// - Parameter refs: the pull requests it's under.
    package init(refs: Set<ItemRef>, order: PullRequestOrder) {
        self.refs = refs
        self.order = order
    }

    package var body: some View {
        if let change = order.lastChange, refs.contains(change.ref) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .foregroundStyle(.secondary)
                Text(change.words + ".")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    StageCommand.undo(order)
                } label: {
                    Text("Undo").foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Button {
                    order.dismissLastChange()
                } label: {
                    Image(systemName: "xmark")
                        .font(size: 9, weight: .bold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .font(size: 11)
            .accessibilityElement(children: .contain)
        }
    }
}
