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

/// Azure DevOps' settings and a way to open it: in the gear menu, and in a widget's context menu.
struct SourceMenuContent: View {
    @EnvironmentObject private var store: PRStore

    var body: some View {
        AzureDevOpsSettings(place: .menu)
        Divider()
        Button("Open Azure DevOps") { store.openPullRequestsPage() }
    }
}

/// One of Azure DevOps' settings. Its menus have all of them, and the Settings window each in one place: its page, or, for
/// those about its pull requests, the Pull Requests page (`AzureDevOpsSettings.Place`). They're kept in its settings
/// either way, so a menu and the window show the same.
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

    /// On the Pull Requests page in Settings rather than Azure DevOps' own: which of its pull requests it lists and counts,
    /// and for how long, where one opens, and what you change on them. The rest are about all it reads, its sprint and
    /// pipelines too: its notifications, which tasks sent to Copilot post too, the brief it words with Apple Intelligence,
    /// how often it reads and from which organizations, and Send Work to Copilot, which sends the sprint's work items as
    /// well as pull requests' work, and whose prompt is the work items'.
    var isAboutPullRequests: Bool {
        switch self {
        case .showToReview, .followMerges, .opensPullRequestsInBriefBar, .chatLinks, .keepDone, .idle, .watchedPullRequests,
             .makesChanges:
            true
        case .notifications, .summaries, .refresh, .organizations, .copilot:
            false
        }
    }
}

/// Azure DevOps' settings, where they show.
struct AzureDevOpsSettings: View {
    /// Where they show, and so which of them.
    enum Place: Sendable {
        /// Its gear menu and its widgets' menus: all of them.
        case menu
        /// Its page in Settings: all but those about pull requests.
        case ownPage
        /// The Pull Requests page in Settings: those about pull requests, whether Azure DevOps is on or not, so without its
        /// store while it's off (`\.prStore`).
        case pullRequestsPage

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
            case .menu: true
            case .ownPage: !setting.isAboutPullRequests
            case .pullRequestsPage: setting.isAboutPullRequests
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
            Toggle(setting.title, isOn: $settings.showToReview)
        case .followMerges:
            Toggle(setting.title, isOn: $settings.followMerges)
        case .opensPullRequestsInBriefBar:
            OpenInBriefBarSetting()
        case .chatLinks:
            ChatLinksSetting()
        case .refresh:
            Picker(setting.title, selection: $settings.refreshSeconds) {
                ForEach(AppSettings.refreshChoices, id: \.seconds) { Text($0.title).tag($0.seconds) }
            }
            .pickerStyle(.menu)
        case .keepDone:
            Picker(setting.title, selection: $settings.keepDoneHours) {
                ForEach(AppSettings.keepDoneChoices, id: \.hours) { Text($0.title).tag($0.hours) }
            }
            .pickerStyle(.menu)
        case .idle:
            Picker(setting.title, selection: $settings.idleDays) {
                ForEach(AppSettings.idleChoices, id: \.days) { Text($0.title).tag($0.days) }
            }
            .pickerStyle(.menu)
        case .organizations:
            Menu(setting.title) {
                OrganizationsMenuContent()
            }
        case .watchedPullRequests:
            WatchedPullRequestsSetting()
        case .makesChanges:
            MakeChangesSetting()
        case .copilot:
            CopilotSetting()
        }
    }
}

/// Notifications, and a way to allow them while macOS doesn't: on Azure DevOps' page and in its menus, while it's on.
private struct NotificationsSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore

    var body: some View {
        Toggle(AzureDevOpsSetting.notifications.title, isOn: $settings.notifications)
        if settings.notifications && store.notificationsBlocked {
            Button("Allow Notifications in System Settings…") { Notifier.openSystemSettings() }
        }
    }
}

/// Summaries by Apple Intelligence, while this Mac has it: on Azure DevOps' page and in its menus, while it's on.
private struct SummariesSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore

    var body: some View {
        Toggle(AzureDevOpsSetting.summaries.title, isOn: $settings.summaries)
            .disabled(!store.summarizer.isAvailable)
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
/// when you click it; and nothing else. On the Pull Requests page in Settings, it says what it writes; in a menu, turning it
/// on opens that page instead.
struct MakeChangesSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var services: AppServices
    @Environment(\.inSettingsForm) private var inSettingsForm

    nonisolated static let title = "Make Changes in Azure DevOps"
    static let explanation = """
        Adds Reply and a status menu to each comment thread in a pull request's details in BriefBar's window, Edit and \
        Delete to your own comments, and Add Tag and ✕ to its tags; and, on My Work, Move to Sprint to your tasks and bugs \
        outside the sprint. BriefBar then writes these to Azure DevOps, as you, with your Azure CLI sign-in, and only when \
        you click: your reply in a thread, a thread's status, such as Resolved or Won't Fix, your comment as you edited it, \
        or deleted, a tag you add to a pull request or remove from it, and, on My Work, the sprint a task or bug of yours \
        is in, moved to your team's current sprint or its next once you confirm. Nothing else, and never by itself: \
        otherwise it only reads. It remembers the tags you add, for each project, to suggest them. Fix Grammar, in a reply \
        or an edit, uses Apple Intelligence on this Mac unless you choose a Copilot model, which sends what you wrote to \
        GitHub Copilot. Agents get none of it. Turning it off forgets the replies and edits you haven't sent, the tags you \
        added, and Undo for the task you moved.
        """

    var body: some View {
        if inSettingsForm || settings.makesChanges {
            Toggle(isOn: $settings.makesChanges) {
                Text(Self.title)
                if inSettingsForm {
                    Text(Self.explanation)
                }
            }
        } else {
            Button(Self.title + "…") { services.openSettings(.pullRequests) }
        }
    }
}

/// Open Pull Requests in BriefBar, off by default: where a pull request clicked in the menu bar's list, a widget or a
/// notification opens. On the Pull Requests page in Settings, it says what it does.
struct OpenInBriefBarSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.inSettingsForm) private var inSettingsForm

    nonisolated static let title = "Open Pull Requests in BriefBar"
    static let explanation = """
        Clicking a pull request in the menu bar's list or a widget, or one of its notifications, shows its details on the \
        Pull Requests page of BriefBar's window, at the comment or the run it's about, rather than opening it in Azure \
        DevOps. Either way, its menu has both, and in BriefBar's window a click shows its details.
        """

    var body: some View {
        Toggle(isOn: $settings.opensPullRequestsInBriefBar) {
            Text(Self.title)
            if inSettingsForm {
                Text(Self.explanation)
            }
        }
    }
}

/// Pull requests sent in chats, off by default: it reads every app's notifications. On the Pull Requests page in Settings,
/// it says what it reads; in a menu, turning it on opens that page instead.
struct ChatLinksSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var services: AppServices
    @Environment(\.inSettingsForm) private var inSettingsForm
    @Environment(\.prStore) private var store

    nonisolated static let title = "Pull Requests Sent in Chats"
    static let explanation = """
        Lists a pull request as needing you when someone sends you a link to it. BriefBar looks for links in the \
        notifications that every app posts to Notification Center, such as Teams, Slack, Outlook and Mail, and keeps \
        only the links, with who sent them, in which app and when, never the messages, and only in memory: after a \
        restart, it finds the links that Notification Center still has. It needs Full Disk Access. Turning it off \
        forgets the links.
        """

    var body: some View {
        // The demo reads no notifications.
        let isDemo = store?.mode == .demo
        if inSettingsForm || settings.chatLinksEnabled {
            Toggle(isOn: $settings.chatLinksEnabled) {
                Text(Self.title)
                if inSettingsForm {
                    Text(Self.explanation)
                }
            }
            .disabled(isDemo)
        } else {
            Button(Self.title + "…") { services.openSettings(.pullRequests) }
                .disabled(isDemo)
        }
        if settings.chatLinksEnabled, let store {
            Observing(store) {
                if store.chatAccess == .denied {
                    Button("Allow Full Disk Access…") { store.showChatAccessSetup?() }
                }
            }
        }
    }
}

/// Pull requests you watch by their links: a way to add one, and, for each you watch, to stop. While Azure DevOps is off,
/// on the Pull Requests page in Settings, it lists them by their numbers, and adds none.
struct WatchedPullRequestsSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.prStore) private var store

    nonisolated static let title = "Watched Pull Requests"

    var body: some View {
        if let store {
            Observing(store) { items(store) }
        } else {
            items(nil)
        }
    }

    @ViewBuilder
    private func items(_ store: PRStore?) -> some View {
        // The demo watches nothing new.
        let canWatch = store.map { $0.mode != .demo } ?? false
        if settings.watchedPullRequests.isEmpty {
            Button("Watch a Pull Request…") { if let store { WatchPrompt.ask(store: store) } }
                .disabled(!canWatch)
        } else {
            Menu(Self.title) {
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
