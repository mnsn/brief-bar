import Foundation

/// A question you'd otherwise see twice. When a session waits on a question or a plan, the app tells the session that
/// coordinates it, which then asks you for it: it relays the question (`relay_session_input`), or asks about the plan in
/// its own words (`ask_user`), since a plan can't be relayed. Both then wait on the same decision. Answered in the
/// coordinator, it reaches the session. A plan approved in the session itself leaves the coordinator's question
/// waiting, and approving it there fails.
public enum RelayedQuestions {
    /// The snapshots, with what each coordinator asks you for the sessions it coordinates shown once, on its own row.
    ///
    /// A coordinator asks for a session when it relays that session's question, or asks a question of its own while the
    /// session has waited on a question or plan since before. Until then the session needs you on its own. Each session
    /// asked for moves to Running (`.relayed`), to be answered in the coordinator, or in that coordinator's coordinator
    /// when it asks for the coordinator in turn. The coordinator stays in Needs You, waiting since the longest-waiting
    /// of them, with the words of the question it relays, which a relay doesn't repeat. Permission prompts are never
    /// asked for: only the session itself can answer one.
    /// - Parameter records: what the snapshots were resolved from, with the same IDs.
    public static func merge(_ snapshots: [SessionSnapshot], records: [SessionRecord]) -> [SessionSnapshot] {
        let records = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byId = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // The question each session waits for your answer to.
        var questions: [String: PendingTool] = [:]
        for snapshot in snapshots where snapshot.phase == .needsYou && snapshot.reason == .question {
            if case .needsAnswer(let tool)? = records[snapshot.id]?.log?.activity {
                questions[snapshot.id] = tool
            }
        }
        guard !questions.isEmpty else { return snapshots }

        // A relay names the session by its ID or its workspace's.
        var named: [String: String] = [:]
        for snapshot in snapshots {
            named[snapshot.id] = snapshot.id
        }
        for snapshot in snapshots {
            if let workspaceId = records[snapshot.id]?.meta.workspaceId, named[workspaceId] == nil {
                named[workspaceId] = snapshot.id
            }
        }

        /// The coordinator that asks you for each session.
        var askedIn: [String: String] = [:]

        func root(of session: String) -> String {
            var current = session
            var seen: Set<String> = [session]
            while let next = askedIn[current], seen.insert(next).inserted {
                current = next
            }
            return current
        }

        func ask(_ session: String, in coordinator: String) {
            guard askedIn[session] == nil, session != coordinator, root(of: coordinator) != session else { return }
            askedIn[session] = coordinator
        }

        func relayed(by tool: PendingTool) -> String? {
            tool.relayedSession.flatMap { named[$0] }
        }

        for (coordinator, tool) in questions.sorted(by: { $0.key < $1.key }) {
            guard let session = relayed(by: tool), let waiting = byId[session],
                  waiting.phase == .needsYou, waiting.reason == .question
            else { continue }
            ask(session, in: coordinator)
        }
        for snapshot in snapshots where snapshot.phase == .needsYou
            && (snapshot.reason == .question || snapshot.reason == .planApproval) {
            guard let coordinator = records[snapshot.id]?.meta.coordinatorSessionId, questions[coordinator] != nil,
                  let waitingSince = snapshot.since, let askedSince = byId[coordinator]?.since, waitingSince <= askedSince
            else { continue }
            ask(snapshot.id, in: coordinator)
        }
        guard !askedIn.isEmpty else { return snapshots }

        /// What a session asks you: a relay's words are those of the session it relays.
        func words(of session: String, depth: Int = 0) -> (detail: String?, choices: [String]) {
            if depth < 8, let tool = questions[session], let relayedSession = relayed(by: tool),
               askedIn[relayedSession] == session {
                let relayedWords = words(of: relayedSession, depth: depth + 1)
                if relayedWords.detail != nil { return relayedWords }
            }
            return (byId[session]?.detail, byId[session]?.choices ?? [])
        }

        var asksFor: [String: [SessionSnapshot]] = [:]
        for session in askedIn.keys {
            if let snapshot = byId[session] {
                asksFor[root(of: session), default: []].append(snapshot)
            }
        }

        return snapshots.map { original in
            var snapshot = original
            if askedIn[original.id] != nil, let coordinator = byId[root(of: original.id)] {
                let answerIn = RelatedSession(id: coordinator.id, name: coordinator.displayName)
                (snapshot.detail, snapshot.choices) = words(of: original.id)
                snapshot.phase = .running
                snapshot.reason = .relayed
                snapshot.headline = "Answer in “\(answerIn.name)”"
                snapshot.answerIn = answerIn
            } else if let sessions = asksFor[original.id] {
                let sessions = sessions.sorted {
                    ($0.since ?? .distantFuture, $0.id) < ($1.since ?? .distantFuture, $1.id)
                }
                (snapshot.detail, snapshot.choices) = words(of: original.id)
                snapshot.since = ([original.since] + sessions.map(\.since)).compactMap { $0 }.min()
                snapshot.asksFor = sessions.map { RelatedSession(id: $0.id, name: $0.displayName) }
            }
            return snapshot
        }
    }
}
