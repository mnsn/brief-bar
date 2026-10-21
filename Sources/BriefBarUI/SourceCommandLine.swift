import BriefBarCore
import Foundation

/// What every source's command-line modes are given.
package struct CommandLineOptions: Sendable {
    package var arguments: [String]
    /// Made-up data instead of yours.
    package var demo: Bool

    package init(arguments: [String], demo: Bool) {
        self.arguments = arguments
        self.demo = demo
    }
}

/// A source's command-line modes, which run without the app's UI, mainly to check what it would show.
package protocol SourceCommandLine {
    static var source: SourceID { get }
    /// `SourceDescription.version` of the source: the modes cover a source only while it's on in the app,
    /// unless `--source` names it.
    static var descriptionVersion: Int { get }
    /// For `--help`: the modes and variables of its own, one per line.
    static var usage: String { get }
    /// The flags of its own modes, which imply `--source` for it.
    static var flags: [String] { get }

    /// `--dump`: prints what the source shows. Returns the exit code.
    static func dump(_ options: CommandLineOptions) -> Int32
    /// `--json`: what the source shows, as a JSON object, with its counts under `counts`.
    static func json(_ options: CommandLineOptions) -> [String: Any]?
    /// `--watch`: starts printing changes as they happen, and returns.
    static func watch(_ options: CommandLineOptions)
    /// Its own modes, such as `--diagnose`. Nil when the arguments have none of them.
    static func run(_ options: CommandLineOptions) -> Int32?
}

extension SourceCommandLine {
    package static var flags: [String] { [] }
    package static func run(_ options: CommandLineOptions) -> Int32? { nil }

    /// Encodes a value the way every source's `--json` does, as a JSON object.
    package static func jsonObject(_ value: some Encodable) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
