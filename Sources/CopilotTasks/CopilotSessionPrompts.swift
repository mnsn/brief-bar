import Foundation

/// **Send Prompts to Copilot Sessions**, in Settings › Agents: whether BriefBar's extension for the GitHub Copilot app's
/// sessions, its second Copilot plugin (`briefbar-sessions`), is on, as BriefBar last knew. With it, BriefBar can send a
/// prompt straight to one of the app's sessions, or fork one and send the prompt to the fork, when you ask it to.
///
/// It's off until you turn it on. The Agents page turns it on once the Copilot CLI has installed the plugin, and off as
/// soon as you turn the option, or agents, off. Sessions that were open then keep running the extension until they
/// start again, so BriefBar sends prompts to sessions only while this is on, never just because one listens.
public enum CopilotSessionPrompts {
    /// The option's name, as BriefBar shows it.
    public static let title = "Send Prompts to Copilot Sessions"

    /// Where BriefBar's preferences keep it.
    public static let defaultsKey = "agents.copilotSessionPrompts"

    public static func isOn(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// Turns it on, or off, which leaves nothing of it in the preferences.
    public static func set(_ isOn: Bool, in defaults: UserDefaults) {
        if isOn {
            defaults.set(true, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}
