import BriefBarCore
import CopilotCore
import Darwin
import Foundation
import Synchronization
@testable import CopilotTasks

/// BriefBar's extension in one of the Copilot app's sessions, as the contract has it, written apart from BriefBar's side:
/// it says it listens, claims its own session's requests by renaming them, acts only on those that pass the contract's
/// checks, and says how each went, removing what it claimed.
final class FakeExtension: Sendable {
    /// How often it looks for requests, and BriefBar's side of these tests at the outbox (`Timing.patient`), as do these
    /// tests' own waits. Each look reads the outbox's folders, in many tests at once: looking every 25 ms rather than every 5,
    /// these tests use about a quarter less CPU, and take about as long.
    static let lookEvery: Duration = .milliseconds(25)

    /// How it answers a request it claimed.
    enum Answer: Sendable {
        /// It's done: a send's message ID, a fork's session, or a create's new session.
        case done(fork: String? = nil, created: String? = nil)
        /// It isn't: the contract's code, and a message.
        case failed(String, String)
        /// After a while.
        indirect case after(Duration, Answer)
        /// Once the test says so, looking every `lookEvery`: as when it stops BriefBar, or turns it off, before BriefBar
        /// hears how it went, however slow the tests' threads are.
        indirect case once(@Sendable () -> Bool, Answer)
        /// Never: as if it ended as it handled it.
        case never
    }

    struct Received: Sendable, Equatable {
        /// The session a create starts, as its request has it.
        struct Started: Sendable, Equatable {
            var projectId: String
            var name: String
            var mode: String
            var model: String?
            var effort: String?
        }

        var kind: String
        var prompt: String?
        /// A send asked it to report how its turn goes.
        var report = false
        var started: Started?
    }

    let outbox: URL
    let sessionId: String
    /// What it acted on and refused; the looking under way, and the token of the one `start` began last, which alone
    /// claims requests, until `stop()`.
    private let state = Mutex<(received: [Received], refused: Int, task: Task<Void, Never>?, looking: UUID?)>(([], 0, nil, nil))

    init(outbox: URL, sessionId: String) {
        self.outbox = outbox
        self.sessionId = sessionId
    }

    /// The requests it acted on, in order.
    var received: [Received] { state.withLock { $0.received } }
    /// The requests for its session that it refused, as the contract has it.
    var refused: Int { state.withLock { $0.refused } }

    /// Says it listens, as an extension does once it has joined its session.
    func listen(kinds: [String] = ["send", "fork"], pid: Int32 = getpid(), startedAt: Date? = nil) throws {
        let started = startedAt ?? DetachedProgram.startTime(of: pid) ?? Date()
        let fields: [String: Any] = [
            "version": 1, "sessionId": sessionId, "pid": Int(pid), "kinds": kinds,
            "startedAt": started.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
        ]
        try Self.write(try JSONSerialization.data(withJSONObject: fields), to: folder("listening"), named: "\(sessionId).json")
    }

    func stopListening() {
        try? FileManager.default.removeItem(at: folder("listening").appendingPathComponent("\(sessionId).json"))
    }

    /// Says how the turn of a send it reports goes, as an extension does, in its report, which it writes whole: by this
    /// process, which runs, unless the fields say otherwise.
    func report(_ requestId: String, state: String, _ fields: [String: Any] = [:]) throws {
        let now = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let started = (DetachedProgram.startTime(of: getpid()) ?? Date()).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let report: [String: Any] = [
            "version": 1, "requestId": requestId, "sessionId": sessionId, "messageId": "message-1", "pid": Int(getpid()),
            "startedAt": started, "state": state, "since": now, "updatedAt": now,
        ]
        try Self.write(
            JSONSerialization.data(withJSONObject: report.merging(fields) { $1 }), to: folder("reports"), named: "\(requestId).json"
        )
    }

    /// Starts taking its session's requests, looking every `lookEvery`, until `stop()`. Started again, it answers as it's
    /// told then, and stops looking as it was told before, which would otherwise go on until the tests end. It looks, and
    /// answers, on `TestThreads`, beside the tests, as an extension in another process would: so once `stop()` or `start`
    /// returns, a look begun before may still be under way, but claims nothing.
    /// - Parameter reports: it reports the turns of the sends that ask, as an extension does since BriefBar asks; otherwise
    ///   it takes no notice, as one from before did.
    func start(reports: Bool = false, answer: @escaping @Sendable (Received) -> Answer = { _ in .done() }) {
        let looking = UUID()
        state.withLock {
            $0.task?.cancel()
            $0.looking = looking
            $0.task = Task(executorPreference: TestThreads.shared) { [self] in
                while !Task.isCancelled {
                    takeRequests(reports: reports, answer: answer, while: looking)
                    try? await Task.sleep(for: Self.lookEvery)
                }
            }
        }
    }

    func stop() {
        state.withLock {
            $0.task?.cancel()
            $0.looking = nil
        }
    }

    private func folder(_ name: String) -> URL {
        outbox.appendingPathComponent(name, isDirectory: true)
    }

    private func takeRequests(reports: Bool, answer: @escaping @Sendable (Received) -> Answer, while looking: UUID) {
        let requests = folder("requests")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? []
        for name in names where name.hasPrefix("\(sessionId).") && name.hasSuffix(".json") {
            let requestId = String(name.dropFirst(sessionId.count + 1).dropLast(5))
            let claimed = requests.appendingPathComponent(".\(sessionId).\(requestId).claimed-\(getpid())")
            // Claimed by renaming, so it's handled once; gone when BriefBar withdrew it first. Claimed under the lock `start`
            // and `stop()` take, only while this looking is still the one `start` began last: once either returns, an
            // earlier look claims nothing.
            guard state.withLock({ $0.looking == looking && rename(requests.appendingPathComponent(name).path, claimed.path) == 0 })
            else { continue }
            guard let request = Self.check(claimed, requestId: requestId, sessionId: sessionId) else {
                state.withLock { $0.refused += 1 }
                try? FileManager.default.removeItem(at: claimed)
                continue
            }
            state.withLock { $0.received.append(request) }
            let response = answer(request)
            Task(executorPreference: TestThreads.shared) { [self] in
                await respond(response, to: request, requestId: requestId, reports: reports)
                try? FileManager.default.removeItem(at: claimed)
            }
        }
    }

    private func respond(_ answer: Answer, to request: Received, requestId: String, reports: Bool) async {
        var fields: [String: Any] = [
            "version": 1, "requestId": requestId, "sessionId": sessionId, "kind": request.kind,
            "finishedAt": Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
        ]
        switch answer {
        case .never:
            return
        case .after(let delay, let then):
            try? await Task.sleep(for: delay)
            return await respond(then, to: request, requestId: requestId, reports: reports)
        case .once(let ready, let then):
            while !ready() { try? await Task.sleep(for: Self.lookEvery) }
            return await respond(then, to: request, requestId: requestId, reports: reports)
        case .done(let fork, let created):
            fields["ok"] = true
            if let fork {
                fields["forkSessionId"] = fork
            } else if let created {
                fields["createdSessionId"] = created
            } else {
                fields["messageId"] = "message-1"
            }
            // Its first report, written before the result that says it reports.
            if reports, request.report, (try? report(requestId, state: "working")) != nil { fields["reports"] = true }
        case .failed(let code, let message):
            fields["ok"] = false
            fields["error"] = ["code": code, "message": message]
        }
        try? Self.write(JSONSerialization.data(withJSONObject: fields), to: folder("results"), named: "\(requestId).json")
    }

    /// A request it may act on: a regular file that's yours, only yours to read, of 256 KiB or less, at version 1, for its
    /// own session, with a prompt only for a send or a create, a report asked for only by a send, and a session to start,
    /// in a project, with a name and a mode, only for a create, that hasn't expired and was given at most 120 seconds.
    static func check(_ file: URL, requestId: String, sessionId: String) -> Received? {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600,
              info.st_uid == getuid(), info.st_size <= 256 << 10,
              let data = FileManager.default.contents(atPath: file.path),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              fields["version"] as? Int == 1, fields["requestId"] as? String == requestId,
              fields["sessionId"] as? String == sessionId,
              let kind = fields["kind"] as? String, ["send", "fork", "create"].contains(kind),
              let created = (fields["createdAt"] as? String).flatMap({ try? Date($0, strategy: .iso8601) }),
              let expires = (fields["expiresAt"] as? String).flatMap({ try? Date($0, strategy: .iso8601) }),
              Date() < expires, expires.timeIntervalSince(created) <= 120
        else { return nil }
        let prompt = fields["prompt"] as? String
        guard (kind == "send" || kind == "create") == (prompt != nil) else { return nil }
        var report = false
        if let asked = fields["report"] {
            guard kind == "send", let flag = asked as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            report = flag.boolValue
        }
        var started: Received.Started?
        if kind == "create" {
            guard let projectId = fields["projectId"] as? String, AppSessions.isSessionID(projectId),
                  let name = fields["name"] as? String, !name.isEmpty, name.utf16.count <= 40,
                  let mode = fields["mode"] as? String, ["interactive", "plan", "autopilot"].contains(mode),
                  fields["model"].map({ $0 is String }) != false, fields["effort"].map({ $0 is String }) != false
            else { return nil }
            started = .init(projectId: projectId, name: name, mode: mode, model: fields["model"] as? String, effort: fields["effort"] as? String)
        } else if ["projectId", "name", "mode", "model", "effort"].contains(where: { fields[$0] != nil }) {
            return nil
        }
        return Received(kind: kind, prompt: prompt, report: report, started: started)
    }

    /// Writes a file atomically, only yours to read, as the extension does: under a name starting with `.`, then renamed.
    static func write(_ data: Data, to folder: URL, named name: String) throws {
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let temporary = folder.appendingPathComponent(".\(name).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw TestError("can't write \(name)") }
        _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard rename(temporary.path, folder.appendingPathComponent(name).path) == 0 else { throw TestError("can't rename \(name)") }
    }
}

extension SessionSender.Timing {
    /// Long enough for each step even while other tests keep the process busy for many seconds, so that a test waits only
    /// as long as the step takes: a test that waits for a step to time out shortens that step's.
    static var patient: SessionSender.Timing {
        var timing = SessionSender.Timing()
        timing.poll = FakeExtension.lookEvery
        timing.claim = 60
        timing.load = 60
        timing.listen = 60
        timing.sent = 60
        timing.forked = 60
        timing.confirm = 60
        return timing
    }

    /// With some steps shortened, for a test that waits for them to time out.
    func with(_ change: (inout SessionSender.Timing) -> Void) -> SessionSender.Timing {
        var timing = self
        change(&timing)
        return timing
    }
}
