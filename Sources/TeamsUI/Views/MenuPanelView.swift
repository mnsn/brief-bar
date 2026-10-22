import BriefBarUI
import NotificationCenterDB
import SwiftUI
import TeamsCore

/// A menu-bar item's popover: the unread chats of one kind, and the ones read recently.
struct MenuPanelView: View {
    let group: ChatGroup

    @EnvironmentObject private var store: ConversationStore

    @LocalState private var contentHeight: CGFloat = 0
    @LocalState private var showRecent = false

    static let width: CGFloat = 360
    private static let maxListHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                list
                    .padding(8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .panelListHeight(contentHeight, max: Self.maxListHeight)
            Divider()
            footer
        }
        .panelFrame(width: Self.width)
    }

    private var unread: [ConversationSummary] { store.state.unread(in: group) }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: group.symbol)
                .foregroundStyle(group.color)
            Text(group.title)
                .font(.headline)
            if !unread.isEmpty {
                CountBadge(count: unread.count, color: group.color)
                    .help(group.unreadDescription(unread.count))
            }
            Spacer()
            if !unread.isEmpty {
                Button("Mark All Read") { store.markAllRead(group) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .help("Mark every \(group == .chats ? "chat" : "group chat") here as read")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem = store.problem {
                ProblemView(problem: problem, lostAccess: store.lostAccess)
                    .padding(.bottom, 4)
            }

            if store.hasLoaded, unread.isEmpty, store.problem?.isBlocking != true {
                EmptyListView(group: group, hasTeamsNotifications: store.hasTeamsNotifications)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }

            ForEach(unread) { conversation in
                ChatRow(conversation: conversation)
            }

            let recent = store.state.recent(in: group)
            if !recent.isEmpty {
                DisclosureGroup(isExpanded: $showRecent) {
                    VStack(spacing: 0) {
                        ForEach(recent) { conversation in
                            ChatRow(conversation: conversation)
                        }
                    }
                } label: {
                    Text("Recent (\(recent.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showRecent.toggle() } }
                }
                .padding(.horizontal, 8)
                .padding(.top, unread.isEmpty ? 0 : 6)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                TeamsApp.activate()
            } label: {
                Label("Open Teams", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            Spacer()
            Menu {
                SettingsMenuContent()
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A chat in a list: Teams' own lists, and a list by state that mixes every source's. It opens the chat, and its menu
/// marks it read and summarizes it.
struct ChatRow: View {
    let conversation: ConversationSummary

    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var summarizer: Summarizer

    /// Summaries need the previews on (they'd reveal the same), the setting, and Apple Intelligence.
    private var canSummarize: Bool {
        settings.showPreviews && settings.showSummaries && Summarizer.unavailableReason == nil
    }

    var body: some View {
        ConversationRowView(
            conversation: conversation, now: store.now, showPreview: settings.showPreviews,
            open: { store.open(conversation) },
            markRead: conversation.isUnread ? { store.markRead(conversation) } : nil,
            summary: settings.showSummaries ? summarizer.state(for: conversation) : nil,
            summarize: canSummarize ? { summarizer.summarize(conversation) } : nil
        )
    }
}

/// Why the list is empty or incomplete, and what to do about it.
struct ProblemView: View {
    let problem: PulseProblem
    let lostAccess: Bool

    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var fullDiskAccess: FullDiskAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(problem.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if problem == .noAccess {
                    Button("Set Up Full Disk Access…") { fullDiskAccess.show() }
                } else {
                    Button("Copy Diagnostics") { Diagnose.copyReport(paths: store.paths) }
                        .help("Copies a description of the database's structure, without names, messages or IDs")
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    private var message: String {
        if problem == .noAccess, lostAccess {
            return "It had access before. That happens when it's rebuilt with another signature, and turning it off and on keeps the old one: in Full Disk Access, remove BriefBar with −, then add it again."
        }
        return problem.message
    }
}

struct EmptyListView: View {
    let group: ChatGroup
    let hasTeamsNotifications: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.bubble")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(group.unreadDescription(0))
                .font(.system(size: 13, weight: .semibold))
            if !hasTeamsNotifications {
                Text("Teams hasn't posted any notifications yet. Check that it may: System Settings › Notifications › Microsoft Teams.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
    }
}
