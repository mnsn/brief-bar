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
    /// How often it looks for requests, and BriefBar's side of these tests at the outbox (`Timing.patient`). Every look reads
    /// the outbox's folders, on the one thread that `make test` leaves the tests' async work, so many tests looking every few
    /// milliseconds at once held up other suites' tests until they ran out of time.
    static let lookEvery: Duration = .milliseconds(25)

    /// How it answers a request it claimed.
    enum Answer: Sendable {
        /// It's done: a send's message ID, or a fork's session.
        case done(fork: String? = nil)
        /// It isn't: the contract's code, and a message.
        case failed(String, String)
        /// After a while.
        indirect case after(Duration, Answer)
        /// Never: as if it ended as it handled it.
        case never
    }

    struct Received: Sendable, Equatable {
        var kind: String
        var prompt: String?
    }

    let outbox: URL
    let sessionId: String
    private let state = Mutex<(received: [Received], refused: Int, task: Task<Void, Never>?)>(([], 0, nil))

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

    /// Starts taking its session's requests, looking every `lookEvery`, until `stop()`. Started again, it answers as it's
    /// told then, and stops looking as it was told before, which would otherwise go on until the tests end.
    func start(answer: @escaping @Sendable (Received) -> Answer = { _ in .done() }) {
        let task = Task { [self] in
            while !Task.isCancelled {
                takeRequests(answer: answer)
                try? await Task.sleep(for: Self.lookEvery)
            }
        }
        state.withLock {
            $0.task?.cancel()
            $0.task = task
        }
    }

    func stop() {
        state.withLock { $0.task?.cancel() }
    }

    private func folder(_ name: String) -> URL {
        outbox.appendingPathComponent(name, isDirectory: true)
    }

    private func takeRequests(answer: @escaping @Sendable (Received) -> Answer) {
        let requests = folder("requests")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? []
        for name in names where name.hasPrefix("\(sessionId).") && name.hasSuffix(".json") {
            let requestId = String(name.dropFirst(sessionId.count + 1).dropLast(5))
            let claimed = requests.appendingPathComponent(".\(sessionId).\(requestId).claimed-\(getpid())")
            // Claimed by renaming, so it's handled once; gone when BriefBar withdrew it first.
            guard rename(requests.appendingPathComponent(name).path, claimed.path) == 0 else { continue }
            guard let request = Self.check(claimed, requestId: requestId, sessionId: sessionId) else {
                state.withLock { $0.refused += 1 }
                try? FileManager.default.removeItem(at: claimed)
                continue
            }
            state.withLock { $0.received.append(request) }
            let response = answer(request)
            Task { [self] in
                await respond(response, to: request, requestId: requestId)
                try? FileManager.default.removeItem(at: claimed)
            }
        }
    }

    private func respond(_ answer: Answer, to request: Received, requestId: String) async {
        var fields: [String: Any] = [
            "version": 1, "requestId": requestId, "sessionId": sessionId, "kind": request.kind,
            "finishedAt": Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
        ]
        switch answer {
        case .never:
            return
        case .after(let delay, let then):
            try? await Task.sleep(for: delay)
            return await respond(then, to: request, requestId: requestId)
        case .done(let fork):
            fields["ok"] = true
            if let fork { fields["forkSessionId"] = fork } else { fields["messageId"] = "message-1" }
        case .failed(let code, let message):
            fields["ok"] = false
            fields["error"] = ["code": code, "message": message]
        }
        try? Self.write(JSONSerialization.data(withJSONObject: fields), to: folder("results"), named: "\(requestId).json")
    }

    /// A request it may act on: a regular file that's yours, only yours to read, of 256 KiB or less, at version 1, for its
    /// own session, with a prompt only for a send, that hasn't expired and was given at most 120 seconds.
    static func check(_ file: URL, requestId: String, sessionId: String) -> Received? {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600,
              info.st_uid == getuid(), info.st_size <= 256 << 10,
              let data = FileManager.default.contents(atPath: file.path),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              fields["version"] as? Int == 1, fields["requestId"] as? String == requestId,
              fields["sessionId"] as? String == sessionId,
              let kind = fields["kind"] as? String, ["send", "fork"].contains(kind),
              let created = (fields["createdAt"] as? String).flatMap({ try? Date($0, strategy: .iso8601) }),
              let expires = (fields["expiresAt"] as? String).flatMap({ try? Date($0, strategy: .iso8601) }),
              Date() < expires, expires.timeIntervalSince(created) <= 120
        else { return nil }
        let prompt = fields["prompt"] as? String
        guard (kind == "send") == (prompt != nil) else { return nil }
        return Received(kind: kind, prompt: prompt)
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
