import BriefBarCore
import Foundation
import Synchronization
import Testing
@testable import GitHubCore

/// Fixed reference time for fixtures: 2026-10-18T10:00:00Z.
let referenceDate = Date(timeIntervalSince1970: 1_792_317_600)

/// The reference time plus `seconds`.
func t(_ seconds: TimeInterval) -> Date {
    referenceDate.addingTimeInterval(seconds)
}

let minute: TimeInterval = 60
let hour: TimeInterval = 3_600

enum Fixture {
    static let me = "robin"

    static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    /// A pull request as GitHub's GraphQL API answers it.
    static func pullRequest(
        _ number: Int, repository: String = "octo/app", title: String? = nil, author: String? = "priya", isDraft: Bool = false,
        updated: Date = t(0), reviewDecision: String? = nil, mergeable: String = "MERGEABLE", rollup: String? = nil,
        reviews: [(state: String, author: String?)] = []
    ) -> [String: Any] {
        let object: [String: Any] = [
            "id": "PR_\(repository)_\(number)",
            "number": number,
            "title": title ?? "Pull request \(number)",
            "url": "https://github.com/\(repository)/pull/\(number)",
            "isDraft": isDraft,
            "createdAt": iso(updated.addingTimeInterval(-hour)),
            "updatedAt": iso(updated),
            "author": author.map { ["login": $0] as Any } ?? NSNull(),
            "repository": ["nameWithOwner": repository],
            "reviewDecision": reviewDecision ?? NSNull(),
            "mergeable": mergeable,
            "commits": ["nodes": [["commit": ["statusCheckRollup": rollup.map { ["state": $0] as Any } ?? NSNull()]]]],
            "latestOpinionatedReviews": ["nodes": reviews.map { review in
                ["state": review.state, "author": review.author.map { ["login": $0] as Any } ?? NSNull()] as [String: Any]
            }],
        ]
        return object
    }

    /// The whole answer to `PullRequestQuery`.
    static func answer(
        login: String = me, reviewing: [Any] = [], authored: [Any] = [], reviewingCount: Int? = nil, authoredCount: Int? = nil,
        errors: [[String: Any]]? = nil
    ) -> [String: Any] {
        var answer: [String: Any] = [
            "data": [
                "viewer": ["login": login],
                "reviewing": ["issueCount": reviewingCount ?? reviewing.count, "nodes": reviewing],
                "authored": ["issueCount": authoredCount ?? authored.count, "nodes": authored],
                "rateLimit": ["remaining": 4_990, "resetAt": iso(t(hour))],
            ] as [String: Any],
        ]
        if let errors { answer["errors"] = errors }
        return answer
    }

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A pull request decoded from GitHub's JSON, as the app reads it.
    static func decoded(_ object: [String: Any]) throws -> GitHubPullRequest {
        GitHubPullRequest(try GitHubJSON.decoder().decode(APIPullRequest.self, from: data(object)))
    }

    static func queryData(_ answer: [String: Any]) throws -> PullRequestQueryData {
        let data = try #require(answer["data"])
        return try GitHubJSON.decoder().decode(PullRequestQueryData.self, from: Self.data(data))
    }

    /// A pull request built directly, for the classifier.
    static func make(
        _ number: Int = 1, author: String? = "priya", isDraft: Bool = false, updated: Date = t(0),
        decision: GitHubPullRequest.ReviewDecision? = nil, conflicts: Bool = false, checks: GitHubPullRequest.Checks? = nil,
        reviews: [GitHubPullRequest.Review] = [], id: String? = nil
    ) -> GitHubPullRequest {
        GitHubPullRequest(
            id: id ?? "PR_\(number)", number: number, title: "Pull request \(number)",
            url: URL(string: "https://github.com/octo/app/pull/\(number)")!, repository: "octo/app", author: author,
            isDraft: isDraft, createdAt: updated.addingTimeInterval(-hour), updatedAt: updated, reviewDecision: decision,
            hasConflicts: conflicts, checks: checks, reviews: reviews
        )
    }
}

/// Tokens named after a stub server, so its requests find it: "<server>:<n>", n going up each time one is
/// invalidated.
actor FakeTokens: GitHubTokenProviding {
    let server: String
    private(set) var invalidations = 0
    private(set) var calls = 0
    private var error: GitHubAuthError?

    init(_ server: String, error: GitHubAuthError? = nil) {
        self.server = server
        self.error = error
    }

    func token() async throws -> GitHubToken {
        calls += 1
        if let error { throw error }
        return GitHubToken(value: "\(server):\(invalidations)", fetchedAt: referenceDate)
    }

    func invalidate() {
        invalidations += 1
    }
}

/// A token for a read that gives up as it comes, as one does when GitHub is turned off just then.
struct GivingUpTokens: GitHubTokenProviding {
    let server: String

    func token() async throws -> GitHubToken {
        withUnsafeCurrentTask { $0?.cancel() }
        return GitHubToken(value: "\(server):0", fetchedAt: referenceDate)
    }

    func invalidate() async {}
}

/// Answers GraphQL requests. Each test gets its own server; requests find it through their bearer token, which
/// starts with the server's ID, so tests can run in parallel.
final class StubServer: Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"]
        var body = Data()
        var error: URLError?
        /// Where the request is redirected, with its headers, as a server's 307 would.
        var redirect: URL?

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            var reply = Reply(status: status, body: Fixture.data(object))
            reply.headers.merge(headers) { $1 }
            return reply
        }

        static func text(_ text: String, status: Int, headers: [String: String] = [:]) -> Reply {
            var reply = Reply(status: status, body: Data(text.utf8))
            reply.headers.merge(headers) { $1 }
            return reply
        }

        static func failure(_ code: URLError.Code) -> Reply {
            Reply(error: URLError(code))
        }

        static func redirect(to location: String) -> Reply {
            Reply(status: 307, headers: ["Location": location], redirect: URL(string: location))
        }
    }

    /// A request as the server saw it, with its body, which URLProtocol gets as a stream.
    struct Received: Sendable {
        var request: URLRequest
        var body: Data
        var token: String

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    let id = UUID().uuidString
    private let replies = Mutex<[Reply]>([])
    private let fallback = Mutex<Reply>(.text("{}", status: 404))
    private let log = Mutex<[Received]>([])

    init() {
        StubRegistry.servers.withLock { $0[id] = self }
    }

    func client(tokens: (any GitHubTokenProviding)? = nil, now: @escaping @Sendable () -> Date = { referenceDate }) -> GitHubClient {
        GitHubClient(
            tokens: tokens ?? FakeTokens(id), session: GitHubClient.makeSession(protocolClasses: [StubURLProtocol.self]), now: now
        )
    }

    /// The next requests get these replies, in order; after them, `always`'s.
    func reply(_ replies: Reply...) {
        self.replies.withLock { $0.append(contentsOf: replies) }
    }

    func always(_ reply: Reply) {
        fallback.withLock { $0 = reply }
    }

    var received: [Received] { log.withLock { $0 } }

    func handle(_ request: URLRequest, body: Data, token: String) -> Reply {
        log.withLock { $0.append(Received(request: request, body: body, token: token)) }
        if let next = replies.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return next }
        return fallback.withLock { $0 }
    }
}

enum StubRegistry {
    static let servers = Mutex<[String: StubServer]>([:])
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = authorization.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        let serverID = String(token.split(separator: ":").first ?? "")
        guard let server = StubRegistry.servers.withLock({ $0[serverID] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let reply = server.handle(request, body: Self.body(of: request), token: token)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let target = reply.redirect {
            // As Apple's CustomHTTPProtocol sample does: report the redirect, then end this load. URLSession asks the
            // task's delegate, then loads the new request with another instance, or ends the task.
            var redirected = URLRequest(url: target)
            redirected.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didFailWithError: CocoaError(.userCancelled))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A tiny lock-protected value for test bookkeeping.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    func set(_ value: Value) {
        lock.withLock { stored = value }
    }

    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}

/// Runs nothing: answers each run with the next scripted result, and remembers what it was asked to run.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]?
        var timeout: TimeInterval
    }

    enum Outcome: Sendable {
        case result(ProcessResult)
        case error(String)

        static func output(_ stdout: String, status: Int32 = 0, stderr: String = "") -> Outcome {
            .result(ProcessResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)))
        }
    }

    struct Failure: Error, LocalizedError {
        var errorDescription: String?
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var fallback: Outcome
    private var log: [Call] = []
    private var stops = 0
    private var held: Bool
    /// How long each run takes, so callers at the same time can overlap.
    let delay: Duration

    /// `held`: each run then goes on until `release()`, or until it's stopped, however slow the machine.
    init(_ outcomes: [Outcome] = [], fallback: Outcome = .output("", status: 1), delay: Duration = .zero, held: Bool = false) {
        self.outcomes = outcomes
        self.fallback = fallback
        self.delay = delay
        self.held = held
    }

    var calls: [Call] { lock.withLock { log } }

    /// How many runs were stopped, as `ProcessRunner` stops one whose task is cancelled.
    var stopped: Int { lock.withLock { stops } }

    /// Lets held runs end: those under way, and those to come.
    func release() {
        lock.withLock { held = false }
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        let outcome = lock.withLock {
            log.append(Call(executable: executable.path, arguments: arguments, environment: environment, timeout: timeout))
            return outcomes.isEmpty ? fallback : outcomes.removeFirst()
        }
        do {
            if delay > .zero { try await Task.sleep(for: delay) }
            while lock.withLock({ held }) { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            lock.withLock { stops += 1 }
            throw error
        }
        switch outcome {
        case .result(let result): return result
        case .error(let message): throw Failure(errorDescription: message)
        }
    }
}

extension GitHubCLILocator {
    /// Finds `gh` only at `path`, without a login shell.
    static func fixed(_ path: String?) -> GitHubCLILocator {
        GitHubCLILocator(environment: [:], candidates: path.map { [$0] } ?? [], useLoginShell: false, runner: FakeRunner()) {
            $0 == path
        }
    }
}
