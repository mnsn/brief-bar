import BriefBarCore
import Foundation

/// Locations of the GitHub Copilot app's local state. Everything here is read-only for us.
public struct CopilotPaths: Sendable, Equatable {
    public var root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Points BriefBar at another Copilot data directory, such as the demo data.
    public static let directoryVariable = "BRIEFBAR_COPILOT_DIR"

    /// `~/.copilot`, overridable with `BRIEFBAR_COPILOT_DIR` (used by tests and for debugging) while BriefBar has the
    /// permissions of the app that started it (`Attribution.environment`).
    public static func `default`(
        environment: [String: String] = Attribution.environment
    ) -> CopilotPaths {
        if let paths = overridden(environment: environment) {
            return paths
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CopilotPaths(root: home.appendingPathComponent(".copilot", isDirectory: true))
    }

    /// The directory `BRIEFBAR_COPILOT_DIR` names, if it names one: the only data the demo reads.
    public static func overridden(
        environment: [String: String] = Attribution.environment
    ) -> CopilotPaths? {
        guard let override = environment[directoryVariable], !override.isEmpty else { return nil }
        let expanded = (override as NSString).expandingTildeInPath
        return CopilotPaths(root: URL(fileURLWithPath: expanded, isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("data.db") }
    /// SQLite's write-ahead log, where the app's commits land until a checkpoint.
    public var databaseWAL: URL { root.appendingPathComponent("data.db-wal") }
    public var sessionState: URL { root.appendingPathComponent("session-state", isDirectory: true) }

    public func sessionDirectory(_ id: String) -> URL {
        sessionState.appendingPathComponent(id, isDirectory: true)
    }

    public func eventsFile(_ id: String) -> URL {
        sessionDirectory(id).appendingPathComponent("events.jsonl")
    }
}
