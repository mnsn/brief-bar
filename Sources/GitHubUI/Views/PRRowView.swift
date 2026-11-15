import BriefBarCore
import BriefBarUI
import GitHubCore
import SwiftUI

/// One pull request, as Azure DevOps' rows are: its title and how long since it changed; why it's in its group, who, and
/// where it is; and, on a quiet line, where it stands in its mission and its links. Its ⋯ menu shows while you're at it
/// (`RowActivity`).
struct PRRowView: View {
    let item: GitHubPRSnapshot
    let now: Date
    var compact = false
    /// Where it stands in its mission, for its order capsule, on the window's Pull Requests page with Pull Request Order on.
    var order: OrderRowContext? = nil
    var action: () -> Void

    private let activity = RowActivity()
    @Environment(\.interfaceOptions) private var options
    @Environment(\.textScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            RowSummary(subject: linkRef)
                .padding(.leading, 8 + options.rowIconWidth * textScale + options.rowIconSpacing)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
        }
        // The row and its summary, together.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(activity.isPointedAt ? Color.primary.opacity(0.08) : .clear)
        )
        .onHover { activity.isHovered = $0 }
        .contextMenu {
            Button("Open on GitHub", action: action)
            SummarizeMenuItems(linkRef)
            LinkMenuItems(linkRef)
        }
    }

    private var row: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: options.rowIconSpacing) {
                Image(systemName: item.reason.symbol)
                    .font(size: compact ? 15 : 17)
                    .foregroundStyle(item.group.color)
                    .frame(width: options.rowIconWidth * textScale, height: 20 * textScale)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.pullRequest.title)
                            .font(size: 13, weight: .semibold)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        RowTime(Elapsed.short(since: item.since, now: now), subject: linkRef, isHovered: activity.isPointedAt)
                    }
                    if compact {
                        Text("\(item.headline) · \(item.pullRequest.reference)")
                            .font(size: options.rowDetailSize)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        // Why, who, and where, the reference cut short in its middle before the rest: its order capsule and
                        // links are on its quiet line.
                        HStack(spacing: 0) {
                            Text(subtitle)
                                .layoutPriority(1)
                            Text(" · " + item.pullRequest.reference)
                                .truncationMode(.middle)
                        }
                        .font(size: options.rowReasonSize, weight: .medium)
                        .foregroundStyle(options.quietAppearance ? Color.secondary : item.group.textColor)
                        .lineLimit(1)
                        RowLinksLine(linkRef, hasLeading: order?.showsCapsule == true) {
                            if let order { OrderCapsule(order) }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowFocus(activity, .row)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.pullRequest.title), \(item.headline)")
        .accessibilityValue([item.detail, item.pullRequest.reference, order?.sentence].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens the pull request on GitHub")
        .accessibilityActions {
            SummarizeMenuItems(linkRef, divided: false)
            if let open = order?.open { Button("Show Its Mission", action: open) }
        }
        .rowActions(for: item.pullRequest.title, openTitle: "Open on GitHub", open: action, activity: activity) {
            SummarizeMenuItems(linkRef)
            LinkMenuItems(linkRef)
        }
        .rowSummarizeButton(linkRef)
    }

    private var subtitle: String {
        item.detail.map { "\(item.headline) · \($0)" } ?? item.headline
    }

    private var linkRef: ItemRef {
        .gitHubPullRequest(repository: item.pullRequest.repository, number: item.pullRequest.number)
    }

    private var helpText: String {
        [item.pullRequest.title, item.pullRequest.reference, subtitle, "Click to open on GitHub"].joined(separator: "\n")
    }
}

/// Small "icon count" chips for the non-empty groups.
struct CountChips: View {
    let counts: GitHubGroupCounts
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        if options.clearerStates {
            AttentionSummary(states: counts.states)
        } else {
            StateCountChips(GitHubPRGroup.allCases.filter { counts[$0] > 0 }, leastUrgentFirst: GitHubPRGroup.allCases.reversed()) { group in
                HStack(spacing: 3) {
                    Image(systemName: group.symbol)
                        .foregroundStyle(group.color)
                    Text("\(counts[group])")
                        .monospacedDigit()
                }
                .font(size: 11, weight: .semibold)
                .help("\(counts[group]) \(group.countLabel)")
            }
        }
    }
}
