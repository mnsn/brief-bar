import BriefBarCore
import Foundation
import Synchronization

/// The Copilot CLI as the server its SDK talks to, `copilot --headless --stdio`, for what its options can't do without
/// someone at the keyboard: fork a session (`sessions.fork`), and ask one a side question (`session.ui.ephemeralQuery`).
/// `/fork` and `/ask` are its terminal's commands: with `-p`, they're words sent to the model. The server's are JSON-RPC
/// 2.0 requests over its standard input and output, each message after a `Content-Length` header, as the Copilot SDK
/// sends them (its protocol version 3). Nothing else is asked of it: what it asks of BriefBar, such as for permission,
/// is refused, and what it says unasked is ignored. It runs as a `RunningProgram`, responsible for itself, with your
/// environment, until it's closed: it quits once its input ends.
final class CopilotServer: Sendable {
    /// What `copilot` is started with.
    static let arguments = ["--headless", "--stdio"]
    /// The protocol version of the requests BriefBar sends, the oldest server that takes them.
    static let protocolVersion = 3

    enum Failure: Error, Sendable, Equatable {
        /// It couldn't start: why.
        case couldntStart(String)
        /// It doesn't do what was asked, being too old or another program: what it said.
        case unsupported(String)
        /// It's a Copilot CLI too old to do it without changing the session: its version.
        case tooOld(String)
        /// It answered with an error, in its own words.
        case failed(String)
        /// It ended before it answered, with this status.
        case exited(Int32)
        /// It wrote what BriefBar can't read as a message, or as an answer to what was asked.
        case unreadable
        /// It took longer than BriefBar waits.
        case timedOut
        /// The task that asked was cancelled.
        case cancelled

        /// What its error says: a method it doesn't have is `unsupported`; anything else is `failed`, in its own words,
        /// without the server's "Request <method> failed with message: " before them.
        static func from(_ error: RemoteError, method: String) -> Failure {
            if error.code == -32601 { return .unsupported(error.message) }
            let wrapping = "Request \(method) failed with message: "
            let message = error.message.hasPrefix(wrapping) ? String(error.message.dropFirst(wrapping.count)) : error.message
            return .failed(message)
        }
    }

    /// A Copilot CLI's version, as the server says it: `1.0.105`, or a prerelease such as `1.0.95-3` or
    /// `1.0.102-0.unstable.r40949665530.gab1eef5`, which comes before its release. Compared by its three numbers, then by a
    /// prerelease's first one.
    struct Version: Comparable, Sendable, CustomStringConvertible {
        var numbers: [Int]
        /// A prerelease's first number; 0 when it doesn't start with one. Nil for a release.
        var prerelease: Int?
        var description: String

        init?(_ text: String) {
            let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { part -> Int? in
                part.isEmpty || part.count > 9 || !part.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : Int(part)
            }
            guard numbers.count == 3, numbers.allSatisfy({ $0 != nil }) else { return nil }
            self.numbers = numbers.compactMap { $0 }
            if parts.count == 2 {
                let first = parts[1].prefix { $0 != "." }
                prerelease = first.count <= 9 && first.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(first) ?? 0 : 0
            }
            description = text
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
            switch (lhs.prerelease, rhs.prerelease) {
            case (let left?, let right?): return left < right
            case (_?, nil): return true
            case (nil, _): return false
            }
        }

        static func == (lhs: Version, rhs: Version) -> Bool {
            lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease
        }
    }

    /// What a server's `connect` says about it.
    struct Connection: Decodable, Sendable {
        var protocolVersion: Int?
        var version: String?
    }

    /// An error as the server sends it.
    struct RemoteError: Codable, Sendable, Equatable {
        var code: Int
        var message: String
    }

    /// A message's ID: BriefBar's are numbers; the server's own requests' may be either.
    enum MessageID: Codable, Sendable, Equatable {
        case number(Int)
        case text(String)

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Int.self) {
                self = .number(number)
            } else {
                self = .text(try value.decode(String.self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .number(let number): try value.encode(number)
            case .text(let text): try value.encode(text)
            }
        }
    }

    private struct Call {
        var method: String
        var continuation: CheckedContinuation<Data, any Error>
        /// It's waited for to the end (`call(_:_:as:timeout:patient:)`).
        var isPatient: Bool
    }

    private struct State {
        var nextID = 1
        var calls: [Int: Call] = [:]
        /// Calls whose task was cancelled before they were sent, which aren't.
        var cancelled: Set<Int> = []
        var reader = MessageReader()
        /// Once it has exited, written what can't be read, or been given up on, every call fails with this.
        var ended: Failure?
        var exitStatus: Int32?
        var exitWaiters: [UUID: CheckedContinuation<Int32?, Never>] = [:]
    }

    /// Where what it writes, its exit and the timeouts are handled, one at a time.
    private let queue = DispatchQueue(label: "BriefBar.CopilotServer")
    private let state = Mutex(State())
    private let program = Mutex<RunningProgram?>(nil)

    private init() {}

    /// Starts `copilot` as its SDK's server.
    static func start(_ copilot: URL, environment: [String: String]) throws -> CopilotServer {
        let server = CopilotServer()
        // It's heard only once it's all set up.
        server.queue.suspend()
        defer { server.queue.resume() }
        do {
            let program = try RunningProgram.start(
                copilot, arguments: arguments, environment: environment, callbackQueue: server.queue,
                onOutput: { [weak server] in server?.heard($0) }, onExit: { [weak server] in server?.exited(status: $0) }
            )
            server.program.withLock { $0 = program }
        } catch {
            throw Failure.couldntStart(String(describing: error))
        }
        return server
    }

    /// Asks it something, and waits up to `timeout` seconds for its answer. Throws a `Failure`.
    /// - Parameter patient: for a request that makes something, such as a fork, whose answer is the only word of what it
    ///   made: once it's sent, it's waited for to the end, even once the task that asked is cancelled, so the caller can
    ///   undo it; and once `timeout` has passed, the server is given up on rather than the request (`giveUp()`).
    func call<Answer: Decodable & Sendable>(
        _ method: String, _ params: some Encodable & Sendable, as answer: Answer.Type = Answer.self, timeout: TimeInterval,
        patient: Bool = false
    ) async throws -> Answer {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        let body: Data
        do {
            body = try Self.encoder.encode(Request(id: id, method: method, params: params))
        } catch {
            throw Failure.failed("BriefBar couldn't write its request: \(error)")
        }
        let message: Data
        if patient {
            message = try await send(body, id: id, method: method, timeout: timeout, patient: true)
        } else {
            message = try await withTaskCancellationHandler {
                try await send(body, id: id, method: method, timeout: timeout, patient: false)
            } onCancel: {
                fail(id, with: .cancelled)
            }
        }
        do {
            return try JSONDecoder().decode(Answered<Answer>.self, from: message).result
        } catch {
            throw Failure.unreadable
        }
    }

    /// Sends a request, unless its task was cancelled first, and waits for its answer.
    private func send(_ body: Data, id: Int, method: String, timeout: TimeInterval, patient: Bool) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let refusal: Failure? = state.withLock { state in
                if let ended = state.ended { return ended }
                if state.cancelled.remove(id) != nil || Task.isCancelled { return .cancelled }
                state.calls[id] = Call(method: method, continuation: continuation, isPatient: patient)
                return nil
            }
            if let refusal {
                continuation.resume(throwing: refusal)
                return
            }
            program.withLock { $0 }?.write(MessageReader.frame(body))
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.timedOut(id) }
        }
    }

    /// Ends its input, which tells it to quit, and waits up to `grace` seconds for it to; then ends it, with whatever it
    /// started. Its exit status, once it exited.
    @discardableResult
    func close(grace: TimeInterval = 5) async -> Int32? {
        let program = program.withLock { $0 }
        program?.closeInput()
        if let status = await exitStatus(within: grace) { return status }
        program?.terminate()
        return await exitStatus(within: 2)
    }

    /// Its exit status, once it exits within `timeout` seconds; nil if it doesn't.
    private func exitStatus(within timeout: TimeInterval) async -> Int32? {
        let waiter = UUID()
        return await withCheckedContinuation { continuation in
            let status: Int32? = state.withLock { state in
                if let status = state.exitStatus { return status }
                state.exitWaiters[waiter] = continuation
                return nil
            }
            if let status {
                continuation.resume(returning: status)
                return
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.state.withLock { $0.exitWaiters.removeValue(forKey: waiter) }?.resume(returning: nil)
            }
        }
    }

    // MARK: What it writes

    private func heard(_ data: Data) {
        let messages = state.withLock { state in Result { try state.reader.read(data) } }
        switch messages {
        case .success(let messages):
            messages.forEach(handle)
        case .failure:
            end(with: .unreadable)
            program.withLock { $0 }?.terminate()
        }
    }

    /// An answer to one of BriefBar's calls goes to it. A request of its own, such as for permission, is refused: BriefBar
    /// grants nothing. A notification, such as its session's events, is ignored.
    private func handle(_ message: Data) {
        guard let header = try? JSONDecoder().decode(Incoming.self, from: message) else { return }
        if let method = header.method {
            if let id = header.id {
                let refusal = Refusal(id: id, error: RemoteError(code: -32601, message: "BriefBar doesn't handle \(method)."))
                if let body = try? Self.encoder.encode(refusal) {
                    program.withLock { $0 }?.write(MessageReader.frame(body))
                }
            }
            return
        }
        guard case .number(let id)? = header.id, let call = state.withLock({ $0.calls.removeValue(forKey: id) }) else { return }
        if let error = header.error {
            call.continuation.resume(throwing: Failure.from(error, method: call.method))
        } else {
            call.continuation.resume(returning: message)
        }
    }

    /// A call that's still waiting at its timeout fails, or, if it's patient, the server is given up on.
    private func timedOut(_ id: Int) {
        switch state.withLock({ $0.calls[id]?.isPatient }) {
        case nil: return
        case false?: fail(id, with: .timedOut)
        case true?: giveUp()
        }
    }

    /// Ends its input, so that it finishes what it's at, which may answer a patient call, and quits; and ends it, with
    /// whatever it started, five seconds later if it hasn't. From now on, what's asked of it fails, and so does what it
    /// hasn't answered by the time it's gone: `timedOut`.
    private func giveUp() {
        state.withLock { state in
            if state.ended == nil { state.ended = .timedOut }
        }
        let program = program.withLock { $0 }
        program?.closeInput()
        queue.asyncAfter(deadline: .now() + 5) { program?.terminate() }
    }

    private func fail(_ id: Int, with failure: Failure) {
        let call = state.withLock { state -> Call? in
            if let call = state.calls.removeValue(forKey: id) { return call }
            if failure == .cancelled { state.cancelled.insert(id) }
            return nil
        }
        call?.continuation.resume(throwing: failure)
    }

    /// Every call fails from now on, and those waiting fail now: with why it was given up on, if it was, or else this.
    private func end(with failure: Failure) {
        let (calls, reason) = state.withLock { state -> ([Call], Failure) in
            if state.ended == nil { state.ended = failure }
            defer { state.calls = [:] }
            return (Array(state.calls.values), state.ended ?? failure)
        }
        for call in calls { call.continuation.resume(throwing: reason) }
    }

    private func exited(status: Int32) {
        end(with: .exited(status))
        let waiters = state.withLock { state -> [CheckedContinuation<Int32?, Never>] in
            state.exitStatus = status
            defer { state.exitWaiters = [:] }
            return Array(state.exitWaiters.values)
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    // MARK: Messages

    /// Compact JSON, with no line break, its keys sorted.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private struct Request<Params: Encodable>: Encodable {
        var jsonrpc = "2.0"
        var id: Int
        var method: String
        var params: Params
    }

    private struct Refusal: Encodable {
        var jsonrpc = "2.0"
        var id: MessageID
        var error: RemoteError
    }

    /// What tells a message apart: an answer has an ID and no method; a request of the server's own has both; a
    /// notification only a method.
    private struct Incoming: Decodable {
        var id: MessageID?
        var method: String?
        var error: RemoteError?
    }

    private struct Answered<Answer: Decodable>: Decodable {
        var result: Answer
    }
}

/// An answer whose content doesn't matter, whatever it is.
struct IgnoredAnswer: Decodable, Sendable {
    init(from decoder: any Decoder) throws {}
}

/// Cuts messages out of what the Copilot CLI's server writes, as they come: each is a header, lines that end with CR LF,
/// one of them `Content-Length: <bytes>`, then an empty line, then that many bytes of JSON, as the Language Server
/// Protocol frames them, and the Copilot SDK.
struct MessageReader: Sendable {
    struct Malformed: Error, Equatable {}

    /// Longer messages are skipped, as they come, without being kept: what the server says unasked, such as a
    /// session's events, can carry a whole conversation, and its answers to BriefBar are short.
    var maxLength = 16 << 20
    /// How long a header may be.
    static let maxHeader = 8 << 10

    private var buffer: [UInt8] = []
    /// The length of the message whose header was read, while its body is still to come.
    private var length: Int?
    /// How much more of a message that's too long is still to come, and is skipped.
    private var skipping = 0

    init(maxLength: Int = 16 << 20) {
        self.maxLength = maxLength
    }

    /// A message to send, after its header.
    static func frame(_ body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    /// The messages that `data` completes, in order. Throws when a header isn't one, after which nothing it writes can be
    /// read.
    mutating func read(_ data: Data) throws -> [Data] {
        buffer.append(contentsOf: data)
        var messages: [Data] = []
        var offset = 0
        defer { buffer.removeFirst(offset) }
        while true {
            if skipping > 0 {
                let skipped = min(skipping, buffer.count - offset)
                skipping -= skipped
                offset += skipped
                if skipping > 0 { return messages }
            }
            if let length {
                guard buffer.count - offset >= length else { return messages }
                messages.append(Data(buffer[offset..<(offset + length)]))
                offset += length
                self.length = nil
                continue
            }
            guard let end = headerEnd(from: offset) else {
                if buffer.count - offset > Self.maxHeader { throw Malformed() }
                return messages
            }
            let length = try Self.contentLength(buffer[offset..<end])
            offset = end + 4
            if length > maxLength {
                skipping = length
            } else {
                self.length = length
            }
        }
    }

    /// Where the empty line after a header starts: the first CR LF CR LF, within `maxHeader`.
    private func headerEnd(from start: Int) -> Int? {
        let last = min(buffer.count, start + Self.maxHeader + 4) - 4
        guard last >= start else { return nil }
        for index in start...last
        where buffer[index] == 13 && buffer[index + 1] == 10 && buffer[index + 2] == 13 && buffer[index + 3] == 10 {
            return index
        }
        return nil
    }

    /// `Content-Length`'s value, whatever its case, among a header's lines, each a name and a value after a colon; other
    /// fields, such as `Content-Type`, don't matter.
    private static func contentLength(_ header: ArraySlice<UInt8>) throws -> Int {
        var length: Int?
        for line in String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { throw Malformed() }
            guard line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard length == nil, !value.isEmpty, value.count <= 12, value.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw Malformed()
            }
            length = Int(value)
        }
        guard let length else { throw Malformed() }
        return length
    }
}
