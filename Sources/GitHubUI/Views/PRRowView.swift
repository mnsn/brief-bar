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

    /// Fixed height of a compact row, so the widget can size itself to a whole number of rows.
    static let compactHeight: CGFloat = 42

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: item.reason.symbol)
                    .font(.system(size: compact ? 15 : 17))
                    .foregroundStyle(item.group.color)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.pullRequest.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(Elapsed.short(since: item.since, now: now))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if compact {
                        Text("\(item.headline) · \(item.pullRequest.reference)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(item.group.color)
                            .lineLimit(1)
                        Text(item.pullRequest.reference)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.pullRequest.title), \(item.headline)")
        .accessibilityValue([item.detail, item.pullRequest.reference].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens the pull request on GitHub")
    }

    private var subtitle: String {
        item.detail.map { "\(item.headline) · \($0)" } ?? item.headline
    }

    private var helpText: String {
        [item.pullRequest.title, item.pullRequest.reference, subtitle, "Click to open on GitHub"].joined(separator: "\n")
    }
}

/// Small "icon count" chips for the non-empty groups.
struct CountChips: View {
    let counts: GitHubGroupCounts

    var body: some View {
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
