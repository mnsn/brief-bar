import Foundation

/// What turning agents off left in the Copilot CLI: BriefBar's MCP server and its plugin, each as the CLI said once
/// BriefBar had tried to remove it. Agents are off by then, so the Agents page shows only this, with Try Again.
public struct AgentCleanup: Sendable, Equatable {
    /// Why BriefBar's MCP server is still there, or nil once it's gone.
    public var server: String?
    /// Why BriefBar's plugin is still there, or nil once it's gone.
    public var plugin: String?

    /// - Parameters: what the CLI said once BriefBar had tried to remove each, or nil while it's still at it.
    public init(server: CopilotMCPRegistration.Status?, plugin: CopilotPluginRegistration.Status?) {
        self.server = server.flatMap(Self.leftover)
        self.plugin = plugin.flatMap(Self.leftover)
    }

    /// Nothing of BriefBar's is left, as far as BriefBar knows.
    public var isDone: Bool { server == nil && plugin == nil }

    /// Why BriefBar's server is still there. A server by its name that isn't BriefBar was never BriefBar's to remove,
    /// and without a Copilot CLI, there's nothing to remove.
    static func leftover(_ status: CopilotMCPRegistration.Status) -> String? {
        switch status {
        case .added, .addedElsewhere: return "The Copilot CLI still has it."
        case .failed(let message): return message
        case .noCLI, .absent, .taken: return nil
        }
    }

    /// Why BriefBar's plugin is still there. A marketplace by its name that BriefBar can't tell is its own was never
    /// BriefBar's to remove.
    static func leftover(_ status: CopilotPluginRegistration.Status) -> String? {
        switch status {
        case .installed, .installedElsewhere: return "The Copilot CLI still has it."
        case .failed(let message): return message
        case .noCLI, .absent, .taken: return nil
        }
    }
}
