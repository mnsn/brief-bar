import BriefBarCore
import BriefBarUI
import SwiftUI

/// The gear menu in the popover.
struct SettingsMenuContent: View {
    var body: some View {
        SourceMenuContent()
        Divider()
        AppMenuItems(source: .github)
    }
}

/// Reading GitHub again now, and a way to open it: in the gear menu, and in a widget's context menu. Its settings are in
/// Settings.
struct SourceMenuContent: View {
    @EnvironmentObject private var store: GitHubStore

    var body: some View {
        Button("Refresh Now") { store.refresh(listingAccounts: true) }
            .disabled(store.mode == .demo)
        Divider()
        Button("Open GitHub") { store.openPullRequestsPage() }
    }
}

/// GitHub's own settings, on its page in Settings.
struct GitHubSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Picker(selection: $settings.refreshMinutes) {
            ForEach(AppSettings.refreshChoices, id: \.minutes) { Text($0.title).tag($0.minutes) }
        } label: {
            Text("Refresh Every")
            Text("How often BriefBar reads GitHub: one request for each account each time.")
        }
        .pickerStyle(.menu)
    }
}
