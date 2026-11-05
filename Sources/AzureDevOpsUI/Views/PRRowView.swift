import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// One pull request: an icon for why it's here, the title, what's going on and where, a detail such as
/// the comment that needs you, and how long ago it happened. In Needs You, a dot marks what's new.
struct PRRowView: View {
    let item: PRSnapshot
    let now: Date
    var compact = false
    var showsActions = false
    /// Its time is how long ago it was created, as in a list by date, rather than since what it's there for.
    var showsCreated = false
    /// What's left before you can complete it, under it, for your own: in lists, folded Idle's too, but not in a widget,
    /// whose rows keep one height.
    var showsReadiness = true
    /// Its details show beside the list.
    var isSelected = false
    /// Opens the message it was sent in (right-click); nil when it wasn't.
    var openSource: (() -> Void)? = nil
    /// Stops watching it (right-click); nil when you don't watch it.
    var stopWatching: (() -> Void)? = nil
    /// Takes it off Needs You (right-click); nil when it isn't there.
    var dismiss: (() -> Void)? = nil
    /// Shows its details: beside the list, on the window's page, or else on that page of BriefBar's window; nil where they
    /// can't show, such as when no window has the page. A click does, unless `opensDetails` says otherwise.
    var showDetails: (() -> Void)? = nil
    /// Whether a click shows its details, where they can show, rather than opening it in Azure DevOps: in BriefBar's
    /// window, and in the menu bar's list and widgets once you chose to Open Pull Requests in BriefBar. Its menu has both.
    var opensDetails = true
    /// Its details show in BriefBar's window, from the menu bar or a widget, rather than in the window it's in: its menu
    /// says Show in BriefBar.
    var showsInWindow = false
    /// Where it stands in its mission, for its order capsule, on a window's Pull Requests page with Pull Request Order on.
    var order: OrderRowContext? = nil
    /// Its Mission menu, and VoiceOver's actions for it, on a window's Pull Requests page with Pull Request Order on.
    var mission: MissionMenuContext? = nil
    /// Opens it in Azure DevOps.
    var action: () -> Void

    @LocalState private var isHovered = false
    @Environment(\.interfaceOptions) private var options
    @Environment(\.textScale) private var textScale

    /// Needs you with something you haven't seen; without it, it's what you've seen and haven't answered.
    private var isNew: Bool { item.group == .needsYou && item.hasNews }

    /// Its details, when a click shows them.
    private var clickShows: (() -> Void)? { opensDetails ? showDetails : nil }

    /// Its menu's way to its details: beside the list, or on the window's Pull Requests page, from another; in BriefBar's
    /// window, from the menu bar or a widget.
    private var detailsTitle: String { showsInWindow ? "Show in BriefBar" : "Show Details" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The row, and its summary under it, which ends where its time does, left of its actions.
            VStack(alignment: .leading, spacing: 0) {
                Button(action: clickShows ?? action) {
                    content
                        .padding(.horizontal, 8)
                        .padding(.vertical, compact ? 5 : 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(helpText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.title), \(item.headline)")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(clickShows == nil ? "Opens the pull request in Azure DevOps"
                    : showsInWindow ? "Shows its details in BriefBar's window" : "Shows its details")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityActions {
                    SummarizeMenuItems(item.key.linkRef, divided: false)
                    if let open = order?.open { Button("Show Its Mission", action: open) }
                }
                .missionActions(item.key.linkRef, context: mission)
                RowSummary(subject: item.key.linkRef)
                    .padding(.leading, 8 + options.rowIconWidth * textScale + (options.readableRows ? 10 : 9))
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
            }
            .rowSummarizeButton(item.key.linkRef)

            if showsActions, !options.visibleActions {
                Menu {
                    menuItems
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .font(size: 11.5, weight: .medium)
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
                .fill(isSelected ? Color.accentColor.opacity(isHovered ? 0.22 : 0.16) : isHovered ? Color.primary.opacity(0.08) : .clear)
        )
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
        .rowActions(for: item.title, openTitle: clickShows == nil ? "Open in Azure DevOps" : detailsTitle, open: clickShows ?? action) {
            if clickShows != nil {
                Button("Open in Azure DevOps", action: action)
            } else if let showDetails {
                Button(detailsTitle, action: showDetails)
            }
            additionalMenuItems
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: options.readableRows ? 10 : 9) {
            RowIcon(item: item, size: compact ? 15 : 17)
                .frame(width: options.rowIconWidth * textScale, height: 20 * textScale)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(size: 13, weight: item.group == .idle ? .regular : .semibold)
                        .foregroundStyle(item.group == .idle ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if isNew {
                        Circle()
                            .fill(.tint)
                            .frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                    }
                    RowTime(Elapsed.short(since: time, now: now), subject: item.key.linkRef, isHovered: isHovered)
                }
                if compact {
                    Text(compactLine)
                        .font(size: options.rowDetailSize)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 6) {
                        Text(item.subtitle)
                            .font(size: options.rowReasonSize, weight: .medium)
                            .foregroundStyle(options.quietAppearance ? Color.secondary : item.rowColor)
                            .lineLimit(1)
                        PullRequestCopilotStatus(key: item.key, showsActions: showsActions)
                        PullRequestLinks(key: item.key)
                        if let order { OrderCapsule(order) }
                    }
                    if let detail = item.detail {
                        Text(detail)
                            .font(size: options.rowDetailSize)
                            .foregroundStyle(.secondary)
                            .lineLimit(item.group == .needsYou ? 3 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if showsReadiness, let readiness = item.readiness, !readiness.items.isEmpty {
                    ReadinessLine(readiness: readiness, isQuiet: item.group == .idle)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What a click does first, then the other: its details, and opening it in Azure DevOps.
    @ViewBuilder
    private var menuItems: some View {
        if let clickShows {
            Button(detailsTitle, action: clickShows)
        }
        Button("Open in Azure DevOps", action: action)
        if clickShows == nil, let showDetails {
            Button(detailsTitle, action: showDetails)
        }
        additionalMenuItems
    }

    private var additionalMenuItems: some View {
        PullRequestMenuItems(item: item, openSource: openSource, dismiss: dismiss, stopWatching: stopWatching, mission: mission)
    }

    private var compactLine: String {
        guard let detail = item.detail else { return item.subtitle }
        return "\(item.headline) · \(detail)"
    }

    /// When it was created, in a list by date; otherwise since what it's there for.
    private var time: Date? {
        showsCreated ? item.createdAt ?? item.since : item.since
    }

    private var accessibilityValue: String {
        var parts = [isNew ? "New" : nil, item.repository, item.detail, order?.sentence].compactMap { $0 }
        if let readiness = item.readiness, !readiness.items.isEmpty { parts += readiness.lines }
        // What a list by date is sorted by, which its time says.
        if showsCreated, let created = item.createdAt { parts.append("Created \(Elapsed.short(since: created, now: now)) ago") }
        return parts.joined(separator: ", ")
    }

    private var helpText: String {
        var lines = [item.title, "\(item.repository) · \(item.project) · !\(item.key.number) by \(item.author)", item.headline]
        if let detail = item.detail { lines.append(detail) }
        if !item.approvals.isEmpty && item.group != .ready && item.readiness == nil {
            lines.append("Approved by " + item.approvals.joined(separator: ", "))
        }
        if let readiness = item.readiness, !readiness.items.isEmpty { lines += readiness.lines }
        if let created = item.createdAt { lines.append("Created \(Elapsed.short(since: created, now: now)) ago") }
        if item.group == .needsYou && !isNew {
            lines.append("You've seen it: it stays here until you reply, the comments are resolved, or you remove it")
        }
        lines.append(clickShows == nil ? "Click to open in Azure DevOps"
            : showsInWindow ? "Click to see its details in BriefBar's window" : "Click to see its details")
        let menu = showsActions ? "Use Actions" : "Right-click"
        if let source = item.chatSource {
            lines.append(source.messageURL == nil ? "\(menu) to show \(source.appName)" : "\(menu) to open the message in \(source.appName)")
        }
        if dismiss != nil {
            lines.append("\(menu) to remove it from Needs You")
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
    @Environment(\.textScale) private var textScale

    var body: some View {
        if item.reason.needsBadge && item.group != .idle {
            ZStack {
                Circle()
                    .fill(item.rowColor)
                Image(systemName: item.rowSymbol)
                    .font(size: size * 0.52, weight: .bold)
                    .foregroundStyle(.white)
            }
            .frame(width: size * 1.06 * textScale, height: size * 1.06 * textScale)
        } else {
            Image(systemName: item.rowSymbol)
                .font(size: size)
                .foregroundStyle(item.rowColor)
        }
    }
}

/// What's left before you can complete one of your pull requests, the most pressing first, then what's done: "✕ Build
/// failed  ✋ Resolve 2 comments  ◷ 1 of 2 approvals  ✓ Work item linked", on as many lines as it takes. Its symbols keep
/// their colors with quieter colors on; what's done reads quieter than what's left.
struct ReadinessLine: View {
    let readiness: PRReadiness
    /// Its words all quiet, as an idle row's title is.
    var isQuiet = false

    @Environment(\.interfaceOptions) private var options

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 2) {
            ForEach(Array(readiness.items.enumerated()), id: \.offset) { _, item in
                // As wide as it needs, or as the row has room for, its words cut short then: the tooltip says all of it.
                HStack(spacing: 3) {
                    Image(systemName: item.symbol)
                        .font(size: options.rowDetailSize - 1.5, weight: .semibold)
                        .foregroundStyle(item.color)
                    Text(item.label)
                        .foregroundStyle(item.isDone || isQuiet ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(size: options.rowDetailSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readiness.lines.joined(separator: ". "))
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
                        .font(size: 11, weight: .semibold)
                        .help("\(counts[group]) \(group.countLabel)")
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
