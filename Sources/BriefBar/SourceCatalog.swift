import AzureDevOpsUI
import BriefBarCore
import BriefBarUI
import CopilotUI
import TeamsUI

/// Every source BriefBar has, in the order Settings lists them. Creating one reads nothing: a source
/// starts only while it's on.
@MainActor
enum SourceCatalog {
    /// - Parameter chats: how Azure DevOps reads Notification Center for pull requests sent in chats: only the app
    ///   itself passes it, never `--render` or the demo.
    static func sources(services: AppServices, chats: ChatReading = .inert) -> [any BriefBarSource] {
        [TeamsSource(services: services), AzureDevOpsSource(services: services, chats: chats), CopilotSource(services: services)]
    }

    /// Each source's command-line modes.
    static let commandLines: [any SourceCommandLine.Type] = [TeamsCommandLine.self, AzureDevOpsCommandLine.self, CopilotCommandLine.self]
}
