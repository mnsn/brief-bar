import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// Under a pull request's heading, in its details, while Pull Request Order shows its stage: the steps of its flow, In
/// progress › Your review › Teammate's review › Can merge, wrapping where the details are narrow, the one it's in filled in
/// its stage's color and those before it ticked, Merged ticking them all; why it's there, since when and who set it; its
/// next step's button; and its stage's menu. A click on one of the first three moves it there; Can merge's says when it
/// comes, or, while it waits, what its order puts first. Someone else's that you finished reviewing says so, off your
/// board.
struct PullRequestStageTrack: View {
    let item: PRSnapshot
    @ObservedObject var ordering: PullRequestOrder
    let now: Date
    /// Opens it in Azure DevOps, to add reviewers or complete it there.
    let openInAzureDevOps: () -> Void

    var body: some View {
        if ordering.isOn, let reading = ordering.stage(of: item.key.linkRef) {
            track(reading)
        } else if ordering.isOn, ordering.lastStageChange?.ref == item.key.linkRef {
            // Your last change left it without a stage, such as someone else's that asks nothing of you once BriefBar
            // decides: Undo stays where you made it.
            StageUndoLine(refs: [item.key.linkRef], order: ordering)
                .font(size: 12)
                .padding(.vertical, 2)
        }
    }

    private func track(_ reading: StageReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if reading.isOnBoard {
                FlowLayout(spacing: 4, lineSpacing: 5) { steps(reading) }
            }
            words(reading)
            actions(reading)
            StageUndoLine(refs: [item.key.linkRef], order: ordering)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(reading.stage.color.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(reading.stage.color.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stage")
    }

    // MARK: Its steps

    /// The four steps of its flow: Waits stands where Can merge does, by what it waits for.
    private static let track: [PullRequestStage] = [.inProgress, .yourReview, .teammateReview, .canMerge]

    /// Each step, with › after it but the last, so a line that wraps ends on one.
    @ViewBuilder
    private func steps(_ reading: StageReading) -> some View {
        ForEach(Array(Self.track.enumerated()), id: \.offset) { index, stage in
            HStack(spacing: 4) {
                step(stage, in: reading)
                if index < Self.track.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(size: 8, weight: .bold)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private func step(_ stage: PullRequestStage, in reading: StageReading) -> some View {
        let state: StageTrackStep.Place = reading.stage == .merged || stage.step < reading.stage.step ? .done
            : stage.step == reading.stage.step ? .current : .later
        // Its own stage where the track's is Can merge's: Waits, by what it waits for.
        let shown = stage == .canMerge && reading.stage == .waits ? PullRequestStage.waits : stage
        let title = shown == .waits ? StageText.why(reading, name: ordering.name(of:)) : shown.title
        let label = StageTrackStep(stage: shown, title: title, place: state)
        let spoken = "\(shown == .waits ? "Waits for another PR, " + title : shown.title), "
            + (state == .done ? "done" : state == .current ? "current" : "to come")
        // Someone else's asks for its own reviews: Finished My Review takes it off your board instead.
        let othersReviews = stage == .teammateReview ? ordering.whyNotTeammateReview(item.key.linkRef) : nil
        // Merged ticks them all, and nothing moves it on.
        if stage.isSettable, othersReviews == nil, state != .current, reading.stage != .merged {
            Button {
                StageCommand.set(stage, of: item.key.linkRef, order: ordering)
            } label: {
                label.contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Move it to \(stage.title)")
            .accessibilityLabel(spoken)
            .accessibilityHint("Moves it to \(stage.title)")
        } else {
            label
                .help(othersReviews.map { state == .current ? StageText.sentence(reading, now: now, name: ordering.name(of:)) : $0 }
                    ?? (stage == .canMerge ? (shown == .waits ? title : StageText.canMergeHelp)
                        : StageText.sentence(reading, now: now, name: ordering.name(of:))))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    // MARK: Why, and who set it

    private func words(_ reading: StageReading) -> some View {
        let name = { (ref: ItemRef) in ordering.name(of: ref) }
        var line = StageText.why(reading, name: name)
        if let who = StageText.who(reading, now: now, name: name) {
            line += " · " + who
        } else if let since = reading.since, reading.why.saysWhen {
            line += " · " + Elapsed.short(since: since, now: now)
        }
        return Text(line)
            .font(size: 12)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(SpokenText.unquoted(reading.stage.title + ": " + StageWords.spokenWhy(reading, order: ordering, now: now)))
    }

    // MARK: What to do

    @ViewBuilder
    private func actions(_ reading: StageReading) -> some View {
        let ref = item.key.linkRef
        FlowLayout(spacing: 8, lineSpacing: 6) {
            if reading.isOnBoard {
                switch reading.stage {
                case .yourReview:
                    Button {
                        StageCommand.finishedReview(ref, order: ordering)
                    } label: {
                        ControlLabel("Finished My Review", systemImage: "arrow.right")
                    }
                    .glassButtonStyle()
                    .help(FinishedReviewButton.help(for: ref, order: ordering))
                case .teammateReview where reading.why == .findReviewer:
                    Button(action: openInAzureDevOps) {
                        ControlLabel("Add Reviewers in Azure DevOps", systemImage: "arrow.up.forward.app")
                    }
                    .glassButtonStyle()
                    .help("Nobody but you is asked to review it: add reviewers in Azure DevOps")
                case .canMerge:
                    Button(action: openInAzureDevOps) {
                        ControlLabel("Complete in Azure DevOps", systemImage: "arrow.up.forward.app")
                    }
                    .glassButtonStyle()
                    .help("Azure DevOps says it's ready to complete")
                default:
                    EmptyView()
                }
            }
            if let yours = reading.replaced {
                Button {
                    StageCommand.putYoursBack(ref, order: ordering)
                } label: {
                    ControlLabel("Put Yours Back")
                }
                .glassButtonStyle()
                .help(StageText.putBack(yours, now: now))
            }
            if reading.stage != .merged {
                Menu {
                    StageMenuItems(ref: ref, order: ordering, now: now)
                } label: {
                    HStack(spacing: 3) {
                        Text("Stage")
                        MenuChevron()
                    }
                    .font(size: 12, weight: .medium)
                    .contentShape(Rectangle())
                }
                .labelMenuStyle()
                .fixedSize()
                .help("Change its stage")
                .accessibilityLabel("Change its stage")
            }
        }
        .controlSize(.small)
        .font(size: 11)
    }
}

/// One step of a pull request's stage track: its symbol and title, filled in its stage's color while it's the one it's in.
/// Waits, which says what it waits for, keeps to one line where it fits, as the other steps do, and wraps where the track
/// is too narrow for it, as with bigger text, rather than running past the details.
struct StageTrackStep: View {
    enum Place {
        case done, current, later
    }

    let stage: PullRequestStage
    let title: String
    let place: Place

    var body: some View {
        if stage == .waits {
            ViewThatFits(in: .horizontal) {
                oneLine
                label(lines: 4, alignment: .firstTextBaseline)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            oneLine
        }
    }

    private var oneLine: some View {
        label(lines: 1, alignment: .center)
            .background(Capsule().fill(fill))
            .fixedSize()
    }

    private var fill: Color {
        place == .current ? stage.color.opacity(0.16) : Color.clear
    }

    private func label(lines: Int, alignment: VerticalAlignment) -> some View {
        HStack(alignment: alignment, spacing: 4) {
            Image(systemName: place == .done ? "checkmark.circle.fill" : place == .current ? stage.symbol : "circle")
                .font(size: 10, weight: .bold)
                .foregroundStyle(place == .current ? stage.color : Color.secondary)
            Text(stage == .waits ? Self.unbroken(title) : title)
                .font(size: 11.5, weight: place == .current ? .bold : .regular)
                .foregroundStyle(place == .current ? stage.textColor : place == .done ? Color.secondary : Color.secondary.opacity(0.8))
                .lineLimit(lines)
        }
        .padding(.horizontal, place == .current ? 6 : 2)
        .padding(.vertical, 2)
    }

    /// What it waits for, with each pull request's ! joined to its number, so a line never breaks between them.
    static func unbroken(_ title: String) -> String {
        title.replacingOccurrences(of: "!", with: "!\u{2060}")
    }
}
