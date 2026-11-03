import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// What's left before you can complete one of your pull requests, in its details, as its row's line says it: the most
/// pressing first, then what's done. What's yours to do says so, or that Copilot's on it, and an item with a part of its
/// own below, its comments, its builds and checks or its reviewers, takes you there.
struct PullRequestLeftSection: View {
    let readiness: PRReadiness
    /// What the task Copilot is at work on for it does, while Send Work to Copilot is on: what it takes care of is
    /// Copilot's turn.
    var copilotAction: PullRequestAction?
    /// Takes the details to where an item leads (`PullRequestDetailsStore.Place.of(_:in:)`).
    let go: (PRReadiness.Item) -> Void

    var body: some View {
        let left = readiness.left.count
        VStack(alignment: .leading, spacing: 8) {
            PageSectionHeader(title: "What's Left", count: left > 0 ? left : nil)
            if readiness.isReady {
                Label("Nothing's left: you can complete it", systemImage: "checkmark.seal.fill")
                    .font(size: 12, weight: .medium)
                    .foregroundStyle(ItemState.done.textColor)
            } else if !readiness.isCurrent {
                Text("It changed since its policies were read: they're read again at the next refresh.")
                    .font(size: 11.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array(readiness.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Divider()
                            .opacity(0.6)
                            .padding(.leading, 34)
                    }
                    LeftRow(
                        item: item, section: PullRequestPanel.section(of: item),
                        isCopilots: copilotAction?.takesCare(of: item.kind) == true, go: go
                    )
                }
            }
            .padding(.vertical, 3)
            .background(GlassCard(cornerRadius: 12, raised: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One thing it requires: done, failing, yours to do, running or waiting on someone else, and more about it; a click takes
/// you to its part of the details, where it has one.
private struct LeftRow: View {
    let item: PRReadiness.Item
    let section: PullRequestPanel.Section?
    /// Copilot's at work on it.
    let isCopilots: Bool
    let go: (PRReadiness.Item) -> Void

    @LocalState private var isHovered = false

    /// What you have to do yourself: a draft to publish, changes someone wants, comments to resolve, a build that failed;
    /// unless Copilot's at work on it.
    private var isYourTurn: Bool {
        item.isRequired && (item.state == .needsYou || item.state == .failing) && !isCopilots
    }

    /// What Copilot's at work on, which would be yours otherwise.
    private var isCopilotsTurn: Bool {
        item.isRequired && (item.state == .needsYou || item.state == .failing) && isCopilots
    }

    var body: some View {
        if let section {
            Button {
                go(item)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(item.described + "\n" + Self.hint(section))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(Self.hint(section))
            .accessibilityAddTraits(.isButton)
        } else {
            row
                .help(item.described)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.symbol)
                .font(size: 12, weight: .semibold)
                .foregroundStyle(item.color)
                .frame(width: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(size: 12.5, weight: item.isDone ? .regular : .medium)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(size: 11.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isYourTurn {
                Text("Your turn")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(item.state?.textColor ?? .secondary)
                    .fixedSize()
            } else if isCopilotsTurn {
                Label("Copilot's on it", systemImage: "paperplane.fill")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(ItemState.running.textColor)
                    .fixedSize()
            }
            if section != nil {
                Image(systemName: "chevron.right")
                    .font(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(section != nil && isHovered ? 0.06 : 0))
                .padding(.horizontal, 3)
        )
        .contentShape(Rectangle())
    }

    private var accessibilityLabel: String {
        var parts = [item.described]
        if isYourTurn {
            parts.append("your turn")
        } else if isCopilotsTurn {
            parts.append("Copilot's on it")
        } else if item.isDone {
            parts.append("done")
        }
        return parts.joined(separator: ", ")
    }

    /// "Shows its comments".
    static func hint(_ section: PullRequestPanel.Section) -> String {
        switch section {
        case .comments: "Shows its comments"
        case .checks: "Shows its builds and checks"
        case .reviewers: "Shows its reviewers"
        }
    }
}
