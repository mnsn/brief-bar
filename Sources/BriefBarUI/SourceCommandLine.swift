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

/// The command-line modes and `--render` print or save what they read, so they run only with the permissions of the
/// app that started BriefBar, such as Terminal. Started as an app (by `open`, say), BriefBar has its own Full Disk
/// Access, and whoever started it would get what it read, even with `--demo`, whose data its environment names.
package enum CommandLineAccess {
    /// Why they can't run, or nil when they can.
    package static func refusal(_ attribution: Attribution) -> String? {
        guard attribution == .itself else { return nil }
        return """
            BriefBar's command-line modes and --render run only from a shell, such as Terminal's, with its \
            permissions. Started as an app (by open, say), BriefBar has its own Full Disk Access, so they don't run. \
            Run \(Bundle.main.executablePath ?? "BriefBar") from Terminal instead.
            """
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
    /// `--watch`: starts printing changes as they happen, and returns whether it keeps doing so (the demo
    /// of a source that polls prints its changes and is done).
    static func watch(_ options: CommandLineOptions) -> Bool
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

    /// Runs async work from a mode, which is synchronous and runs on the main thread. The main run loop keeps
    /// turning while it waits, rather than the thread blocking, so work that needs the main actor still runs.
    package static func wait<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        dispatchPrecondition(condition: .onQueue(.main))
        let result = CommandLineResult<T>()
        Task.detached {
            let value = await body()
            DispatchQueue.main.async { result.value = value }
        }
        while result.value == nil {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
        return result.value!
    }
}

/// What `wait` waits for. Only read and written on the main thread.
private final class CommandLineResult<T>: @unchecked Sendable {
    var value: T?
}
