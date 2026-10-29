import Foundation

/// That you let agents, such as the Copilot CLI, use BriefBar (`BriefBar --mcp`), having seen what they get.
public struct AgentConsent: Codable, Equatable, Sendable {
    /// The version of what agents get (`AgentAccess.version`), when you turned them on.
    public var version: Int
    public var date: Date

    public init(version: Int, date: Date) {
        self.version = version
        self.date = date
    }
}

/// Whether agents may use BriefBar, saved in its preferences. Like a source, it's off until you turn it on: nothing but
/// `turnOn` turns it on, and until you do, `--mcp` answers every call by saying so. When agents get something new, they
/// wait until you've seen what they get now (`SourceState.needsReview`).
public enum AgentAccess {
    /// What agents get: raise it when they get something new, such as another tool or another source's data.
    public static let version = 2

    public static let defaultsKey = "agents"

    public static func state(in defaults: some SettingsStorage, version: Int = version) -> SourceState {
        guard let data = defaults.data(forKey: defaultsKey), let consent = try? JSONDecoder().decode(AgentConsent.self, from: data)
        else { return .off }
        return consent.version >= version ? .on : .needsReview
    }

    /// Turns agents on, with your consent to what they get now.
    public static func turnOn(in defaults: some SettingsStorage, version: Int = version, at date: Date = Date()) {
        guard let data = try? JSONEncoder().encode(AgentConsent(version: version, date: date)) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    public static func turnOff(in defaults: some SettingsStorage) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// What `--mcp` answers instead of using BriefBar, unless agents are on.
    public static func refusal(_ state: SourceState) -> String? {
        switch state {
        case .on:
            return nil
        case .off:
            return "Agents are off in BriefBar. Turn them on in BriefBar's Settings, under Agents, to use BriefBar here."
        case .needsReview:
            return """
                Since you let agents use BriefBar, an update gave them more, so they wait until you've seen what they get \
                now: look in BriefBar's Settings, under Agents.
                """
        }
    }

    /// What a source's tools, and its part of `needs_me`, answer in `--mcp` while it's off in the app. The other
    /// sources still answer.
    public static func refusal(source name: String) -> String {
        "\(name) is off in BriefBar. Turn it on in BriefBar's Settings to use it here."
    }
}
