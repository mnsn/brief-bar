import Foundation

/// What turning agents off left in the Copilot CLI: BriefBar's MCP server, its plugin and its extension for the app's
/// sessions (Send Prompts to Copilot Sessions), each as the CLI said once BriefBar had tried to remove it. Agents are off
/// by then, so the Agents page shows only this, with Try Again.
public struct AgentCleanup: Sendable, Equatable {
    /// Why BriefBar's MCP server is still there, or nil once it's gone.
    public var server: String?
    /// Why BriefBar's plugin is still there, or nil once it's gone.
    public var plugin: String?
    /// Why BriefBar's extension for the app's sessions is still there, or nil once it's gone.
    public var sessionPrompts: String?

    /// - Parameters: what the CLI said once BriefBar had tried to remove each, or nil while it's still at it.
    public init(
        server: CopilotMCPRegistration.Status?, plugin: CopilotPluginRegistration.Status?,
        sessionPrompts: CopilotPluginRegistration.Status? = nil
    ) {
        self.server = server.flatMap(Self.leftover)
        self.plugin = plugin.flatMap(Self.leftover)
        self.sessionPrompts = sessionPrompts.flatMap(Self.leftover)
    }

    /// Nothing of BriefBar's is left, as far as BriefBar knows.
    public var isDone: Bool { server == nil && plugin == nil && sessionPrompts == nil }

    /// What turning agents off left, once every check and change BriefBar asked the CLI for is done; nil before, or if
    /// nothing's left.
    public static func left(
        server: CopilotCLIProgress<CopilotMCPRegistration.Status>,
        plugin: CopilotCLIProgress<CopilotPluginRegistration.Status>,
        sessionPrompts: CopilotCLIProgress<CopilotPluginRegistration.Status> = CopilotCLIProgress()
    ) -> AgentCleanup? {
        guard !server.isWorking, !plugin.isWorking, !sessionPrompts.isWorking else { return nil }
        let cleanup = AgentCleanup(server: server.status, plugin: plugin.status, sessionPrompts: sessionPrompts.status)
        return cleanup.isDone ? nil : cleanup
    }

    /// Why BriefBar's server is still there. A server by its name that isn't BriefBar was never BriefBar's to remove,
    /// and without a Copilot CLI, there's nothing to remove.
    static func leftover(_ status: CopilotMCPRegistration.Status) -> String? {
        switch status {
        case .added, .addedElsewhere: return "The Copilot CLI still has it."
        case .failed(let message): return message
        case .noCLI, .absent, .taken: return nil
        }
    }

    /// Why one of BriefBar's plugins is still there. A marketplace by its name that BriefBar can't tell is its own was
    /// never BriefBar's to remove.
    static func leftover(_ status: CopilotPluginRegistration.Status) -> String? {
        switch status {
        case .installed, .installedElsewhere: return "The Copilot CLI still has it."
        case .failed(let message): return message
        case .noCLI, .absent, .taken: return nil
        }
    }
}
