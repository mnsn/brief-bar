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

/// A way to open Copilot, when it's on this Mac: in the gear menu, and in a widget's context menu. Its settings are in
/// Settings.
struct SourceMenuContent: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        if store.appInstalled {
            Button("Open GitHub Copilot") { CopilotApp.activate() }
        }
    }
}

/// Copilot's own settings, on its page in Settings, each with what it does for you.
struct CopilotSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Picker(selection: $settings.keepEndedMinutes) {
            ForEach(AppSettings.keepEndedChoices, id: \.minutes) { Text($0.title).tag($0.minutes) }
        } label: {
            Text("Keep Finished Sessions For")
            Text("How long finished and stopped sessions stay listed, unless you clear them.")
        }
        .pickerStyle(.menu)

        SettingToggle(
            "Move Viewed Sessions to Idle",
            caption: "Moves a finished or stopped session to Idle once you've opened it.",
            info: "Hide finished and stopped sessions after you open them or view them in Copilot. Off keeps them until Clear or the retention time expires.",
            isOn: $settings.moveViewedToIdle
        )
        SettingToggle(
            "Show Relayed Questions Once",
            caption: "Shows a question one session relays for another once, where you answer it.",
            info: "When a session that coordinates another asks you that session's question or plan, show it once, on the coordinating session, where you answer it. Off shows both.",
            isOn: $settings.showRelayedQuestionsOnce
        )
        SettingToggle(
            "Nest Sessions Under Their Parents",
            caption: "Shows a session that another one started under it, as Copilot's sidebar does.",
            info: "Show a session that another session started under it, indented, as the Copilot app's sidebar does, when both are in the same group. Elsewhere, a ↳ tag names the session that started it and opens it. Off lists each session on its own.",
            isOn: $settings.nestSessions
        )
        SettingToggle(
            "Show Context Usage", caption: "Shows how full each session's context window is.", isOn: $settings.showContextUsage
        )
    }
}
