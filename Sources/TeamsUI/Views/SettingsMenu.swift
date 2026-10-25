import AppKit
import BriefBarUI
import NotificationCenterDB
import SwiftUI
import TeamsCore

/// The gear menu, shared by both lists.
struct SettingsMenuContent: View {
    var body: some View {
        SourceMenuContent()
        Divider()
        AppMenuItems(source: .teams)
    }
}

/// Teams' settings and ways to fix and open it: in the gear menu, and in a widget's context menu.
struct SourceMenuContent: View {
    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var fullDiskAccess: FullDiskAccess

    var body: some View {
        TeamsSettings()
        Divider()
        if store.access != .granted {
            Button("Set Up Full Disk Access…") { fullDiskAccess.show() }
        }
        Button("Copy Diagnostics") { Diagnose.copyReport(store) }
        Button("Open Microsoft Teams") { TeamsApp.activate() }
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
        Toggle("Mark Chats Read When You Read Them in Teams", isOn: $settings.followReadsInTeams)
        Toggle("Mark All Read When Teams' Badge Clears", isOn: $settings.clearWithDockBadge)
    }
}

enum Diagnose {
    /// Copies the structure-only report (no names, messages or IDs) for an issue.
    @MainActor
    static func copyReport(_ store: ConversationStore) {
        let version = AppIdentity.version
        let (paths, cache, follows) = (store.paths, store.storage.cache, store.followsReadsInTeams)
        Task(priority: .userInitiated) { @MainActor in
            let report = await Diagnostics.report(paths: paths, cache: cache, followsReadsInTeams: follows, appVersion: version)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }
}
