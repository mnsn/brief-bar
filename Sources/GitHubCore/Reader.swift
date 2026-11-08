import Foundation

/// What one read of GitHub found.
public struct GitHubLoad: Sendable, Equatable {
    /// Who the GitHub CLI is signed in as: the first account read, its active one unless that couldn't be read.
    public var login: String
    /// Every account it reads as, the GitHub CLI's active one first: `login` alone, unless it's signed in to more.
    public var logins: [String]
    public var items: [GitHubPRSnapshot]
    /// What GitHub couldn't read, such as an organization's pull requests that need single sign-on.
    public var notice: String?
    /// More pull requests matched than BriefBar reads (`PullRequestQuery.count` of each kind).
    public var moreThanShown: Bool

    public init(login: String, logins: [String]? = nil, items: [GitHubPRSnapshot], notice: String? = nil, moreThanShown: Bool = false) {
        self.login = login
        self.logins = logins ?? [login]
        self.items = items
        self.notice = notice
        self.moreThanShown = moreThanShown
    }

    public var counts: GitHubGroupCounts { GitHubGroupCounts(items) }
}

public enum GitHubReader {
    /// Reads your pull requests from GitHub, in one request; two when GitHub can't answer the order's query.
    /// - Parameter order: while Pull Request Order is on: with what an order needs, when GitHub answers that.
    public static func load(client: GitHubClient, order: Bool = false) async throws -> GitHubLoad {
        let result = try await client.pullRequests(order: order)
        return load(from: result.data, errors: result.errors)
    }

    /// What a query's answer means for the list.
    public static func load(from data: PullRequestQueryData, errors: [GraphQLError] = []) -> GitHubLoad {
        let items = GitHubClassifier.snapshots(
            reviewing: data.reviewing.nodes.map(GitHubPullRequest.init),
            authored: data.authored.nodes.map(GitHubPullRequest.init)
        )
        let moreThanShown = data.reviewing.issueCount > data.reviewing.nodes.count
            || data.authored.issueCount > data.authored.nodes.count
        return GitHubLoad(login: data.viewer.login, items: items, notice: notice(for: errors), moreThanShown: moreThanShown)
    }

    /// Errors GitHub answered with alongside what it could read.
    static func notice(for errors: [GraphQLError]) -> String? {
        guard let first = errors.first else { return nil }
        if errors.contains(where: { $0.message.localizedCaseInsensitiveContains("SAML") }) {
            return "Some organizations use single sign-on: authorize the GitHub CLI for them to see their pull requests."
        }
        return "Some pull requests couldn't be read: \(first.message.prefix(200))"
    }

    /// What one account gave a read of every account's: what it read; or, when it couldn't, why, with what its last read
    /// found, unless it takes signing in again to read it.
    public struct AccountRead: Sendable, Equatable {
        public var account: GitHubAccount
        public var load: GitHubLoad?
        public var problem: GitHubProblem?

        public init(account: GitHubAccount, load: GitHubLoad?, problem: GitHubProblem? = nil) {
            self.account = account
            self.load = load
            self.problem = problem
        }
    }

    /// The list from every account's read, the active one first: each pull request once, as yours when it's yours as any of
    /// them, with what GitHub couldn't read as each, and which accounts couldn't be read, and why. A single account's is
    /// its own read, as BriefBar read before more were.
    /// - Parameter shown: the problem the list shows, when no account could be read: an account that couldn't be read for
    ///   what it says isn't named again.
    public static func merge(_ reads: [AccountRead], besides shown: GitHubProblem? = nil) -> GitHubLoad {
        if reads.count == 1, let only = reads.first, only.problem == nil, let load = only.load { return load }
        let named = reads.count > 1
        var logins: [String] = []
        var loads: [GitHubLoad] = []
        var notices: [String] = []
        for var read in reads {
            let login = read.load?.login ?? read.account.login
            if !login.isEmpty {
                // Two accounts that turn out to be one, as when the active one's token is another's: in the first one's
                // place, the one read just now, rather than what was read last of one that couldn't be.
                guard !logins.contains(login) else { continue }
                logins.append(login)
                if read.problem != nil, let current = reads.first(where: { $0.problem == nil && $0.load?.login == login }) {
                    read = current
                }
            }
            if let load = read.load {
                loads.append(load)
                if let notice = load.notice { notices.append(named ? "\(login.isEmpty ? "Its active account" : login): \(notice)" : notice) }
            }
            if let problem = read.problem, problem.message != shown?.message {
                let whose = login.isEmpty ? "the GitHub CLI's active account's" : "\(login)'s"
                notices.append(problem.needsSignIn
                    ? "Sign in to the GitHub CLI again to see \(whose) pull requests."
                    : "Couldn't read \(whose) pull requests: \(problem.message)")
            }
        }
        return GitHubLoad(
            login: logins.first ?? "", logins: logins, items: GitHubClassifier.merged(loads.map(\.items)),
            notice: notices.isEmpty ? nil : notices.joined(separator: "\n"), moreThanShown: loads.contains(where: \.moreThanShown)
        )
    }
}

/// Reads the pull requests of every account the GitHub CLI is signed in to on github.com: one request each, at the same
/// time, each with its own token, and its own wait when GitHub asks BriefBar to slow down. The list has each pull request
/// once, as yours when it's yours as any of them. When some accounts can't be read and others can, it says which and
/// why, beside the others' pull requests and what it last read of those it couldn't, unless they need you to sign in
/// again; when none can be read, it fails as the first one did, the GitHub CLI's active account, unless that needs you to
/// sign in again and another doesn't, with what's left of the list when there's more than one (`Failure`).
public actor GitHubAccountsReader {
    /// No account could be read, of more than one, or of one left of more, and some not for a sign-in: why the first of
    /// those couldn't, which the list says is wrong, with what's left of the list, as when only some can't be read. Its
    /// problem never takes signing in again, so the list it comes with isn't one to hide.
    public struct Failure: Error {
        /// Why the first account that doesn't need signing in again couldn't be read: the GitHub CLI's active one, unless
        /// that one does.
        public var error: any Error
        /// What each account last read, unless it takes signing in to it again, with why each of the others couldn't be
        /// read, unless it's what `error` says.
        public var load: GitHubLoad
        /// Until when GitHub asked BriefBar to slow down as every account: the soonest of those times. Nil when it didn't ask
        /// that of each, so that the others can be read sooner.
        public var waitsUntil: Date?

        public init(error: any Error, load: GitHubLoad, waitsUntil: Date? = nil) {
            self.error = error
            self.load = load
            self.waitsUntil = waitsUntil
        }
    }

    private let accounts: GitHubCLIAccounts
    private let makeClient: @Sendable (GitHubAccount) -> GitHubClient
    /// Each account's client, by its key (`key(of:)`), while the GitHub CLI lists it.
    private var clients: [String: GitHubClient] = [:]
    /// What each account's last read found, by its key, for when the next one can't read it.
    private var last: [String: GitHubLoad] = [:]
    /// How many accounts the last read listed.
    private var accountsRead = 0

    public init(
        accounts: GitHubCLIAccounts = GitHubCLIAccounts(),
        makeClient: @escaping @Sendable (GitHubAccount) -> GitHubClient = GitHubAccountsReader.client(for:)
    ) {
        self.accounts = accounts
        self.makeClient = makeClient
    }

    /// A client that reads as `account`, with the GitHub CLI's token for it.
    public static func client(for account: GitHubAccount) -> GitHubClient {
        GitHubClient(tokens: GitHubCLITokenProvider(user: account.tokenUser))
    }

    /// Lists the GitHub CLI's accounts again at the next read, rather than once the list is half an hour old.
    public func listAgain() async {
        await accounts.invalidate()
    }

    /// The `gh` executable, once it has looked for it.
    public var executablePath: String? {
        get async { await accounts.executablePath }
    }

    /// Reads the pull requests of every account, in one request each.
    /// - Parameter order: while Pull Request Order is on: with what an order needs, when GitHub answers that.
    public func load(order: Bool = false) async throws -> GitHubLoad {
        let listed = try await accounts.accounts()
        let keys = Set(listed.map(Self.key(of:)))
        clients = clients.filter { keys.contains($0.key) }
        last = last.filter { keys.contains($0.key) }
        let reading = listed.map { client(for: $0) }
        let results = await withTaskGroup(of: (Int, Result<GitHubLoad, any Error>).self) { group in
            for (index, client) in reading.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await GitHubReader.load(client: client, order: order)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Result<GitHubLoad, any Error>](repeating: .failure(CancellationError()), count: reading.count)
            for await (index, result) in group {
                results[index] = result
            }
            return results
        }
        // Given up, as when GitHub is turned off: what was read goes nowhere.
        try Task.checkCancellation()
        let readMore = accountsRead > 1
        accountsRead = listed.count
        var reads: [GitHubReader.AccountRead] = []
        var errors: [any Error] = []
        for (account, result) in zip(listed, results) {
            let key = Self.key(of: account)
            switch result {
            case .success(let load):
                last[key] = load
                reads.append(.init(account: account, load: load))
            case .failure(let error):
                if error is CancellationError { throw error }
                errors.append(error)
                let problem = GitHubProblem.from(error)
                if problem.needsSignIn { last[key] = nil }
                // The GitHub CLI has no token for it anymore: it may have been signed out of it, so list them again.
                if case .auth(.signedOut)? = error as? GitHubError { await accounts.invalidate() }
                reads.append(.init(account: account, load: last[key], problem: problem))
            }
        }
        if errors.count == reads.count, let first = errors.first {
            // What's wrong with the list is the first account's reason, the GitHub CLI's active one's, unless it takes signing
            // in again: then the next one's that doesn't, as what that one read last stays, and that one goes in a notice,
            // as when only some couldn't be read. One account, or every one needing signing in again, fails as BriefBar's
            // read did before it read more, and its list goes; but one left of more that the last read listed has what's
            // left go with it, so that the others' pull requests go.
            guard reads.count > 1 || readMore, let shown = reads.firstIndex(where: { $0.problem?.needsSignIn == false }) else {
                throw first
            }
            throw Failure(
                error: errors[shown], load: GitHubReader.merge(reads, besides: reads[shown].problem),
                waitsUntil: Self.waitsUntil(reads.compactMap(\.problem))
            )
        }
        return GitHubReader.merge(reads)
    }

    /// The soonest time GitHub said to wait until, when it said so as each account: until then, none can be read. Nil when
    /// one couldn't be read for another reason, as it may be read again sooner.
    static func waitsUntil(_ problems: [GitHubProblem]) -> Date? {
        var soonest: Date?
        for problem in problems {
            guard case .throttled(let until) = problem else { return nil }
            soonest = min(soonest ?? until, until)
        }
        return soonest
    }

    /// The client for `account`: the one it had while it's listed, so its wait when GitHub asked to slow down holds.
    private func client(for account: GitHubAccount) -> GitHubClient {
        let key = Self.key(of: account)
        if let client = clients[key] { return client }
        let client = makeClient(account)
        clients[key] = client
        return client
    }

    /// What tells accounts apart: the login whose token `gh` gives, or none for the active account's.
    static func key(of account: GitHubAccount) -> String {
        account.tokenUser ?? ""
    }
}
