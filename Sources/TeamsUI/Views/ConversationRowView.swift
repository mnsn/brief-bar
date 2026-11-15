import BriefBarUI
import TeamsCore
import SwiftUI

/// One chat: avatar, name, the latest message, how long ago, how many messages are unread and, on
/// request, a one-sentence summary from Apple's on-device model. Its ⋯ menu, and ✨ for a chat without a summary yet, show
/// while you're at it (`RowActivity`).
struct ConversationRowView: View {
    let conversation: ConversationSummary
    let now: Date
    let showPreview: Bool
    var open: () -> Void
    var markRead: (() -> Void)?
    var summary: Summarizer.State?
    /// Nil when summaries are off or unavailable.
    var summarize: (() -> Void)?

    private let activity = RowActivity()
    @Environment(\.interfaceOptions) private var options
    @Environment(\.textScale) private var textScale

    private var showsSummaryOnly: Bool {
        guard options.compactBriefs, showPreview, case .done = summary else { return false }
        return true
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(conversation: conversation)
                    .frame(width: 30 * textScale, height: 30 * textScale)
                    .opacity(conversation.isUnread ? 1 : 0.6)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(conversation.name)
                            .font(size: 13, weight: conversation.isUnread ? .semibold : .regular)
                            .foregroundStyle(conversation.isUnread ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        RowTimeSlot(RelativeTime.short(lastMessageDate, now: now), summarizes: showsSummarizeButton, isActive: activity.isActive)
                        if showsSummaryOnly, conversation.unreadCount > 0 {
                            CountBadge(count: conversation.unreadCount, color: conversation.group.color)
                        }
                    }
                    if !showsSummaryOnly {
                        HStack(alignment: .top, spacing: 6) {
                            Text(previewText)
                                .font(size: options.largerReasons ? 13 : 12)
                                .foregroundStyle(showPreview && conversation.isUnread ? .rowContent : Color.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if conversation.unreadCount > 0 {
                                CountBadge(count: conversation.unreadCount, color: conversation.group.color)
                            }
                        }
                    }
                    if showPreview, let summary {
                        SummaryLine(state: summary)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowKeyboardFocus(activity)
        // In its time's place, over the row's button, which would take its click.
        .rowTimeSummarizeButton {
            if let summarize {
                Button(action: summarize) {
                    Image(systemName: "sparkles")
                        .font(size: 11, weight: .semibold)
                        .foregroundStyle(.purple)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .rowFocus(activity, .summarize)
                .help("Summarize with Apple Intelligence, on this Mac")
                .accessibilityLabel("Summarize")
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .rowVoiceOverFocus(activity)
        .accessibilityLabel(conversation.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens the chat in Microsoft Teams")
        .accessibilityActions {
            if let markRead, conversation.isUnread {
                Button("Mark as Read", action: markRead)
            }
            if let summarize, showPreview {
                Button("Summarize", action: summarize)
            }
        }
        .rowActions(for: conversation.name, openTitle: "Open in Teams", open: open, activity: activity) {
            if let markRead, conversation.isUnread {
                Button("Mark as Read", action: markRead)
            }
            if let summarize, showPreview {
                Button("Summarize", action: summarize)
            }
        }
        // The row and its ⋯, together.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(activity.isPointedAt ? Color.primary.opacity(0.08) : .clear)
        )
        .onHover { activity.isHovered = $0 }
        .contextMenu {
            Button("Open in Teams", action: open)
            if let markRead, conversation.isUnread {
                Button("Mark as Read", action: markRead)
            }
            if let summarize, showPreview {
                Button("Summarize with Apple Intelligence", action: summarize)
            }
        }
    }

    /// The sparkles button takes the time's place while you're at a chat that has no summary yet.
    private var showsSummarizeButton: Bool {
        activity.isActive && showPreview && summarize != nil && summary == nil && !options.visibleActions
    }

    private var lastMessageDate: Date {
        conversation.unread.last?.deliveredAt ?? conversation.lastActivity
    }

    private var unreadText: String {
        conversation.unreadCount == 1 ? "1 new message" : "\(conversation.unreadCount) new messages"
    }

    private var previewText: String {
        guard showPreview else { return conversation.isUnread ? unreadText : "No new messages" }
        return (conversation.unread.last ?? conversation.latest)?.preview ?? unreadText
    }

    private var helpText: String {
        var lines = [conversation.name]
        if showPreview {
            let messages = conversation.isUnread ? conversation.unread.suffix(5) : conversation.latestMessages.suffix(3)
            lines += messages.map(\.preview)
        } else if conversation.isUnread {
            lines.append(unreadText)
        }
        lines.append("Click to open in Microsoft Teams")
        return lines.joined(separator: "\n")
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if conversation.isUnread { parts.append(unreadText) }
        if showPreview, let latest = conversation.unread.last ?? conversation.latest { parts.append(latest.preview) }
        if showPreview, case .done(let text) = summary { parts.append("Summary: \(text)") }
        return parts.joined(separator: ", ")
    }
}

/// A chat's summary, or why there isn't one.
struct SummaryLine: View {
    let state: Summarizer.State
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.mini)
                Text("Summarizing…")
                    .foregroundStyle(.secondary)
            case .done(let text):
                Image(systemName: "sparkles")
                    .foregroundStyle(options.quietAppearance ? Color.secondary : .purple)
                Text(text)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let reason):
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                Text(reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(size: options.rowDetailSize)
    }
}
