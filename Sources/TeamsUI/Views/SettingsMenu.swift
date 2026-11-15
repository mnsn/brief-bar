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

/// What you'd change of Teams in the moment, such as hiding what messages say while you share your screen, and ways to fix
/// and open it: in the gear menu, and in a widget's context menu. The rest are in Settings.
struct SourceMenuContent: View {
    @EnvironmentObject private var store: ConversationStore
    @EnvironmentObject private var fullDiskAccess: FullDiskAccess
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Toggle(TeamsSettings.previewsTitle, isOn: $settings.showPreviews)
        Divider()
        if store.access != .granted {
            Button("Set Up Full Disk Access…") { fullDiskAccess.show() }
        }
        Button("Copy Diagnostics") { Diagnose.copyReport(store) }
        Button("Open Microsoft Teams") { TeamsApp.activate() }
    }
}

/// Teams' own settings, on its page in Settings, each with what it does for you.
struct TeamsSettings: View {
    @EnvironmentObject private var settings: AppSettings

    static let previewsTitle = "Show Message Previews"

    var body: some View {
        Picker(selection: $settings.keepUnread) {
            ForEach(AppSettings.KeepUnread.allCases) { Text($0.title).tag($0) }
        } label: {
            Text("Keep Unread For")
            Text("How long a message stays unread when BriefBar doesn't see it being read.")
        }
        .pickerStyle(.menu)

        SettingToggle(
            Self.previewsTitle, caption: "Shows each chat's latest message; off shows only how many, for screen sharing.",
            isOn: $settings.showPreviews
        )
        SettingToggle(
            "Summarize with Apple Intelligence",
            caption: "Sums up a chat in a sentence on this Mac, and words chats in the brief.",
            info: "With Show Message Previews on too, Apple's on-device model writes summaries on your Mac: a chat's when you ask for one, with ✨, and the brief's while a list by state or the window's Overview shows your chats.",
            isOn: $settings.showSummaries
        )
        .disabled(!settings.showPreviews)
        if settings.showSummaries, let reason = Summarizer.unavailableReason {
            Text(reason)
                .foregroundStyle(.secondary)
        }
        SettingToggle(
            "Mark Chats Read When You Read Them in Teams",
            caption: "Chats you read in Teams leave BriefBar's list too.",
            info: "BriefBar reads how far you've read each chat from Teams' own data on this Mac, read-only, and keeps only that, in memory.",
            isOn: $settings.followReadsInTeams
        )
        SettingToggle(
            "Mark All Read When Teams' Badge Clears",
            caption: "Marks everything read once Teams' dock badge disappears.",
            info: "Reading a chat in Teams leaves its notifications in Notification Center, but takes it off Teams' badge.",
            isOn: $settings.clearWithDockBadge
        )
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
            ThisMac.copy(report)
        }
    }
}
