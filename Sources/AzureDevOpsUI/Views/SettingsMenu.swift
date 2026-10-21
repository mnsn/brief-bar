import AppKit
import AzureDevOpsCore
import BriefBarUI
import SwiftUI

/// The gear menu in the popover, and the widget's context menu.
struct SettingsMenuContent: View {
    @EnvironmentObject private var store: PRStore

    var body: some View {
        AzureDevOpsSettings()
        Divider()
        Button("Open Azure DevOps") { store.openPullRequestsPage() }
        Divider()
        AppMenuItems(source: .azureDevOps)
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

        SettingsDivider()

        Toggle("Show Desktop Widget", isOn: $settings.showWidget)
        Picker("Widget Position", selection: $settings.placement) {
            ForEach(AppSettings.Placement.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        Picker("Widget Size", selection: $settings.widgetSize) {
            ForEach(AppSettings.WidgetSize.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)

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
