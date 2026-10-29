import BriefBarCore
import Foundation

/// Asks the Copilot CLI to write a summary, with no tools at all: what it's given, which others wrote, such as pull
/// requests' comments, is only ever something to write about. It can't run a command, read or change a file, or reach a
/// web page for it. It runs in a folder of BriefBar's own, without your custom instructions or the built-in MCP servers,
/// in a session of its own named "BriefBar summary", which the CLI keeps, as it keeps every session, and which the
/// Copilot app doesn't list. Nothing runs unless you ask for a summary, and what runs stops when the summary's cancelled.
public actor CopilotSummarizer {
    public enum Failure: Error, Sendable, Equatable {
        /// No `copilot` was found.
        case noCLI
        /// It ended with an error: its first lines, as it said them.
        case failed(String)
        /// It answered nothing.
        case empty
        /// It took longer than `timeout`.
        case timedOut
        /// It was cancelled: Copilot didn't start, or was stopped.
        case cancelled

        /// Why there's no summary, for you.
        public var message: String {
            switch self {
            case .noCLI: return "BriefBar couldn't find the Copilot CLI. Install it, or open the GitHub Copilot app once."
            case .failed(let reason): return "Copilot couldn't write it: \(reason)"
            case .empty: return "Copilot answered nothing."
            case .timedOut: return "Copilot took too long to answer."
            case .cancelled: return "The summary was cancelled."
            }
        }
    }

    /// What `--available-tools` names: no tool is called this, so the model has none. Naming none at all would leave it
    /// every tool, as the CLI takes that as no limit.
    public static let noTools = "briefbar_no_tools"
    /// The session's name, as `copilot --resume` lists it.
    public static let sessionName = "BriefBar summary"
    /// How long a summary may take.
    public static let timeout: TimeInterval = 120
    /// Where it runs: a folder of BriefBar's own, with nothing in it, so no project's instructions, skills or MCP servers
    /// apply.
    public static let defaultFolder = UserHome.url.appendingPathComponent(
        "Library/Application Support/BriefBar/Copilot/Summaries", isDirectory: true
    )

    private let runner: any ProcessRunning
    private let folder: URL
    private let loadEnvironment: @Sendable () async -> [String: String]
    private let locate: @Sendable ([String: String]) -> URL?
    private var environment: [String: String]?

    /// - Parameters:
    ///   - loadEnvironment: your login shell's environment, asked for once (`LoginEnvironment.load`).
    ///   - locate: finds `copilot` (`CopilotCLI.locate`).
    public init(
        runner: any ProcessRunning = ProcessRunner(), folder: URL = CopilotSummarizer.defaultFolder,
        loadEnvironment: @escaping @Sendable () async -> [String: String] = { await LoginEnvironment.load() },
        locate: @escaping @Sendable ([String: String]) -> URL? = { CopilotCLI.locate(environment: $0) }
    ) {
        self.runner = runner
        self.folder = folder
        self.loadEnvironment = loadEnvironment
        self.locate = locate
    }

    /// The CLI's arguments for a summary: the prompt, the model, no tools, shell and writing denied as well, without the
    /// built-in MCP servers or custom instructions, asking nothing, printing only the answer.
    public static func arguments(prompt: String, options: CopilotRunOptions, folder: URL) -> [String] {
        var arguments = ["-p", prompt, "--model", options.model]
        if let effort = options.effort { arguments += ["--reasoning-effort", effort] }
        arguments += [
            "--available-tools=\(noTools)", "--deny-tool", "shell", "--deny-tool", "write",
            "--disable-builtin-mcps", "--no-custom-instructions", "--no-ask-user", "--no-color", "--silent",
            "--name", sessionName, "-C", folder.path,
        ]
        return arguments
    }

    /// What the model answered to the prompt, or why there's no answer. Cancelled, it runs nothing more: Copilot doesn't
    /// start, or it's stopped, with whatever it started.
    public func summarize(_ prompt: String, options: CopilotRunOptions) async -> Result<String, Failure> {
        guard let environment = await loadedEnvironment() else { return .failure(.cancelled) }
        guard let copilot = locate(environment) else { return .failure(.noCLI) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let started = Date()
        let result: ProcessResult
        do {
            result = try await runner.run(
                copilot, arguments: Self.arguments(prompt: prompt, options: options, folder: folder), environment: environment,
                timeout: Self.timeout
            )
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
        if result.status != 0, Date().timeIntervalSince(started) >= Self.timeout { return .failure(.timedOut) }
        let answer = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else { return .failure(.failed(Self.reason(result))) }
        return answer.isEmpty ? .failure(.empty) : .success(answer)
    }

    /// Your login shell's environment, asked for once; nil when the summary was cancelled meanwhile, and then it's asked
    /// again next time, since the shell may have been stopped before it said it all.
    private func loadedEnvironment() async -> [String: String]? {
        if let environment { return environment }
        let loaded = await loadEnvironment()
        guard !Task.isCancelled else { return nil }
        environment = loaded
        return loaded
    }

    /// Why it failed, in its own words: the first lines it printed to standard error, or else to its output, without
    /// terminal escapes, at most 300 characters.
    static func reason(_ result: ProcessResult) -> String {
        let said = [result.stderr, result.stdout].lazy.map { String(decoding: $0, as: UTF8.self) }
            .map { $0.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "") }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let lines = said.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let text = StoryText.line(lines.prefix(3).joined(separator: " "), limit: 300)
        return text.isEmpty ? "It ended with status \(result.status)." : text
    }
}
