import BriefBarCore
import Foundation

/// BriefBar among the Copilot CLI's MCP servers, which the GitHub Copilot app's sessions use too, so their agents can use
/// it. BriefBar asks the CLI itself (`copilot mcp get`, `add` and `remove`), which keeps its own configuration: BriefBar
/// never reads or writes the CLI's files, where other servers' settings are, tokens included.
public struct CopilotMCPRegistration: Sendable {
    /// The name BriefBar goes by among them.
    public static let name = "briefbar"

    public enum Status: Sendable, Equatable {
        /// There's no Copilot CLI.
        case noCLI
        /// The CLI doesn't have BriefBar.
        case absent
        /// It runs this BriefBar's `--mcp`, unless you turned it off in the CLI (`copilot mcp disable`).
        case added(enabled: Bool)
        /// It runs another copy of BriefBar, at this path.
        case addedElsewhere(String)
        /// It has a server by BriefBar's name that isn't BriefBar.
        case taken
        /// The CLI couldn't say, or couldn't change it.
        case failed(String)
    }

    /// `copilot`.
    let cli: URL
    /// Your login shell's, so the CLI uses the same settings as in Terminal, COPILOT_HOME included.
    let environment: [String: String]
    /// BriefBar's binary, which the CLI starts with `--mcp`.
    let executable: String
    let runner: any ProcessRunning

    public init(cli: URL, environment: [String: String], executable: String, runner: any ProcessRunning = ProcessRunner()) {
        self.cli = cli
        self.environment = environment
        self.executable = executable
        self.runner = runner
    }

    /// With the Copilot CLI that your login shell finds, or nil without one.
    public static func find(executable: String, runner: any ProcessRunning = ProcessRunner()) async -> CopilotMCPRegistration? {
        let environment = await LoginEnvironment.load(runner: runner)
        guard let cli = CopilotCLI.locate(environment: environment) else { return nil }
        return CopilotMCPRegistration(cli: cli, environment: environment, executable: executable, runner: runner)
    }

    /// The CLI takes a few seconds to start.
    static let timeout: TimeInterval = 30

    public func status() async -> Status {
        let result: ProcessResult
        do {
            result = try await run(["mcp", "get", Self.name, "--json"])
        } catch {
            return .failed(String(describing: error))
        }
        guard result.status == 0 else {
            let message = Self.firstLine(result.stderr) ?? "It ended with status \(result.status)."
            return message.localizedCaseInsensitiveContains("not found") ? .absent : .failed(message)
        }
        return Self.status(of: result.stdout, executable: executable)
    }

    /// Adds BriefBar, in place of another copy of BriefBar the CLI ran. A server by its name that isn't BriefBar stays.
    public func add() async -> Status {
        let current = await status()
        switch current {
        case .absent:
            break
        case .addedElsewhere:
            if let failure = await change(["mcp", "remove", Self.name]) { return failure }
        case .added, .noCLI, .taken, .failed:
            return current
        }
        if let failure = await change(["mcp", "add", Self.name, "--", executable, "--mcp"]) { return failure }
        return await status()
    }

    /// Removes BriefBar, whichever copy the CLI runs. A server by its name that isn't BriefBar stays.
    public func remove() async -> Status {
        let current = await status()
        switch current {
        case .added, .addedElsewhere:
            if let failure = await change(["mcp", "remove", Self.name]) { return failure }
            return await status()
        case .absent, .noCLI, .taken, .failed:
            return current
        }
    }

    // MARK: The CLI

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        try await runner.run(cli, arguments: arguments, environment: environment, timeout: Self.timeout)
    }

    /// Nil once done, or why not.
    private func change(_ arguments: [String]) async -> Status? {
        do {
            let result = try await run(arguments)
            guard result.status == 0 else { return .failed(Self.firstLine(result.stderr) ?? "It ended with status \(result.status).") }
            return nil
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// What `copilot mcp get <name> --json` says.
    static func status(of output: Data, executable: String) -> Status {
        guard let object = Self.object(in: output), let server = object[name] as? [String: Any] else {
            return .failed("The Copilot CLI's answer couldn't be read.")
        }
        let command = server["command"] as? String ?? ""
        let arguments = server["args"] as? [String] ?? []
        guard isBriefBar(command: command, arguments: arguments) else { return .taken }
        guard isSameFile(command, executable) else { return .addedElsewhere(command) }
        return .added(enabled: server["enabled"] as? Bool ?? true)
    }

    /// The JSON object in the output, after anything the CLI printed before it.
    private static func object(in output: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] { return object }
        guard let start = output.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return try? JSONSerialization.jsonObject(with: output[start...]) as? [String: Any]
    }

    /// A copy of BriefBar, serving agents.
    static func isBriefBar(command: String, arguments: [String]) -> Bool {
        (command as NSString).lastPathComponent == "BriefBar" && arguments.contains("--mcp")
    }

    static func isSameFile(_ first: String, _ second: String) -> Bool {
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return resolved(first) == resolved(second)
    }

    private static func firstLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            .map { $0.hasPrefix("Error: ") ? String($0.dropFirst("Error: ".count)) : $0 }
    }
}
