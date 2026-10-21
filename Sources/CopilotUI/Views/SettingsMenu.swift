import BriefBarCore
import BriefBarUI
import CopilotCore
import SwiftUI

/// The gear menu in the popover, and the widget's context menu.
struct SettingsMenuContent: View {
    var body: some View {
        CopilotSettings()
        Divider()
        Button("Open GitHub Copilot") { CopilotApp.activate() }
        Divider()
        AppMenuItems(source: .copilot)
    }
}

/// Copilot's own settings: in its menus, and on its page in Settings.
struct CopilotSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Toggle("Show Desktop Widget", isOn: $settings.showWidget)

        Picker("Widget Position", selection: $settings.placement) {
            ForEach(AppSettings.Placement.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)

        Picker("Widget Size", selection: $settings.widgetSize) {
            ForEach(AppSettings.WidgetSize.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)

        Picker("Keep Finished Sessions For", selection: $settings.keepEndedMinutes) {
            ForEach(AppSettings.keepEndedChoices, id: \.minutes) { Text($0.title).tag($0.minutes) }
        }
        .pickerStyle(.menu)

        Toggle("Show Context Usage", isOn: $settings.showContextUsage)
    }
}
