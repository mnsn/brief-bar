import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import NotificationCenterDB
import SwiftUI

/// Your Azure DevOps pull requests, by what they need: you, a fix, completing, or someone else; and, while you
/// show them, your team's sprint and the pipelines you follow. It reads Azure DevOps with the Azure CLI's sign-in,
/// the only source that uses the network, and posts notifications.
@MainActor
package final class AzureDevOpsSource: BriefBarSource {
    /// 2: the Sprint and Pipelines sections.
    nonisolated package static let descriptionVersion = 2

    package let id = SourceID.azureDevOps
    package let name = "Azure DevOps"
    package let symbol = "arrow.triangle.pull"
    package let description = SourceDescription(
        version: AzureDevOpsSource.descriptionVersion,
        summary: "Your pull requests: which need you, which are failing and which are ready to complete; and your team's sprint and your pipelines",
        reads: "Your pull requests and the ones you review, in the organizations you choose, with their builds, policies and comment threads, from Azure DevOps. While its Sprint or Pipelines section is on screen: your team's current sprint, with its stories, bugs and tasks and who has them, and the recent runs of the pipelines you pin. BriefBar keeps which pull requests you've seen, your organizations, your team and your pipelines. When Apple Intelligence is on, a brief of what needs you is written on your Mac by Apple's on-device model. Only if you turn on Pull Requests Sent in Chats: the notifications every app posts to Notification Center, for links to pull requests, of which BriefBar keeps only the links, with who sent them, in which app and when, never the messages, and only in memory.",
        network: "Azure DevOps only: dev.azure.com, and app.vssps.visualstudio.com to find your organizations, with your Azure CLI sign-in. Every request is a GET, so it never changes anything there: about 10 to 25 small requests a minute, and a few more while the Sprint or Pipelines section is on screen.",
        needs: "The Azure CLI, signed in with az login: BriefBar gets its tokens from it, so there's no personal access token, and runs it without any of BriefBar's own permissions. And permission to post notifications, which macOS asks for when you turn it on. Pull Requests Sent in Chats also needs Full Disk Access, which macOS grants once, to all of BriefBar.",
        requirements: [.azureCLI, .notifications]
    )
    /// Sprint and Pipelines start in windows only: they read Azure DevOps while they're on screen.
    package let sections = [
        SectionInfo(
            id: .azureDevOpsPullRequests, title: AzureDevOpsPage.pullRequests.title, symbol: AzureDevOpsPage.pullRequests.symbol,
            tint: AzureDevOpsPage.pullRequests.color, surfaces: [.menuBar, .widgets, .windows]
        ),
        SectionInfo(
            id: .azureDevOpsSprint, title: AzureDevOpsPage.sprint.title, symbol: AzureDevOpsPage.sprint.symbol,
            tint: AzureDevOpsPage.sprint.color, surfaces: [.menuBar, .widgets, .windows], hiddenAtFirst: [.menuBar, .widgets]
        ),
        SectionInfo(
            id: .azureDevOpsPipelines, title: AzureDevOpsPage.pipelines.title, symbol: AzureDevOpsPage.pipelines.symbol,
            tint: AzureDevOpsPage.pipelines.color, surfaces: [.menuBar, .widgets, .windows], hiddenAtFirst: [.menuBar, .widgets]
        ),
    ]
    package var panelWidth: CGFloat { MenuPanelView.width }

    package func pageMaxWidth(for section: SectionID) -> CGFloat {
        // The Sprint page's cards fill as many columns as fit; the others keep their lines to a readable width.
        section == .azureDevOpsPullRequests ? 900 : .infinity
    }

    private static let chatAccessReason = "For pull requests sent in chats, BriefBar looks for links to pull requests in the notifications that every app posts to Notification Center, and keeps only the links, in memory."

    private let services: AppServices
    let settings: AppSettings
    /// Made when Azure DevOps starts, so its notifications count from then.
    private var store: PRStore?
    /// Made with it, sharing its client: they read only while their sections are on screen.
    private var sprint: SprintStore?
    private var pipelines: PipelinesStore?
    private let changes = PassthroughSubject<Void, Never>()
    private var cancellables: Set<AnyCancellable> = []

    package init(services: AppServices) {
        self.services = services
        settings = AppSettings(defaults: services.defaults)
    }

    /// The groups counted in the menu bar: what to act on. Waiting and Done only show in the list.
    static func shownGroups(showToReview: Bool) -> [PRGroup] {
        showToReview ? [.needsYou, .failing, .ready, .toReview] : [.needsYou, .failing, .ready]
    }

    private func environment<V: View>(_ view: V) -> AnyView {
        guard let store, let sprint, let pipelines else { return AnyView(EmptyView()) }
        return AnyView(view
            .environmentObject(store)
            .environmentObject(sprint)
            .environmentObject(pipelines)
            .environmentObject(settings)
            .environmentObject(services)
            .environmentObject(services.loginItem))
    }

    /// The pull requests' store, and the Sprint and Pipelines sections' stores, sharing its client.
    private func makeStores(notifier: Notifier?) -> PRStore {
        let store = PRStore(settings: settings, notifier: notifier, mode: services.isDemo ? .demo : .live)
        self.store = store
        sprint = SprintStore(settings: settings, mode: store.mode, client: store.client)
        pipelines = PipelinesStore(settings: settings, mode: store.mode, client: store.client)
        return store
    }

    // MARK: Lifecycle

    package func start() {
        guard store == nil else { return }
        if !services.isDemo {
            settings.startSeeing()
        }
        let store = makeStores(notifier: services.notifier)
        let access = services.fullDiskAccess
        store.showChatAccessSetup = { [weak access] in access?.show() }
        store.chatAccessChanged = { [weak self, weak access] status in
            MainActor.assumeIsolated {
                guard let self, let access, access.isRequested(by: self.id) else { return }
                access.report(granted: status == .granted)
            }
        }
        // Pull requests sent in chats read Notification Center: the access is needed only while that's on, and
        // only for its own database (not a copy that BRIEFBAR_CHAT_LINKS_DB names). The demo never reads it.
        if !services.isDemo {
            let database = ChatLinkDatabase.url()
            if ChatLinkDatabase.isSystemDatabase(database) {
                settings.$chatLinksEnabled.removeDuplicates()
                    .sink { [weak self] enabled in MainActor.assumeIsolated { self?.chatLinksChanged(enabled, database: database) } }
                    .store(in: &cancellables)
            }
        }
        // The access window saw it granted: read now rather than at the next check.
        access.$isGranted
            .removeDuplicates()
            .filter { $0 == true }
            .sink { [weak store] _ in MainActor.assumeIsolated { store?.refreshChats() } }
            .store(in: &cancellables)
        store.$counts.removeDuplicates().map { _ in () }
            .merge(with: settings.$showToReview.removeDuplicates().map { _ in () })
            .merge(with: store.$problem.map { _ in () })
            .merge(with: sprint?.$board.map { _ in () }.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher())
            .merge(with: pipelines?.$statuses.map { _ in () }.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.changes.send() } }
            .store(in: &cancellables)

        store.start()
        sprint?.start()
        pipelines?.start()
        changes.send()
    }

    package func didTurnOn() {
        // You just turned it on, having read that it posts notifications: macOS asks now.
        if settings.notifications {
            services.notifier.requestAuthorization()
        }
        // And pull requests sent in chats, if they were on when you turned it off: the steps for Full Disk Access.
        if settings.chatLinksEnabled {
            store?.askForChatAccessIfMissing()
        }
    }

    package func stop() {
        cancellables.removeAll()
        store?.stop()
        sprint?.stop()
        pipelines?.stop()
        store = nil
        sprint = nil
        pipelines = nil
        services.fullDiskAccess.unregister(.azureDevOps)
    }

    private func chatLinksChanged(_ enabled: Bool, database: URL) {
        let access = services.fullDiskAccess
        if enabled {
            access.register(.azureDevOps, name: "Azure DevOps", reason: Self.chatAccessReason) {
                DatabaseAccess.check(database) == .granted
            }
        } else if access.isRequested(by: id) {
            access.unregister(.azureDevOps)
            // You just turned it off: if nothing else reads Notification Center, BriefBar can be taken off the list.
            DispatchQueue.main.async { [weak access] in access?.offerRemoval() }
        }
    }

    package func deleteSavedData() {
        settings.forgetSeen()
    }

    // MARK: Menu bar

    package func segment(for section: SectionID) -> MenuBarSegment {
        switch section {
        case .azureDevOpsSprint: return sprintSegment()
        case .azureDevOpsPipelines: return pipelinesSegment()
        default: return pullRequestsSegment()
        }
    }

    /// How many of your stories and tasks are left in the sprint.
    private func sprintSegment() -> MenuBarSegment {
        let mine = sprint?.board?.myWork ?? []
        let title = NSMutableAttributedString()
        if !mine.isEmpty {
            title.append(NSAttributedString(string: " "))
            title.append(MenuBarDrawing.count(mine.count))
        }
        let summary = sprint?.board == nil ? "Sprint" : mine.isEmpty ? "Sprint: nothing left for you" : "Sprint: \(mine.count) of yours left"
        return MenuBarSegment(glyph: AzureDevOpsPage.sprint.symbol, title: title, summary: summary, count: mine.count, needsAttention: false)
    }

    /// How many pinned pipelines failed, and how many are running.
    private func pipelinesSegment() -> MenuBarSegment {
        let counts = pipelines?.counts ?? PipelineCounts([])
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        for (count, symbol, color) in [(counts.failed, "xmark.circle.fill", NSColor.systemRed), (counts.running, "arrow.triangle.2.circlepath.circle.fill", .systemBlue)] where count > 0 {
            title.append(NSAttributedString(string: " "))
            title.append(MenuBarDrawing.symbol(symbol, color: color, font: font, sizeDelta: -2, monochrome: true))
            title.append(MenuBarDrawing.count(count, font: font))
        }
        let spoken = [(counts.failed, "failed"), (counts.running, "running")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let summary = spoken.isEmpty ? "Pipelines" : "Pipelines: " + spoken.joined(separator: ", ")
        return MenuBarSegment(
            glyph: AzureDevOpsPage.pipelines.symbol, title: title, summary: summary, count: counts.failed, needsAttention: counts.failed > 0
        )
    }

    private func pullRequestsSegment() -> MenuBarSegment {
        let counts = store?.counts ?? GroupCounts()
        let needsSignIn = store?.problem?.needsSignIn == true
        let groups = Self.shownGroups(showToReview: settings.showToReview)
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        if needsSignIn {
            // A small orange person badge while you need to sign in.
            title.append(NSAttributedString(string: " "))
            title.append(MenuBarDrawing.symbol("person.crop.circle.badge.exclamationmark.fill", color: .systemOrange, font: font,
                                               sizeDelta: -2, monochrome: true))
        } else {
            for group in groups where counts[group] > 0 {
                title.append(NSAttributedString(string: " "))
                // Monochrome keeps the check and the cross cut out; one palette color fills them in.
                title.append(MenuBarDrawing.symbol(group.symbol, color: group.nsColor, font: font, sizeDelta: -2, monochrome: true))
                title.append(MenuBarDrawing.count(counts[group], font: font))
            }
        }
        let spoken = groups.filter { counts[$0] > 0 }.map { "\(counts[$0]) \($0.countLabel)" }
        let summary = needsSignIn
            ? "Azure DevOps: sign in to see your pull requests"
            : spoken.isEmpty ? "Azure DevOps: nothing needs you" : "Azure DevOps: " + spoken.joined(separator: ", ")
        return MenuBarSegment(
            glyph: symbol, title: title, summary: summary, count: counts.needsYou,
            needsAttention: counts.needsYou > 0 || needsSignIn
        )
    }

    package var segmentsChanged: AnyPublisher<Void, Never> {
        changes.eraseToAnyPublisher()
    }

    package func panel(for section: SectionID) -> AnyView {
        switch section {
        case .azureDevOpsSprint: return environment(WorkPanelView(page: .sprint))
        case .azureDevOpsPipelines: return environment(WorkPanelView(page: .pipelines))
        default: return environment(MenuPanelView())
        }
    }

    package func page(for section: SectionID) -> AnyView {
        let page: AnyView = switch section {
        case .azureDevOpsSprint: environment(SprintPage())
        case .azureDevOpsPipelines: environment(PipelinesPage())
        default: environment(PullRequestsPage())
        }
        return AnyView(page.environment(\.panelStyle, .page))
    }

    package func panelWillShow(_ section: SectionID) {
        store?.refreshIfStale()
    }

    package func sectionVisibilityChanged(_ section: SectionID, isShowing: Bool, by viewer: SectionViewer) {
        // The sprint and pipelines are read only while something shows them.
        switch section {
        case .azureDevOpsSprint:
            sprint?.setVisible(isShowing, for: viewer.name)
            return
        case .azureDevOpsPipelines:
            pipelines?.setVisible(isShowing, for: viewer.name)
            return
        default:
            break
        }
        // What a popover or a window's page shows in Answered counts as seen once none shows it; a widget or the
        // menu bar's count doesn't.
        guard viewer.kind == .popover || viewer.kind == .window else { return }
        if isShowing {
            store?.viewerDidOpen(viewer.name)
        } else {
            store?.viewerDidClose(viewer.name)
        }
    }

    // MARK: Widgets

    package func widget(for section: SectionID, size: WidgetSize, rows: Int) -> AnyView {
        switch section {
        case .azureDevOpsSprint: return environment(SprintWidgetSection(rows: rows))
        case .azureDevOpsPipelines: return environment(PipelinesWidgetSection(rows: rows))
        default: return environment(WidgetSectionView(size: size, rows: rows))
        }
    }

    package func widgetHeight(for section: SectionID, rows: Int) -> CGFloat {
        switch section {
        case .azureDevOpsSprint: return SprintWidgetSection.height(rows: rows)
        case .azureDevOpsPipelines: return PipelinesWidgetSection.height(rows: rows)
        default: return WidgetSectionView.height(rows: rows)
        }
    }

    package func widgetWidth(for section: SectionID, size: WidgetSize) -> CGFloat {
        size.width
    }

    package func widgetMenu(for section: SectionID) -> AnyView {
        environment(SourceMenuContent())
    }

    package func openNotification(_ userInfo: [String: String]) {
        if let link = userInfo["url"].flatMap(URL.init(string:)) {
            store?.openFromNotification(key: userInfo["pullRequest"], url: link)
        } else if !services.showPanel(.azureDevOpsPullRequests) {
            // Hidden from the menu bar: the pull requests in Azure DevOps instead.
            store?.openPullRequestsPage()
        }
    }

    // MARK: Settings

    package func settingsView() -> AnyView {
        environment(AzureDevOpsSettings())
    }

    package func statusView() -> AnyView? {
        guard store != nil else { return nil }
        return environment(SignInStatusView().environmentObject(services.notifier))
    }

    // MARK: Rendering

    package func loadForRendering() async {
        let store = makeStores(notifier: nil)
        await store.loadOnce()
        await sprint?.loadOnce()
        await pipelines?.loadOnce()
        // Let the on-device model word the brief before drawing.
        await store.summarizer.complete(store.brief.compactMap(store.briefRequest), timeout: 45)
    }
}

/// How the Azure CLI's sign-in and notifications stand, on Azure DevOps' page in Settings.
struct SignInStatusView: View {
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var notifier: Notifier

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(
                ok: store.problem?.needsSignIn != true,
                title: store.problem == .cliNotFound ? "The Azure CLI isn't installed"
                    : store.problem?.needsSignIn == true ? "Not signed in to the Azure CLI"
                    : store.hasLoaded ? "Signed in with the Azure CLI" : "Checking the Azure CLI's sign-in…",
                detail: store.problem?.needsSignIn == true
                    ? "BriefBar reads Azure DevOps with the Azure CLI's sign-in."
                    : "It renews itself, usually for months.",
                action: store.problem?.needsSignIn == true
                    ? (store.problem == .cliNotFound ? "Install the Azure CLI…" : "Sign In…") : nil
            ) { store.signIn() }
            if settings.notifications && notifier.isAvailable {
                row(
                    ok: !store.notificationsBlocked,
                    title: store.notificationsBlocked ? "Notifications are off for BriefBar" : "Notifications are on",
                    detail: store.notificationsBlocked
                        ? "Allow them in System Settings, or turn Notifications off below."
                        : "For replies, mentions, reviews, failing builds and pull requests that are ready.",
                    action: store.notificationsBlocked ? "Open System Settings…" : nil
                ) { Notifier.openSystemSettings() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { notifier.refreshStatus() }
    }

    private func row(ok: Bool, title: String, detail: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action {
                Button(action, action: perform)
            }
        }
    }
}

/// The Sprint or Pipelines section in a menu-bar item's popover: its widget's rows, every one of them, and a way to
/// open its page in a window, where there's room for the whole board.
struct WorkPanelView: View {
    let page: AzureDevOpsPage
    @EnvironmentObject private var sprint: SprintStore
    @EnvironmentObject private var pipelines: PipelinesStore
    @EnvironmentObject private var services: AppServices

    @LocalState private var contentHeight: CGFloat = 0
    private static let maxListHeight: CGFloat = 560

    private var rows: Int {
        switch page {
        case .sprint: max(sprint.board?.myWork.count ?? 0, 2)
        default: max(pipelines.statuses.count, 2)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                section
                    .padding(.bottom, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .panelListHeight(contentHeight, max: Self.maxListHeight)
            Divider()
            footer
        }
        .panelFrame(width: MenuPanelView.width)
    }

    @ViewBuilder
    private var section: some View {
        switch page {
        case .sprint: SprintWidgetSection(rows: rows, draggable: false)
        default: PipelinesWidgetSection(rows: rows, draggable: false)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                services.openWindow(page.section)
            } label: {
                Label("Open \(page.title)", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open the \(page.title) page in BriefBar's window")
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
