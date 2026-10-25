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

/// GitHub's settings and a way to open it: in the gear menu, and in a widget's context menu.
struct SourceMenuContent: View {
    @EnvironmentObject private var store: GitHubStore

    var body: some View {
        GitHubSettings()
        Button("Refresh Now") { store.refresh() }
            .disabled(store.mode == .demo)
        Divider()
        Button("Open GitHub") { store.openPullRequestsPage() }
    }
}

/// GitHub's own settings: in its menus, and on its page in Settings.
struct GitHubSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Picker("Refresh Every", selection: $settings.refreshMinutes) {
            ForEach(AppSettings.refreshChoices, id: \.minutes) { Text($0.title).tag($0.minutes) }
        }
        .pickerStyle(.menu)
    }
}
