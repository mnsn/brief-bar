import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The menu-bar popover: every pull request grouped by what it needs from you, or listed by when each was created.
struct MenuPanelView: View {
    /// The order to list them in, for pictures; nil for the one you chose.
    var order: PROrder? = nil

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var loginItem: LoginItem
    @Environment(\.interfaceOptions) private var options

    @LocalState private var contentHeight: CGFloat = 0
    @LocalState private var showIdle = false

    static let width: CGFloat = 400
    private static let maxListHeight: CGFloat = 560
    private static let shownGroups: [PRGroup] = [.needsYou, .answered, .failing, .ready, .toReview, .waiting, .done]
    /// What Needs You's Mark as Seen does, in the popover and on the window's page.
    static let markAsSeenHelp = "You've seen these: what's new moves on, and comments that wait on you stay until you reply, they're resolved, or you remove them"

    private var shownOrder: PROrder { order ?? settings.pullRequestOrder }

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
        .onAppear { loginItem.refresh() }
    }

    private var header: some View {
        HStack {
            PageLink(.azureDevOpsPullRequests, name: AzureDevOpsPage.pullRequests.title) {
                HStack {
                    Image(systemName: AzureDevOpsPage.pullRequests.symbol)
                        .foregroundStyle(options.quietAppearance ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(TintShapeStyle()))
                    Text(AzureDevOpsPage.pullRequests.title)
                        .font(style: .headline)
                }
            }
            Spacer()
            CountChips(counts: store.counts, showToReview: settings.showToReview)
            PullRequestOrderMenu(order: shownOrder)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let problem = store.problem {
                ProblemView(problem: problem) { store.signIn() }
            }

            if settings.chatLinksEnabled && store.chatAccess == .denied {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane")
                        .foregroundStyle(.secondary)
                    Text("Pull requests sent in chats need Full Disk Access.")
                        .foregroundStyle(.secondary)
                    Button("Set Up…") { store.showChatAccessSetup?() }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .font(size: 11)
                .padding(.horizontal, 8)
            } else if settings.chatLinksEnabled, let problem = store.chatProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.notifications && store.notificationsBlocked {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.secondary)
                    Text("Notifications are off for BriefBar.")
                        .foregroundStyle(.secondary)
                    Button("Turn On…") { Notifier.openSystemSettings() }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .font(size: 11)
                .padding(.horizontal, 8)
                .help("Allow notifications for BriefBar in System Settings › Notifications, or turn Notifications off in Azure DevOps' settings")
            }

            // Without organizations to watch, pull requests people sent you may still be listed.
            if store.mode == .live && settings.organizations.isEmpty && store.items.isEmpty {
                OrganizationsPlaceholder()
            } else if store.isLoading && store.problem == nil {
                VStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading your pull requests…")
                        .font(size: 13, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else if store.hasLoaded && store.activeItems.isEmpty && store.problem == nil {
                QuietView(idleCount: store.counts.idle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }

            if store.showsBrief, !options.compactBriefs {
                BriefView()
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
                            BriefView()
                        }
                    }
                }
            }

            let idle = store.items(by: shownOrder).filter { $0.group == .idle }
            if !idle.isEmpty {
                DisclosureGroup(isExpanded: $showIdle) {
                    VStack(spacing: 0) {
                        ForEach(idle) { item in
                            PullRequestRow(item: item, compact: true, showsCreated: shownOrder.isByDate)
                        }
                    }
                } label: {
                    Text("Idle (\(idle.count))")
                        .font(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showIdle.toggle() } }
                }
                .padding(.horizontal, 8)
                .help("Drafts, pull requests without recent activity, and reviews you've approved or declined")
            }
        }
    }

    private func section(_ group: PRGroup, _ items: [PRSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(group.title) (\(items.count))")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(options.quietAppearance ? Color.primary : group.color)
                    .help(group == .answered ? "You took care of these in Azure DevOps. Once you've seen them here, they go back to their usual group." : "")
                Spacer()
                if group == .done || group == .needsYou && items.contains(where: \.hasNews) {
                    Button(group == .needsYou ? "Mark as Seen" : "Clear") { store.clear(group) }
                        .buttonStyle(.borderless)
                        .font(size: 11)
                        .help(group == .needsYou ? Self.markAsSeenHelp : "Remove these from the list")
                }
            }
            .padding(.horizontal, 8)
            ForEach(items) { item in
                PullRequestRow(item: item)
            }
        }
    }

    /// Every open pull request in one list, by when each was created, each saying where it stands; then Done's.
    @ViewBuilder
    private var byDate: some View {
        let listed = store.dateList(shownOrder)
        if !listed.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(shownOrder.title) (\(listed.count))")
                        .font(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .help("By when each was created. Each says where it stands, and yours what's left before you can complete them.")
                    Spacer()
                    if listed.contains(where: { $0.group == .needsYou && $0.hasNews }) {
                        Button("Mark as Seen") { store.clear(.needsYou) }
                            .buttonStyle(.borderless)
                            .font(size: 11)
                            .help(Self.markAsSeenHelp)
                    }
                }
                .padding(.horizontal, 8)
                ForEach(listed) { item in
                    PullRequestRow(item: item, showsCreated: true)
                }
            }
            if options.compactBriefs, store.showsBrief {
                BriefView()
            }
        }
        let done = store.items(in: .done)
        if !done.isEmpty {
            section(.done, done)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                store.openPullRequestsPage()
            } label: {
                Label("Open Azure DevOps", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            Spacer()
            RefreshStatus()
            Menu {
                SettingsMenuContent()
            } label: {
                Image(systemName: "gearshape")
                    .frame(minWidth: options.visibleActions ? 28 : nil, minHeight: options.visibleActions ? 28 : nil)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .font(size: 12)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A pull request in a list outside its window's page: the menu bar's list, a list by state that mixes every source's, the
/// window's Overview, or a widget. A click shows its details in BriefBar's window, at the comment or the run it's about,
/// from a page of the window, and from anywhere else once you chose to Open Pull Requests in BriefBar; or else opens it in
/// Azure DevOps. Its menu has both, and the message it was sent in, taking it off Needs You, and no longer watching it.
struct PullRequestRow: View {
    let item: PRSnapshot
    var compact = false
    /// Its time is how long ago it was created, as in a list by date.
    var showsCreated = false
    /// What's left before you can complete it, under it: not in a widget, whose rows keep one height.
    var showsReadiness = true
    /// Stop Watching in its menu, for one you watch: not in a widget's.
    var stopsWatching = true

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var details: PullRequestDetailsStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.panelStyle) private var panelStyle

    var body: some View {
        // On a page of BriefBar's window, such as the Overview, rather than in the menu bar or a widget.
        let inWindow = panelStyle == .page
        PRRowView(
            item: item, now: store.now, compact: compact, showsCreated: showsCreated, showsReadiness: showsReadiness,
            openSource: item.chatSource == nil ? nil : { store.openSource(item) },
            stopWatching: stopsWatching && item.isWatched ? { store.stopWatching(item) } : nil,
            dismiss: item.group == .needsYou ? { store.dismiss(item) } : nil,
            showDetails: details.hasPage() ? { details.showDetails(item) } : nil,
            opensDetails: inWindow || settings.opensPullRequestsInBriefBar, showsInWindow: !inWindow
        ) {
            store.open(item)
        }
    }
}

/// Lists the pull requests by status, or by when each was created, newest or oldest first: in the list's header.
struct PullRequestOrderMenu: View {
    /// The order the list shows.
    let order: PROrder
    /// The order's name beside its symbol, on a window's page; the symbol alone in a popover.
    var showsTitle = false

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Menu {
            Picker("Sort", selection: $settings.pullRequestOrder) {
                ForEach(PROrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if showsTitle {
                Label(order.title, systemImage: "arrow.up.arrow.down")
            } else {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
        .help("Sort: \(order.title). By Status groups them by what they need from you; Newest First and Oldest First list them by when each was created")
        .accessibilityLabel("Sort Pull Requests")
        .accessibilityValue(order.title)
    }
}

/// A pinned pipeline in a list by state: the row its widget shows, which opens its latest run.
struct PipelineRow: View {
    let status: PipelineStatus

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var pipelines: PipelinesStore

    var body: some View {
        WidgetPipelineRow(status: status, now: store.now) {
            if let latest = status.latest { pipelines.open(latest) } else { pipelines.open(status.pipeline) }
        }
    }
}

/// "Updated 2m ago", a spinner while refreshing, and a button to refresh now.
struct RefreshStatus: View {
    @EnvironmentObject private var store: PRStore

    var body: some View {
        HStack(spacing: 6) {
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            } else if let refreshedAt = store.refreshedAt, store.mode == .live {
                Text(Elapsed.short(since: refreshedAt, now: store.now) == "now" ? "Updated now" : "Updated \(Elapsed.short(since: refreshedAt, now: store.now)) ago")
                    .foregroundStyle(.secondary)
                    .font(size: 11)
            }
            if store.mode == .live {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .help("Refresh now")
            }
        }
    }
}

/// A few lines at the top, worded on this Mac by Apple Intelligence: what needs you, what failed, what's ready. Each shows
/// its pull request's details at what it's about: beside the list, on the window's page; from the menu bar's list, in
/// BriefBar's window once you chose to Open Pull Requests in BriefBar, or else in Azure DevOps.
struct BriefView: View {
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var details: PullRequestDetailsStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.panelStyle) private var panelStyle

    var body: some View {
        BriefContainer(count: store.brief.count, isWritten: true) { collapsed in
            ForEach(collapsed ? Array(store.brief.prefix(2)) : store.brief) { item in
                Button {
                    if let snapshot = store.items.first(where: { $0.key == item.key }) { open(snapshot) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(item.group.color)
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                        Text(store.briefText(item))
                            .font(size: 12)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(collapsed ? 2 : nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? store.briefText(item) : clickHelp)
            }
        }
        .help("Summarized on this Mac by Apple Intelligence")
    }

    private var isOnPage: Bool { panelStyle == .page }

    private var clickHelp: String {
        if isOnPage { return "Click to see its details" }
        return settings.opensPullRequestsInBriefBar && details.hasPage() ? "Click to see its details in BriefBar's window"
            : "Click to open in Azure DevOps"
    }

    private func open(_ item: PRSnapshot) {
        guard isOnPage else {
            details.open(item)
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { details.show(item, at: details.about(item)) }
    }
}

/// Why the list is missing or may be out of date, with a way to sign in when that's the reason.
struct ProblemView: View {
    let problem: PulseProblem
    var signIn: () -> Void

    var body: some View {
        if problem.needsSignIn {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(problem.message)
                        .font(size: 12, weight: .semibold)
                } icon: {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                Text(explanation)
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(problem == .cliNotFound ? "Install the Azure CLI…" : "Sign In…", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
            .padding(.horizontal, 4)
        } else {
            Label(problem.message, systemImage: "exclamationmark.triangle")
                .font(style: .callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        if problem == .cliNotFound {
            return "Install it with Homebrew (brew install azure-cli), then sign in once. No personal access token needed."
        }
        return "BriefBar uses the Azure CLI's sign-in, so there's no token to create. Sign In opens Terminal to run "
            + "az login in your browser; it stays signed in after that."
    }
}

/// Before there are organizations to watch: finding them, or choosing them.
struct OrganizationsPlaceholder: View {
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 6) {
            if store.discovery == .running || !settings.hasDiscovered && store.problem == nil {
                ProgressView()
                    .controlSize(.small)
                Text("Finding your Azure DevOps organizations…")
                    .font(size: 13, weight: .semibold)
                Text("Once, the first time: it looks for the ones where you have pull requests.")
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if settings.hasDiscovered {
                Image(systemName: "building.2")
                    .font(size: 22)
                    .foregroundStyle(.secondary)
                Text("No organizations to watch")
                    .font(size: 13, weight: .semibold)
                Text("None of your organizations has an active pull request of yours or for you to review.")
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Menu("Choose Organizations") {
                    OrganizationsMenuContent()
                }
                .fixedSize()
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
    }
}

struct QuietView: View {
    let idleCount: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal")
                .font(size: 22)
                .foregroundStyle(.secondary)
            Text("All clear")
                .font(size: 13, weight: .semibold)
            Text(idleCount == 0 ? "No open pull requests" : idleCount == 1 ? "1 idle pull request" : "\(idleCount) idle pull requests")
                .font(size: 11)
                .foregroundStyle(.secondary)
        }
    }
}
