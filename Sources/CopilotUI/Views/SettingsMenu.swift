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

/// Copilot's settings and a way to open it, when it's on this Mac: in the gear menu, and in a widget's context menu.
struct SourceMenuContent: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        CopilotSettings()
        if store.appInstalled {
            Divider()
            Button("Open GitHub Copilot") { CopilotApp.activate() }
        }
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

        Toggle("Move Viewed Sessions to Idle", isOn: $settings.moveViewedToIdle)
            .help("Hide finished and stopped sessions after you open them or view them in Copilot. Off keeps them until Clear or the retention time expires.")

        Toggle("Show Relayed Questions Once", isOn: $settings.showRelayedQuestionsOnce)
            .help("When a session that coordinates another asks you that session's question or plan, show it once, on the coordinating session, where you answer it. Off shows both.")

        Toggle("Nest Sessions Under Their Parents", isOn: $settings.nestSessions)
            .help("Show a session that another session started under it, indented, as the Copilot app's sidebar does, when both are in the same group. Elsewhere, a ↳ tag names the session that started it and opens it. Off lists each session on its own.")

        Toggle("Show Context Usage", isOn: $settings.showContextUsage)
    }
}
