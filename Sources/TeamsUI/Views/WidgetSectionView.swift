import BriefBarCore
import BriefBarUI
import SwiftUI
import TeamsCore

/// A chat group's part of a desktop widget: its unread chats, newest first, and "+N more" when they don't fit,
/// or the chats read in the last day to fill the space, as in the list's Recent. Message previews show only while
/// Show Message Previews is on, as in the lists.
struct WidgetSectionView: View {
    let group: ChatGroup
    let rows: Int

    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.interfaceOptions) private var options

    private static let headerHeight: CGFloat = 36
    var body: some View {
        let unread = store.state.unread(in: group)
        // Reserve the last row for the "+N more" line when everything doesn't fit.
        let visible = unread.count > rows ? Array(unread.prefix(rows - 1)) : unread
        let more = unread.count - visible.count
        let recent = more > 0 ? [] : Array(store.state.recent(in: group).prefix(rows - visible.count))

        VStack(alignment: .leading, spacing: 0) {
            header(count: unread.count)
                .padding(.horizontal, 14)
                .frame(height: Self.headerHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            if visible.isEmpty && recent.isEmpty {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(visible) { row($0) }
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, conversation in
                        row(conversation)
                            .overlay(alignment: .top) {
                                if index == 0 && !visible.isEmpty {
                                    Rectangle()
                                        .fill(.separator)
                                        .frame(height: 1)
                                        .padding(.horizontal, 8)
                                }
                            }
                    }
                    if more > 0 {
                        WidgetMore(hidden: more, total: unread.count, section: group == .chats ? .teamsChats : .teamsGroupChats)
                    }
                }
                .padding(.horizontal, 6)
                Spacer(minLength: 0)
            }
        }
        .frame(height: Self.height(rows: rows, options: options))
    }

    private func row(_ conversation: ConversationSummary) -> some View {
        CompactConversationRow(conversation: conversation, now: store.now, showPreview: settings.showPreviews) {
            store.open(conversation)
        }
        .frame(height: options.compactRowHeight)
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.symbol)
                .font(size: 12, weight: .semibold)
                .foregroundStyle(options.quietAppearance ? Color.secondary : count > 0 ? group.color : Color.accentColor)
            Text(group.title)
                .font(size: 13, weight: .semibold)
            if let problem = store.problem, problem.isBlocking {
                Image(systemName: "exclamationmark.triangle")
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                    .help(problem.title)
            }
            Spacer()
            if count > 0 {
                CountBadge(count: count, color: group.color)
                    .help(group.unreadDescription(count))
            } else if store.hasLoaded {
                Text("All read")
                    .font(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let problem = store.problem, problem.isBlocking {
            Label(problem.title, systemImage: "exclamationmark.triangle")
                .font(size: 11)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
        } else if store.hasLoaded {
            Text(group.unreadDescription(0))
                .font(size: 11)
                .foregroundStyle(.secondary)
        }
    }

    static func height(rows: Int, options: InterfaceOptions = InterfaceOptions()) -> CGFloat {
        headerHeight + CGFloat(rows) * options.compactRowHeight
    }
}

/// One unread chat on a single line: who, the latest message (or how many are new, without previews), and when.
struct CompactConversationRow: View {
    let conversation: ConversationSummary
    let now: Date
    let showPreview: Bool
    var open: () -> Void

    @LocalState private var isHovered = false
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        Button(action: open) {
            HStack(spacing: options.readableRows ? 10 : 8) {
                AvatarView(conversation: conversation)
                    .frame(width: 22, height: 22)
                    .frame(width: options.readableRows ? 30 : 22)
                    .opacity(conversation.isUnread ? 1 : 0.6)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(conversation.name)
                            .font(size: options.readableRows ? 13 : 12, weight: conversation.isUnread ? .semibold : .regular)
                            .foregroundStyle(conversation.isUnread ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(RelativeTime.short(lastMessageDate, now: now))
                            .font(size: 10.5).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Text(previewText)
                        .font(size: options.rowDetailSize)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Click to open in Microsoft Teams")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(conversation.name)
        .accessibilityValue(showPreview ? "\(unreadText), \(previewText)" : unreadText)
        .accessibilityHint("Opens the chat in Microsoft Teams")
        .rowActions(for: conversation.name, openTitle: "Open in Teams", open: open) { EmptyView() }
    }

    private var lastMessageDate: Date {
        conversation.unread.last?.deliveredAt ?? conversation.lastActivity
    }

    private var unreadText: String {
        guard conversation.isUnread else { return "No new messages" }
        return conversation.unreadCount == 1 ? "1 new message" : "\(conversation.unreadCount) new messages"
    }

    private var previewText: String {
        guard showPreview else { return unreadText }
        return (conversation.unread.last ?? conversation.latest)?.preview ?? unreadText
    }
}
