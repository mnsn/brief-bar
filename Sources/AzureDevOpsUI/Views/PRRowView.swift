import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// One pull request: an icon for why it's here, the title, what's going on and where, a detail such as
/// the comment that needs you, and how long ago it happened.
struct PRRowView: View {
    let item: PRSnapshot
    let now: Date
    var compact = false
    var showsActions = false
    /// Opens the message it was sent in (right-click); nil when it wasn't.
    var openSource: (() -> Void)? = nil
    /// Stops watching it (right-click); nil when you don't watch it.
    var stopWatching: (() -> Void)? = nil
    var action: () -> Void

    @LocalState private var isHovered = false
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: action) {
                content
                    .padding(.horizontal, 8)
                    .padding(.vertical, compact ? 5 : 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.title), \(item.headline)")
            .accessibilityValue([item.repository, item.detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Opens the pull request in Azure DevOps")

            if showsActions, !options.visibleActions {
                Menu {
                    menuItems
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Actions for this pull request")
                .accessibilityLabel("Actions for \(item.title)")
                .padding(.trailing, 8)
                .padding(.top, compact ? 5 : 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
        )
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
        .rowActions(for: item.title, openTitle: "Open in Azure DevOps", open: action) { additionalMenuItems }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: options.readableRows ? 10 : 9) {
            RowIcon(item: item, size: compact ? 15 : 17)
                .frame(width: options.rowIconWidth, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: item.group == .idle ? .regular : .semibold))
                        .foregroundStyle(item.group == .idle ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Elapsed.short(since: item.since, now: now))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if compact {
                    Text(compactLine)
                        .font(.system(size: options.rowDetailSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 6) {
                        Text(item.subtitle)
                            .font(.system(size: options.rowReasonSize, weight: .medium))
                            .foregroundStyle(options.quietAppearance ? Color.secondary : item.rowColor)
                            .lineLimit(1)
                        PullRequestCopilotStatus(key: item.key, showsActions: showsActions)
                        PullRequestLinks(key: item.key)
                    }
                    if let detail = item.detail {
                        Text(detail)
                            .font(.system(size: options.rowDetailSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(item.group == .needsYou ? 3 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open in Azure DevOps", action: action)
        additionalMenuItems
    }

    @ViewBuilder
    private var additionalMenuItems: some View {
        if let source = item.chatSource, let openSource {
            Button(source.messageURL == nil ? "Show \(source.appName)" : "Open Message in \(source.appName)", action: openSource)
        }
        PullRequestCopilotMenuItems(item: item)
        LinkMenuItems(item.key.linkRef)
        if item.isWatched, let stopWatching {
            Divider()
            Button("Stop Watching", action: stopWatching)
        }
    }

    private var compactLine: String {
        guard let detail = item.detail else { return item.subtitle }
        return "\(item.headline) · \(detail)"
    }

    private var helpText: String {
        var lines = [item.title, "\(item.repository) · \(item.project) · !\(item.key.number) by \(item.author)", item.headline]
        if let detail = item.detail { lines.append(detail) }
        if !item.approvals.isEmpty && item.group != .ready { lines.append("Approved by " + item.approvals.joined(separator: ", ")) }
        lines.append("Click to open in Azure DevOps")
        if let source = item.chatSource {
            let menu = showsActions ? "Use Actions" : "Right-click"
            lines.append(source.messageURL == nil ? "\(menu) to show \(source.appName)" : "\(menu) to open the message in \(source.appName)")
        }
        if item.isWatched {
            lines.append(showsActions ? "You watch it: use Actions to stop" : "You watch it: right-click to stop")
        }
        return lines.joined(separator: "\n")
    }
}

/// The row's symbol in its color; outline glyphs sit on a filled circle so every row icon has the same weight.
struct RowIcon: View {
    let item: PRSnapshot
    let size: CGFloat

    var body: some View {
        if item.reason.needsBadge && item.group != .idle {
            ZStack {
                Circle()
                    .fill(item.rowColor)
                Image(systemName: item.rowSymbol)
                    .font(.system(size: size * 0.52, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size * 1.06, height: size * 1.06)
        } else {
            Image(systemName: item.rowSymbol)
                .font(.system(size: size))
                .foregroundStyle(item.rowColor)
        }
    }
}

/// Small "icon count" chips for the non-empty groups.
struct CountChips: View {
    let counts: GroupCounts
    var groups: [PRGroup] = [.needsYou, .failing, .ready, .toReview, .waiting]
    var showToReview = false
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        if options.clearerStates {
            AttentionSummary(states: counts.states(showToReview: showToReview))
        } else {
            HStack(spacing: 8) {
                ForEach(groups, id: \.self) { group in
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
