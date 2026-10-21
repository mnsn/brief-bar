import BriefBarCore
import BriefBarUI

/// Every source BriefBar has, in the order Settings lists them. Creating one reads nothing: a source
/// starts only while it's on.
@MainActor
enum SourceCatalog {
    static func sources(services: AppServices) -> [any BriefBarSource] {
        []
    }

    /// Each source's command-line modes.
    static let commandLines: [any SourceCommandLine.Type] = []
}
