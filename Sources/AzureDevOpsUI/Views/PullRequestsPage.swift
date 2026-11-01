import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The Pull Requests section's page in a window: the popover's groups, each in a card, with room for every detail; or, by
/// date, every open pull request in one.
struct PullRequestsPage: View {
    /// The order to list them in, for pictures; nil for the one you chose.
    var order: PROrder? = nil

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.interfaceOptions) private var options

    @LocalState private var showIdle = false

    private static let shownGroups: [PRGroup] = [.needsYou, .answered, .failing, .ready, .toReview, .waiting, .done]

    private var shownOrder: PROrder { order ?? settings.pullRequestOrder }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Pull Requests", subtitle: subtitle) {
                PageRefreshStatus(page: .pullRequests)
                PullRequestOrderMenu(order: shownOrder, showsTitle: true)
                    .menuStyle(.button)
                    .glassButtonStyle()
                    .fixedSize()
                Button {
                    store.openPullRequestsPage()
                } label: {
                    Label("Open in Azure DevOps", systemImage: "arrow.up.forward.app")
                }
                .glassButtonStyle()
            }
            PageScroll {
                VStack(alignment: .leading, spacing: 18) {
                    notices
                    if store.showsBrief, !options.compactBriefs {
                        BriefView()
                            .padding(.horizontal, -4)
                    }
                    if shownOrder.isByDate {
                        byDate
                    } else {
                        ForEach(Self.shownGroups, id: \.self) { group in
                            let items = store.items(in: group)
                            if !items.isEmpty {
                                section(group, items)
                                if options.compactBriefs, store.showsBrief,
                                   group == Self.shownGroups.first(where: { !store.items(in: $0).isEmpty }) {
                                    BriefView().padding(.horizontal, -4)
                                }
                            }
                        }
                    }
                    idle
                }
            }
        }
    }

    private var subtitle: String {
        let counts = store.counts
        let parts = [PRGroup.needsYou, .failing, .ready, .toReview].filter { counts[$0] > 0 }.map { "\(counts[$0]) \($0.countLabel)" }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return store.hasLoaded ? "Nothing needs you" : "Your pull requests, and the ones you review"
    }

    @ViewBuilder
    private var notices: some View {
        if let problem = store.problem {
            ProblemView(problem: problem) { store.signIn() }
        }
        if store.mode == .live && settings.organizations.isEmpty && store.items.isEmpty {
            OrganizationsPlaceholder()
        } else if store.isLoading && store.problem == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your pull requests…")
                    .font(style: .body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if store.hasLoaded && store.activeItems.isEmpty && store.problem == nil {
            QuietView(idleCount: store.counts.idle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    private func section(_ group: PRGroup, _ items: [PRSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                    .foregroundStyle(group.color)
                Text(group.title)
                    .foregroundStyle(.primary)
                Text("\(items.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if group == .done || group == .needsYou && items.contains(where: \.hasNews) {
                    Button(group == .needsYou ? "Mark as Seen" : "Clear") { store.clear(group) }
                        .buttonStyle(.borderless)
                        .font(size: 11)
                        .help(group == .needsYou ? MenuPanelView.markAsSeenHelp : "Remove these from the list")
                }
            }
            .font(size: 12, weight: .semibold)
            .padding(.horizontal, 4)
            card(items)
        }
    }

    /// Every open pull request in one card, by when each was created, each saying where it stands; then Done's.
    @ViewBuilder
    private var byDate: some View {
        let listed = store.dateList(shownOrder)
        if !listed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                    Text(shownOrder.title)
                        .foregroundStyle(.primary)
                    Text("\(listed.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if listed.contains(where: { $0.group == .needsYou && $0.hasNews }) {
                        Button("Mark as Seen") { store.clear(.needsYou) }
                            .buttonStyle(.borderless)
                            .font(size: 11)
                            .help(MenuPanelView.markAsSeenHelp)
                    }
                }
                .font(size: 12, weight: .semibold)
                .padding(.horizontal, 4)
                card(listed, showsCreated: true)
            }
            if options.compactBriefs, store.showsBrief {
                BriefView().padding(.horizontal, -4)
            }
        }
        let done = store.items(in: .done)
        if !done.isEmpty {
            section(.done, done)
        }
    }

    /// The rows, in a card.
    private func card(_ items: [PRSnapshot], showsCreated: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().padding(.leading, 44).padding(.trailing, 12)
                }
                PRRowView(
                    item: item, now: store.now, showsActions: true, showsCreated: showsCreated, openSource: source(item),
                    stopWatching: watching(item), dismiss: dismissing(item)
                ) { store.open(item) }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 4)
        .background(GlassCard(cornerRadius: 18))
    }

    @ViewBuilder
    private var idle: some View {
        let idle = store.items(by: shownOrder).filter { $0.group == .idle }
        if !idle.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showIdle.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(size: 9, weight: .bold)
                            .rotationEffect(.degrees(showIdle ? 90 : 0))
                        Text("Idle")
                        Text("\(idle.count)").monospacedDigit()
                    }
                    .font(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .help("Drafts, pull requests without recent activity, and reviews you've approved or declined")
                if showIdle {
                    VStack(spacing: 0) {
                        ForEach(idle) { item in
                            PRRowView(item: item, now: store.now, compact: true, showsActions: true, showsCreated: shownOrder.isByDate,
                                      openSource: source(item), stopWatching: watching(item)) { store.open(item) }
                                .padding(.horizontal, 6)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(GlassCard(cornerRadius: 18))
                }
            }
        }
    }

    private func source(_ item: PRSnapshot) -> (() -> Void)? {
        item.chatSource == nil ? nil : { store.openSource(item) }
    }

    private func watching(_ item: PRSnapshot) -> (() -> Void)? {
        item.isWatched ? { store.stopWatching(item) } : nil
    }

    private func dismissing(_ item: PRSnapshot) -> (() -> Void)? {
        item.group == .needsYou ? { store.dismiss(item) } : nil
    }
}
