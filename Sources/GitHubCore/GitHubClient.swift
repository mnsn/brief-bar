import Foundation

public enum GitHubError: Error, Sendable, Equatable, CustomStringConvertible {
    case auth(GitHubAuthError)
    /// GitHub rejected the token, even a fresh one.
    case unauthorized
    /// Signed in, but GitHub refused the request.
    case forbidden
    /// GitHub asked BriefBar to slow down.
    case throttled(retryAfter: TimeInterval)
    case offline
    case http(Int)
    case network(String)
    case decoding(String)
    /// GitHub answered with errors and nothing it could read.
    case graphQL(String)

    public var description: String {
        switch self {
        case .auth(let error): return error.description
        case .unauthorized: return "GitHub didn't accept the GitHub CLI's sign-in."
        case .forbidden: return "GitHub refused the request."
        case .throttled: return "GitHub asked BriefBar to slow down."
        case .offline: return "You're offline."
        case .http(let status): return "GitHub answered with HTTP \(status)."
        case .network(let message): return message
        case .decoding(let message): return "Unexpected response from GitHub (\(message))."
        case .graphQL(let message): return "GitHub couldn't answer: \(message)"
        }
    }
}

/// What `GitHubClient.pullRequests()` reads, with any errors about parts it couldn't.
public struct PullRequestQueryResult: Sendable, Equatable {
    public var data: PullRequestQueryData
    public var errors: [GraphQLError]

    public init(data: PullRequestQueryData, errors: [GraphQLError] = []) {
        self.data = data
        self.errors = errors
    }
}

/// Reads your pull requests from GitHub. It sends one request, always the same query (`PullRequestQuery`), so it can
/// only read: GitHub's GraphQL API takes queries as POST requests, and BriefBar never sends a mutation.
public struct GitHubClient: Sendable {
    public static let endpoint = URL(string: "https://api.github.com/graphql")!

    public let tokens: any GitHubTokenProviding
    let session: URLSession
    let gate: RateLimitGate
    let now: @Sendable () -> Date

    /// With its own session. The app's code makes clients with this, so that only this module and
    /// AzureDevOpsCore use networking APIs (scripts/check-boundaries.sh).
    public init(tokens: any GitHubTokenProviding) {
        self.init(tokens: tokens, session: GitHubClient.makeSession())
    }

    public init(tokens: any GitHubTokenProviding, session: URLSession, now: @escaping @Sendable () -> Date = { Date() }) {
        self.tokens = tokens
        self.session = session
        self.now = now
        gate = RateLimitGate(now: now)
    }

    /// No cookies, no cache and no credentials kept: every request carries its own token.
    public static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "BriefBar"]
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }

    /// Who you are, the pull requests that request your review and your own, as GitHub answers `PullRequestQuery`.
    public func pullRequests() async throws -> PullRequestQueryResult {
        let (data, response) = try await send(PullRequestQuery.body())
        let decoded: GraphQLResponse<PullRequestQueryData>
        do {
            decoded = try GitHubJSON.decoder().decode(GraphQLResponse<PullRequestQueryData>.self, from: data)
        } catch {
            throw GitHubError.decoding(Self.describe(error))
        }
        let errors = decoded.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
            let wait = Self.resetWait(response, now: now()) ?? 60
            await gate.hold(for: wait)
            throw GitHubError.throttled(retryAfter: wait)
        }
        guard let payload = decoded.data else {
            throw GitHubError.graphQL(String((errors.first?.message ?? "no data").prefix(300)))
        }
        return PullRequestQueryResult(data: payload, errors: errors)
    }

    /// The only way requests are made: the query, with the token, retried once with a fresh token if it's rejected.
    func send(_ body: Data) async throws -> (Data, HTTPURLResponse) {
        if let wait = await gate.remainingWait() {
            throw GitHubError.throttled(retryAfter: wait)
        }
        var token = try await accessToken()
        for attempt in 0..<2 {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: Self.request(body, token: token.value))
            } catch let error as URLError {
                throw Self.map(error)
            } catch {
                throw GitHubError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw GitHubError.network("No response from GitHub.")
            }
            switch http.statusCode {
            case 200..<300:
                // Out of requests for this hour: wait for the reset rather than be refused.
                if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0", let wait = Self.resetWait(http, now: now()) {
                    await gate.hold(for: wait)
                }
                return (data, http)
            case 401:
                if attempt == 0 {
                    await tokens.invalidate()
                    token = try await accessToken()
                    continue
                }
                throw GitHubError.unauthorized
            case 403, 429:
                if let wait = Self.rateLimitWait(http, body: data, now: now()) {
                    await gate.hold(for: wait)
                    throw GitHubError.throttled(retryAfter: wait)
                }
                throw GitHubError.forbidden
            default:
                throw GitHubError.http(http.statusCode)
            }
        }
        throw GitHubError.unauthorized
    }

    private func accessToken() async throws -> GitHubToken {
        do {
            return try await tokens.token()
        } catch let error as GitHubAuthError {
            throw GitHubError.auth(error)
        }
    }

    static func request(_ body: Data, token: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    /// How long to wait when GitHub refuses a request for its rate limits, or nil when it refused it for another
    /// reason: `Retry-After` for its secondary limits, the hourly limit's reset when that's used up, or a minute
    /// when it only says so in words. 429 is always a rate limit.
    static func rateLimitWait(_ response: HTTPURLResponse, body: Data, now: Date) -> TimeInterval? {
        if let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
           let seconds = TimeInterval(value), seconds > 0 {
            return min(seconds, 3_600)
        }
        if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0", let wait = resetWait(response, now: now) {
            return wait
        }
        let message = String(decoding: body, as: UTF8.self).lowercased()
        if response.statusCode == 429 || message.contains("rate limit") {
            return 60
        }
        return nil
    }

    /// Until the hourly limit resets (`x-ratelimit-reset`, seconds since 1970), at least a second and at most an hour.
    static func resetWait(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "x-ratelimit-reset"), let reset = TimeInterval(value) else { return nil }
        return min(max(reset - now.timeIntervalSince1970, 1), 3_600)
    }

    static func map(_ error: URLError) -> GitHubError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut: return .network("GitHub didn't answer in time.")
        case .cannotFindHost, .dnsLookupFailed: return .network("Can't reach GitHub.")
        default: return .network(error.localizedDescription)
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return String(describing: error) }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "missing \((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.codingPath.map(\.stringValue).joined(separator: ".") + ": " + context.debugDescription
        @unknown default:
            return String(describing: decodingError)
        }
    }
}

/// Remembers how long GitHub asked BriefBar to wait, so no request goes out before then.
actor RateLimitGate {
    private let now: @Sendable () -> Date
    private var notBefore = Date.distantPast

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    func hold(for seconds: TimeInterval) {
        notBefore = max(notBefore, now().addingTimeInterval(seconds))
    }

    func remainingWait() -> TimeInterval? {
        let wait = notBefore.timeIntervalSince(now())
        return wait > 0 ? wait : nil
    }
}
