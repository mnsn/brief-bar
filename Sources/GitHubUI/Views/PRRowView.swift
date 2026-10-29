import BriefBarCore
import BriefBarUI
import GitHubCore
import SwiftUI

/// One pull request: why it's in its group, its title, where it is and how long since it changed.
struct PRRowView: View {
    let item: GitHubPRSnapshot
    let now: Date
    var compact = false
    var action: () -> Void

    @LocalState private var isHovered = false
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            RowSummary(subject: linkRef)
                .padding(.leading, 8 + options.rowIconWidth + (options.readableRows ? 10 : 9))
                .padding(.trailing, 8)
                .padding(.bottom, 6)
        }
        // The row and its summary, together.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open on GitHub", action: action)
            SummarizeMenuItems(linkRef)
            LinkMenuItems(linkRef)
        }
    }

    private var row: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: options.readableRows ? 10 : 9) {
                Image(systemName: item.reason.symbol)
                    .font(.system(size: compact ? 15 : 17))
                    .foregroundStyle(item.group.color)
                    .frame(width: options.rowIconWidth, height: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.pullRequest.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        RowTime(Elapsed.short(since: item.since, now: now), subject: linkRef, isHovered: isHovered)
                    }
                    if compact {
                        Text("\(item.headline) · \(item.pullRequest.reference)")
                            .font(.system(size: options.rowDetailSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        HStack(spacing: 6) {
                            Text(subtitle)
                                .font(.system(size: options.rowReasonSize, weight: .medium))
                                .foregroundStyle(options.quietAppearance ? Color.secondary : item.group.color)
                                .lineLimit(1)
                            LinkCapsules(linkRef)
                        }
                        Text(item.pullRequest.reference)
                            .font(.system(size: options.rowDetailSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.pullRequest.title), \(item.headline)")
        .accessibilityValue([item.detail, item.pullRequest.reference].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens the pull request on GitHub")
        .accessibilityActions { SummarizeMenuItems(linkRef, divided: false) }
        .rowActions(for: item.pullRequest.title, openTitle: "Open on GitHub", open: action) {
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
            HStack(spacing: 8) {
                ForEach(GitHubPRGroup.allCases, id: \.self) { group in
                    if counts[group] > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: group.symbol)
                                .foregroundStyle(group.color)
                            Text("\(counts[group])")
                                .monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .help("\(counts[group]) \(group.countLabel)")
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
