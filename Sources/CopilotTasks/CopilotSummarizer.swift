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
        /// The Copilot CLI isn't signed in: its first lines, as it said them.
        case notSignedIn(String)
        /// The model isn't one your Copilot plan offers, or the CLI knows: its first lines.
        case modelUnavailable(String)
        /// Your Copilot plan's premium requests ran out: its first lines.
        case outOfRequests(String)
        /// It ended with another error: its first lines.
        case failed(String)
        /// It answered nothing.
        case empty
        /// It took longer than `timeout`.
        case timedOut
        /// It was cancelled: Copilot didn't start, or was stopped.
        case cancelled

        /// Why there's no summary, for you, in a sentence, with what to do about it when there's something.
        /// - Parameter model: the model's name, as you chose it.
        public func message(model: String) -> String {
            switch self {
            case .noCLI: return "BriefBar can't find the Copilot CLI. Install it, or open the GitHub Copilot app once."
            case .notSignedIn: return "The Copilot CLI isn't signed in. Run copilot in Terminal once."
            case .modelUnavailable: return "\(model) isn't on your Copilot plan."
            case .outOfRequests: return "You're out of premium requests this month."
            case .failed(let reason): return "Copilot couldn't write it: \(reason)"
            case .empty: return "Copilot answered nothing."
            case .timedOut: return "Copilot took too long to answer."
            case .cancelled: return "The summary was cancelled."
            }
        }

        /// What the CLI said, as it said it, when the message says it in other words.
        public var detail: String? {
            switch self {
            case .notSignedIn(let said), .modelUnavailable(let said), .outOfRequests(let said): return said
            case .noCLI, .failed, .empty, .timedOut, .cancelled: return nil
            }
        }

        /// What failed, by what the CLI said: its first lines, `reason`, and all of it, `said`, which tells. Not signed in:
        /// "No authentication information found", "Run /login to sign in again". The model: `Model "x" from --model flag is
        /// not available`. Out of requests: premium requests, a quota or AI credits that ran out, or payment required.
        static func failure(said: String, reason: String) -> Failure {
            let said = said.lowercased()
            func says(_ pattern: String) -> Bool { said.range(of: pattern, options: .regularExpression) != nil }
            if says(#"no authentication information|not (logged|signed) in|log ?in again|/login\b|copilot login|authentication token|not authenticated|unauthori[sz]ed|\b401\b"#) {
                return .notSignedIn(reason)
            }
            let allowance = #"(premium (request|interaction)s?|quota|ai credits?|allowance|spending limit)"#
            let spent = #"(exceed|exhaust|reached|used (up|all)|run out|ran out|out of|no (more|remaining)|insufficient)"#
            if says(allowance + #"[^.\n]{0,80}"# + spent) || says(spent + #"[^.\n]{0,80}"# + allowance)
                || says(#"payment required|\b402\b"#) {
                return .outOfRequests(reason)
            }
            if says(#"\bmodel\b[^\n]{0,120}\b(is not available|isn'?t available|unavailable|not supported|isn'?t supported|not enabled|not found)"#)
                || says(#"invalid_model|model_not_supported|unknown model"#) {
                return .modelUnavailable(reason)
            }
            return .failed(reason)
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
        guard result.status == 0 else { return .failure(Failure.failure(said: Self.said(result), reason: Self.reason(result))) }
        return answer.isEmpty ? .failure(.empty) : .success(answer)
    }

    /// Whether the Copilot CLI is there, as your login shell finds it, for Settings to say when it isn't; nil when the task
    /// that asks is cancelled before it can tell.
    public func findsCLI() async -> Bool? {
        guard let environment = await loadedEnvironment() else { return nil }
        return locate(environment) != nil
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

    /// What it printed to standard error, or else to its output, without terminal escapes.
    static func said(_ result: ProcessResult) -> String {
        [result.stderr, result.stdout].lazy.map { String(decoding: $0, as: UTF8.self) }
            .map { $0.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "") }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    /// Why it failed, in its own words: the first lines it said (`said`), at most 300 characters.
    static func reason(_ result: ProcessResult) -> String {
        let lines = said(result).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let text = StoryText.line(lines.prefix(3).joined(separator: " "), limit: 300)
        return text.isEmpty ? "It ended with status \(result.status)." : text
    }
}
