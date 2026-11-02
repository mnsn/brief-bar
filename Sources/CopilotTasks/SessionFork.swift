import BriefBarCore
import CopilotCore
import Foundation

/// Forking a session, and asking one a side question, through the Copilot CLI's server (`CopilotServer`).
extension CopilotServer {
    /// The oldest Copilot CLI that forks a session without changing it. Tried with the CLI's own builds on a session that
    /// 1.0.105 wrote: 1.0.78 added a line to the session it forked, and 1.0.87 replaced that session's whole log with that
    /// line, where 1.0.95, 1.0.99, 1.0.102, 1.0.103 and 1.0.105 left its log and `workspace.yaml` as they were, adding only
    /// an empty `.workspace-fork.lock` to its folder, as the CLI's `/fork` does.
    static let forksSafelyFrom = Version("1.0.95-3")!

    /// Shakes hands with it, and makes sure it forks a session without changing it (`forksSafelyFrom`): its version.
    @discardableResult
    func connectForForking(timeout: TimeInterval) async throws -> Version {
        let connection = try await call("connect", NoParameters(), as: Connection.self, timeout: timeout)
        guard let said = connection.version, let version = Version(said) else {
            throw Failure.unsupported("It didn't say which version of the Copilot CLI it is.")
        }
        guard (connection.protocolVersion ?? 0) >= Self.protocolVersion, version >= Self.forksSafelyFrom else {
            throw Failure.tooOld(said)
        }
        return version
    }

    /// A new session with the session's whole history, as it's saved, named `name`, or else "<its name> (fork)": its ID.
    /// The session itself stays as it was, even while it runs a turn, or the Copilot app has it open. Its answer is the
    /// only word of the fork, so once it's asked, it's waited for even if the task that asked is cancelled, which then
    /// deletes the fork; and if it takes longer than `timeout`, the server is given up on (`call(_:_:as:timeout:patient:)`).
    func fork(_ id: String, name: String?, timeout: TimeInterval) async throws -> String {
        let fork = try await call("sessions.fork", Fork(sessionId: id, name: name), as: Forked.self, timeout: timeout, patient: true)
        // Its ID names its folder.
        guard AppSessions.isSessionID(fork.sessionId), fork.sessionId != id else { throw Failure.unreadable }
        return fork.sessionId
    }

    /// Opens a session to ask it a side question: with the model chosen, or else its own; with no tools; and without your
    /// skills, MCP servers or plugins, which a side question doesn't use.
    func openToAsk(_ id: String, options: CopilotRunOptions?, timeout: TimeInterval) async throws {
        _ = try await call(
            "session.resume", Resume(sessionId: id, model: options?.model, reasoningEffort: options?.effort),
            as: IgnoredAnswer.self, timeout: timeout
        )
    }

    /// What the model answers a question about an open session's conversation, as the CLI's `/ask` does: with no tools,
    /// and without adding either to the conversation.
    func askAside(_ question: String, in id: String, timeout: TimeInterval) async throws -> String {
        try await call("session.ui.ephemeralQuery", Question(sessionId: id, question: question), as: Answer.self, timeout: timeout)
            .answer
    }

    /// Deletes a session, its log and its folder, as the CLI does: only ever a fork BriefBar made and has no use for.
    func delete(_ id: String, timeout: TimeInterval) async throws {
        let deleted = try await call("session.delete", Session(sessionId: id), as: Deleted.self, timeout: timeout)
        guard deleted.success else { throw Failure.failed(deleted.error ?? "It didn't delete the session.") }
    }

    private struct NoParameters: Encodable, Sendable {}

    private struct Fork: Encodable, Sendable {
        var sessionId: String
        var name: String?
    }

    private struct Forked: Decodable, Sendable {
        var sessionId: String
    }

    private struct Resume: Encodable, Sendable {
        var sessionId: String
        var clientName = "BriefBar"
        var model: String?
        var reasoningEffort: String?
        /// A tool nobody has: the model gets none. An empty list would leave it every tool.
        var availableTools = [CopilotSummarizer.noTools]
        var enableConfigDiscovery = false
        var enableSkills = false
    }

    private struct Question: Encodable, Sendable {
        var sessionId: String
        var question: String
    }

    private struct Answer: Decodable, Sendable {
        var answer: String
    }

    private struct Session: Encodable, Sendable {
        var sessionId: String
    }

    private struct Deleted: Decodable, Sendable {
        var success: Bool
        var error: String?
    }
}

/// Forks a session for a task (`CopilotLauncher.Request.forking`), and deletes the fork when the task can't start in it.
struct SessionForker: Sendable {
    var copilot: URL
    var environment: [String: String]
    var timeout: TimeInterval = 60

    /// The fork's ID: a new session with the session's whole history, named `name`. Throws `LaunchError.cantFork`; and
    /// cancelled once it's asked for, it deletes the fork it made.
    func fork(_ id: String, name: String?) async throws -> String {
        let server: CopilotServer
        do {
            server = try CopilotServer.start(copilot, environment: environment)
        } catch {
            throw LaunchError.cantFork(Self.reason(error))
        }
        let fork: String
        do {
            try await server.connectForForking(timeout: timeout)
            fork = try await server.fork(id, name: name, timeout: timeout)
        } catch {
            await server.close()
            throw LaunchError.cantFork(Self.reason(error))
        }
        await server.close()
        if Task.isCancelled {
            await discard(fork)
            throw LaunchError.cantFork(Self.reason(CopilotServer.Failure.cancelled))
        }
        return fork
    }

    /// Deletes a fork it made, whatever happens to the task that asked, even once it's cancelled. Whether it's gone, as
    /// its folder says.
    @discardableResult
    func discard(_ fork: String) async -> Bool {
        let copilot = copilot, environment = environment, timeout = timeout
        await Task {
            guard let server = try? CopilotServer.start(copilot, environment: environment) else { return }
            _ = try? await server.delete(fork, timeout: timeout)
            await server.close()
        }.value
        return isGone(fork)
    }

    /// Whether a session's folder is gone from the CLI's folder.
    func isGone(_ session: String) -> Bool {
        !FileManager.default.fileExists(atPath: CopilotPaths(root: CopilotCLI.home(environment: environment)).sessionDirectory(session).path)
    }

    /// Why it couldn't fork the session, for you, in a sentence.
    static func reason(_ error: any Error) -> String {
        switch error as? CopilotServer.Failure {
        case .couldntStart(let why)?: return "The Copilot CLI couldn't start to fork the session: \(why)"
        case .tooOld(let version)?:
            return "The Copilot CLI \(version) can't fork a session without changing it. Update it with copilot update."
        case .unsupported?: return "This Copilot CLI can't fork a session. Update it with copilot update."
        case .failed(let said)?: return "The Copilot CLI couldn't fork the session: \(StoryText.line(said, limit: 300))"
        case .exited(let status)?: return "The Copilot CLI ended, with status \(status), before it forked the session."
        case .unreadable?: return "The Copilot CLI answered in a way BriefBar can't read, so it didn't fork the session."
        case .timedOut?: return "The Copilot CLI took too long to fork the session."
        case .cancelled?: return "Forking the session was cancelled."
        case nil: return "The Copilot CLI couldn't fork the session: \(error)"
        }
    }
}

/// Asks a Copilot session a side question, and answers with what Copilot says, without changing the session: its history
/// gets neither the question nor the answer, nothing changes a file, and the session can be asked while it works, or
/// while the Copilot app has it open. As the CLI's `/ask` does, which only its terminal offers, it's one request to the
/// model, with the session's conversation and no tools; but it's asked of a fork of the session, made for it and
/// deleted after, so the session's own log doesn't record it either, as `/ask`'s would. Through the Copilot CLI's server
/// (`CopilotServer`), 1.0.95 or later (`CopilotServer.forksSafelyFrom`). Nothing runs unless you ask, and what runs stops
/// when the question's cancelled.
public actor SessionQuestions {
    public enum Failure: Error, Sendable, Equatable {
        /// No `copilot` was found.
        case noCLI
        /// This Copilot CLI can't ask a session a side question without changing it: too old, or not one that can. Its
        /// version, when it said.
        case unsupported(version: String?)
        /// The Copilot CLI has no such session in its folder.
        case noSession
        /// The Copilot CLI isn't signed in: what it said.
        case notSignedIn(String)
        /// The model isn't one your Copilot plan offers, or the CLI knows: what it said.
        case modelUnavailable(String)
        /// Your Copilot plan's premium requests ran out: what it said.
        case outOfRequests(String)
        /// It failed otherwise: why, in a few words.
        case failed(String)
        /// It answered nothing.
        case empty
        /// It took longer than `Timeouts.answer`.
        case timedOut
        /// It was cancelled: Copilot didn't start, or was stopped.
        case cancelled

        /// Why there's no answer, for you, in a sentence, with what to do about it when there's something.
        /// - Parameter model: the model's name, as you chose it; nil for the session's own.
        public func message(model: String?) -> String {
            switch self {
            case .noCLI: return "BriefBar can't find the Copilot CLI. Install it, or open the GitHub Copilot app once."
            case .unsupported(let version):
                return "The Copilot CLI\(version.map { " \($0)" } ?? "") can't ask a session a side question without changing it. Update it with copilot update."
            case .noSession: return "The Copilot CLI doesn't have this session."
            case .notSignedIn: return "The Copilot CLI isn't signed in. Run copilot in Terminal once."
            case .modelUnavailable: return "\(model ?? "The session's model") isn't on your Copilot plan."
            case .outOfRequests: return "You're out of premium requests this month."
            case .failed(let reason): return "Copilot couldn't answer: \(reason)"
            case .empty: return "Copilot answered nothing."
            case .timedOut: return "Copilot took too long to answer."
            case .cancelled: return "The question was cancelled."
            }
        }

        /// What the CLI said, as it said it, when the message says it in other words.
        public var detail: String? {
            switch self {
            case .notSignedIn(let said), .modelUnavailable(let said), .outOfRequests(let said): return said
            case .noCLI, .unsupported, .noSession, .failed, .empty, .timedOut, .cancelled: return nil
            }
        }
    }

    /// How long each step may take, in seconds.
    public struct Timeouts: Sendable, Equatable {
        /// For the CLI's server to start and say which version it is.
        public var start: TimeInterval
        /// To fork the session, as long as its log is, and open the fork.
        public var fork: TimeInterval
        /// For the model's answer.
        public var answer: TimeInterval
        /// To delete the fork once it's done.
        public var cleanUp: TimeInterval

        public init(start: TimeInterval = 30, fork: TimeInterval = 60, answer: TimeInterval = 180, cleanUp: TimeInterval = 30) {
            self.start = start
            self.fork = fork
            self.answer = answer
            self.cleanUp = cleanUp
        }
    }

    /// What the fork it asks is called, for as long as it's there.
    public static let forkName = "BriefBar question"

    private let loadEnvironment: @Sendable () async -> [String: String]
    private let locate: @Sendable ([String: String]) -> URL?
    private let timeouts: Timeouts
    private var environment: [String: String]?
    /// Forks that neither the server that made them nor another could delete: each is deleted before the next question.
    private(set) var undeleted: Set<String> = []

    /// - Parameters:
    ///   - loadEnvironment: your login shell's environment, asked for once (`LoginEnvironment.load`).
    ///   - locate: finds `copilot` (`CopilotCLI.locate`).
    public init(
        loadEnvironment: @escaping @Sendable () async -> [String: String] = { await LoginEnvironment.load() },
        locate: @escaping @Sendable ([String: String]) -> URL? = { CopilotCLI.locate(environment: $0) },
        timeouts: Timeouts = Timeouts()
    ) {
        self.loadEnvironment = loadEnvironment
        self.locate = locate
        self.timeouts = timeouts
    }

    /// What Copilot answers a question about a session: one of BriefBar's tasks', or one of the Copilot app's, in the Copilot
    /// CLI's folder (`CopilotCLI.home`). Or why there's no answer.
    /// - Parameter options: the model to answer with; nil for the session's own.
    public func ask(_ question: String, session id: String, options: CopilotRunOptions? = nil) async -> Result<String, Failure> {
        // Its ID names its log, and the fork's.
        guard AppSessions.isSessionID(id) else { return .failure(.noSession) }
        guard let environment = await loadedEnvironment() else { return .failure(.cancelled) }
        guard let copilot = locate(environment) else { return .failure(.noCLI) }
        let log = CopilotPaths(root: CopilotCLI.home(environment: environment)).sessionDirectory(id).appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: log.path) else { return .failure(.noSession) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let server: CopilotServer
        do {
            server = try CopilotServer.start(copilot, environment: environment)
        } catch {
            return .failure(Self.failure(error))
        }
        let forker = SessionForker(copilot: copilot, environment: environment, timeout: timeouts.cleanUp)
        var fork: String?
        let result: Result<String, Failure>
        do {
            try await server.connectForForking(timeout: timeouts.start)
            for leftover in undeleted {
                _ = try? await server.delete(leftover, timeout: timeouts.cleanUp)
                if forker.isGone(leftover) { undeleted.remove(leftover) }
            }
            let made = try await server.fork(id, name: Self.forkName, timeout: timeouts.fork)
            fork = made
            // Cancelled while the fork was made, it's deleted unasked.
            if Task.isCancelled { throw CopilotServer.Failure.cancelled }
            try await server.openToAsk(made, options: options, timeout: timeouts.fork)
            let answer = try await server.askAside(question, in: made, timeout: timeouts.answer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result = answer.isEmpty ? .failure(.empty) : .success(answer)
        } catch {
            result = .failure(Self.failure(error))
        }
        // Whatever happened, even once it's cancelled, the fork goes, then the server: through another server, when this
        // one has ended, or can't; and if that can't either, before the next question.
        let made = fork, cleanUp = timeouts.cleanUp
        let gone = await Task {
            guard let made else {
                await server.close()
                return true
            }
            _ = try? await server.delete(made, timeout: cleanUp)
            await server.close()
            return forker.isGone(made) ? true : await forker.discard(made)
        }.value
        if let made, !gone { undeleted.insert(made) }
        return result
    }

    /// Your login shell's environment, asked for once; nil when the question was cancelled meanwhile, and then it's asked
    /// again next time, since the shell may have been stopped before it said it all.
    private func loadedEnvironment() async -> [String: String]? {
        if let environment { return environment }
        let loaded = await loadEnvironment()
        guard !Task.isCancelled else { return nil }
        environment = loaded
        return loaded
    }

    /// What went wrong, as a `Failure`: what the CLI said about its sign-in, the model or your premium requests, as for a
    /// summary (`CopilotSummarizer.Failure.failure(said:reason:)`).
    static func failure(_ error: any Error) -> Failure {
        switch error as? CopilotServer.Failure {
        case .couldntStart(let why)?: return .failed("The Copilot CLI couldn't start: \(why)")
        case .tooOld(let version)?: return .unsupported(version: version)
        case .unsupported?: return .unsupported(version: nil)
        case .failed(let said)?:
            switch CopilotSummarizer.Failure.failure(said: said, reason: StoryText.line(said, limit: 300)) {
            case .notSignedIn(let reason): return .notSignedIn(reason)
            case .modelUnavailable(let reason): return .modelUnavailable(reason)
            case .outOfRequests(let reason): return .outOfRequests(reason)
            case .failed(let reason): return .failed(reason)
            case .noCLI, .empty, .timedOut, .cancelled: return .failed(StoryText.line(said, limit: 300))
            }
        case .exited(let status)?: return .failed("The Copilot CLI ended, with status \(status), before it answered.")
        case .unreadable?: return .failed("The Copilot CLI answered in a way BriefBar can't read.")
        case .timedOut?: return .timedOut
        case .cancelled?: return .cancelled
        case nil: return .failed(String(describing: error))
        }
    }
}
