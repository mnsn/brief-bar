import BriefBarCore
import BriefBarUI
import SwiftUI
import TeamsCore

/// A Teams section's page in a window, as the window's other pages show theirs: the unread chats of one kind in a card
/// under Needs You, then the ones read recently, folded. A click opens a chat in Teams.
struct ChatsPage: View {
    let group: ChatGroup

    @EnvironmentObject private var store: ConversationStore
    @Environment(\.textScale) private var textScale

    @LocalState private var showRecent = false

    var body: some View {
        let unread = store.state.unread(in: group)
        VStack(spacing: 0) {
            PageHeader(title: group.title, subtitle: Self.subtitle(group, unread: unread.count, hasLoaded: store.hasLoaded)) {
                Button {
                    store.markAllRead(group)
                } label: {
                    ControlLabel("Mark All Read", systemImage: "checkmark.bubble")
                }
                .glassButtonStyle()
                .disabled(unread.isEmpty)
                .help("Mark All Read: mark every \(group == .chats ? "chat" : "group chat") here as read")
                Button {
                    TeamsApp.activate()
                } label: {
                    ControlLabel("Open Teams", systemImage: "arrow.up.forward.app")
                }
                .glassButtonStyle()
                .help("Open Microsoft Teams")
            }
            PageScroll {
                VStack(alignment: .leading, spacing: 18) {
                    notices(unread)
                    if !unread.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            let state = ItemState.needsYou
                            SectionHeading(symbol: state.symbol, color: state.color, title: state.title, count: unread.count)
                                .padding(.horizontal, 4)
                            card(unread)
                        }
                    }
                    recent
                }
            }
        }
    }

    /// "2 need you", as the window's other pages count what needs you: unread chats do.
    static func subtitle(_ group: ChatGroup, unread: Int, hasLoaded: Bool) -> String {
        if unread > 0 { return unread == 1 ? "1 needs you" : "\(unread) need you" }
        guard hasLoaded else { return group == .chats ? "Your unread Teams chats" : "Your unread group and meeting chats" }
        return "Nothing needs you"
    }

    @ViewBuilder
    private func notices(_ unread: [ConversationSummary]) -> some View {
        if let problem = store.problem {
            ProblemView(problem: problem, lostAccess: store.lostAccess)
        }
        if store.hasLoaded, unread.isEmpty, store.problem?.isBlocking != true {
            EmptyListView(group: group, hasTeamsNotifications: store.hasTeamsNotifications)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if !store.hasLoaded, store.problem == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your chats…")
                    .font(style: .body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    /// The chats in a card, a line between each two.
    private func card(_ conversations: [ConversationSummary]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(conversations.enumerated()), id: \.element.id) { index, conversation in
                if index > 0 {
                    Divider().padding(.leading, dividerInset).padding(.trailing, 12)
                }
                ChatRow(conversation: conversation)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 4)
        .background(GlassCard(cornerRadius: 18))
    }

    /// Where a row's name starts, for the line between rows: the card's and the row's padding, the avatar, and the space
    /// after it.
    private var dividerInset: CGFloat {
        6 + 8 + 30 * textScale + 10
    }

    /// Chats read lately, folded until you open them, as in the popover.
    @ViewBuilder
    private var recent: some View {
        let recent = store.state.recent(in: group)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FoldingSectionHeading(title: "Recent", count: recent.count, isExpanded: $showRecent)
                    .padding(.horizontal, 4)
                if showRecent {
                    card(recent)
                }
            }
        }
    }
}
