import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// Who reviews a pull request, in its details: the people and teams it requires first, each with how they voted.
struct PullRequestReviewersSection: View {
    let panel: PullRequestPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageSectionHeader(title: "Reviewers", count: panel.reviewers.isEmpty ? nil : panel.reviewers.count)
            if panel.reviewers.isEmpty {
                Text("No reviewers yet")
                    .font(size: 12.5)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(panel.reviewers.enumerated()), id: \.element.id) { index, reviewer in
                        if index > 0 {
                            Divider()
                                .opacity(0.6)
                                .padding(.leading, 38)
                        }
                        ReviewerRow(reviewer: reviewer)
                    }
                }
                .padding(.vertical, 3)
                .background(GlassCard(cornerRadius: 12, raised: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A reviewer: who, whether it's required, and how they voted.
private struct ReviewerRow: View {
    let reviewer: PullRequestPanel.ReviewerLine

    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if reviewer.isGroup {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.18))
                    Image(systemName: "person.3.fill")
                        .font(size: 8.5, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 20 * textScale, height: 20 * textScale)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            } else {
                Avatar(name: reviewer.name, size: 20, isMe: reviewer.isYou)
                    .accessibilityHidden(true)
            }
            // How they voted beside them while it fits, or else under them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    who
                    Spacer(minLength: 8)
                    verdict
                }
                VStack(alignment: .leading, spacing: 3) {
                    who
                    verdict
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [reviewer.isYou ? "\(reviewer.name), you" : reviewer.name, reviewer.isRequired ? "required" : nil, reviewer.verdict]
                .compactMap { $0 }.joined(separator: ", ")
        )
    }

    private var who: some View {
        HStack(spacing: 8) {
            Text(reviewer.isYou ? "\(reviewer.name) (you)" : reviewer.name)
                .font(size: 12.5)
                .lineLimit(1)
                .truncationMode(.tail)
            if reviewer.isRequired {
                Chip(text: "Required")
                    .help("It can't be completed until they approve")
            }
        }
    }

    private var verdict: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(size: 11.5, weight: .semibold)
                .foregroundStyle(color)
            Text(reviewer.verdict)
                .font(size: 11.5, weight: .medium)
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var symbol: String {
        if reviewer.hasDeclined { return "minus.circle" }
        switch reviewer.vote {
        case .approved, .approvedWithSuggestions: return "checkmark.circle.fill"
        case .waitingForAuthor: return "exclamationmark.bubble.fill"
        case .rejected: return "xmark.circle.fill"
        case .none: return "circle.dashed"
        }
    }

    /// Its state's: done for an approval, needs you for changes, failing for a rejection.
    private var state: ItemState? {
        if reviewer.hasDeclined { return nil }
        switch reviewer.vote {
        case .approved, .approvedWithSuggestions: return .done
        case .waitingForAuthor: return .needsYou
        case .rejected: return .failing
        case .none: return nil
        }
    }

    private var color: Color { state?.color ?? .secondary }
    private var textColor: Color { state?.textColor ?? .secondary }
}
