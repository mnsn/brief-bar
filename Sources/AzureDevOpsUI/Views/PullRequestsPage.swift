import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The Pull Requests section's page in a window: the popover's groups, each in a card, with room for every detail.
struct PullRequestsPage: View {
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings

    @LocalState private var showIdle = false

    private static let shownGroups: [PRGroup] = [.needsYou, .answered, .failing, .ready, .toReview, .waiting, .done]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Pull Requests", subtitle: subtitle) {
                PageRefreshStatus(page: .pullRequests)
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
                    if store.showsBrief {
                        BriefView()
                            .padding(.horizontal, -4)
                    }
                    ForEach(Self.shownGroups, id: \.self) { group in
                        let items = store.items(in: group)
                        if !items.isEmpty {
                            section(group, items)
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
                if group == .needsYou || group == .done {
                    Button(group == .needsYou ? "Mark as Seen" : "Clear") { store.clear(group) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 44).padding(.trailing, 12)
                    }
                    PRRowView(item: item, now: store.now, showsActions: true, openSource: source(item), stopWatching: watching(item)) { store.open(item) }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
            }
            .padding(.vertical, 4)
            .background(GlassCard(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var idle: some View {
        let idle = store.items(in: .idle)
        if !idle.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showIdle.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showIdle ? 90 : 0))
                        Text("Idle")
                        Text("\(idle.count)").monospacedDigit()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .help("Drafts, pull requests without recent activity, and reviews you've approved or declined")
                if showIdle {
                    VStack(spacing: 0) {
                        ForEach(idle) { item in
                            PRRowView(item: item, now: store.now, compact: true, showsActions: true, openSource: source(item), stopWatching: watching(item)) { store.open(item) }
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
}
