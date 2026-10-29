import AppKit
import BriefBarCore
import BriefBarUI
import Combine
import NotificationCenterDB
import SwiftUI
import TeamsCore

/// Your unread Microsoft Teams chats, from the notifications Teams sends to Notification Center: 1:1 chats
/// and group chats, each a section of its own. Reading Notification Center's database needs Full Disk
/// Access, which macOS grants to all of BriefBar, and so does reading how far you've read each chat from Teams'
/// own data.
@MainActor
package final class TeamsSource: BriefBarSource {
    nonisolated package static let descriptionVersion = 2

    package let id = SourceID.teams
    package let name = "Microsoft Teams"
    package let symbol = "bubble.left.and.text.bubble.right"
    package let description = SourceDescription(
        version: TeamsSource.descriptionVersion,
        summary: "Your unread Teams chats: 1:1 chats, and group and meeting chats",
        reads: "The notifications Teams sends to Notification Center, from Notification Center's database on this Mac, read-only. BriefBar keeps only your unread chats (each chat's name, and its unread messages' sender and text), encrypted with a key in your login keychain, until they're read. It also reads how far you've read each chat in Teams, from Teams' own data on this Mac, read-only, keeping only that, in memory, so chats you read in Teams are read here too (you can turn this off); and Teams' dock badge, to see when you've read everything in Teams. With Show Message Previews and Summarize with Apple Intelligence on, Apple's on-device model writes summaries on your Mac: a chat's when you ask for one, and the brief's while a list by state or the window's Overview shows your chats.",
        network: "None. Nothing about your chats leaves your Mac.",
        needs: "Full Disk Access, which macOS requires to read Notification Center's database and Teams' own data. macOS has no prompt for it, so BriefBar walks you through System Settings. It's for all of BriefBar, once: only sources you turn on that read Notification Center use it.",
        requirements: [.fullDiskAccess]
    )
    /// Their widgets start hidden: a widget would put your chats on the desktop after an update.
    package let sections = [ChatGroup.chats, .groups].map { group in
        SectionInfo(
            id: group.section, title: group.title, symbol: group.symbol, tint: group.color,
            counted: group == .chats ? CountNoun("chat", "chats") : CountNoun("group chat", "group chats"), states: [.needsYou],
            surfaces: [.menuBar, .widgets, .windows], hiddenAtFirst: [.widgets]
        )
    }
    package var panelWidth: CGFloat { MenuPanelView.width }

    private static let accessReason = "BriefBar finds your unread Teams chats in the notifications that macOS keeps in Notification Center."

    private let services: AppServices
    let settings: AppSettings
    private let summarizer = Summarizer()
    /// Made when Teams starts, never while it's off: making one reads the saved chats and their key.
    private var store: ConversationStore?
    private var badgeMonitor: BadgeMonitor?
    private let changes = PassthroughSubject<Void, Never>()
    private var cancellables: Set<AnyCancellable> = []

    package init(services: AppServices) {
        self.services = services
        settings = AppSettings(defaults: services.defaults)
    }

    /// Notification Center's database, or for the demo, only the made-up one `BRIEFBAR_TEAMS_DB` names.
    private func storage(readOnly: Bool = false) -> StorageMode {
        let storage = services.isDemo ? StorageMode.demo() : StorageMode.current()
        return readOnly ? storage.readOnly : storage
    }

    private func environment<V: View>(_ view: V, store: ConversationStore) -> some View {
        view
            .interfaceOptions(from: services)
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(summarizer)
            .environmentObject(services)
            .environmentObject(services.loginItem)
            .environmentObject(services.fullDiskAccess)
    }

    // MARK: Lifecycle

    package func start() {
        guard store == nil else { return }
        let store = ConversationStore(settings: settings, storage: storage())
        self.store = store
        let access = services.fullDiskAccess
        // Only Notification Center's own database needs the access; the demo's doesn't.
        if store.paths.isSystemDatabase {
            let database = store.paths.database
            access.register(.teams, name: "Teams", reason: Self.accessReason) {
                DatabaseAccess.check(database) == .granted
            }
        }

        store.$state.map { _ in () }
            .merge(with: store.$problem.removeDuplicates().map { _ in () })
            .sink { [weak self] in MainActor.assumeIsolated { self?.changes.send() } }
            .store(in: &cancellables)
        store.$access
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak store] status in
                MainActor.assumeIsolated {
                    guard let store, store.paths.isSystemDatabase else { return }
                    access.report(granted: status == .granted)
                }
            }
            .store(in: &cancellables)
        // Without access, start with the steps to grant it.
        store.$access
            .compactMap { $0 }
            .first()
            .sink { status in
                MainActor.assumeIsolated {
                    if status == .denied { access.show() }
                }
            }
            .store(in: &cancellables)
        // The access window saw it granted: read now rather than at the next check.
        access.$isGranted
            .removeDuplicates()
            .filter { $0 == true }
            .sink { [weak store] _ in MainActor.assumeIsolated { store?.refresh() } }
            .store(in: &cancellables)

        store.start()
        let badgeMonitor = BadgeMonitor(store: store, settings: settings)
        badgeMonitor.start()
        self.badgeMonitor = badgeMonitor
        changes.send()
    }

    package func stop() {
        badgeMonitor?.stop()
        badgeMonitor = nil
        store?.stop()
        cancellables.removeAll()
        services.fullDiskAccess.unregister(.teams)
    }

    package func deleteSavedData() {
        store?.finishSaving()
        ConversationStore.deleteSavedData(storage())
        store = nil
    }

    // MARK: Menu bar

    private func group(_ section: SectionID) -> ChatGroup {
        section == .teamsGroupChats ? .groups : .chats
    }

    package func segment(for section: SectionID) -> MenuBarSegment {
        let group = group(section)
        let count = store?.state.count(group) ?? 0
        let states = store?.state.states(group) ?? StateCounts()
        let problem = store?.problem
        let attention = problem?.isBlocking == true
        let blocking = attention ? problem.map { "Teams: \($0.title)" } : nil
        var summary = "Teams: " + group.unreadDescription(count).lowercased()
        if let problem, attention {
            summary += ". " + problem.title
        }
        // With nothing unread, just the symbol in the menu bar's own color; with unread chats, the
        // symbol in the section's color and the count.
        guard count > 0 || attention else {
            return MenuBarSegment(glyph: group.symbol, title: NSAttributedString(), summary: summary, count: 0, needsAttention: false,
                                  states: states)
        }
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        title.append(MenuBarDrawing.symbol(group.symbol, color: count > 0 ? group.nsColor : .labelColor, font: font))
        if count > 0 {
            title.append(MenuBarDrawing.count(count, font: font))
        }
        if attention {
            title.append(NSAttributedString(string: "\u{2009}"))
            title.append(MenuBarDrawing.symbol("exclamationmark.triangle.fill", color: .systemOrange, font: font, scale: 0.75))
        }
        return MenuBarSegment(glyph: nil, title: title, summary: summary, count: count, needsAttention: true, states: states,
                              problem: blocking)
    }

    package var segmentsChanged: AnyPublisher<Void, Never> {
        changes.eraseToAnyPublisher()
    }

    /// Unread chats, each in a sentence: who wrote and how many, and what only while Show Message Previews is on.
    /// Apple Intelligence words a chat only while summaries are on too.
    package func briefLines(for section: SectionID) -> [BriefLine] {
        guard let store else { return [] }
        let showsText = settings.showPreviews
        let summarizes = settings.showPreviews && settings.showSummaries
        return store.state.unread(in: group(section)).map { conversation in
            // The chat's ✨ summary, once it has one: the brief says it the same way.
            var summary: String?
            if summarizes, case .done(let text)? = summarizer.state(for: conversation) {
                summary = "\(conversation.name): \(text)"
            }
            return BriefLine(
                id: "teams/" + SummaryPrompt.key(for: conversation) + (showsText ? "/text" : ""), source: id, state: .needsYou,
                date: conversation.unread.last?.deliveredAt ?? conversation.lastActivity,
                sentence: SummaryPrompt.briefSentence(for: conversation, showsText: showsText),
                request: summarizes && summary == nil
                    ? BriefRequest(prompt: SummaryPrompt.prompt(for: conversation), instructions: SummaryPrompt.instructions,
                                   lead: "\(conversation.name): ")
                    : nil,
                written: summary,
                open: { [weak store] in store?.open(conversation) }
            )
        }
    }

    /// The chats, and their summaries as they arrive; and what the brief may say of them, at once when you change it.
    package var stateRowsChanged: AnyPublisher<Void, Never> {
        changes
            .merge(with: summarizer.objectWillChange.map { _ in () })
            // Sent once the new value is stored: `@Published` sends before.
            .merge(with: settings.$showPreviews.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).map { _ in () })
            .merge(with: settings.$showSummaries.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).map { _ in () })
            .eraseToAnyPublisher()
    }

    /// Unread chats need you, the newest message first.
    package func stateRows(for section: SectionID) -> [StateRow] {
        guard let store else { return [] }
        return store.state.unread(in: group(section)).map { conversation in
            StateRow(
                id: conversation.id, state: .needsYou, date: conversation.unread.last?.deliveredAt ?? conversation.lastActivity,
                view: AnyView(environment(ChatRow(conversation: conversation), store: store))
            )
        }
    }

    package func panel(for section: SectionID) -> AnyView {
        guard let store else { return AnyView(EmptyView()) }
        return AnyView(environment(MenuPanelView(group: group(section)), store: store))
    }

    package func panelWillShow(_ section: SectionID) {
        store?.refresh()
    }

    // MARK: Widgets

    package func widget(for section: SectionID, size: WidgetSize, rows: Int) -> AnyView {
        guard let store else { return AnyView(EmptyView()) }
        return AnyView(environment(WidgetSectionView(group: group(section), rows: rows), store: store))
    }

    package func widgetHeight(for section: SectionID, rows: Int) -> CGFloat {
        WidgetSectionView.height(rows: rows, options: services.interfaceOptions)
    }

    package func widgetWidth(for section: SectionID, size: WidgetSize) -> CGFloat {
        size == .compact ? 270 : 320
    }

    package func widgetMenu(for section: SectionID) -> AnyView {
        guard let store else { return AnyView(EmptyView()) }
        return AnyView(environment(SourceMenuContent(), store: store))
    }

    // MARK: Settings

    package func settingsView() -> AnyView {
        AnyView(TeamsSettings().environmentObject(settings))
    }

    package func statusView() -> AnyView? {
        guard let store, store.paths.isSystemDatabase else { return nil }
        return AnyView(environment(AccessStatusView(), store: store))
    }

    // MARK: Rendering

    package func loadForRendering() async {
        let store = ConversationStore(settings: settings, storage: storage(readOnly: true))
        store.receive(NotificationEngine.loadOnce(paths: store.paths))
        if ConversationStore.readsMarkers(following: settings.followReadsInTeams, cache: store.storage.cache, access: store.access),
           let cache = store.storage.cache {
            store.receive(ReadMarkerEngine.loadOnce(location: cache))
        }
        self.store = store
        if store.paths.isSystemDatabase {
            services.fullDiskAccess.register(.teams, name: "Teams", reason: Self.accessReason) { false }
        }
        // BRIEFBAR_RENDER_SUMMARIES=1 summarizes the unread chats first, with the on-device model.
        if ProcessInfo.processInfo.environment["BRIEFBAR_RENDER_SUMMARIES"] == "1", Summarizer.unavailableReason == nil {
            let unread = ChatGroup.allCases.flatMap { store.state.unread(in: $0) }
            unread.forEach(summarizer.summarize)
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, unread.contains(where: { summarizer.state(for: $0) == .loading }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    package func extraRenderings() -> [(name: String, view: AnyView)] {
        if !services.fullDiskAccess.isNeeded {
            services.fullDiskAccess.register(.teams, name: "Teams", reason: Self.accessReason) { false }
        }
        let window = FullDiskAccessView()
            .environmentObject(services.fullDiskAccess)
            .background(Color(nsColor: .windowBackgroundColor))
        return [(name: "full-disk-access", view: AnyView(window))]
    }
}

/// Whether BriefBar can read Notification Center, on Teams' page in Settings.
struct AccessStatusView: View {
    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var access: FullDiskAccess

    var body: some View {
        let granted = store.access == .granted
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(granted ? "Full Disk Access is on" : "BriefBar can't read Notification Center yet")
                    .font(style: .headline)
                Text(granted
                     ? "BriefBar reads Teams' notifications as they arrive."
                     : "It needs Full Disk Access, which you give it in System Settings, once.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Set Up Full Disk Access…") { access.show() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension ChatGroup {
    /// The section that lists its chats.
    var section: SectionID { self == .chats ? .teamsChats : .teamsGroupChats }
}
