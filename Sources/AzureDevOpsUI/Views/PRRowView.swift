import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// One pull request, in four parts at most: an icon for why it's here, its title and how long ago it happened; why, and
/// where, with Copilot's task on it and its links; what someone wrote, such as the comment that needs you; and one quiet
/// line with its stage, where its order puts it, and what's left before you can complete it (`RowLines`). In Needs You, a
/// dot marks what's new. Its ⋯ menu, ✨ Summarize, and Finished My Review in Your review, show while you're at it
/// (`RowActivity`); what's done, and why it's in its stage, are in its details and its pill's menu.
struct PRRowView: View {
    let item: PRSnapshot
    let now: Date
    var compact = false
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
    /// Its stage, on its quiet line, while Pull Request Order is on: nil on a row of one line, such as a widget's, which
    /// keeps one height. A value, so that the row draws again as it changes.
    var stage: StageReading? = nil
    /// Pull Request Order, while it's on, for a full row: for its stage's menu and VoiceOver's actions, and Undo of your last
    /// change to it, which stay even once it has no stage left to show; and the names of the sessions its stage names.
    var ordering: PullRequestOrder? = nil
    /// Opens it in Azure DevOps.
    var action: () -> Void

    private let activity = RowActivity()
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
        // The row, and its summary under it, which ends where its time does, left of its ⋯.
        VStack(alignment: .leading, spacing: 0) {
            Button(action: clickShows ?? action) {
                content
                    .padding(.horizontal, 8)
                    .padding(.vertical, compact ? 5 : 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rowKeyboardFocus(activity)
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.title), \(item.headline)")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(clickShows == nil ? "Opens the pull request in Azure DevOps"
                : showsInWindow ? "Shows its details in BriefBar's window" : "Shows its details")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .rowVoiceOverFocus(activity)
            .accessibilityActions {
                SummarizeMenuItems(item.key.linkRef, divided: false)
                if let open = order?.open { Button("Show Its Mission", action: open) }
                if let ordering { StageAccessibilityActions(ref: item.key.linkRef, order: ordering) }
            }
            .missionActions(item.key.linkRef, context: mission)
            // Its stage's menu and Finished My Review, over the row's button, which would take their clicks.
            .stageControls(ref: item.key.linkRef, order: stage == nil ? nil : ordering, now: now, activity: activity)
            RowSummary(subject: item.key.linkRef)
                .padding(.leading, 8 + options.rowIconWidth * textScale + options.rowIconSpacing)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
        }
        .rowSummarizeButton(item.key.linkRef, activity: activity)
        .rowActions(for: item.title, openTitle: clickShows == nil ? "Open in Azure DevOps" : detailsTitle, open: clickShows ?? action,
                    activity: activity) {
            if clickShows != nil {
                Button("Open in Azure DevOps", action: action)
            } else if let showDetails {
                Button(detailsTitle, action: showDetails)
            }
            additionalMenuItems
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(activity.isPointedAt ? 0.22 : 0.16)
                    : activity.isPointedAt ? Color.primary.opacity(0.08) : .clear)
        )
        .onHover { activity.isHovered = $0 }
        .contextMenu { menuItems }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: options.rowIconSpacing) {
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
                    RowTime(Elapsed.short(since: time, now: now), subject: item.key.linkRef, isActive: activity.isActive)
                }
                if compact {
                    // With what someone wrote, it reads as content does.
                    Text(compactLine)
                        .font(size: options.rowDetailSize)
                        .foregroundStyle(item.detailIsWritten ? .rowContent : Color.secondary)
                        .lineLimit(1)
                    PRQuietLine(item: item, left: left)
                        .padding(.top, 2)
                } else {
                    RowLines {
                        reason(item.headline)
                            .rowLine(.reason)
                        if !item.repository.isEmpty {
                            reason(" · " + item.repository)
                                .rowLine(.place)
                        }
                        HStack(spacing: 6) {
                            PullRequestCopilotStatus(key: item.key)
                            PullRequestLinks(key: item.key)
                        }
                        .rowLine(.chips)
                        if let detail = item.detail {
                            Text(detail)
                                .font(size: options.rowDetailSize)
                                .foregroundStyle(item.detailIsWritten ? .rowContent : Color.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .rowLine(.detail)
                        }
                        PRQuietLine(item: item, stage: stage, ordering: ordering, order: order, left: left)
                            .rowLine(.quiet)
                        // In room the quiet line makes for it as it shows, folding what's left if it must.
                        if offersFinishedReview, activity.isActive || options.visibleActions {
                            FinishedReviewLabel()
                                .stageSpot(.finishedReview)
                                .rowLine(.trailing)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Why it's here, and where, in its state's color for words.
    private func reason(_ words: String) -> some View {
        Text(words)
            .font(size: options.rowReasonSize, weight: .medium)
            .foregroundStyle(options.quietAppearance ? Color.secondary : item.rowTextColor)
            .lineLimit(1)
    }

    /// In Your review, on your board: Finished My Review moves it to Teammate's review.
    private var offersFinishedReview: Bool {
        ordering != nil && stage?.isOnBoard == true && stage?.stage == .yourReview
    }

    /// What's left before you can complete it, for your own: never what's done, which its details list, nor what its reason
    /// says already, such as Merge conflicts.
    private var left: [PRReadiness.Item] {
        guard showsReadiness else { return [] }
        return (item.readiness?.left ?? []).filter { $0.label.localizedCaseInsensitiveCompare(item.headline) != .orderedSame }
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
        PullRequestMenuItems(
            item: item, openSource: openSource, dismiss: dismiss, stopWatching: stopWatching, mission: mission,
            ordering: ordering
        )
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
        var parts = [isNew ? "New" : nil, item.repository, item.detail].compactMap { $0 }
        if let stage, let ordering { parts.append(StageWords.spoken(stage, order: ordering, now: now)) }
        if let sentence = order?.sentence { parts.append(sentence) }
        if let readiness = item.readiness, !readiness.items.isEmpty { parts += readiness.lines }
        // What a list by date is sorted by, which its time says.
        if showsCreated, let created = item.createdAt { parts.append("Created \(Elapsed.short(since: created, now: now)) ago") }
        return parts.joined(separator: ", ")
    }

    private var helpText: String {
        var lines = [item.title, "\(item.repository) · \(item.project) · !\(item.key.number) by \(item.author)", item.headline]
        if let detail = item.detail { lines.append(detail) }
        // Why it's in its stage, which its pill's menu says too: its row shows the pill alone.
        if let stage, let ordering { lines.append(StageText.sentence(stage, now: now, name: ordering.name(of:))) }
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
        if let source = item.chatSource {
            lines.append(source.messageURL == nil ? "Right-click to show \(source.appName)" : "Right-click to open the message in \(source.appName)")
        }
        if dismiss != nil {
            lines.append("Right-click to remove it from Needs You")
        }
        if item.isWatched {
            lines.append("You watch it: right-click to stop")
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

/// A row's quiet line, one line high: its stage's pill, where its order puts it, and what's left before you can complete it,
/// the most pressing first. Where it doesn't all fit, what's left shows its first few and "+2" for the rest, then only how
/// many are left: the row's tooltip, VoiceOver and its details say all of it. Where even that doesn't fit, as a stage's pill
/// and an order's capsule together can be too wide for a narrow row, it goes on as many lines as it needs, rather than past
/// the row's edge. What's done is in its details alone, and why it's in its stage in its pill's menu. Its links, where its
/// reason's line has no room for them, and Finished My Review go after it (`RowLines`).
/// The row is a button, which would take every click: the pill's menu and Finished My Review go over it, where their spots
/// are (`stageControls`). Someone else's that you finished reviewing says so in words, without a pill: it's off your board.
struct PRQuietLine: View {
    let item: PRSnapshot
    var stage: StageReading? = nil
    var ordering: PullRequestOrder? = nil
    var order: OrderRowContext? = nil
    /// What's left before you can complete it: nothing that's done.
    let left: [PRReadiness.Item]

    @Environment(\.interfaceOptions) private var options

    var body: some View {
        if !isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(shownCounts, id: \.self) { shown in
                    line(shown: shown)
                }
                // Too narrow even for only how many are left: on more lines, as its stage's line wrapped before.
                FlowLayout(spacing: 6, lineSpacing: 3) {
                    parts(shown: 0)
                }
                .lineLimit(1)
            }
            .font(size: options.rowDetailSize)
        }
    }

    /// What the line tries, the first that fits: everything that's left by name, then fewer, down to one; then only how
    /// many are left.
    private var shownCounts: [Int] {
        left.isEmpty ? [0] : Array((0...left.count).reversed())
    }

    private var isEmpty: Bool {
        stage == nil && order?.showsCapsule != true && left.isEmpty
    }

    /// - Parameter shown: how many of what's left show by name; "+2" says the rest.
    private func line(shown: Int) -> some View {
        HStack(spacing: 6) {
            parts(shown: shown)
        }
        .lineLimit(1)
    }

    /// Its stage, its order, and what's left, `shown` of them by name.
    @ViewBuilder
    private func parts(shown: Int) -> some View {
        if let stage {
            if stage.isOnBoard {
                StagePillLabel(stage.stage, opensMenu: stage.stage != .merged)
                    .stageSpot(.pill)
            } else if let ordering {
                Text(StageText.why(stage, name: { ordering.name(of: $0) }))
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
            }
        }
        if let order { OrderCapsule(order) }
        if !left.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(left.prefix(shown).enumerated()), id: \.offset) { _, item in
                    LeftItem(item: item, isQuiet: self.item.group == .idle)
                }
                if shown < left.count {
                    let rest = left.dropFirst(shown)
                    Text(shown == 0 ? "\(rest.count) left" : "+\(rest.count)")
                        .foregroundStyle(self.item.group == .idle ? Color.secondary : .rowContent)
                        .fixedSize()
                        .help(rest.map(\.described).joined(separator: "\n"))
                }
            }
        }
    }

    /// One thing that's left, as its details list it: its symbol in its color, then its words, readable as content.
    private struct LeftItem: View {
        let item: PRReadiness.Item
        /// Its words quiet, as an idle row's title is.
        let isQuiet: Bool

        @Environment(\.interfaceOptions) private var options

        var body: some View {
            HStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(size: options.rowDetailSize - 1.5, weight: .semibold)
                    .foregroundStyle(item.color)
                Text(item.label)
                    .foregroundStyle(isQuiet ? Color.secondary : .rowContent)
            }
            .fixedSize()
            .help(item.described)
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
            StateCountChips(groups.filter { counts[$0] > 0 }, leastUrgentFirst: groups.reversed()) { group in
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
