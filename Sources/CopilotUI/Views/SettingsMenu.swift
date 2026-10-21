import BriefBarCore
import BriefBarUI
import CopilotCore
import SwiftUI

/// The gear menu in the popover.
struct SettingsMenuContent: View {
    var body: some View {
        SourceMenuContent()
        Divider()
        AppMenuItems(source: .copilot)
    }
}

/// Copilot's settings and a way to open it: in the gear menu, and in a widget's context menu.
struct SourceMenuContent: View {
    var body: some View {
        CopilotSettings()
        Divider()
        Button("Open GitHub Copilot") { CopilotApp.activate() }
    }
}

/// Copilot's own settings: in its menus, and on its page in Settings.
struct CopilotSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Picker("Keep Finished Sessions For", selection: $settings.keepEndedMinutes) {
            ForEach(AppSettings.keepEndedChoices, id: \.minutes) { Text($0.title).tag($0.minutes) }
        }
        .pickerStyle(.menu)

        Toggle("Show Context Usage", isOn: $settings.showContextUsage)
    }
}
