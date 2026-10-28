import BriefBarCore
import BriefBarUI
import CopilotCore
import Foundation

extension CopilotCommandLine {
    /// `--mcp`: the GitHub Copilot app's sessions, for agents, as the app shows them. It only reads.
    package static func mcp(_ options: CommandLineOptions) -> MCPSource? {
        guard let paths = paths(options) else { return nil }
        let agent = CopilotAgent(paths: paths, isDemo: options.demo)
        return MCPSource(name: "GitHub Copilot", tools: agent.tools) { await agent.needsYou() }
    }
}

/// The tools `--mcp` gives agents for the GitHub Copilot app's sessions.
struct CopilotAgent: Sendable {
    let paths: CopilotPaths
    var isDemo = false

    var tools: [MCPTool] {
        [
            MCPTool(
                name: "copilot_sessions",
                title: "Copilot Sessions",
                description: """
                    The user's sessions in the GitHub Copilot app as BriefBar shows them: the ones waiting for an \
                    answer, a plan's review or a permission, the ones working, done, stopped or idle, each with its \
                    project, branch, what it's doing or asks, and its session ID.
                    """,
                inputSchema: MCPSchema.object([
                    "phase": MCPSchema.string("Only the sessions in this phase", oneOf: DisplayPhase.allCases.map(\.agentName)),
                ])
            ) { arguments in try await sessions(phase: arguments["phase"]) },
        ]
    }

    /// The sessions, as the app resolves them now. The app's database and the sessions' logs are read off the
    /// concurrency pool's threads.
    func load(now: Date = Date()) async -> (sessions: [SessionSnapshot], problem: String?) {
        let paths = paths
        let state = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SessionEngine.loadOnce(paths: paths))
            }
        }
        return (CopilotCommandLine.resolve(state, now: now, defaults: isDemo ? MemoryDefaults() : nil), state.problem)
    }

    func sessions(phase: JSONValue?, now: Date = Date()) async throws -> String {
        var only: DisplayPhase?
        if let phase {
            guard let found = phase.string.flatMap(DisplayPhase.named) else {
                throw MCPToolError("There's no phase “\(phase.string ?? "")”: use one of \(DisplayPhase.allCases.map(\.agentName).joined(separator: ", ")).")
            }
            only = found
        }
        let (sessions, problem) = await load(now: now)
        if sessions.isEmpty, let problem { throw MCPToolError(problem) }
        let counts = PhaseCounts(sessions)
        var lines: [String] = []
        if let problem { lines.append("BriefBar couldn't read everything: \(problem)\n") }
        lines.append(DisplayPhase.allCases.map { "\(counts[$0]) \($0.title.lowercased())" }.joined(separator: " · "))
        for phase in only.map({ [$0] }) ?? DisplayPhase.allCases {
            let inPhase = sessions.filter { $0.phase == phase }
            guard !inPhase.isEmpty || only != nil else { continue }
            lines.append("\n## \(phase.title) (\(inPhase.count))")
            lines += inPhase.isEmpty ? ["None."] : inPhase.map { Self.line($0, now: now) }
        }
        return lines.joined(separator: "\n")
    }

    /// The sessions that need you, and the ones that stopped, as the menu bar counts them.
    func needsYou(now: Date = Date()) async -> String? {
        let (sessions, problem) = await load(now: now)
        var sections: [String] = []
        for phase in [DisplayPhase.needsYou, .stopped] {
            let inPhase = sessions.filter { $0.phase == phase }
            guard !inPhase.isEmpty else { continue }
            sections.append("\(phase.title) (\(inPhase.count)):\n" + inPhase.map { Self.line($0, now: now) }.joined(separator: "\n"))
        }
        if sections.isEmpty { return problem.map { "BriefBar couldn't read everything: \($0)" } }
        return sections.joined(separator: "\n\n")
    }

    /// A session in a list: what it is, where, what it's doing or asks and since when, and its ID.
    static func line(_ session: SessionSnapshot, now: Date) -> String {
        var place = [session.projectName, session.branch].compactMap { $0 }.joined(separator: ", ")
        if session.isChat { place = place.isEmpty ? "a chat" : "a chat, \(place)" }
        var text = "- “\(session.displayName)”" + (place.isEmpty ? "" : " (\(place))") + ": \(session.headline)"
        if let since = session.since {
            let elapsed = Elapsed.short(since: since, now: now)
            text += elapsed == "now" ? ", just now" : ", \(elapsed) ago"
        }
        if let detail = session.detail, !detail.isEmpty { text += ". \(detail)" }
        if !session.choices.isEmpty { text += "\n  Choices: " + session.choices.joined(separator: " · ") }
        return text + "\n  session \(session.id)"
    }
}

extension DisplayPhase {
    /// What agents call it: `needs_you`.
    var agentName: String {
        rawValue.reduce(into: "") { result, character in
            if character.isUppercase {
                result += "_" + character.lowercased()
            } else {
                result.append(character)
            }
        }
    }

    static func named(_ name: String) -> DisplayPhase? {
        allCases.first { $0.agentName == name.lowercased() || $0.rawValue.lowercased() == name.lowercased() }
    }
}
