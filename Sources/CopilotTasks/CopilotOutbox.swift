import BriefBarCore
import CopilotCore
import Darwin
import Foundation

/// What BriefBar asks its extension in one of the Copilot app's sessions to do (`CopilotOutbox`): send that session a
/// prompt, fork it, stop its turn, or start a new session of the app's with a prompt.
public struct OutboxRequest: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Send the session the prompt, as your own message.
        case send
        /// Fork the session with the app's own fork, and say the fork's ID. It sends nothing.
        case fork
        /// Stop the turn that runs in the session, as the app's own Stop does. It sends nothing.
        case stop
        /// Start a new session of the app's with its own `create_session`, the prompt as its first message, and say the new
        /// session's ID. The session whose extension takes it gets nothing, and the new one is no child of it.
        case create
    }

    /// A lowercase UUID, which names its result.
    public let requestId: String
    /// The session whose extension takes it: a lowercase UUID.
    public let sessionId: String
    public let kind: Kind
    /// For a send, and a create's first message; nil for a fork or a stop.
    public let prompt: String?
    /// For a send: its extension reports how the message's turn goes (`CopilotOutbox.report(of:sentTo:)`), when it can.
    public let report: Bool
    /// For a create: the session it starts.
    public let newSession: NewSession?
    public let createdAt: Date
    /// After this, no extension takes it.
    public let expiresAt: Date

    /// The longest a request waits for an extension to take it: the contract allows no longer.
    public static let lifetime: TimeInterval = 120
    /// The largest request an extension takes.
    public static let largestFile = 256 << 10

    /// Asks the session's extension to send it a prompt, and, with `report`, to report how its turn goes.
    public static func send(_ prompt: String, to sessionId: String, report: Bool = false, now: Date = Date()) -> OutboxRequest {
        OutboxRequest(sessionId: sessionId, kind: .send, prompt: prompt, report: report, now: now)
    }

    /// Asks the session's extension to fork it.
    public static func fork(_ sessionId: String, now: Date = Date()) -> OutboxRequest {
        OutboxRequest(sessionId: sessionId, kind: .fork, prompt: nil, now: now)
    }

    /// Asks the session's extension to stop the turn that runs in it.
    public static func stop(_ sessionId: String, now: Date = Date()) -> OutboxRequest {
        OutboxRequest(sessionId: sessionId, kind: .stop, prompt: nil, now: now)
    }

    /// Asks the extension in `host`, one of the app's sessions, to start a new session of the app's with the prompt as its
    /// first message.
    public static func create(_ prompt: String, _ session: NewSession, from host: String, now: Date = Date()) -> OutboxRequest {
        OutboxRequest(sessionId: host, kind: .create, prompt: prompt, newSession: session, now: now)
    }

    init(
        sessionId: String, kind: Kind, prompt: String?, report: Bool = false, newSession: NewSession? = nil, now: Date,
        requestId: String = UUID().uuidString.lowercased()
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.kind = kind
        self.prompt = prompt
        self.report = report
        self.newSession = newSession
        // In whole seconds, so that the times it's written with are exactly its lifetime apart.
        createdAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        expiresAt = createdAt.addingTimeInterval(Self.lifetime)
    }

    /// `<sessionId>.<requestId>.json`, in `requests`.
    public var fileName: String { "\(sessionId).\(requestId).json" }

    /// It as the contract has it, version 1: only for a session's ID, with a prompt for a send or a create and none for a
    /// fork or a stop, asking for a report only for a send, and starting a session, a valid one, only for a create.
    func encoded() throws -> Data {
        let hasPrompt = kind == .send || kind == .create
        guard AppSessions.isSessionID(sessionId), AppSessions.isSessionID(requestId),
              hasPrompt == (prompt != nil), prompt?.isEmpty != true, !report || kind == .send,
              (kind == .create) == (newSession != nil), newSession?.isValid != false,
              expiresAt > createdAt, expiresAt.timeIntervalSince(createdAt) <= Self.lifetime
        else { throw OutboxError.invalidRequest }
        var fields: [String: Any] = [
            "version": CopilotOutbox.version, "requestId": requestId, "sessionId": sessionId, "kind": kind.rawValue,
            "createdAt": CopilotOutbox.timestamp(createdAt), "expiresAt": CopilotOutbox.timestamp(expiresAt),
        ]
        if let prompt { fields["prompt"] = prompt }
        if report { fields["report"] = true }
        if let newSession {
            fields["projectId"] = newSession.projectId
            fields["name"] = newSession.name
            fields["mode"] = newSession.mode.rawValue
            if let model = newSession.model { fields["model"] = model }
            if let effort = newSession.effort { fields["effort"] = effort }
        }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
}

/// A new session of the Copilot app's that a create starts (`OutboxRequest.create`): in a worktree of one of the app's
/// projects, named as the app's sidebar shows it, in a mode, with a model and a reasoning effort, or the app's own.
public struct NewSession: Sendable, Equatable {
    /// How it starts, as the app's own modes are named.
    public enum Mode: String, Sendable, Equatable {
        case interactive
        case plan
        /// It works on its own until it calls the task done, as a task BriefBar runs with the Copilot CLI does.
        case autopilot
    }

    /// The app's project it works in, by its ID: a lowercase UUID.
    public var projectId: String
    /// One line, at most `longestName` characters as the app counts them.
    public var name: String
    public var mode: Mode
    /// Such as `claude-opus-5.5`; nil for the app's own.
    public var model: String?
    /// Such as `max`; nil for the model's own.
    public var effort: String?

    /// The longest name the app's `create_session` takes, in UTF-16 code units, as JavaScript counts a string.
    public static let longestName = 40

    public init(projectId: String, name: String, mode: Mode, model: String? = nil, effort: String? = nil) {
        self.projectId = projectId
        self.name = name
        self.mode = mode
        self.model = model
        self.effort = effort
    }

    /// A name for it, from a longer one: on one line, without control characters or what could be taken for a session's
    /// link or ID in what the app answers, such as parentheses, and cut short to what the app takes. "Untitled" for none.
    public static func name(_ text: String) -> String {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.map { isHidden($0) ? " " : $0 }))
        let plain = PlainText.singleLine(visible.replacingOccurrences(of: "[()]", with: "", options: .regularExpression))
        guard !plain.isEmpty else { return "Untitled" }
        guard plain.utf16.count > longestName else { return plain }
        var short = ""
        for character in plain {
            guard (short + String(character) + "…").utf16.count <= longestName else { break }
            short.append(character)
        }
        return short.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A control or format character, which the app's sidebar wouldn't show, and the extension turns down in a name.
    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
    }

    /// As the contract has it: a project's ID, a name the app takes, and a model and an effort that are their IDs.
    var isValid: Bool {
        AppSessions.isSessionID(projectId) && !name.trimmingCharacters(in: .whitespaces).isEmpty && name.utf16.count <= Self.longestName
            && !name.unicodeScalars.contains(where: Self.isHidden)
            && model.map { $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$"#, options: .regularExpression) != nil } != false
            && effort.map { $0.range(of: #"^[a-z]{1,20}$"#, options: .regularExpression) != nil } != false
    }
}

/// What an extension says became of a request.
public struct OutboxResult: Sendable, Equatable {
    /// Why it didn't do it.
    public enum Failure: String, Sendable, Equatable {
        /// The request's file, its JSON or a field was bad.
        case invalid
        /// The request expired before the extension took it.
        case expired
        /// The session didn't take the message.
        case sendFailed = "send_failed"
        /// The session doesn't offer the app's fork, as chats and remote sessions may not.
        case forkUnavailable = "fork_unavailable"
        /// The fork failed, or gave no session ID.
        case forkFailed = "fork_failed"
        /// The session didn't stop its turn.
        case stopFailed = "stop_failed"
        /// The session doesn't offer the app's `create_session`, as one the Copilot CLI has open doesn't, or Copilot refused
        /// it: no session was started.
        case createUnavailable = "create_unavailable"
        /// Starting the session failed, or gave no session ID: it may have been started.
        case createFailed = "create_failed"
        /// A code this version of BriefBar doesn't know.
        case unknown
        /// BriefBar couldn't read what the extension said: not as the contract has it.
        case unreadable
    }

    public var requestId: String
    /// The session that took it.
    public var sessionId: String
    public var kind: OutboxRequest.Kind
    /// Nil once it's done.
    public var failure: Failure?
    /// What went wrong, in the extension's words, on one line: never the prompt.
    public var message: String?
    /// The message the session got, for a send.
    public var messageId: String?
    /// For a send BriefBar asked to report: its extension reports how the message's turn goes, in a report named for the
    /// request (`CopilotOutbox.report(of:sentTo:)`). False from one that doesn't, as an extension from before reports did.
    public var reports: Bool
    /// The new session, for a fork: a lowercase UUID, the app's ID for it.
    public var forkSessionId: String?
    /// The new session, for a create: a lowercase UUID, the app's ID for it.
    public var createdSessionId: String?
    public var finishedAt: Date?

    public init(
        requestId: String, sessionId: String, kind: OutboxRequest.Kind, failure: Failure? = nil, message: String? = nil,
        messageId: String? = nil, reports: Bool = false, forkSessionId: String? = nil, createdSessionId: String? = nil,
        finishedAt: Date? = nil
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.kind = kind
        self.failure = failure
        self.message = message
        self.messageId = messageId
        self.reports = reports
        self.forkSessionId = forkSessionId
        self.createdSessionId = createdSessionId
        self.finishedAt = finishedAt
    }

    public var isDone: Bool { failure == nil }

    /// The most an extension's message says.
    static let longestMessage = 300

    /// A result the extension wrote for `request`, as version 1 of the contract has it; or one that says BriefBar couldn't
    /// read it (`unreadable`), when it's for another request, or a fork's or a create's says no session that BriefBar can
    /// send to or show.
    init(_ data: Data, for request: OutboxRequest) {
        self.init(requestId: request.requestId, sessionId: request.sessionId, kind: request.kind, failure: .unreadable)
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              CopilotOutbox.number(fields["version"]) == Double(CopilotOutbox.version),
              fields["requestId"] as? String == request.requestId, fields["sessionId"] as? String == request.sessionId,
              fields["kind"] as? String == request.kind.rawValue,
              let ok = fields["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID()
        else { return }
        finishedAt = (fields["finishedAt"] as? String).flatMap(CopilotOutbox.date)
        guard ok.boolValue else {
            let error = fields["error"] as? [String: Any]
            failure = (error?["code"] as? String).map { Failure(rawValue: $0) ?? .unknown } ?? .unknown
            if failure == .unreadable { failure = .unknown }
            message = (error?["message"] as? String).map(Self.oneLine).flatMap { $0.isEmpty ? nil : $0 }
            return
        }
        switch request.kind {
        case .send:
            messageId = fields["messageId"] as? String
            // Only for a report BriefBar asked for: one it didn't, it wouldn't read.
            if request.report, let reports = fields["reports"] as? NSNumber, CFGetTypeID(reports) == CFBooleanGetTypeID() {
                self.reports = reports.boolValue
            }
        case .fork:
            guard let fork = fields["forkSessionId"] as? String, AppSessions.isSessionID(fork), fork != request.sessionId else { return }
            forkSessionId = fork
        case .create:
            guard let made = fields["createdSessionId"] as? String, AppSessions.isSessionID(made), made != request.sessionId else { return }
            createdSessionId = made
        case .stop:
            break
        }
        failure = nil
    }

    static func oneLine(_ text: String) -> String {
        let line = PlainText.singleLine(text)
        return line.count > longestMessage ? String(line.prefix(longestMessage - 1)) + "…" : line
    }
}

/// BriefBar's extension, running in one of the Copilot app's sessions, as it says while it runs.
public struct OutboxListener: Sendable, Equatable {
    public var sessionId: String
    /// The extension's process.
    public var pid: Int32
    /// When the extension started, as it says: its process started no later.
    public var startedAt: Date
    /// What it does, of what this version of BriefBar knows.
    public var kinds: Set<OutboxRequest.Kind>

    public init(sessionId: String, pid: Int32, startedAt: Date, kinds: Set<OutboxRequest.Kind>) {
        self.sessionId = sessionId
        self.pid = pid
        self.startedAt = startedAt
        self.kinds = kinds
    }

    /// One as version 1 of the contract has it, for the session its file is named for.
    init?(_ data: Data, sessionId: String) {
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              CopilotOutbox.number(fields["version"]) == Double(CopilotOutbox.version),
              fields["sessionId"] as? String == sessionId,
              let pid = CopilotOutbox.number(fields["pid"]).flatMap({ Int32(exactly: $0) }), pid > 0,
              let startedAt = (fields["startedAt"] as? String).flatMap(CopilotOutbox.date),
              let kinds = fields["kinds"] as? [String]
        else { return nil }
        self.init(sessionId: sessionId, pid: pid, startedAt: startedAt, kinds: Set(kinds.compactMap(OutboxRequest.Kind.init(rawValue:))))
    }
}

/// How the turn of a prompt goes that BriefBar asked its extension to report (`OutboxRequest.report`), as the extension
/// says in `reports/<requestId>.json`, which it rewrites whole as the turn changes, until it's over: what the session's
/// documented events say of the message it sent, never the prompt.
public struct OutboxReport: Sendable, Equatable {
    public enum State: String, Sendable, Equatable, CaseIterable {
        /// Sent, and waiting in the session's queue for the turn before it to end.
        case waiting
        /// The session works on it.
        case working
        /// Copilot asks you something, shows you a plan, or waits for your permission, in the app.
        case needsYou
        case finished
        case failed
        case stopped

        /// Over: finished, failed or stopped. Nothing changes a report after.
        public var isOver: Bool {
            switch self {
            case .finished, .failed, .stopped: true
            case .waiting, .working, .needsYou: false
            }
        }
    }

    /// What waits on you.
    public enum Asks: String, Sendable, Equatable {
        case question
        case plan
        /// Something else Copilot asks for, such as signing in to a server, or switching to another model.
        case input
        case permission
    }

    /// Why a turn stopped, when it wasn't a Stop of yours.
    public enum Cause: String, Sendable, Equatable {
        /// The session closed, or its runtime stopped: a session that opens again doesn't go on with it.
        case closed
        /// Autopilot reached the most it may spend.
        case creditLimit
    }

    public var requestId: String
    /// The session it went to.
    public var sessionId: String
    /// The message the session got.
    public var messageId: String?
    /// The extension's process, which follows the turn, and when it started, as its `listening` file says them: while it
    /// runs, the report may still change (`CopilotOutbox.isLive(_:)`).
    public var pid: Int32
    public var startedAt: Date
    /// The session's name, as the app shows it, when the extension could tell.
    public var name: String?
    public var state: State
    /// Since when it stands so: for a turn that's over, when it ended.
    public var since: Date
    /// While it works, the step it's at.
    public var step: String?
    /// While it waits on you, what for.
    public var asks: Asks?
    /// What Copilot said as it ended, or the error it failed with; while it waits on you, its question, or its plan's
    /// summary: its lines kept, at most `longestSaid` characters.
    public var said: String?
    /// For one that stopped, why, when it wasn't a Stop of yours.
    public var cause: Cause?

    public init(
        requestId: String, sessionId: String, messageId: String? = nil, pid: Int32, startedAt: Date, name: String? = nil,
        state: State, since: Date, step: String? = nil, asks: Asks? = nil, said: String? = nil, cause: Cause? = nil
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.messageId = messageId
        self.pid = pid
        self.startedAt = startedAt
        self.name = name
        self.state = state
        self.since = since
        self.step = step
        self.asks = asks
        self.said = said
        self.cause = cause
    }

    /// The most of what Copilot said that BriefBar takes from a report, as its extension sends at most.
    public static let longestSaid = 4_000

    /// Its turn is over: finished, failed or stopped.
    public var isOver: Bool { state.isOver }

    /// One as version 1 of the contract has it, of the request it's named for, sent to that session; nil for anything
    /// else. What it says is checked as BriefBar shows it: one line for a name or a step, and only what goes with its state.
    init?(_ data: Data, requestId: String, sessionId: String) {
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              CopilotOutbox.number(fields["version"]) == Double(CopilotOutbox.version),
              fields["requestId"] as? String == requestId, fields["sessionId"] as? String == sessionId,
              let pid = CopilotOutbox.number(fields["pid"]).flatMap({ Int32(exactly: $0) }), pid > 0,
              let startedAt = (fields["startedAt"] as? String).flatMap(CopilotOutbox.date),
              let state = (fields["state"] as? String).flatMap(State.init(rawValue:)),
              let since = (fields["since"] as? String).flatMap(CopilotOutbox.date)
        else { return nil }
        let line = { (key: String) in (fields[key] as? String).map(OutboxResult.oneLine).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(
            requestId: requestId, sessionId: sessionId, messageId: (fields["messageId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            pid: pid, startedAt: startedAt, name: line("name"), state: state, since: since,
            step: state == .working ? line("step") : nil,
            asks: state == .needsYou ? (fields["asks"] as? String).flatMap(Asks.init(rawValue:)) : nil,
            said: state == .needsYou || state.isOver ? (fields["said"] as? String).flatMap(Self.words) : nil,
            cause: state == .stopped ? (fields["cause"] as? String).flatMap(Cause.init(rawValue:)) : nil
        )
    }

    /// What Copilot wrote, its lines kept, without other control characters or space around it, and no more than
    /// `longestSaid` characters: nil for nothing.
    static func words(_ text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let kept = String(String.UnicodeScalarView(normalized.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else { return nil }
        return kept.count > longestSaid ? String(kept.prefix(longestSaid - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" : kept
    }
}

public enum OutboxError: Error, Sendable, Equatable, CustomStringConvertible {
    /// One of the outbox's folders isn't a real one that only you can open, or couldn't be made: its name.
    case unsafeFolder(String)
    /// A request whose fields the contract doesn't allow.
    case invalidRequest
    /// A request too large for an extension to take.
    case tooLarge
    /// Writing it failed, with this error.
    case couldntWrite(Int32)

    public var description: String {
        switch self {
        case .unsafeFolder(let name):
            return "BriefBar's folder for the Copilot app's sessions (\(name)) isn't a folder only you can open, so BriefBar won't use it."
        case .invalidRequest: return "BriefBar can't send that to a session."
        case .tooLarge: return "The prompt is too long to send to a session."
        case .couldntWrite(let code): return "BriefBar couldn't write to its folder for the Copilot app's sessions: \(String(cString: strerror(code)))."
        }
    }
}

/// The folder BriefBar shares with its extension in the Copilot app's sessions, which the opt-in `briefbar-sessions` plugin
/// installs (version 1 of the contract, in docs/how-it-works.md): local files only. BriefBar writes requests to
/// `requests`, where an extension claims its own session's by renaming it, then writes a result to `results`; while it
/// runs, an extension says so in `listening`; and for a send BriefBar asked it to report, it says how the message's turn
/// goes in `reports`, which BriefBar reads, and removes once the turn is over.
///
/// Each of its folders is a real one, yours, that only you can open (0700), and each file a regular one, yours, that only
/// you can read (0600), written whole to a name starting with `.`, then renamed into place: what isn't so is never read,
/// and a folder that isn't so is never used. Nothing below `root` is followed through a symbolic link, so nothing BriefBar
/// writes or reads here can lead elsewhere, whatever BriefBar may have access to. Reading makes nothing; a request makes
/// the folders it needs.
public struct CopilotOutbox: Sendable {
    public enum Folder: String, Sendable, CaseIterable {
        /// BriefBar's requests, which extensions claim.
        case requests
        /// Extensions' results, which BriefBar reads and removes.
        case results
        /// The extensions that run, each in its own session.
        case listening
        /// How the turns go of the sends BriefBar asked extensions to report, which BriefBar reads, and removes once over.
        case reports
    }

    /// The contract's version.
    public static let version = 1
    /// The largest result, listening file or report BriefBar reads.
    static let largestAnswer = 64 << 10
    /// How old BriefBar's requests and their results get before BriefBar removes them, as it starts another.
    public static let oldAge: TimeInterval = 3_600

    /// A folder that's trusted as it is: your home folder, or a test's temporary folder.
    public let root: URL
    /// The folders below it, down to the outbox's own, each a single name.
    public let path: [String]

    public init(root: URL, path: [String] = ["Outbox"]) {
        precondition(!path.isEmpty && path.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") })
        self.root = root
        self.path = path
    }

    /// `~/Library/Application Support/BriefBar/Copilot/Outbox`.
    public static let standard = CopilotOutbox(
        root: UserHome.url, path: ["Library", "Application Support", "BriefBar", "Copilot", "Outbox"]
    )

    public var url: URL {
        path.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    // MARK: Requests

    /// Writes a request, for its session's extension to claim.
    public func write(_ request: OutboxRequest) throws {
        let data = try request.encoded()
        guard data.count <= OutboxRequest.largestFile else { throw OutboxError.tooLarge }
        let folder = try openFolder(.requests, create: true)
        defer { close(folder) }
        try Self.writeFile(data, named: request.fileName, in: folder)
    }

    /// Whether the request still waits for its extension: false once one claimed it, or it was withdrawn.
    public func isWaiting(_ request: OutboxRequest) -> Bool {
        guard let folder = try? openFolder(.requests, create: false) else { return false }
        defer { close(folder) }
        var info = stat()
        return fstatat(folder, request.fileName, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    /// Takes a request back before an extension claims it: true once it's withdrawn; false when it's gone already, claimed,
    /// so that its result is still to come.
    @discardableResult
    public func withdraw(_ request: OutboxRequest) -> Bool {
        guard let folder = try? openFolder(.requests, create: false) else { return false }
        defer { close(folder) }
        return unlinkat(folder, request.fileName, 0) == 0
    }

    /// The request's result, once its extension wrote it, which BriefBar then removes: nil until then. One that isn't as
    /// the contract has it says so (`OutboxResult.Failure.unreadable`).
    public func takeResult(of request: OutboxRequest) -> OutboxResult? {
        guard let folder = try? openFolder(.results, create: false) else { return nil }
        defer { close(folder) }
        let name = "\(request.requestId).json"
        let found = Self.read(name, in: folder, limit: Self.largestAnswer)
        if case .missing = found { return nil }
        unlinkat(folder, name, 0)
        guard case .data(let data) = found else {
            return OutboxResult(requestId: request.requestId, sessionId: request.sessionId, kind: request.kind, failure: .unreadable)
        }
        return OutboxResult(data, for: request)
    }

    // MARK: Listeners

    /// The extension that says it listens in the session, whether or not it still runs (`isLive`).
    public func listener(of sessionId: String) -> OutboxListener? {
        guard AppSessions.isSessionID(sessionId), let folder = try? openFolder(.listening, create: false) else { return nil }
        defer { close(folder) }
        return Self.listener(named: "\(sessionId).json", in: folder)
    }

    /// Every extension that says it listens, in a session of its own, whether or not it still runs (`isLive`): none when
    /// the outbox can't be read.
    public func listeners() -> [OutboxListener] {
        guard let folder = try? openFolder(.listening, create: false) else { return [] }
        defer { close(folder) }
        return Self.names(in: folder).compactMap { name in
            guard name.hasSuffix(".json"), AppSessions.isSessionID(String(name.dropLast(".json".count))) else { return nil }
            return Self.listener(named: name, in: folder)
        }
    }

    /// Whether the extension still runs: its process does, and started no later than the extension says it did, give or
    /// take two seconds, as `DetachedProgram.isRunning` checks a handle. Otherwise, a process that got its ID later has it.
    public static func isLive(
        _ listener: OutboxListener, isRunning: (pid_t) -> Bool = SessionLock.isRunning,
        startTime: (pid_t) -> Date? = DetachedProgram.startTime(of:)
    ) -> Bool {
        isLive(pid: listener.pid, startedAt: listener.startedAt, isRunning: isRunning, startTime: startTime)
    }

    /// Whether the extension that follows a turn still runs, as `isLive` checks one that listens: until it's over, its report
    /// may still change.
    public static func isLive(
        _ report: OutboxReport, isRunning: (pid_t) -> Bool = SessionLock.isRunning,
        startTime: (pid_t) -> Date? = DetachedProgram.startTime(of:)
    ) -> Bool {
        isLive(pid: report.pid, startedAt: report.startedAt, isRunning: isRunning, startTime: startTime)
    }

    private static func isLive(pid: Int32, startedAt: Date, isRunning: (pid_t) -> Bool, startTime: (pid_t) -> Date?) -> Bool {
        guard isRunning(pid), let started = startTime(pid) else { return false }
        return started <= startedAt.addingTimeInterval(2)
    }

    // MARK: Reports

    /// What the extension that sent a prompt says of its turn, in the report named for its request, sent to `sessionId`:
    /// nil when there's none, or none as the contract has it, in a file BriefBar reads as it reads results.
    public func report(of requestId: String, sentTo sessionId: String) -> OutboxReport? {
        guard AppSessions.isSessionID(requestId), AppSessions.isSessionID(sessionId),
              let folder = try? openFolder(.reports, create: false)
        else { return nil }
        defer { close(folder) }
        guard case .data(let data) = Self.read("\(requestId).json", in: folder, limit: Self.largestAnswer) else { return nil }
        return OutboxReport(data, requestId: requestId, sessionId: sessionId)
    }

    /// Removes a turn's report, once BriefBar has taken how it ended: it holds what Copilot said.
    public func removeReport(of requestId: String) {
        guard AppSessions.isSessionID(requestId), let folder = try? openFolder(.reports, create: false) else { return }
        defer { close(folder) }
        unlinkat(folder, "\(requestId).json", 0)
    }

    /// Removes the reports that are more than `age` old but those of the requests BriefBar still follows a turn by: one
    /// whose prompt BriefBar no longer keeps, as when it cleared it, or Azure DevOps was off, nothing reads.
    public func removeOldReports(keeping kept: Set<String>, now: Date = Date(), age: TimeInterval = CopilotOutbox.oldAge) {
        guard let folder = try? openFolder(.reports, create: false) else { return }
        defer { close(folder) }
        Self.removeOld(in: folder, now: now, age: age) { name in
            !(name.hasSuffix(".json") && kept.contains(String(name.dropLast(".json".count))))
        }
    }

    // MARK: Cleaning up

    /// Removes BriefBar's requests, claimed or not, and their results, that are more than `age` old, as it starts a
    /// request: an extension that ended as it handled one leaves it.
    public func removeOld(now: Date = Date(), age: TimeInterval = CopilotOutbox.oldAge) {
        for kind in [Folder.requests, .results] {
            guard let folder = try? openFolder(kind, create: false) else { continue }
            defer { close(folder) }
            Self.removeOld(in: folder, now: now, age: age) { _ in true }
        }
    }

    /// Removes the files, or links, in a folder that are more than `age` old, of those whose names `goes` takes.
    private static func removeOld(in folder: Int32, now: Date, age: TimeInterval, where goes: (String) -> Bool) {
        for name in Self.names(in: folder) where goes(name) {
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFLNK
            else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) >= age { unlinkat(folder, name, 0) }
        }
    }

    /// Removes every request and result, whatever its age, as when Azure DevOps is turned off: they hold its prompts; and
    /// every report, which holds what Copilot said. A folder of them that isn't only yours anymore, such as one that others
    /// can open now, is emptied all the same, and goes too, for the next request to make it anew; a link or a file in its
    /// place is unlinked, never followed. What extensions say in `listening` stays, theirs while they run.
    /// - Returns: false when some of them may stay: what couldn't be removed, or what couldn't be opened to look.
    @discardableResult
    public func forget() -> Bool {
        // The outbox, without following a link below `root`, as `openFolder` opens it, but whatever its mode: what's in it
        // was written while it was only yours.
        var outbox = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard outbox >= 0 else { return errno == ENOENT }
        for name in path {
            let next = openat(outbox, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            close(outbox)
            // Not there, or no real folder, such as a link: BriefBar wrote nothing there.
            guard next >= 0 else { return failure == ENOENT || failure == ENOTDIR || failure == ELOOP }
            outbox = next
        }
        defer { close(outbox) }
        guard Self.isOwnFolder(outbox) else { return false }
        var forgotten = true
        for kind in [Folder.requests, .results, .reports] where !Self.empty(kind, in: outbox) { forgotten = false }
        return forgotten
    }

    /// Removes BriefBar's requests, their results, or reports, from the outbox: what's in their folder, without following a
    /// link, and the folder too unless it's only yours, as BriefBar makes it; or a link or a file in its place. False when
    /// something stays, such as a folder of someone else's.
    static func empty(_ kind: Folder, in outbox: Int32) -> Bool {
        let name = kind.rawValue
        var info = stat()
        guard fstatat(outbox, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        guard info.st_mode & S_IFMT == S_IFDIR else { return unlinkat(outbox, name, 0) == 0 }
        guard info.st_uid == getuid() else { return false }
        let folder = openat(outbox, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return false }
        // What can't be listed may hold prompts still.
        guard let entries = listing(folder) else {
            close(folder)
            return false
        }
        var emptied = true
        // Requests, claimed or not, results, and what was being written: files, or links, never followed.
        for entry in entries where unlinkat(folder, entry, 0) != 0 { emptied = false }
        let isOnlyYours = isPrivateFolder(folder)
        close(folder)
        if emptied, !isOnlyYours { emptied = unlinkat(outbox, name, AT_REMOVEDIR) == 0 }
        return emptied
    }

    // MARK: Files

    /// Opens one of the outbox's folders, or the outbox itself, without following a symbolic link below `root`: the outbox
    /// and its folders must be real ones, yours, that only you can open. With `create`, makes what's missing, only yours.
    func openFolder(_ folder: Folder?, create: Bool) throws -> Int32 {
        let names = path + (folder.map { [$0.rawValue] } ?? [])
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw OutboxError.unsafeFolder(root.lastPathComponent) }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        for (index, name) in names.enumerated() {
            var next = openat(descriptor, name, flags)
            if next < 0, errno == ENOENT, create {
                if mkdirat(descriptor, name, 0o700) == 0 {
                    next = openat(descriptor, name, flags)
                    // Only yours, whatever the umask.
                    if next >= 0, Self.isOwnFolder(next) { fchmod(next, 0o700) }
                } else if errno == EEXIST {
                    // An extension made it meanwhile: as it made it.
                    next = openat(descriptor, name, flags)
                }
            }
            close(descriptor)
            guard next >= 0 else { throw OutboxError.unsafeFolder(name) }
            // The outbox and its folders; not those it's in, such as Library.
            if index >= path.count - 1, !Self.isPrivateFolder(next) {
                close(next)
                throw OutboxError.unsafeFolder(name)
            }
            descriptor = next
        }
        return descriptor
    }

    static func isOwnFolder(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    /// A folder of yours that only you can open: mode 0700, nothing more.
    static func isPrivateFolder(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o7777 == 0o700
    }

    /// Writes a file whole, only yours to read (0600), to a name starting with `.`, then renames it into place, never over
    /// another file.
    static func writeFile(_ data: Data, named name: String, in folder: Int32) throws {
        let temporary = ".\(name).\(UUID().uuidString.lowercased())"
        let descriptor = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw OutboxError.couldntWrite(errno) }
        var failure: Int32 = fchmod(descriptor, 0o600) == 0 ? 0 : errno
        if failure == 0 {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        failure = errno
                        return
                    }
                    offset += written
                }
            }
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        if failure == 0, renameatx_np(folder, temporary, folder, name, UInt32(RENAME_EXCL)) != 0 { failure = errno }
        guard failure == 0 else {
            unlinkat(folder, temporary, 0)
            throw OutboxError.couldntWrite(failure)
        }
    }

    enum Read: Equatable {
        case missing
        /// It's there, but isn't a regular file of yours that only you can read, of at most the size allowed.
        case unsafe
        case data(Data)
    }

    /// A file in a folder, opened without following a symbolic link.
    static func read(_ name: String, in folder: Int32, limit: Int) -> Read {
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .unsafe }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600, info.st_size <= limit
        else { return .unsafe }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        while data.count <= limit {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.count <= limit ? .data(data) : .unsafe
    }

    static func listener(named name: String, in folder: Int32) -> OutboxListener? {
        guard case .data(let data) = read(name, in: folder, limit: largestAnswer) else { return nil }
        return OutboxListener(data, sessionId: String(name.dropLast(".json".count)))
    }

    /// The names in a folder, but `.` and `..`: none when they can't be read.
    static func names(in folder: Int32) -> [String] {
        listing(folder) ?? []
    }

    /// The names in a folder, but `.` and `..`: nil when they can't all be read.
    static func listing(_ folder: Int32) -> [String]? {
        let copy = dup(folder)
        guard copy >= 0 else { return nil }
        guard let directory = fdopendir(copy) else {
            close(copy)
            return nil
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        while true {
            errno = 0
            // The end, or, when it says why, a failure.
            guard let entry = readdir(directory) else { return errno == 0 ? names : nil }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    // MARK: Times

    /// A JSON number, but not `true` or `false`, which Foundation reads as numbers too.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// ISO 8601, in UTC, to the second.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    /// An ISO 8601 time, with or without fractions of a second, as JavaScript's `toISOString()` writes one.
    static func date(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
