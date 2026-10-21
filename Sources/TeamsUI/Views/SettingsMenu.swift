import AppKit
import BriefBarUI
import NotificationCenterDB
import SwiftUI
import TeamsCore

/// The gear menu, shared by both lists.
struct SettingsMenuContent: View {
    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var fullDiskAccess: FullDiskAccess

    var body: some View {
        TeamsSettings()
        Divider()
        if store.access != .granted {
            Button("Set Up Full Disk Access…") { fullDiskAccess.show() }
        }
        Button("Copy Diagnostics") { Diagnose.copyReport(paths: store.paths) }
        Button("Open Microsoft Teams") { TeamsApp.activate() }
        Divider()
        AppMenuItems(source: .teams)
    }
}

/// Teams' own settings: in its menus, and on its page in Settings.
struct TeamsSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Picker("Keep Unread For", selection: $settings.keepUnread) {
            ForEach(AppSettings.KeepUnread.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)

        Toggle("Show Message Previews", isOn: $settings.showPreviews)
        Toggle("Summarize with Apple Intelligence", isOn: $settings.showSummaries)
            .disabled(!settings.showPreviews)
        if settings.showSummaries, let reason = Summarizer.unavailableReason {
            Text(reason)
        }
        Toggle("Mark All Read When Teams' Badge Clears", isOn: $settings.clearWithDockBadge)
    }
}

enum Diagnose {
    /// Copies the structure-only report (no names, messages or IDs) for an issue.
    @MainActor
    static func copyReport(paths: NotificationPaths) {
        let version = AppIdentity.version
        DispatchQueue.global(qos: .userInitiated).async {
            let report = Diagnostics.report(paths: paths, appVersion: version)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }
    }
}
