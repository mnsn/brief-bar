import BriefBarCore
import BriefBarUI
import CopilotCore
import Foundation

extension CopilotCommandLine {
    /// `--mcp`: the GitHub Copilot app's sessions, for agents, as the app shows them, and the ones on the pull requests
    /// another source's tools name. It only reads.
    package static func mcp(_ options: CommandLineOptions) -> MCPSource? {
        guard let paths = paths(options) else { return nil }
        let agent = CopilotAgent(paths: paths, isDemo: options.demo)
        return MCPSource(name: "GitHub Copilot", tools: agent.tools, related: agent.teller) { await agent.needsYou() }
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
    /// - Parameter links: read where each session's work goes too (`SessionLinks`), to link it to pull requests.
    func load(now: Date = Date(), links: Bool = false) async -> (sessions: [SessionSnapshot], problem: String?) {
        let paths = paths
        let state = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SessionEngine.loadOnce(paths: paths, links: links))
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

    // MARK: What the other sources' tools name

    /// What it tells the other sources' tools: the app's sessions on the pull requests they name.
    var teller: MCPRelated.Teller {
        MCPRelated.Teller(title: "Copilot sessions") { query in try await related(query) }
    }

    /// The app's sessions that go with the pull requests a query names, as Show Links links them: on a pull request's
    /// branch, or recorded by the app as one they started from or opened. The ones that need you first, then the newest,
    /// the first `limit` with what Copilot recorded of their work, read from their folders off the concurrency pool's
    /// threads. The sessions BriefBar started for work it sent aren't the app's: the source that sent it tells of those.
    func related(_ query: MCPRelated.Query, now: Date = Date()) async throws -> [MCPRelated.Item] {
        guard query.items.contains(where: \.kind.isPullRequest) || !query.branches.isEmpty else { return [] }
        let (sessions, problem) = await load(now: now, links: true)
        if sessions.isEmpty, let problem { throw MCPToolError(problem) }
        let found = Self.linked(sessions, to: query)
        let ids = found.prefix(max(query.limit, 0)).map(\.session.id)
        let paths = paths
        let accounts = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var accounts: [String: ItemStory.Account] = [:]
                for id in ids { accounts[id] = SessionAccount.read(paths: paths, id: id) }
                continuation.resume(returning: accounts)
            }
        }
        return found.enumerated().map { index, linked in
            Self.item(linked, account: accounts[linked.session.id], whole: index < query.limit, now: now)
        }
    }

    /// A session linked to what a query names, and why.
    struct Linked {
        var session: SessionSnapshot
        var ref: ItemRef
        var links: [MCPRelated.Link]
    }

    /// The sessions linked to the pull requests a query names, as Show Links links them (`LinkGraph`), each with why: the
    /// ones that need you first, then what's wrong, what's at work and what's done, then the rest, the newest first in each.
    static func linked(_ sessions: [SessionSnapshot], to query: MCPRelated.Query) -> [Linked] {
        let pullRequests = Set(query.items.filter(\.kind.isPullRequest)).union(query.branches.keys).sorted()
        var refs: [String: ItemRef] = [:]
        var hints: [ItemRef: BranchHint] = [:]
        for session in sessions {
            guard let ref = ItemRef.session(session.id) else { continue }
            refs[session.id] = ref
            hints[ref] = session.branchHint
        }
        let graph = LinkGraph(links: sessions.flatMap(\.recordedLinks) + BranchLinks.links(sessions: hints, pullRequests: query.branches))
        let found = sessions.compactMap { session -> Linked? in
            guard let ref = refs[session.id] else { return nil }
            let links = pullRequests.compactMap { pullRequest -> MCPRelated.Link? in
                let origins = graph.origins(ref, pullRequest)
                guard !origins.isEmpty else { return nil }
                let roles = (session.links?.pullRequests ?? []).filter { $0.ref == pullRequest }.map(\.role)
                return MCPRelated.Link(item: pullRequest, reason: reason(origins, roles: roles, pullRequest: pullRequest))
            }
            return links.isEmpty ? nil : Linked(session: session, ref: ref, links: links)
        }
        return found.sorted { lhs, rhs in
            let (left, right) = (ItemState.rank(lhs.session.phase.state), ItemState.rank(rhs.session.phase.state))
            if left != right { return left < right }
            if lhs.session.since != rhs.session.since { return (lhs.session.since ?? .distantPast) > (rhs.session.since ?? .distantPast) }
            return lhs.ref < rhs.ref
        }
    }

    /// Why a session goes with a pull request: "opened !4091", "started from !4091", "on !4120's branch", or both.
    static func reason(_ origins: [LinkOrigin], roles: [RecordedPullRequest.Role?], pullRequest: ItemRef) -> String {
        let name = pullRequest.kind == .gitHubPullRequest ? "#\(pullRequest.id)" : "!\(pullRequest.id)"
        var reasons: [String] = []
        if origins.contains(.copilot) {
            if roles.contains(where: { $0 == .opened }) {
                reasons.append("opened \(name)")
            } else if roles.contains(where: { $0 == .startedFrom }) {
                reasons.append("started from \(name)")
            } else {
                reasons.append("linked to \(name) in the Copilot app")
            }
        }
        if origins.contains(.branch) { reasons.append(reasons.isEmpty ? "on \(name)'s branch" : "on its branch") }
        return reasons.joined(separator: ", ")
    }

    /// A session, for another source's tool to tell: its name, where it stands and since when, its link, and why it goes
    /// with what was asked about; and, when `whole`, a few lines of what it asks or does and of what Copilot recorded.
    static func item(_ linked: Linked, account: ItemStory.Account?, whole: Bool, now: Date) -> MCPRelated.Item {
        let session = linked.session
        return MCPRelated.Item(
            ref: linked.ref, title: session.displayName, status: status(session, now: now), state: session.phase.state,
            date: session.since, url: URL(string: "ghapp://sessions/\(session.id)"), links: linked.links,
            lines: whole ? lines(session, account: account) : []
        )
    }

    /// Where a session stands, in a few words, and since when: "waiting for your answer since 4m ago", "finished 2h ago".
    static func status(_ session: SessionSnapshot, now: Date) -> String {
        let elapsed = session.since.map { Elapsed.short(since: $0, now: now) }
        func going(_ words: String) -> String {
            guard let elapsed else { return words }
            return elapsed == "now" ? "\(words), just now" : "\(words) since \(elapsed) ago"
        }
        func ended(_ words: String) -> String {
            guard let elapsed else { return words }
            return elapsed == "now" ? "\(words) just now" : "\(words) \(elapsed) ago"
        }
        switch session.reason {
        case .question: return going("waiting for your answer")
        case .planApproval: return going("waiting for you to review its plan")
        case .permission: return going("waiting for your permission")
        case .working: return going("working")
        case .starting: return going("starting")
        case .finished: return ended("finished")
        case .interrupted: return ended("interrupted")
        case .failed: return ended("stopped with an error")
        case .unresponsive: return ended("stopped responding")
        case .idle: return elapsed.map { $0 == "now" ? "idle" : "idle, last active \($0) ago" } ?? "idle"
        }
    }

    /// What a session asks or does, as its story says it (`SessionStory`), and what it asks you to choose from; then what
    /// Copilot recorded of its work.
    static func lines(_ session: SessionSnapshot, account: ItemStory.Account?) -> [String] {
        guard let story = SessionStory.make(snapshot: session, account: account) else { return [] }
        var lines: [String] = []
        let says: Set<StatusReason> = [.question, .planApproval, .permission, .working, .starting, .failed]
        if session.detail != nil, says.contains(session.reason), !story.sentence.isEmpty { lines.append(story.sentence) }
        lines += story.facts.map { "\($0.label): \($0.value)" }
        if let account = story.account {
            lines += recorded(account)
        } else if session.reason == .finished, let detail = session.detail {
            lines.append("Did: \(brief(detail))")
        }
        return lines
    }

    /// What Copilot recorded, briefly, a line each: what the session did, from its latest checkpoint or the summary it
    /// finished with; its first next step; and what it said last, when that came after.
    static func recorded(_ account: ItemStory.Account) -> [String] {
        if account.source == SessionAccount.fromLastMessage {
            return account.overview.map { ["Said last: \(brief($0))"] } ?? []
        }
        var lines: [String] = []
        if let overview = account.overview {
            lines.append("Did: \(brief(overview))")
        } else if !account.done.isEmpty {
            lines.append("Did: " + account.done.prefix(3).joined(separator: "; "))
        }
        if let next = account.next.first { lines.append("Next: \(next)") }
        if let last = account.lastMessage { lines.append("Said last: \(brief(last))") }
        return lines
    }

    /// A text's first sentences, on one line, as many as fit in `limit` characters; the first one cut short when it
    /// doesn't fit.
    static func brief(_ text: String, limit: Int = 240) -> String {
        let line = StoryText.line(text, limit: max(text.count, 1))
        guard line.count > limit else { return line }
        var end: String.Index?
        var index = line.startIndex
        var count = 0
        while index < line.endIndex {
            let next = line.index(after: index)
            count += 1
            if count > limit { break }
            if ".!?".contains(line[index]), next == line.endIndex || line[next] == " " { end = next }
            index = next
        }
        guard let end else { return StoryText.line(line, limit: limit) }
        return String(line[..<end])
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
