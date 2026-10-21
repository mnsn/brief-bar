import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import SwiftUI

/// Your Azure DevOps pull requests, by what they need: you, a fix, completing, or someone else. It reads
/// Azure DevOps with the Azure CLI's sign-in, the only source that uses the network, and posts
/// notifications.
@MainActor
package final class AzureDevOpsSource: BriefBarSource {
    nonisolated package static let descriptionVersion = 1

    package let id = SourceID.azureDevOps
    package let name = "Azure DevOps"
    package let symbol = "arrow.triangle.pull"
    package let description = SourceDescription(
        version: AzureDevOpsSource.descriptionVersion,
        summary: "Your pull requests: which need you, which are failing and which are ready to complete",
        reads: "Your pull requests and the ones you review, in the organizations you choose, with their builds, policies and comment threads, from Azure DevOps. BriefBar keeps which pull requests you've seen, and your organizations. When Apple Intelligence is on, a brief of what needs you is written on your Mac by Apple's on-device model.",
        network: "Azure DevOps only: dev.azure.com, and app.vssps.visualstudio.com to find your organizations, with your Azure CLI sign-in. Every request is a GET, so it never changes anything there: about 10 to 25 small requests a minute.",
        needs: "The Azure CLI, signed in with az login: BriefBar gets its tokens from it, so there's no personal access token, and runs it without any of BriefBar's own permissions. And permission to post notifications, which macOS asks for when you turn it on.",
        requirements: [.azureCLI, .notifications]
    )
    package let sections = [
        SectionInfo(
            id: .azureDevOpsPullRequests, title: "Pull Requests", symbol: "arrow.triangle.pull",
            tint: Color(red: 0.33, green: 0.45, blue: 0.96), surfaces: [.menuBar, .widgets, .windows]
        ),
    ]
    package var panelWidth: CGFloat { MenuPanelView.width }

    private let services: AppServices
    let settings: AppSettings
    /// Made when Azure DevOps starts, so its notifications count from then.
    private var store: PRStore?
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

    private func environment<V: View>(_ view: V, store: PRStore) -> some View {
        view
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(services)
            .environmentObject(services.loginItem)
    }

    // MARK: Lifecycle

    package func start() {
        guard store == nil else { return }
        if !services.isDemo {
            settings.startSeeing()
        }
        let store = PRStore(settings: settings, notifier: services.notifier, mode: services.isDemo ? .demo : .live)
        self.store = store
        store.$counts.removeDuplicates().map { _ in () }
            .merge(with: settings.$showToReview.removeDuplicates().map { _ in () })
            .merge(with: store.$problem.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.changes.send() } }
            .store(in: &cancellables)

        store.start()
        changes.send()
    }

    package func didTurnOn() {
        // You just turned it on, having read that it posts notifications: macOS asks now.
        if settings.notifications {
            services.notifier.requestAuthorization()
        }
    }

    package func stop() {
        cancellables.removeAll()
        store?.stop()
        store = nil
    }

    package func deleteSavedData() {
        settings.forgetSeen()
    }

    // MARK: Menu bar

    package func segment(for section: SectionID) -> MenuBarSegment {
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
        guard let store else { return AnyView(EmptyView()) }
        return AnyView(environment(MenuPanelView(), store: store))
    }

    package func panelWillShow(_ section: SectionID) {
        store?.refreshIfStale()
    }

    // MARK: Widgets

    package func widget(for section: SectionID, size: WidgetSize, rows: Int) -> AnyView {
        guard let store else { return AnyView(EmptyView()) }
        return AnyView(environment(WidgetSectionView(size: size, rows: rows), store: store))
    }

    package func widgetHeight(for section: SectionID, rows: Int) -> CGFloat {
        WidgetSectionView.height(rows: rows)
    }

    package func widgetWidth(for section: SectionID, size: WidgetSize) -> CGFloat {
        size.width
    }

    package func widgetMenu(for section: SectionID) -> AnyView {
        guard let store else { return AnyView(EmptyView()) }
        return AnyView(environment(SourceMenuContent(), store: store))
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
        guard let store else { return AnyView(EmptyView()) }
        return AnyView(environment(AzureDevOpsSettings(), store: store))
    }

    package func statusView() -> AnyView? {
        guard let store else { return nil }
        return AnyView(environment(SignInStatusView(), store: store).environmentObject(services.notifier))
    }

    // MARK: Rendering

    package func loadForRendering() async {
        let store = PRStore(settings: settings, mode: services.isDemo ? .demo : .live)
        self.store = store
        // Let the on-device model word the brief before drawing.
        await store.loadOnce()
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
