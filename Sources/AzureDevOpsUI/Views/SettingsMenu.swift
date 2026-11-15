import AppKit
import AzureDevOpsCore
import BriefBarUI
import SwiftUI

/// The gear menu in the popover.
struct SettingsMenuContent: View {
    var body: some View {
        SourceMenuContent()
        Divider()
        AppMenuItems(source: .azureDevOps)
    }
}

/// What you'd change of Azure DevOps in the moment, and a way to open it: in the gear menu, and in a widget's context menu.
/// The rest are in Settings.
struct SourceMenuContent: View {
    @EnvironmentObject private var store: PRStore

    var body: some View {
        AzureDevOpsSettings(place: .menu)
        Divider()
        Button("Open Azure DevOps") { store.openPullRequestsPage() }
    }
}

/// One of Azure DevOps' settings. The Settings window has each in one place: its page; for those about its pull requests,
/// the Pull Requests page; or, for Send Work to Copilot, the Send to Copilot page (`AzureDevOpsSettings.Place`). Its menus
/// have those you'd change in the moment too. They're kept in its settings either way, so a menu and the window show the
/// same.
enum AzureDevOpsSetting: CaseIterable, Sendable {
    case notifications
    case summaries
    case showToReview
    case followMerges
    case opensPullRequestsInBriefBar
    case chatLinks
    case refresh
    case keepDone
    case idle
    case organizations
    case watchedPullRequests
    case makesChanges
    case copilot

    /// Its name, as it shows.
    var title: String {
        switch self {
        case .notifications: "Notifications"
        case .summaries: "Summaries by Apple Intelligence"
        case .showToReview: "Show To Review in the Menu Bar"
        case .followMerges: "Follow Pipelines After You Merge"
        case .opensPullRequestsInBriefBar: OpenInBriefBarSetting.title
        case .chatLinks: ChatLinksSetting.title
        case .refresh: "Refresh"
        case .keepDone: "Keep Done For"
        case .idle: "Idle After No Activity For"
        case .organizations: "Organizations"
        case .watchedPullRequests: WatchedPullRequestsSetting.title
        case .makesChanges: MakeChangesSetting.title
        case .copilot: CopilotSetting.title
        }
    }

    /// What it does for you, in a line under it in Settings.
    var caption: String {
        switch self {
        case .notifications: "Tells you of replies, mentions, reviews, failing builds and ready pull requests."
        case .summaries: "Shows a brief of what needs you, written on this Mac by Apple Intelligence."
        case .showToReview: "Counts the pull requests you review in the menu bar too."
        case .followMerges: "Lists the pipelines that run after your pull requests merge, while Done keeps them."
        case .opensPullRequestsInBriefBar: "Opens a pull request in BriefBar's window, rather than in Azure DevOps."
        case .chatLinks: "Lists a pull request as needing you when someone sends you its link."
        case .refresh: "How often BriefBar reads Azure DevOps."
        case .keepDone: "How long completed and abandoned pull requests stay in Done."
        case .idle: "Pull requests with no activity for this long move to Idle."
        case .organizations: "Which of your organizations BriefBar reads."
        case .watchedPullRequests: "Pull requests you're not on, listed as if you reviewed them."
        case .makesChanges: "Writes your replies, statuses, tags, sprints and states to Azure DevOps, when you click."
        case .copilot: "Sends work items, and fixes for your pull requests, to Copilot on this Mac."
        }
    }

    /// On the Pull Requests page in Settings rather than Azure DevOps' own: which of its pull requests it lists and counts,
    /// and for how long, where one opens, and what you change on them. The rest are about all it reads, its sprint and
    /// pipelines too: its notifications, which tasks sent to Copilot post too, the brief it words with Apple Intelligence,
    /// how often it reads and from which organizations; and Send Work to Copilot, which sends the sprint's work items as
    /// well as pull requests' work, and whose prompt is the work items', on a page of its own.
    var isAboutPullRequests: Bool {
        switch self {
        case .showToReview, .followMerges, .opensPullRequestsInBriefBar, .chatLinks, .keepDone, .idle, .watchedPullRequests,
             .makesChanges:
            true
        case .notifications, .summaries, .refresh, .organizations, .copilot:
            false
        }
    }

    /// In its menus too: what you'd change in the moment, such as its notifications during a meeting, or a pull request to
    /// watch from a link you've just been sent. The rest you set once, in Settings.
    var isForTheMoment: Bool {
        switch self {
        case .notifications, .watchedPullRequests:
            true
        case .summaries, .showToReview, .followMerges, .opensPullRequestsInBriefBar, .chatLinks, .refresh, .keepDone, .idle,
             .organizations, .makesChanges, .copilot:
            false
        }
    }
}

/// Azure DevOps' settings, where they show.
struct AzureDevOpsSettings: View {
    /// Where they show, and so which of them.
    enum Place: Sendable {
        /// Its gear menu and its widgets' menus: those you'd change in the moment.
        case menu
        /// Its page in Settings: those about all it reads, but Send Work to Copilot.
        case ownPage
        /// The Pull Requests page in Settings: those about pull requests, whether Azure DevOps is on or not, so without its
        /// store while it's off (`\.prStore`).
        case pullRequestsPage
        /// The Send to Copilot page in Settings: Send Work to Copilot, with where it sends work and how, whether Azure DevOps
        /// is on or not.
        case sendToCopilotPage

        /// Those it shows, in a group for each part of a menu, in the order they show.
        var groups: [[AzureDevOpsSetting]] {
            let all: [[AzureDevOpsSetting]] = [
                [.notifications, .summaries, .showToReview, .followMerges, .opensPullRequestsInBriefBar, .chatLinks],
                [.refresh, .keepDone, .idle, .organizations, .watchedPullRequests],
                [.makesChanges, .copilot],
            ]
            return all.map { group in group.filter(shows) }.filter { !$0.isEmpty }
        }

        /// Those it shows, in order.
        var settings: [AzureDevOpsSetting] {
            groups.flatMap { $0 }
        }

        private func shows(_ setting: AzureDevOpsSetting) -> Bool {
            switch self {
            case .menu: setting.isForTheMoment
            case .ownPage: !setting.isAboutPullRequests && setting != .copilot
            case .pullRequestsPage: setting.isAboutPullRequests
            case .sendToCopilotPage: setting == .copilot
            }
        }
    }

    let place: Place

    var body: some View {
        let groups = place.groups
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 {
                SettingsDivider()
            }
            ForEach(groups[index], id: \.self) { setting in
                AzureDevOpsSettingView(setting: setting)
            }
        }
    }
}

/// One of Azure DevOps' settings, in a menu or a form.
private struct AzureDevOpsSettingView: View {
    let setting: AzureDevOpsSetting

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        switch setting {
        case .notifications:
            NotificationsSetting()
        case .summaries:
            SummariesSetting()
        case .showToReview:
            SettingToggle(setting.title, caption: setting.caption, isOn: $settings.showToReview)
        case .followMerges:
            SettingToggle(setting.title, caption: setting.caption, isOn: $settings.followMerges)
        case .opensPullRequestsInBriefBar:
            OpenInBriefBarSetting()
        case .chatLinks:
            ChatLinksSetting()
        case .refresh:
            Picker(selection: $settings.refreshSeconds) {
                ForEach(AppSettings.refreshChoices, id: \.seconds) { Text($0.title).tag($0.seconds) }
            } label: {
                Text(setting.title)
                Text(setting.caption)
            }
            .pickerStyle(.menu)
        case .keepDone:
            Picker(selection: $settings.keepDoneHours) {
                ForEach(AppSettings.keepDoneChoices, id: \.hours) { Text($0.title).tag($0.hours) }
            } label: {
                Text(setting.title)
                Text(setting.caption)
            }
            .pickerStyle(.menu)
        case .idle:
            Picker(selection: $settings.idleDays) {
                ForEach(AppSettings.idleChoices, id: \.days) { Text($0.title).tag($0.days) }
            } label: {
                Text(setting.title)
                Text(setting.caption)
            }
            .pickerStyle(.menu)
        case .organizations:
            OrganizationsSetting()
        case .watchedPullRequests:
            WatchedPullRequestsSetting()
        case .makesChanges:
            MakeChangesSetting()
        case .copilot:
            CopilotSetting()
        }
    }
}

/// Notifications: on Azure DevOps' page, and in its menus, with a way to allow them while macOS doesn't. On its page, the
/// status above its settings offers that.
private struct NotificationsSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore
    @Environment(\.inSettingsForm) private var inSettingsForm

    var body: some View {
        let setting = AzureDevOpsSetting.notifications
        if inSettingsForm {
            SettingToggle(setting.title, caption: setting.caption, isOn: $settings.notifications)
        } else {
            Toggle(setting.title, isOn: $settings.notifications)
            if settings.notifications && store.notificationsBlocked {
                Button("Allow Notifications in System Settings…") { Notifier.openSystemSettings() }
            }
        }
    }
}

/// Summaries by Apple Intelligence, while this Mac has it: on Azure DevOps' page.
private struct SummariesSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore

    var body: some View {
        let setting = AzureDevOpsSetting.summaries
        SettingToggle(setting.title, caption: setting.caption, isOn: $settings.summaries)
            .disabled(!store.summarizer.isAvailable)
    }
}

/// The organizations to watch, on Azure DevOps' page: those it watches, in a menu with a checkmark for each, a way to add
/// one, and to find them again.
private struct OrganizationsSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore

    var body: some View {
        let setting = AzureDevOpsSetting.organizations
        SettingRow(setting.title, caption: setting.caption) {
            Menu {
                OrganizationsMenuContent()
            } label: {
                Text(watched)
            }
            .fixedSize()
        }
    }

    /// "contoso", "contoso and fabrikam", "3 organizations", or "None".
    private var watched: String {
        let names = OrganizationDiscovery.merged(settings.organizations, preferring: settings.knownOrganizations)
            .filter { settings.isWatching($0) }
        switch names.count {
        case 0: return "None"
        case 1, 2: return names.joined(separator: " and ")
        default: return "\(names.count) Organizations"
        }
    }
}

private struct PRStoreKey: EnvironmentKey {
    static var defaultValue: PRStore? { nil }
}

extension EnvironmentValues {
    /// Azure DevOps' pull requests, for the settings that use them: nil on the Pull Requests page in Settings while Azure
    /// DevOps is off, where those show without them.
    var prStore: PRStore? {
        get { self[PRStoreKey.self] }
        set { self[PRStoreKey.self] = newValue }
    }
}

/// Make Changes in Azure DevOps, off by default: your replies in pull requests' comment threads, their statuses, your own
/// comments and pull requests' tags, from their details, and, on My Work, the sprint a task or bug of yours is in, each
/// when you click it; and nothing else. On the Pull Requests page in Settings, it says what it writes as you turn it on.
struct MakeChangesSetting: View {
    @EnvironmentObject private var settings: AppSettings

    nonisolated static let title = "Make Changes in Azure DevOps"
    static let explanation = """
        Adds Reply and a status menu to each comment thread in a pull request's details in BriefBar's window, Edit and \
        Delete to your own comments, and Add Tag and ✕ to its tags; on My Work, Move to Sprint to your tasks and bugs \
        outside the sprint; and, on the Sprint page, a menu of states, such as New, Active and Closed, to its stories, bugs \
        and tasks. BriefBar then writes these to Azure DevOps, as you, with your Azure CLI sign-in, and only when you \
        click: your reply in a thread, a thread's status, such as Resolved or Won't Fix, your comment as you edited it, or \
        deleted, a tag you add to a pull request or remove from it, on My Work, the sprint a task or bug of yours is in, \
        moved to your team's current sprint or its next once you confirm, and, on the Sprint page, the state you choose \
        for a work item. Nothing else, and never by itself: otherwise it only reads. It remembers the tags you add, for \
        each project, to suggest them. Fix Grammar, in a reply or an edit, uses Apple Intelligence on this Mac unless you \
        choose a Copilot model, which sends what you wrote to GitHub Copilot. Agents get none of it. Turning it off \
        forgets the replies and edits you haven't sent, the tags you added, and Undo for the task you moved and for the \
        state you changed.
        """
    /// What it adds, what it writes and when, what Fix Grammar sends, and what it keeps: the box that shows as you turn it on.
    static let entries: [DescriptionBox.Entry] = [
        .init(title: "What it adds", symbol: "plus.bubble", text: """
            Reply and a status menu on each comment thread in a pull request's details in BriefBar's window, Edit and \
            Delete on your own comments, and Add Tag and ✕ on its tags; on My Work, Move to Sprint on your tasks and bugs \
            outside the sprint; and, on the Sprint page, a menu of states, such as New, Active and Closed, on its \
            stories, bugs and tasks.
            """),
        .init(title: "What it writes", symbol: "square.and.pencil", text: """
            To Azure DevOps, as you, with your Azure CLI sign-in, and only when you click: your reply in a thread, a \
            thread's status, such as Resolved or Won't Fix, your comment as you edited it, or deleted, a tag you add to a \
            pull request or remove from it, on My Work, the sprint a task or bug of yours is in, moved to your team's \
            current sprint or its next once you confirm, and, on the Sprint page, the state you choose for a work item. \
            Nothing else, and never by itself: otherwise it only reads. Agents get none of it.
            """),
        .init(title: "Fix Grammar", symbol: "textformat.abc", text: """
            In a reply or an edit, it uses Apple Intelligence on this Mac unless you choose a Copilot model, which sends \
            what you wrote to GitHub Copilot.
            """),
        .init(title: "What it keeps", symbol: "tray", text: """
            The tags you add, for each project, to suggest them. Turning it off forgets the replies and edits you haven't \
            sent, the tags you added, and Undo for the task you moved and for the state you changed.
            """),
    ]

    var body: some View {
        let setting = AzureDevOpsSetting.makesChanges
        ConsentToggle(
            Self.title, caption: setting.caption, info: Self.explanation, entries: Self.entries, isOn: $settings.makesChanges
        )
    }
}

/// Open Pull Requests in BriefBar, off by default: where a pull request clicked in the menu bar's list, a widget or a
/// notification opens. On the Pull Requests page in Settings.
struct OpenInBriefBarSetting: View {
    @EnvironmentObject private var settings: AppSettings

    nonisolated static let title = "Open Pull Requests in BriefBar"
    static let explanation = """
        Clicking a pull request in the menu bar's list or a widget, or one of its notifications, shows its details on the \
        Pull Requests page of BriefBar's window, at the comment or the run it's about, rather than opening it in Azure \
        DevOps. Either way, its menu has both, and in BriefBar's window a click shows its details.
        """

    var body: some View {
        SettingToggle(
            Self.title, caption: AzureDevOpsSetting.opensPullRequestsInBriefBar.caption, info: Self.explanation,
            isOn: $settings.opensPullRequestsInBriefBar
        )
    }
}

/// Pull requests sent in chats, off by default: it reads every app's notifications. On the Pull Requests page in Settings,
/// it says what it reads as you turn it on.
struct ChatLinksSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.prStore) private var store

    nonisolated static let title = "Pull Requests Sent in Chats"
    static let explanation = """
        Lists a pull request as needing you when someone sends you a link to it. BriefBar looks for links in the \
        notifications that every app posts to Notification Center, such as Teams, Slack, Outlook and Mail, and keeps \
        only the links, with who sent them, in which app and when, never the messages, and only in memory: after a \
        restart, it finds the links that Notification Center still has. It needs Full Disk Access. Turning it off \
        forgets the links.
        """
    /// What it reads, what it keeps and what it needs: the box that shows as you turn it on.
    static let entries: [DescriptionBox.Entry] = [
        .init(title: "What BriefBar reads", symbol: "doc.text.magnifyingglass", text: """
            The notifications that every app posts to Notification Center, such as Teams, Slack, Outlook and Mail, for \
            links to pull requests.
            """),
        .init(title: "What it keeps", symbol: "tray", text: """
            Only the links, with who sent them, in which app and when, never the messages, and only in memory: after a \
            restart, it finds the links that Notification Center still has. Turning it off forgets the links.
            """),
        .init(title: "What it needs", symbol: "lock.shield", text: "Full Disk Access."),
    ]

    var body: some View {
        // The demo reads no notifications.
        let isDemo = store?.mode == .demo
        ConsentToggle(
            Self.title, caption: AzureDevOpsSetting.chatLinks.caption, info: Self.explanation, entries: Self.entries,
            isOn: $settings.chatLinksEnabled
        )
        .disabled(isDemo)
        if settings.chatLinksEnabled, let store {
            Observing(store) {
                if store.chatAccess == .denied {
                    Button("Allow Full Disk Access…") { store.showChatAccessSetup?() }
                }
            }
        }
    }
}

/// Pull requests you watch by their links: a way to add one, and, for each you watch, to stop; in its menus as items, and on
/// the Pull Requests page in Settings as a row. While Azure DevOps is off, that page lists them by their numbers, and adds
/// none.
struct WatchedPullRequestsSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.prStore) private var store
    @Environment(\.inSettingsForm) private var inSettingsForm

    nonisolated static let title = "Watched Pull Requests"

    var body: some View {
        if let store {
            Observing(store) { content(store) }
        } else {
            content(nil)
        }
    }

    @ViewBuilder
    private func content(_ store: PRStore?) -> some View {
        if inSettingsForm {
            SettingRow(Self.title, caption: AzureDevOpsSetting.watchedPullRequests.caption) {
                items(store, menuTitle: settings.watchedPullRequests.count == 1 ? "1 Pull Request" : "\(settings.watchedPullRequests.count) Pull Requests")
                    .fixedSize()
            }
        } else {
            items(store, menuTitle: Self.title)
        }
    }

    @ViewBuilder
    private func items(_ store: PRStore?, menuTitle: String) -> some View {
        // The demo watches nothing new.
        let canWatch = store.map { $0.mode != .demo } ?? false
        if settings.watchedPullRequests.isEmpty {
            Button("Watch a Pull Request…") { if let store { WatchPrompt.ask(store: store) } }
                .disabled(!canWatch)
        } else {
            Menu(menuTitle) {
                ForEach(settings.watchedPullRequests, id: \.self) { link in
                    Button("Stop Watching \(title(link, in: store))") { settings.unwatch([link.key]) }
                }
                Divider()
                Button("Watch a Pull Request…") { if let store { WatchPrompt.ask(store: store) } }
                    .disabled(!canWatch)
            }
        }
    }

    /// Its title once it's been read, else its number and repository.
    private func title(_ link: PullRequestLink, in store: PRStore?) -> String {
        store?.items.first { $0.key == link.key }.map { "“\($0.title)”" } ?? "!\(link.number) in \(link.repository)"
    }
}

/// Asks for a pull request's link, to watch it.
@MainActor
enum WatchPrompt {
    static func ask(store: PRStore) {
        let alert = NSAlert()
        alert.messageText = "Watch a Pull Request"
        alert.informativeText = "Paste its link. BriefBar lists it as if you reviewed it, with what's new on it, until it "
            + "closes or you stop watching it: right-click it in the list."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/4071"
        alert.accessoryView = field
        alert.addButton(withTitle: "Watch")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard ThisMac.ask(alert) == .alertFirstButtonReturn else { return }
        guard let link = PullRequestLink.find(in: field.stringValue).first else {
            let error = NSAlert()
            error.messageText = "That isn't a link to a pull request"
            error.informativeText = "Copy it from the pull request's page in Azure DevOps: it ends in /pullrequest/ and its number."
            ThisMac.ask(error)
            return
        }
        store.watch(link)
    }
}

/// The organizations to watch: a checkmark for each, a way to add one, and to find them again.
struct OrganizationsMenuContent: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore

    var body: some View {
        let names = OrganizationDiscovery.merged(settings.organizations, preferring: settings.knownOrganizations)
        ForEach(names, id: \.self) { name in
            Toggle(name, isOn: Binding(
                get: { settings.isWatching(name) },
                set: { _ in settings.toggleOrganization(name) }
            ))
        }
        if !names.isEmpty { Divider() }
        Button("Add Organization…") { OrganizationPrompt.ask(settings: settings, store: store) }
        Button("Find My Organizations Again") { store.discoverOrganizations() }
            .disabled(store.discovery == .running || store.mode == .demo)
    }
}

/// Asks for an organization's name (or any of its URLs), and checks that your sign-in can read it before watching it.
@MainActor
enum OrganizationPrompt {
    static func ask(settings: AppSettings, store: PRStore) {
        let alert = NSAlert()
        alert.messageText = "Add an Azure DevOps Organization"
        alert.informativeText = "Enter its name, or paste a link from it, such as dev.azure.com/contoso or contoso.visualstudio.com."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "contoso"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard ThisMac.ask(alert) == .alertFirstButtonReturn else { return }
        guard let name = OrganizationDiscovery.name(from: field.stringValue) else {
            let error = NSAlert()
            error.messageText = "That isn't an organization name"
            error.informativeText = "Names are letters, digits and hyphens, like the contoso in dev.azure.com/contoso."
            ThisMac.ask(error)
            return
        }
        guard !settings.isWatching(name) else { return }
        // The demo reads nothing.
        guard store.mode == .live else {
            settings.toggleOrganization(name)
            return
        }
        store.add(organization: name) { access in
            guard let explanation = access.explanation(for: name) else { return }
            let alert = NSAlert()
            alert.messageText = explanation.title
            alert.informativeText = explanation.detail
            if access.signInTenant != nil {
                alert.addButton(withTitle: "Sign In…")
                alert.addButton(withTitle: "Not Now")
            }
            NSApp.activate()
            if ThisMac.ask(alert) == .alertFirstButtonReturn, let tenant = access.signInTenant {
                store.signIn(toTenant: tenant)
            }
        }
    }
}
