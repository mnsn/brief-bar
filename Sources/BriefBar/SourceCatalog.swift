import AzureDevOpsUI
import BriefBarCore
import BriefBarUI
import CopilotUI
import TeamsUI

/// Every source BriefBar has, in the order Settings lists them. Creating one reads nothing: a source
/// starts only while it's on.
@MainActor
enum SourceCatalog {
    static func sources(services: AppServices) -> [any BriefBarSource] {
        [TeamsSource(services: services), AzureDevOpsSource(services: services), CopilotSource(services: services)]
    }

    /// Each source's command-line modes.
    static let commandLines: [any SourceCommandLine.Type] = [TeamsCommandLine.self, AzureDevOpsCommandLine.self, CopilotCommandLine.self]
}
