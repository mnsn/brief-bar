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
        only the links, with who sent them, in which app and when, never the messages. It needs Full Disk Access. \
        Turning it off forgets the links.
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
