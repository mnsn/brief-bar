import BriefBarCore
import Foundation
import Synchronization

public enum ADOError: Error, Sendable, Equatable, CustomStringConvertible {
    case auth(AuthError)
    /// Azure DevOps rejected the token, even a fresh one.
    case unauthorized
    /// The organization is in another directory (a Microsoft Entra tenant), which the Azure CLI isn't signed in to:
    /// `az login --tenant` with its ID signs in there.
    case otherDirectory(organization: String, tenant: String)
    /// Signed in, but without access to this organization or project.
    case forbidden
    case notFound
    /// Azure DevOps asked us to slow down.
    case throttled(retryAfter: TimeInterval)
    case offline
    case http(Int)
    case network(String)
    case decoding(String)
    /// Azure DevOps redirected the request to another host, where BriefBar doesn't go (`RedirectGuard`). Which host isn't
    /// said: problem messages go to the log, and a host can carry an organization's name.
    case redirected
    /// Azure DevOps refused a change BriefBar asked it to make (`ADOWrite`): why, when it says so in a way BriefBar knows,
    /// and what it said, which BriefBar shows on the thread but never logs.
    case refused(Refusal?, message: String?)

    /// Why Azure DevOps refused a change, as BriefBar tells it from its answer.
    public enum Refusal: Sendable, Equatable {
        /// The pull request is completed or abandoned, and takes no change anymore: TF401181,
        /// `GitPullRequestNotEditableException`.
        case notEditable
    }

    public var description: String {
        switch self {
        case .auth(let error): return error.description
        case .unauthorized: return "Azure DevOps didn't accept the sign-in."
        // Without its name or its directory's ID: this goes to the log.
        case .otherDirectory: return "The organization is in a directory your Azure CLI isn't signed in to."
        case .forbidden: return "No access to this organization."
        case .notFound: return "Not found."
        case .throttled: return "Azure DevOps asked BriefBar to slow down."
        case .offline: return "You're offline."
        case .http(let status): return "Azure DevOps answered with HTTP \(status)."
        case .network(let message): return message
        case .decoding(let message): return "Unexpected response from Azure DevOps (\(message))."
        case .redirected: return "Azure DevOps redirected BriefBar to another host, which it doesn't connect to."
        // Without what it said, which can quote the change: this goes to the log.
        case .refused(.notEditable?, _): return "Azure DevOps refused the change: the pull request is completed or abandoned."
        case .refused(nil, _): return "Azure DevOps refused the change."
        }
    }
}

/// Reads from Azure DevOps, with GET requests only, but for the changes `ADOWrite` lists, which `send(_:)` alone makes, when
/// you click them with Make Changes in Azure DevOps on: replies, threads' statuses and pull requests' tags. Each request goes
/// only where it's sent: it follows no redirect (`RedirectGuard`).
public struct ADOClient: Sendable {
    public let tokens: any AccessTokenProvider
    let session: URLSession
    let gate: RateLimitGate
    /// The directory of each organization in another one than your sign-in's, as Azure DevOps named it.
    let directories: OrganizationDirectories

    /// With its own session. The app's code makes clients with this, so that only this module uses
    /// networking APIs (scripts/check-boundaries.sh).
    public init(tokens: any AccessTokenProvider) {
        self.init(tokens: tokens, session: ADOClient.makeSession())
    }

    public init(tokens: any AccessTokenProvider, session: URLSession) {
        self.tokens = tokens
        self.session = session
        gate = RateLimitGate()
        directories = OrganizationDirectories()
    }

    /// No cookies, no cache and no credentials kept: every request carries its own bearer token.
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

    public func get<T: Decodable>(_ url: URL, as type: T.Type = T.self) async throws -> T {
        let data = try await data(url)
        do {
            return try ADOJSON.decoder().decode(T.self, from: data)
        } catch {
            throw ADOError.decoding(Self.describe(error))
        }
    }

    /// A JSON answer's bytes.
    func data(_ url: URL) async throws -> Data {
        try await answer(url, request: { Self.request(url, token: $0) }, isAnswer: Self.isJSON) { request, redirects in
            let (data, response) = try await session.data(for: request, delegate: redirects)
            return (data, response, true)
        }.data
    }

    /// A file's bytes, from a request whose answer is the file itself rather than JSON: at most `limit` of them. Past that,
    /// the rest isn't read, and they aren't complete.
    func file(_ url: URL, limit: Int) async throws -> FileBytes {
        // Any type of file is an answer: 203 is what says it's a sign-in page instead.
        let read = try await answer(
            url, request: { Self.request(url, token: $0, accept: "application/octet-stream") }, isAnswer: { _ in true }
        ) { request, redirects in
            let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
            return try await Self.read(bytes, response, limit: limit)
        }
        return FileBytes(data: read.data, isComplete: read.isComplete)
    }

    /// Makes one of the changes `ADOWrite` lists, the only requests BriefBar sends that aren't GETs, and returns Azure
    /// DevOps' answer. It goes once: a failure isn't tried again, but for a sign-in Azure DevOps didn't take, which it
    /// didn't act on. When Azure DevOps refuses it, the error says why, as it said it (`ADOError.refused`); and when it made
    /// the change but its answer can't be read, the answer says so (`Answer.unreadable`), rather than that it failed. A tag's
    /// change answered with nothing (204) was made all the same: taking one off says nothing more, whatever it answers.
    public func send(_ write: ADOWrite) async throws -> ADOWrite.Answer {
        let isRemoval = write.kind == .removeTag
        let data = try await answer(
            write.url, request: { Self.request(write, token: $0) }, isAnswer: isRemoval ? { _ in true } : Self.isJSON,
            isAnswerWithNothing: write.kind.isTags, refusal: Self.refusal
        ) { request, redirects in
            let (data, response) = try await session.data(for: request, delegate: redirects)
            return (data, response, true)
        }.data
        do {
            switch write.kind {
            case .reply: return .comment(try ADOJSON.decoder().decode(ADOComment.self, from: data))
            case .setStatus: return .thread(try ADOJSON.decoder().decode(ADOThread.self, from: data))
            case .addTag: return .tag(try ADOJSON.decoder().decode(ADOTag.self, from: data))
            case .removeTag: return .done
            }
        } catch {
            return .unreadable(Self.describe(error))
        }
    }

    /// The only way requests are made: a GET (`request(_:token:accept:)`), or one of the changes `ADOWrite` lists
    /// (`request(_:token:)`), which `makeRequest` makes with a token: with a bearer token for the organization's directory,
    /// retried with a fresh token once for each directory whose token is rejected, and once with a token for the
    /// organization's own directory if Azure DevOps names another one than the token's, following no redirect. Azure DevOps
    /// acts on no request it rejects the token of, so a change is retried only then. `isAnswer` tells what was asked for
    /// from a sign-in page; `isAnswerWithNothing`, that an answer with nothing in it (204) is one, as for a change, rather
    /// than nothing there; `refusal` tells, for a change, why Azure DevOps refused it, from its status and its answer; and
    /// `send` sends the request with the guard against redirects it's given, and gets the answer's body, and whether that's
    /// all of it.
    private func answer(
        _ url: URL, request makeRequest: (String) -> URLRequest, isAnswer: (HTTPURLResponse) -> Bool,
        isAnswerWithNothing: Bool = false, refusal: ((Int, Data) -> ADOError?)? = nil,
        _ send: (URLRequest, RedirectGuard) async throws -> (Data, URLResponse, Bool)
    ) async throws -> (data: Data, isComplete: Bool) {
        if let wait = await gate.remainingWait(), wait > 0 {
            throw ADOError.throttled(retryAfter: wait)
        }
        let organization = Self.organization(of: url)
        var tenant: String?
        if let organization { tenant = await directories.tenant(of: organization) }
        var token: AccessToken
        do {
            token = try await accessToken(tenant: tenant, for: organization)
        } catch ADOError.otherDirectory {
            // Signed out of the directory it was in: with a token from yours, Azure DevOps names the one it's in now,
            // which may be another.
            if let organization { await directories.forget(organization) }
            tenant = nil
            token = try await accessToken(tenant: nil, for: organization)
        }
        // The directories whose token was refreshed: your own, say, and then the organization's, once it's named.
        var refreshed: Set<String?> = []
        var movedDirectory = false
        for _ in 0..<4 {
            let redirects = RedirectGuard()
            let (data, response, isComplete): (Data, URLResponse, Bool)
            do {
                (data, response, isComplete) = try await send(makeRequest(token.value), redirects)
            } catch {
                // A refused redirect ends the request, however URLSession ends it.
                if let redirect = redirects.refused { throw Self.error(refusing: redirect) }
                if let error = error as? URLError { throw Self.map(error) }
                throw ADOError.network(error.localizedDescription)
            }
            if let redirect = redirects.refused {
                throw Self.error(refusing: redirect)
            }
            guard let http = response as? HTTPURLResponse else {
                throw ADOError.network("No response from Azure DevOps.")
            }
            if let retryAfter = Self.retryAfter(http) {
                await gate.hold(for: retryAfter)
            }
            switch http.statusCode {
            case 204 where isAnswerWithNothing:
                return (data, isComplete)
            case 204:
                // Nothing there, such as the timeline of a run that has none yet: not a sign-in problem.
                throw ADOError.notFound
            case 200..<300 where http.statusCode != 203 && isAnswer(http):
                return (data, isComplete)
            case 200..<300, 401:
                // 203 with a sign-in page is how Azure DevOps answers a request it didn't authenticate. An organization
                // in another directory names its own: once a token from there works, it's read with one from there.
                if let organization, !movedDirectory, let other = Self.otherDirectory(of: http, token: token) {
                    movedDirectory = true
                    tenant = other
                    token = try await accessToken(tenant: other, for: organization)
                    await directories.remember(other, for: organization)
                    continue
                }
                if !refreshed.contains(tenant) {
                    refreshed.insert(tenant)
                    await tokens.invalidate(tenant: tenant)
                    token = try await accessToken(tenant: tenant, for: organization)
                    continue
                }
                throw ADOError.unauthorized
            case 403: throw ADOError.forbidden
            case 404: throw ADOError.notFound
            case 429, 503:
                // Asked to slow down without saying for how long: nothing goes out for a minute, as if it had said so,
                // whichever engine or summary asks next.
                let wait = Self.retryAfter(http) ?? Self.retryAfterUnsaid
                await gate.hold(for: wait)
                throw ADOError.throttled(retryAfter: wait)
            default:
                if let refused = refusal?(http.statusCode, data) { throw refused }
                throw ADOError.http(http.statusCode)
            }
        }
        throw ADOError.unauthorized
    }

    /// A token for `tenant`'s directory, or for your sign-in's. When the Azure CLI isn't signed in to an organization's
    /// directory, that's the organization's problem, which signing in there fixes: the others are still read.
    private func accessToken(tenant: String?, for organization: String?) async throws -> AccessToken {
        do {
            return try await tokens.token(tenant: tenant)
        } catch let error as AuthError {
            if let tenant, let organization, case .signedOut = error {
                throw ADOError.otherDirectory(organization: organization, tenant: tenant)
            }
            throw ADOError.auth(error)
        }
    }

    /// An answer's bytes, up to `limit`, when it's what was asked for. An error's or a sign-in page's aren't read.
    private static func read(
        _ bytes: URLSession.AsyncBytes, _ response: URLResponse, limit: Int
    ) async throws -> (Data, URLResponse, Bool) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), ![203, 204].contains(http.statusCode)
        else {
            bytes.task.cancel()
            return (Data(), response, true)
        }
        if http.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            return (Data(), response, false)
        }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else {
                bytes.task.cancel()
                return (data, response, false)
            }
            data.append(byte)
        }
        return (data, response, true)
    }

    static func request(_ url: URL, token: String, accept: String = "application/json") -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // Answer an unauthenticated request with 401 instead of a redirect to the sign-in page.
        request.setValue("Suppress", forHTTPHeaderField: "X-TFS-FedAuthRedirect")
        return request
    }

    static func isJSON(_ response: HTTPURLResponse) -> Bool {
        (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("json")
    }

    /// A change's request: its method, its URL and its JSON body, with a GET's sign-in and headers. One with nothing to say
    /// but its address, as taking a tag off, has no body.
    static func request(_ write: ADOWrite, token: String) -> URLRequest {
        var request = request(write.url, token: token)
        request.httpMethod = write.method
        let body = write.body
        if !body.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// Why Azure DevOps refused a change, from its answer, which says why in JSON: TF401181,
    /// `GitPullRequestNotEditableException`, for a pull request that's completed or abandoned. Nil for a status that isn't
    /// a refusal, but an error like any other: a server's, say.
    static func refusal(status: Int, data: Data) -> ADOError? {
        guard (400..<500).contains(status) else { return nil }
        struct Said: Decodable {
            var message: String?
            var typeKey: String?
        }
        let said = try? JSONDecoder().decode(Said.self, from: data)
        let message = said?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notEditable = said?.typeKey == "GitPullRequestNotEditableException" || message?.hasPrefix("TF401181") == true
        return .refused(notEditable ? .notEditable : nil, message: message.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) })
    }

    /// The organization a request reads, by name: the first part of a dev.azure.com path. Nil for one that reads no
    /// organization, such as finding yours.
    static func organization(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "dev.azure.com",
              let name = components.path.split(separator: "/").first, !name.isEmpty
        else { return nil }
        return String(name)
    }

    /// The directory an organization that rejected `token` is in, when it's another one than the token's: Azure DevOps
    /// names the organization's directories in `X-VSS-ResourceTenant`. Nil when it names the token's, or none.
    static func otherDirectory(of response: HTTPURLResponse, token: AccessToken) -> String? {
        guard let tokenTenant = token.tenant?.lowercased() else { return nil }
        let named = resourceTenants(response)
        guard !named.contains(tokenTenant) else { return nil }
        return named.first
    }

    /// The directories in `X-VSS-ResourceTenant`, lowercased: only tenant IDs, which are GUIDs, since one goes to
    /// `az login --tenant`; and not the empty one.
    static func resourceTenants(_ response: HTTPURLResponse) -> [String] {
        (response.value(forHTTPHeaderField: "X-VSS-ResourceTenant") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { UUID(uuidString: $0) != nil && $0 != "00000000-0000-0000-0000-000000000000" }
    }

    /// How long `Retry-After` asks to wait from `now`, in seconds or until the date it gives, at most an hour.
    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        RetryAfter.wait(response.value(forHTTPHeaderField: "Retry-After"), now: now).map { min($0, 3_600) }
    }

    /// How long to wait when Azure DevOps asks to slow down without saying for how long.
    static let retryAfterUnsaid: TimeInterval = 60

    /// What a request that Azure DevOps didn't answer in time fails with (`ADOError.network`): a change may have been made
    /// all the same.
    public static let unansweredMessage = "Azure DevOps didn't answer in time."

    static func map(_ error: URLError) -> ADOError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut: return .network(unansweredMessage)
        case .cannotFindHost, .dnsLookupFailed: return .network("Can't reach Azure DevOps.")
        default: return .network(error.localizedDescription)
        }
    }

    /// A redirect to another host says so; one on the same host is an HTTP error like any other.
    static func error(refusing redirect: RedirectGuard.Refusal) -> ADOError {
        redirect.toAnotherHost ? .redirected : .http(redirect.status)
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \(([key] + context.codingPath.reversed()).map(\.stringValue).reversed().joined(separator: "."))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.codingPath.map(\.stringValue).joined(separator: ".") + ": " + context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }
}

/// Remembers how long Azure DevOps asked us to wait (`Retry-After`), so no request goes out before then.
actor RateLimitGate {
    private var notBefore = Date.distantPast

    func hold(for seconds: TimeInterval) {
        notBefore = max(notBefore, Date().addingTimeInterval(seconds))
    }

    func remainingWait() -> TimeInterval? {
        let wait = notBefore.timeIntervalSinceNow
        return wait > 0 ? wait : nil
    }
}

/// Which directory each organization in another one than your sign-in's is in, as Azure DevOps named it when it
/// rejected a token from yours, while a token from there works: by organization name, which Azure DevOps compares
/// ignoring case.
actor OrganizationDirectories {
    private var tenants: [String: String] = [:]

    func tenant(of organization: String) -> String? {
        tenants[organization.lowercased()]
    }

    func remember(_ tenant: String, for organization: String) {
        tenants[organization.lowercased()] = tenant
    }

    func forget(_ organization: String) {
        tenants[organization.lowercased()] = nil
    }
}

/// Follows no redirect, so each request goes only where it's sent, with the Azure CLI's token: Azure DevOps answers it
/// there. One for each request, which keeps the redirect it refused, for the client to say so.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    /// A redirect it refused: its status, and whether it pointed to another host.
    struct Refusal: Sendable, Equatable {
        var status: Int
        var toAnotherHost: Bool
    }

    private let refusal = Mutex<Refusal?>(nil)

    /// The redirect it refused, if there was one.
    var refused: Refusal? { refusal.withLock { $0 } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        let refused = Refusal(status: response.statusCode, toAnotherHost: Self.isAnotherHost(request.url, than: response.url))
        refusal.withLock { $0 = refused }
        return nil
    }

    /// Whether `target` is on another host than `source`: not when it stays on `source`'s, whatever its scheme, port or
    /// path, or has none.
    static func isAnotherHost(_ target: URL?, than source: URL?) -> Bool {
        guard let host = target?.host(percentEncoded: true)?.lowercased(), !host.isEmpty else { return false }
        return host != source?.host(percentEncoded: true)?.lowercased()
    }
}

/// The REST endpoints BriefBar reads, and the web pages it opens.
public enum ADOEndpoint {
    static let apiVersion = "7.1"

    public static func connectionData(organization: String) -> URL {
        url("https://dev.azure.com", [organization, "_apis", "connectionData"], [])
    }

    /// Pull requests across every project in the organization.
    public static func pullRequests(
        organization: String, creatorId: String? = nil, reviewerId: String? = nil, status: String,
        closedSince: Date? = nil, top: Int = 200
    ) -> URL {
        var query: [(String, String)] = []
        if let creatorId { query.append(("searchCriteria.creatorId", creatorId)) }
        if let reviewerId { query.append(("searchCriteria.reviewerId", reviewerId)) }
        query.append(("searchCriteria.status", status))
        if let closedSince {
            query.append(("searchCriteria.minTime", closedSince.formatted(.iso8601)))
            query.append(("searchCriteria.queryTimeRangeType", "closed"))
        }
        query.append(("$top", String(top)))
        query.append(("api-version", apiVersion))
        return url("https://dev.azure.com", [organization, "_apis", "git", "pullrequests"], query)
    }

    public static func pullRequest(organization: String, id: Int) -> URL {
        url("https://dev.azure.com", [organization, "_apis", "git", "pullrequests", String(id)], [("api-version", apiVersion)])
    }

    /// Branch policies (builds, status checks, reviewer rules...) and how each one stands.
    public static func policyEvaluations(organization: String, projectId: String, pullRequestId: Int) -> URL {
        let artifact = "vstfs:///CodeReview/CodeReviewId/\(projectId)/\(pullRequestId)"
        return url("https://dev.azure.com", [organization, projectId, "_apis", "policy", "evaluations"],
                   [("artifactId", artifact), ("api-version", "7.1-preview.1")])
    }

    public static func threads(organization: String, projectId: String, repositoryId: String, pullRequestId: Int) -> URL {
        url("https://dev.azure.com",
            [organization, projectId, "_apis", "git", "repositories", repositoryId, "pullRequests", String(pullRequestId), "threads"],
            [("api-version", apiVersion)])
    }

    public static let profile = url("https://app.vssps.visualstudio.com", ["_apis", "profile", "profiles", "me"],
                                    [("api-version", apiVersion)])

    public static func accounts(memberId: String) -> URL {
        url("https://app.vssps.visualstudio.com", ["_apis", "accounts"], [("memberId", memberId), ("api-version", apiVersion)])
    }

    // MARK: Sprints

    /// The teams you're in, across the organization's projects.
    public static func myTeams(organization: String) -> URL {
        url("https://dev.azure.com", [organization, "_apis", "teams"],
            [("$mine", "true"), ("$top", "500"), ("api-version", "7.1-preview.3")])
    }

    /// A team's current sprint.
    public static func currentIteration(team: TeamRef) -> URL {
        url("https://dev.azure.com", [team.organization, team.projectId, team.id, "_apis", "work", "teamsettings", "iterations"],
            [("$timeframe", "current"), ("api-version", apiVersion)])
    }

    /// The work items in a team's sprint, and which tasks are under which story or bug.
    public static func iterationWorkItems(team: TeamRef, iterationId: String) -> URL {
        url("https://dev.azure.com",
            [team.organization, team.projectId, team.id, "_apis", "work", "teamsettings", "iterations", iterationId, "workitems"],
            [("api-version", apiVersion)])
    }

    /// Which work item types are tasks on the team's board, and each state's category.
    public static func backlogConfiguration(team: TeamRef) -> URL {
        url("https://dev.azure.com", [team.organization, team.projectId, team.id, "_apis", "work", "backlogconfiguration"],
            [("api-version", apiVersion)])
    }

    /// Up to 200 work items by ID, with the given fields. Ones that were deleted or can't be read are left out.
    public static func workItems(organization: String, ids: [Int], fields: [String] = ADOWorkItem.fieldNames) -> URL {
        url("https://dev.azure.com", [organization, "_apis", "wit", "workitems"], [
            ("ids", ids.map(String.init).joined(separator: ",")), ("fields", fields.joined(separator: ",")),
            ("errorPolicy", "omit"), ("api-version", apiVersion),
        ])
    }

    // MARK: Pipelines

    /// A project's pipelines whose names contain `text`, by name.
    public static func buildDefinitions(organization: String, projectId: String, containing text: String, top: Int = 50) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
        var query: [(String, String)] = []
        if !trimmed.isEmpty { query.append(("name", "*\(trimmed)*")) }
        query += [("queryOrder", "definitionNameAscending"), ("$top", String(top)), ("api-version", apiVersion)]
        return url("https://dev.azure.com", [organization, projectId, "_apis", "build", "definitions"], query)
    }

    /// A project's pipelines with these IDs. Ones it doesn't have are left out.
    public static func buildDefinitions(organization: String, projectId: String, ids: [Int]) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "build", "definitions"],
            [("definitionIds", ids.map(String.init).joined(separator: ",")), ("api-version", apiVersion)])
    }

    /// The latest runs of each of a project's pipelines, newest first, in one request.
    public static func builds(
        organization: String, projectId: String, definitionIds: [Int], branch: String? = nil, perDefinition: Int = 10
    ) -> URL {
        var query: [(String, String)] = [
            ("definitions", definitionIds.sorted().map(String.init).joined(separator: ",")),
            ("maxBuildsPerDefinition", String(perDefinition)), ("queryOrder", "queueTimeDescending"),
        ]
        if let branch { query.append(("branchName", branch.hasPrefix("refs/") ? branch : "refs/heads/\(branch)")) }
        query.append(("api-version", apiVersion))
        return url("https://dev.azure.com", [organization, projectId, "_apis", "build", "builds"], query)
    }

    /// Recent validation runs scoped to one repository and pull request, newest first.
    public static func pullRequestBuilds(_ pr: PullRequest) -> URL {
        url("https://dev.azure.com", [pr.key.organization, pr.projectId, "_apis", "build", "builds"], [
            ("repositoryId", pr.repositoryId), ("repositoryType", "TfsGit"),
            ("branchName", "refs/pull/\(pr.key.number)/merge"), ("queryOrder", "queueTimeDescending"),
            ("maxBuildsPerDefinition", "1"), ("$top", "200"), ("api-version", apiVersion),
        ])
    }

    /// A run's stages, jobs and tasks.
    public static func timeline(organization: String, projectId: String, buildId: Int) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "build", "builds", String(buildId), "timeline"],
            [("api-version", apiVersion)])
    }

    /// A repository branch's runs queued since a time, oldest first: among them, those that build a merge.
    public static func branchBuilds(
        organization: String, projectId: String, repositoryId: String, branch: String, queuedSince: Date, top: Int = 50
    ) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "build", "builds"], [
            ("repositoryId", repositoryId), ("repositoryType", "TfsGit"),
            ("branchName", branch.hasPrefix("refs/") ? branch : "refs/heads/\(branch)"),
            ("minTime", queuedSince.formatted(.iso8601)), ("queryOrder", "queueTimeAscending"), ("$top", String(top)),
            ("api-version", apiVersion),
        ])
    }

    /// The project's runs that other runs started since a time (pipeline-completion and resource triggers), oldest first.
    public static func triggeredBuilds(organization: String, projectId: String, queuedSince: Date, top: Int = 50) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "build", "builds"], [
            ("reasonFilter", "buildCompletion,resourceTrigger"), ("minTime", queuedSince.formatted(.iso8601)),
            ("queryOrder", "queueTimeAscending"), ("$top", String(top)), ("api-version", apiVersion),
        ])
    }

    /// One pipeline, by its ID: a project's name works in place of its ID.
    public static func buildDefinition(organization: String, project: String, id: Int) -> URL {
        url("https://dev.azure.com", [organization, project, "_apis", "build", "definitions", String(id)], [("api-version", apiVersion)])
    }

    /// One run, by its ID.
    public static func build(organization: String, project: String, id: Int) -> URL {
        url("https://dev.azure.com", [organization, project, "_apis", "build", "builds", String(id)], [("api-version", apiVersion)])
    }

    /// The organization's projects, to search for pipelines in.
    public static func projects(organization: String) -> URL {
        url("https://dev.azure.com", [organization, "_apis", "projects"], [("$top", "1000"), ("api-version", apiVersion)])
    }

    // MARK: Web pages

    /// A run's page.
    public static func buildPage(organization: String, project: String, buildId: Int) -> URL {
        url("https://dev.azure.com", [organization, project, "_build", "results"], [("buildId", String(buildId))])
    }

    public static func pullRequestPage(organization: String, project: String, repository: String, id: Int, threadId: Int? = nil) -> URL {
        url("https://dev.azure.com", [organization, project, "_git", repository, "pullrequest", String(id)],
            threadId.map { [("discussionId", String($0))] } ?? [])
    }

    /// The organization's "My pull requests" page.
    public static func myPullRequestsPage(organization: String) -> URL {
        url("https://dev.azure.com", [organization, "_pulls"], [])
    }

    public static func workItemPage(organization: String, project: String, id: Int) -> URL {
        url("https://dev.azure.com", [organization, project, "_workitems", "edit", String(id)], [])
    }

    /// Builds a URL from unencoded path segments and query items, percent-encoding everything that
    /// isn't unreserved, so names with spaces and IDs like `vstfs:///...` travel intact.
    static func url(_ base: String, _ segments: [String], _ query: [(String, String)]) -> URL {
        var string = base
        for segment in segments {
            string += "/" + encode(segment)
        }
        if !query.isEmpty {
            string += "?" + query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid URL: \(string)")
        }
        return url
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~$")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}
