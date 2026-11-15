import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

/// BriefBar's Settings window: General; a page for each source; where sections show, and how; and what BriefBar does across
/// sources. As System Settings does, it gets taller but not wider, so its rows keep their width; it keeps its height and
/// place.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isOpen: Bool {
        window?.isVisible == true
    }

    func show(_ destination: SettingsDestination) {
        navigation.destination = destination
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model, navigation: navigation)
                .environmentObject(model.services)
                .environmentObject(model.services.loginItem))
            // The window keeps the height you give it, down to the smallest the view takes.
            host.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: host)
            window.title = "BriefBar Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = SettingsView.size
            window.contentMaxSize = NSSize(width: SettingsView.size.width, height: .greatestFiniteMagnitude)
            window.setContentSize(SettingsView.size)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("BriefBarSettings")
            if window.setFrameUsingName("BriefBarSettings") {
                // Its width, whatever was saved; its height, as you left it.
                let height = max(window.contentRect(forFrameRect: window.frame).height, SettingsView.size.height)
                window.setContentSize(NSSize(width: SettingsView.size.width, height: height))
            } else {
                window.center()
            }
            self.window = window
        }
        model.services.loginItem.refresh()
        window?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { model.windowDidClose() }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var destination: SettingsDestination? = .general
}

/// A page's name, its symbol and color, as the sidebar and the page's header show them, and what it's for, in a line.
@MainActor
struct SettingsPageInfo {
    var title: String
    var symbol: String
    var tint: Color
    var subtitle: String

    static let general = SettingsPageInfo(
        title: "General", symbol: "gearshape.fill", tint: Color(nsColor: .systemGray),
        subtitle: "Launch at login, updates and your sources at a glance"
    )
    static let appearance = SettingsPageInfo(
        title: "Appearance", symbol: "paintbrush.fill", tint: Color(nsColor: .systemIndigo),
        subtitle: "Text size in windows, and simpler ways to show what needs you"
    )
    static let pullRequests = SettingsPageInfo(
        title: PullRequestsSettingsPage.title, symbol: PullRequestsSettingsPage.symbol, tint: Color(nsColor: .systemGreen),
        subtitle: PullRequestsSettingsPage.summary
    )
    static let linksAndSummaries = SettingsPageInfo(
        title: "Links & Summaries", symbol: "link", tint: Color(red: 0.0, green: 0.60, blue: 0.80),
        subtitle: "What goes together across sources, and where it stands"
    )
    static let notifications = SettingsPageInfo(
        title: "Notifications", symbol: NotificationsPage.symbol, tint: Color(nsColor: .systemRed),
        subtitle: "What BriefBar notified you of, on a page of its window"
    )
    static let sendToCopilot = SettingsPageInfo(
        title: "Send to Copilot", symbol: "paperplane.fill", tint: Color(red: 0.86, green: 0.30, blue: 0.56),
        subtitle: "Hand work items and pull requests' fixes to Copilot"
    )
    static let agents = SettingsPageInfo(
        title: "Agents", symbol: AgentsText.symbol, tint: Color(nsColor: .systemPurple), subtitle: AgentsText.summary
    )

    static func layout(_ surface: Surface) -> SettingsPageInfo {
        let tint = switch surface {
        case .menuBar: Color(red: 0.27, green: 0.29, blue: 0.34)
        case .widgets: Color(nsColor: .systemTeal)
        case .windows: Color(nsColor: .systemBlue)
        }
        return SettingsPageInfo(title: surface.title, symbol: surface.symbol, tint: tint, subtitle: surface.subtitle)
    }

    /// A source's: its own name and symbol, the color of its first section, as the window's sidebar shows it, and what it
    /// shows.
    static func source(_ source: any BriefBarSource) -> SettingsPageInfo {
        SettingsPageInfo(
            title: source.name, symbol: source.symbol, tint: source.sections.first?.tint ?? .accentColor,
            subtitle: source.description.summary
        )
    }
}

extension SettingsPageHeader where Trailing == EmptyView {
    init(_ info: SettingsPageInfo) {
        self.init(symbol: info.symbol, tint: info.tint, title: info.title, subtitle: info.subtitle)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation

    /// How big it opens: its width, always, and the smallest it gets.
    static let size = CGSize(width: 740, height: 560)
    static let sidebarWidth: CGFloat = 200
    /// How wide a page is, beside the sidebar and its divider.
    static let pageWidth = size.width - sidebarWidth - 1

    @Environment(\.isRendering) private var isRendering

    var body: some View {
        HStack(spacing: 0) {
            // Offscreen, the list's own selection draws as a black capsule, which hides the page's name: the page's row has
            // the window's sidebar's highlight instead.
            List(selection: isRendering ? .constant(nil) : $navigation.destination) {
                SettingsSidebarRow(info: .general)
                    .sidebarRow(.general, selected: shownSelection)
                Section("Sources") {
                    ForEach(model.sources.map(\.id), id: \.self) { id in
                        if let source = model.source(id) {
                            SettingsSidebarRow(info: .source(source), state: model.state(of: id))
                                .sidebarRow(.source(id), selected: shownSelection)
                        }
                    }
                }
                Section("Display") {
                    ForEach(Surface.allCases, id: \.self) { surface in
                        SettingsSidebarRow(info: .layout(surface))
                            .sidebarRow(.layout(surface), selected: shownSelection)
                    }
                    SettingsSidebarRow(info: .appearance)
                        .sidebarRow(.appearance, selected: shownSelection)
                }
                Section("Features") {
                    SettingsSidebarRow(info: .pullRequests)
                        .sidebarRow(.pullRequests, selected: shownSelection)
                    SettingsSidebarRow(info: .linksAndSummaries)
                        .sidebarRow(.linksAndSummaries, selected: shownSelection)
                    SettingsSidebarRow(info: .notifications)
                        .sidebarRow(.notifications, selected: shownSelection)
                    if model.sources.contains(where: \.hasSendToCopilotSettings) {
                        SettingsSidebarRow(info: .sendToCopilot)
                            .sidebarRow(.sendToCopilot, selected: shownSelection)
                    }
                    AgentsSidebarRow(agents: model.agents)
                        .sidebarRow(.agents, selected: shownSelection)
                }
            }
            .listStyle(.sidebar)
            .frame(width: Self.sidebarWidth)

            Divider()

            ScrollView {
                SettingsPage(model: model, destination: navigation.destination ?? .general) { navigation.destination = $0 }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: Self.size.width)
        .frame(minHeight: Self.size.height, idealHeight: Self.size.height, maxHeight: .infinity)
        .interfaceOptions(from: model.services)
    }

    /// The page a picture shows as chosen, offscreen; nil on screen, where the list draws its own selection.
    private var shownSelection: SettingsDestination? {
        isRendering ? navigation.destination ?? .general : nil
    }
}

/// A page of the Settings window, beside its sidebar.
struct SettingsPage: View {
    @ObservedObject var model: AppModel
    let destination: SettingsDestination
    /// Goes to another page.
    var go: (SettingsDestination) -> Void

    var body: some View {
        switch destination {
        case .general:
            GeneralPage(model: model, go: go)
        case .appearance:
            AppearancePage(services: model.services)
        case .source(let id):
            if let source = model.source(id) {
                SourcePage(model: model, source: source, go: go)
                    .id(id)
            }
        case .layout(let surface):
            LayoutPage(model: model, surface: surface)
                .id(surface)
        case .pullRequests:
            PullRequestsSettingsPage(model: model, go: go)
        case .linksAndSummaries:
            LinksAndSummariesPage(links: model.services.links, summaries: model.services.summaries)
        case .notifications:
            NotificationsSettingsPage(model: model, recent: model.services.recentNotifications, go: go)
        case .sendToCopilot:
            SendToCopilotPage(model: model, go: go)
        case .agents:
            AgentsPage(agents: model.agents)
        }
    }
}

private extension View {
    /// A row of Settings' sidebar, for `destination`, with the window's sidebar's highlight while it's `selected`.
    func sidebarRow(_ destination: SettingsDestination, selected: SettingsDestination?) -> some View {
        tag(destination)
            .listRowBackground(selected == destination
                ? RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.10)).padding(.horizontal, 10)
                : nil)
    }
}

/// A page in Settings' sidebar: its symbol on its colored tile, as the window's sidebar has a page's, and its name; for a
/// source, and agents, whether it's on.
struct SettingsSidebarRow: View {
    let info: SettingsPageInfo
    var state: SourceState?

    var body: some View {
        HStack(spacing: 8) {
            SymbolTile(symbol: info.symbol, tint: info.tint, size: 22)
            Text(info.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            switch state {
            case .on:
                Text("On")
                    .font(style: .caption)
                    .foregroundStyle(.secondary)
            case .needsReview:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(ItemState.needsYou.color)
                    .help("Waiting for you to look at what it reads now")
                    .accessibilityLabel("Paused")
            case .off, nil:
                EmptyView()
            }
        }
    }
}

/// Whether a source, or agents, is on, in a page's header: its symbol in its state's color, and the word in the color
/// that reads on the page.
struct SourceStateLabel: View {
    let state: SourceState

    var body: some View {
        switch state {
        case .on:
            Label {
                Text("On")
                    .foregroundStyle(ItemState.done.textColor)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ItemState.done.color)
            }
        case .needsReview:
            Label {
                Text("Paused")
                    .foregroundStyle(ItemState.needsYou.textColor)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(ItemState.needsYou.color)
            }
        case .off:
            Text("Off")
                .foregroundStyle(.secondary)
        }
    }
}

/// A row that opens another page of Settings, as System Settings' rows do: its name, what's there, and ›.
struct SettingsLinkRow: View {
    let title: String
    let caption: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(caption)
                        .font(style: .subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SettingsChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(title) in Settings")
    }
}

/// The › at the end of a row that opens another page.
struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(style: .footnote, weight: .semibold)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

// MARK: - General

/// General: launching at login and updates, each source's state, with a way to its page, and the version.
struct GeneralPage: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var loginItem: LoginItem
    @Environment(\.isRendering) private var isRendering
    var go: (SettingsDestination) -> Void

    var body: some View {
        // Only the installed app launches at login and updates itself; a picture shows them all the same.
        let launches = loginItem.isAvailable || isRendering
        let updates = model.services.updates
        Form {
            Section {
                SettingsPageHeader(.general)
            }
            if launches || updates.isAvailable || isRendering {
                Section {
                    if launches {
                        LaunchAtLoginSetting(loginItem: loginItem)
                    }
                    UpdateSettings(updates: updates, showsAnyway: isRendering)
                }
            }
            Section {
                ForEach(model.sources, id: \.id) { source in
                    SourceSummaryRow(source: source, state: model.state(of: source.id)) {
                        go(.source(source.id))
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Each is off until you turn it on, after it says what it reads.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                AboutRow(updates: updates)
            }
        }
        .settingsForm()
    }
}

/// Launch BriefBar at Login, and what to do when macOS holds it, or it failed.
private struct LaunchAtLoginSetting: View {
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        SettingToggle(
            "Launch BriefBar at Login", caption: "Starts BriefBar when you log in to your Mac.",
            isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })
        )
        if loginItem.needsApproval {
            LabeledContent {
                Button("Allow in Login Items Settings…") { loginItem.openSystemSettings() }
            } label: {
                Text("macOS holds it until you allow it.")
                    .foregroundStyle(.secondary)
            }
        } else if let error = loginItem.lastError {
            Text("Launch at Login failed: \(error)")
                .foregroundStyle(.secondary)
        }
    }
}

/// Whether BriefBar checks for updates by itself, when it updates itself.
struct UpdateSettings: View {
    @ObservedObject var updates: UpdateStatus
    /// For a picture: shown even where the app doesn't update itself.
    var showsAnyway = false

    var body: some View {
        if updates.isAvailable || showsAnyway {
            SettingToggle(
                "Check for Updates Automatically", caption: "Checks once a day, and offers each new version.",
                isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) })
            )
        }
    }
}

/// BriefBar's icon, name and version, with Check for Updates… when it updates itself, and Quit.
private struct AboutRow: View {
    @ObservedObject var updates: UpdateStatus

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(isBundled: AppIdentity.isBundled, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("BriefBar")
                    .font(style: .headline)
                Text("Version \(AppIdentity.version)")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if updates.isAvailable {
                Button("Check for Updates…") { updates.check() }
                    .disabled(!updates.canCheck)
            }
            Button("Quit BriefBar") { NSApp.terminate(nil) }
        }
    }
}

/// A source on General, in a line that opens its page, as the rows that open another page do: its symbol, its name,
/// whether it's on, and ›.
struct SourceSummaryRow: View {
    let source: any BriefBarSource
    let state: SourceState
    var open: () -> Void

    var body: some View {
        let info = SettingsPageInfo.source(source)
        Button(action: open) {
            HStack(spacing: 10) {
                SymbolTile(symbol: info.symbol, tint: info.tint, size: 26)
                Text(source.name)
                Spacer(minLength: 8)
                Text(stateWord)
                    .foregroundStyle(state == .needsReview ? AnyShapeStyle(ItemState.needsYou.textColor) : AnyShapeStyle(.secondary))
                SettingsChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(source.name)
        .accessibilityValue(stateWord)
        .accessibilityHint("Opens its page in Settings")
    }

    private var stateWord: String {
        switch state {
        case .on: "On"
        case .needsReview: "Paused"
        case .off: "Off"
        }
    }
}

// MARK: - Links & Summaries

/// Show Links, and Summaries, which build on its links.
struct LinksAndSummariesPage: View {
    @ObservedObject var links: Links
    let summaries: StorySummaries

    var body: some View {
        Form {
            Section {
                SettingsPageHeader(.linksAndSummaries)
            }
            Section {
                SettingToggle(
                    LinksSetting.title, caption: LinksSetting.caption, info: LinksSetting.explanation,
                    isOn: Binding(get: { links.isOn }, set: { links.setOn($0) })
                )
            }
            Section {
                SummariesSettingRows(summaries: summaries, links: links)
            } footer: {
                if !links.isOn {
                    Text("Summaries need Show Links: turn it on first.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsForm()
    }
}

// MARK: - Notifications

/// The Notifications page in the window, off until you turn it on, and how long it keeps what BriefBar posted; and the way
/// to the notifications a source posts, which are its own.
struct NotificationsSettingsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recent: RecentNotifications
    var go: (SettingsDestination) -> Void

    var body: some View {
        Form {
            Section {
                SettingsPageHeader(.notifications)
            }
            Section {
                NotificationsSetting(recent: recent)
            }
            if let azureDevOps = model.source(.azureDevOps) {
                Section {
                    SettingsLinkRow(
                        title: "\(azureDevOps.name)' Notifications",
                        caption: "Replies, mentions, reviews and builds, on \(azureDevOps.name)' own page."
                    ) {
                        go(.source(.azureDevOps))
                    }
                }
            }
        }
        .settingsForm()
    }
}

/// The Notifications page, off until you turn it on, and how long it keeps what BriefBar posted, as rows of a form.
struct NotificationsSetting: View {
    @ObservedObject var recent: RecentNotifications

    static let title = "Notifications Page"
    static let caption = "Lists what BriefBar notified you of in its window, even what macOS didn't show."
    static let explanation = """
        Lists what BriefBar notified you of, from every source, on a page in its window, after the Overview, so you can \
        see what you missed, even what macOS didn't show. Click one to open what it's about. The page shows only while \
        it lists something. BriefBar keeps them in memory only, so the page starts empty when BriefBar restarts.
        """

    var body: some View {
        SettingToggle(
            Self.title, caption: Self.caption, info: Self.explanation,
            isOn: Binding(get: { recent.isOn }, set: { recent.setOn($0) })
        )
        if recent.isOn {
            Picker(selection: Binding(get: { recent.keepHours }, set: { recent.setKeepHours($0) })) {
                ForEach(NotificationsPage.keepChoices, id: \.hours) { Text($0.title).tag($0.hours) }
            } label: {
                Text("Keep Notifications For")
                Text("How long the page keeps them, in memory only.")
            }
            .pickerStyle(.menu)
        }
    }
}

// MARK: - Send to Copilot

/// Send Work to Copilot, from the sources that have it: Azure DevOps. While it's off or paused, its settings show all the
/// same, disabled, saying why, with a way to its page, as the Pull Requests page does.
struct SendToCopilotPage: View {
    @ObservedObject var model: AppModel
    /// Whether each source is on: as it is, or, for `--render`, as the picture shows it.
    let state: @MainActor (SourceID) -> SourceState
    var go: (SettingsDestination) -> Void

    init(model: AppModel, state: (@MainActor (SourceID) -> SourceState)? = nil, go: @escaping (SettingsDestination) -> Void) {
        self.model = model
        self.state = state ?? { [model] in model.state(of: $0) }
        self.go = go
    }

    var body: some View {
        Form {
            Section {
                SettingsPageHeader(.sendToCopilot)
            }
            ForEach(model.sources.filter(\.hasSendToCopilotSettings), id: \.id) { source in
                if let notice = notice(source) {
                    Section {
                        notice
                    }
                }
                source.sendToCopilotSettingsView(state: state(source.id))
            }
        }
        .settingsForm()
    }

    /// What it says while its source isn't on, with a way to its page.
    private func notice(_ source: any BriefBarSource) -> PullRequestSettingsNotice? {
        let state = state(source.id)
        guard let text = PullRequestSettings.notice(names: [source.name], states: [state], count: 1) else { return nil }
        let action = state == .needsReview
            ? PullRequestSettingsNotice.Action(title: "Review…", label: "Review \(source.name)…") { go(.source(source.id)) }
            : PullRequestSettingsNotice.Action(title: "Turn On…", label: "Turn On \(source.name)…") { go(.source(source.id)) }
        return PullRequestSettingsNotice(text: text, action: action)
    }
}

// MARK: - A source

/// A source's page: before it's on, what it reads, with Turn On; while it's paused, what it reads now, with Keep It On;
/// while it's on, how what it needs stands, its settings, the ways to its settings on other pages, what it reads, and Turn
/// Off.
struct SourcePage: View {
    @ObservedObject var model: AppModel
    let source: any BriefBarSource
    /// Goes to another page.
    var go: (SettingsDestination) -> Void

    @LocalState private var confirmingTurnOff = false
    @LocalState private var offeringToRemoveAccess = false

    private var state: SourceState { model.state(of: source.id) }

    var body: some View {
        Form {
            Section {
                SettingsPageHeader(
                    symbol: SettingsPageInfo.source(source).symbol, tint: SettingsPageInfo.source(source).tint,
                    title: source.name, subtitle: source.description.summary
                ) {
                    SourceStateLabel(state: state)
                }
            }
            switch state {
            case .off:
                Section {
                    DescriptionRows(description: source.description)
                } footer: {
                    HStack(alignment: .center, spacing: 12) {
                        Text("You can turn it off at any time. Turning it off deletes what BriefBar saved for it.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        turnOnButton(title: "Turn On \(source.name)")
                    }
                }
            case .needsReview:
                Section {
                    Label {
                        Text("\(source.name) is paused: since you turned it on, an update changed what it reads. Here's what it reads now.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(ItemState.needsYou.color)
                    }
                    DescriptionRows(description: source.description)
                } footer: {
                    HStack {
                        Spacer()
                        Button("Turn It Off") { model.turnOff(source.id) }
                        turnOnButton(title: "Keep It On")
                    }
                }
            case .on:
                if let status = source.statusView() {
                    Section {
                        status
                    }
                }
                Section {
                    source.settingsView()
                }
                let pullRequests = PullRequestSettings.has(source.id, ownSettings: source.pullRequestSettings)
                if pullRequests || source.hasSendToCopilotSettings {
                    Section {
                        if pullRequests {
                            SettingsLinkRow(title: PullRequestsSettingsPage.title, caption: "Its settings about pull requests.") {
                                go(.pullRequests)
                            }
                        }
                        if source.hasSendToCopilotSettings {
                            SettingsLinkRow(title: SettingsPageInfo.sendToCopilot.title, caption: "Send Work to Copilot, and how it sends work.") {
                                go(.sendToCopilot)
                            }
                        }
                    } header: {
                        Text("On Other Pages")
                    }
                }
                Section {
                    DisclosureGroup("What it reads") {
                        DescriptionRows(description: source.description)
                    }
                } footer: {
                    HStack {
                        Spacer()
                        Button("Turn Off \(source.name)…") { confirmingTurnOff = true }
                    }
                }
            }
        }
        .settingsForm()
        .alert("Turn off \(source.name)?", isPresented: $confirmingTurnOff) {
            Button("Turn Off", role: .destructive) { turnOff() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BriefBar stops reading it, removes it from the menu bar and deletes what it saved for it. Its settings stay.")
        }
        .alert(FullDiskAccess.removalTitle, isPresented: $offeringToRemoveAccess) {
            Button("Open Privacy Settings") { FullDiskAccess.openPrivacySettingsPane() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(FullDiskAccess.removalMessage)
        }
    }

    private func turnOnButton(title: String) -> some View {
        Button(title) { model.turnOn(source.id) }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
    }

    private func turnOff() {
        // Whether it needs the access now, rather than whether it can: Azure DevOps only does for pull requests
        // sent in chats.
        let access = model.services.fullDiskAccess
        let neededAccess = access.isRequested(by: source.id)
        model.turnOff(source.id)
        if neededAccess && !access.isNeeded {
            offeringToRemoveAccess = true
        }
    }
}

/// What a source reads, where it connects and what it needs, or what agents get, as rows of a form, one for each.
struct DescriptionRows: View {
    let entries: [DescriptionBox.Entry]

    init(entries: [DescriptionBox.Entry]) {
        self.entries = entries
    }

    init(description: SourceDescription) {
        self.init(entries: [
            .init(title: "What BriefBar reads", symbol: "doc.text.magnifyingglass", text: description.reads),
            .init(title: "Network", symbol: "network", text: description.network),
            .init(title: "What it needs", symbol: "lock.shield", text: description.needs),
        ])
    }

    var body: some View {
        ForEach(entries.indices, id: \.self) { index in
            let entry = entries[index]
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: entry.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(style: .headline)
                    Text(entry.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
