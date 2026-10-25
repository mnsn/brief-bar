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
        AzureDevOpsSettings()
        Divider()
        Button("Open Azure DevOps") { store.openPullRequestsPage() }
    }
}

/// Azure DevOps' own settings: in its menus, and on its page in Settings.
struct AzureDevOpsSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore

    var body: some View {
        Toggle("Notifications", isOn: $settings.notifications)
        if settings.notifications && store.notificationsBlocked {
            Button("Allow Notifications in System Settings…") { Notifier.openSystemSettings() }
        }
        Toggle("Summaries by Apple Intelligence", isOn: $settings.summaries)
            .disabled(!store.summarizer.isAvailable)
        Toggle("Show To Review in the Menu Bar", isOn: $settings.showToReview)
        Toggle("Follow Pipelines After You Merge", isOn: $settings.followMerges)
        ChatLinksSetting()

        SettingsDivider()

        Picker("Refresh", selection: $settings.refreshSeconds) {
            ForEach(AppSettings.refreshChoices, id: \.seconds) { Text($0.title).tag($0.seconds) }
        }
        .pickerStyle(.menu)
        Picker("Keep Done For", selection: $settings.keepDoneHours) {
            ForEach(AppSettings.keepDoneChoices, id: \.hours) { Text($0.title).tag($0.hours) }
        }
        .pickerStyle(.menu)
        Picker("Idle After No Activity For", selection: $settings.idleDays) {
            ForEach(AppSettings.idleChoices, id: \.days) { Text($0.title).tag($0.days) }
        }
        .pickerStyle(.menu)
        Menu("Organizations") {
            OrganizationsMenuContent()
        }
        WatchedPullRequestsSetting()

        SettingsDivider()

        CopilotSetting()
    }
}

/// Pull requests sent in chats, off by default: it reads every app's notifications. On its page in Settings, it
/// says what it reads; in a menu, turning it on opens that page instead.
struct ChatLinksSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var services: AppServices
    @Environment(\.inSettingsForm) private var inSettingsForm

    static let title = "Pull Requests Sent in Chats"
    static let explanation = """
        Lists a pull request as needing you when someone sends you a link to it. BriefBar looks for links in the \
        notifications that every app posts to Notification Center, such as Teams, Slack, Outlook and Mail, and keeps \
        only the links, with who sent them, in which app and when, never the messages, and only in memory: after a \
        restart, it finds the links that Notification Center still has. It needs Full Disk Access. Turning it off \
        forgets the links.
        """

    var body: some View {
        if inSettingsForm || settings.chatLinksEnabled {
            Toggle(isOn: $settings.chatLinksEnabled) {
                Text(Self.title)
                if inSettingsForm {
                    Text(Self.explanation)
                }
            }
            .disabled(store.mode == .demo)
        } else {
            Button(Self.title + "…") { services.openSettings(.source(.azureDevOps)) }
                .disabled(store.mode == .demo)
        }
        if settings.chatLinksEnabled && store.chatAccess == .denied {
            Button("Allow Full Disk Access…") { store.showChatAccessSetup?() }
        }
    }
}

/// Pull requests you watch by their links: a way to add one, and, for each you watch, to stop.
struct WatchedPullRequestsSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore

    var body: some View {
        if settings.watchedPullRequests.isEmpty {
            Button("Watch a Pull Request…") { WatchPrompt.ask(store: store) }
                .disabled(store.mode == .demo)
        } else {
            Menu("Watched Pull Requests") {
                ForEach(settings.watchedPullRequests, id: \.self) { link in
                    Button("Stop Watching \(title(link))") { settings.unwatch([link.key]) }
                }
                Divider()
                Button("Watch a Pull Request…") { WatchPrompt.ask(store: store) }
                    .disabled(store.mode == .demo)
            }
        }
    }

    /// Its title once it's been read, else its number and repository.
    private func title(_ link: PullRequestLink) -> String {
        store.items.first { $0.key == link.key }.map { "“\($0.title)”" } ?? "!\(link.number) in \(link.repository)"
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let link = PullRequestLink.find(in: field.stringValue).first else {
            let error = NSAlert()
            error.messageText = "That isn't a link to a pull request"
            error.informativeText = "Copy it from the pull request's page in Azure DevOps: it ends in /pullrequest/ and its number."
            error.runModal()
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
        Button("Add Organization…") { OrganizationPrompt.ask(settings: settings) }
        Button("Find My Organizations Again") { store.discoverOrganizations() }
            .disabled(store.discovery == .running || store.mode == .demo)
    }
}

/// Asks for an organization's name (or any of its URLs).
@MainActor
enum OrganizationPrompt {
    static func ask(settings: AppSettings) {
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let name = OrganizationDiscovery.name(from: field.stringValue) else {
            let error = NSAlert()
            error.messageText = "That isn't an organization name"
            error.informativeText = "Names are letters, digits and hyphens, like the contoso in dev.azure.com/contoso."
            error.runModal()
            return
        }
        if !settings.isWatching(name) {
            settings.toggleOrganization(name)
        }
    }
}
