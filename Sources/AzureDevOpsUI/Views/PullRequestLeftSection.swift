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
    /// What Copilot does now about each kind of what's left, while Send Work to Copilot is on, by a task of BriefBar's or a
    /// prompt sent to one of the Copilot app's sessions (`CopilotTasksStore.onIt`).
    var copilot: [PRReadiness.Item.Kind: CopilotWork] = [:]
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
                    LeftRow(item: item, section: PullRequestPanel.section(of: item), copilot: turn(of: item), go: go)
                }
            }
            .padding(.vertical, 3)
            .background(GlassCard(cornerRadius: 12, raised: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Copilot's part in it: at work on it, with the symbol its line has, or asking you something about it in the Copilot
    /// app; or the task at work on the pull request takes care of it, whatever it took on.
    private func turn(of item: PRReadiness.Item) -> LeftRow.CopilotTurn? {
        if let work = copilot[item.kind] {
            return work.state == .needsYou ? .asksYou : .onIt(symbol: work.look.symbol)
        }
        return copilotAction?.takesCare(of: item.kind) == true ? .onIt(symbol: "arrow.triangle.2.circlepath") : nil
    }
}

/// One thing it requires: done, failing, yours to do, running or waiting on someone else, and more about it; a click takes
/// you to its part of the details, where it has one.
private struct LeftRow: View {
    let item: PRReadiness.Item
    let section: PullRequestPanel.Section?
    /// Copilot's part in it, while it's at work on it.
    let copilot: CopilotTurn?
    let go: (PRReadiness.Item) -> Void

    /// Copilot at work on something that's left, or asking you something about it in the Copilot app.
    enum CopilotTurn: Equatable {
        /// With its line's symbol: at work, pushing, or sent and not taken up yet.
        case onIt(symbol: String)
        case asksYou
    }

    @LocalState private var isHovered = false

    /// What you have to do yourself: a draft to publish, changes someone wants, comments to resolve, a build that failed;
    /// unless Copilot's at work on it.
    private var isYourTurn: Bool {
        item.isRequired && (item.state == .needsYou || item.state == .failing) && copilot == nil
    }

    /// What Copilot's at work on, which would be yours otherwise.
    private var copilotsTurn: CopilotTurn? {
        guard item.isRequired, item.state == .needsYou || item.state == .failing else { return nil }
        return copilot
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
            } else if let turn = copilotsTurn {
                // As its line in the details says it: blue while Copilot's at work, orange while it asks you something.
                let (title, symbol, state): (String, String, ItemState) = switch turn {
                case .onIt(let symbol): ("Copilot's on it", symbol, .running)
                case .asksYou: ("Copilot asks you", "questionmark.circle.fill", .needsYou)
                }
                Label(title, systemImage: symbol)
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(state.textColor)
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
        } else if let turn = copilotsTurn {
            parts.append(turn == .asksYou ? "Copilot asks you something in the Copilot app" : "Copilot's on it")
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
