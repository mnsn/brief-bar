import BriefBarCore
import Foundation
import Synchronization

/// A token for GitHub, from the GitHub CLI's sign-in. It's kept in memory only.
public struct GitHubToken: Sendable, Equatable {
    public var value: String
    /// When BriefBar got it from the CLI. `gh` doesn't say when a token expires (most never do), so BriefBar asks
    /// again after a while, and whenever GitHub rejects it.
    public var fetchedAt: Date

    public init(value: String, fetchedAt: Date) {
        self.value = value
        self.fetchedAt = fetchedAt
    }
}

public enum GitHubAuthError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The GitHub CLI isn't installed, or isn't where BriefBar looks.
    case cliNotFound
    /// Not signed in to github.com: `gh auth login` fixes it.
    case signedOut(String)
    case failed(String)

    public var description: String {
        switch self {
        case .cliNotFound: return "The GitHub CLI (gh) isn't installed."
        case .signedOut(let message): return message.isEmpty ? "Not signed in to the GitHub CLI." : message
        case .failed(let message): return message
        }
    }
}

/// Where tokens come from: the GitHub CLI in the app, and fakes in tests.
public protocol GitHubTokenProviding: Sendable {
    func token() async throws -> GitHubToken
    /// Forgets a token GitHub rejected, so the next call gets a fresh one.
    func invalidate() async
}

/// Gets the token of an account the GitHub CLI signed in to (`gh auth login`), with `gh auth token`: its active
/// account's, or another's, by its login. It never asks for a personal access token, and never stores the token: it
/// keeps it in memory for a while, then asks `gh` again.
public actor GitHubCLITokenProvider: GitHubTokenProviding {
    /// BriefBar reads github.com only, not GitHub Enterprise Server.
    public static let host = "github.com"
    /// How long a token is used before `gh` is asked again, in case you signed in as someone else.
    static let lifetime: TimeInterval = 30 * 60

    /// Whose token it gets: an account's login (`--user`), or nil for the GitHub CLI's active account, whoever that is.
    public nonisolated let user: String?
    private let locator: GitHubCLILocator
    private let runner: any ProcessRunning
    private let now: @Sendable () -> Date
    private var executable: URL?
    private var cached: GitHubToken?
    private var pending: SharedRun?

    public init(
        user: String? = nil, locator: GitHubCLILocator = GitHubCLILocator(), runner: any ProcessRunning = ProcessRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.user = user
        self.locator = locator
        self.runner = runner
        self.now = now
    }

    /// The token, from memory or a run of `gh`. A caller that gives up, as a read does when GitHub is turned off, gets no
    /// token: not from memory, nor from the run it waits for, which stops once no caller waits for it, and keeps nothing.
    public func token() async throws -> GitHubToken {
        try Task.checkCancellation()
        if let cached, now().timeIntervalSince(cached.fetchedAt) < Self.lifetime { return cached }
        // Callers asking at the same time share one `gh` run.
        let run: SharedRun
        if let pending, pending.join() {
            run = pending
        } else {
            run = SharedRun(Task { try await self.fetch() })
            pending = run
        }
        let result = await withTaskCancellationHandler {
            await run.task.result
        } onCancel: {
            run.leave()
        }
        if pending === run { pending = nil }
        try Task.checkCancellation()
        let token = try result.get()
        cached = token
        return token
    }

    public func invalidate() {
        cached = nil
    }

    /// The `gh` executable this provider runs, once it has looked for it.
    public var executablePath: String? { executable?.path }

    private func fetch() async throws -> GitHubToken {
        if executable == nil {
            executable = await locator.locate()
        }
        guard let executable else { throw GitHubAuthError.cliNotFound }
        let result: ProcessResult
        do {
            result = try await runner.run(executable, arguments: Self.arguments(user: user), environment: Self.environment(), timeout: 30)
        } catch let error as CancellationError {
            // Stopped, as no caller waits for it anymore: `gh` is where it was.
            throw error
        } catch {
            // It may have been uninstalled or moved: look again next time.
            self.executable = nil
            throw GitHubAuthError.failed("Couldn't run the GitHub CLI: \(error.localizedDescription)")
        }
        guard result.status == 0 else {
            throw Self.error(fromOutput: String(decoding: result.stderr, as: UTF8.self))
        }
        return try Self.parseToken(result.stdout, now: now())
    }

    /// What `gh` runs with: `gh auth token` for github.com, and the account whose token it prints, unless that's the active
    /// one.
    static func arguments(user: String?) -> [String] {
        ["auth", "token", "--hostname", host] + (user.map { ["--user", $0] } ?? [])
    }

    /// A run of `gh` that callers asking at the same time share. Each caller that gives up leaves it, and the last to
    /// leave stops it.
    private final class SharedRun: Sendable {
        private struct Callers {
            var waiting = 1
            var stopped = false
        }

        let task: Task<GitHubToken, Error>
        private let callers = Mutex(Callers())

        /// Waited for by the caller that starts it.
        init(_ task: Task<GitHubToken, Error>) {
            self.task = task
        }

        /// Another caller waits for it too, unless it's stopped.
        func join() -> Bool {
            callers.withLock { callers in
                guard !callers.stopped else { return false }
                callers.waiting += 1
                return true
            }
        }

        /// A caller gave up: once none waits for it, it stops.
        func leave() {
            let isLast = callers.withLock { callers in
                callers.waiting -= 1
                callers.stopped = callers.waiting == 0
                return callers.stopped
            }
            if isLast { task.cancel() }
        }
    }

    /// A Mac app doesn't get the shell's PATH, so add the usual places; and keep `gh` from prompting, checking for
    /// updates or coloring what it prints.
    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let usual = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (path + usual.filter { !path.contains($0) }).joined(separator: ":")
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_SPINNER_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// Reads what `gh auth token` prints: the token, on a line of its own.
    static func parseToken(_ data: Data, now: Date) throws -> GitHubToken {
        let token = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let token, !token.contains(where: \.isWhitespace) else {
            throw GitHubAuthError.failed("The GitHub CLI returned no token.")
        }
        return GitHubToken(value: token, fetchedAt: now)
    }

    /// Tells a missing sign-in, which `gh auth login` fixes, from other failures.
    static func error(fromOutput output: String) -> GitHubAuthError {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let message = String((lines.first ?? "The GitHub CLI failed.").prefix(300))
        let lower = output.lowercased()
        // `gh auth token` arrived in GitHub CLI 2.17.
        if lower.contains("unknown command") || lower.contains("unknown flag") {
            return .failed("This GitHub CLI is too old for BriefBar: update it to version 2.17 or later.")
        }
        let signedOutHints = ["gh auth login", "no oauth token", "not logged in", "not logged into", "authentication required"]
        if signedOutHints.contains(where: lower.contains) {
            return .signedOut(message)
        }
        return .failed(message)
    }
}

/// An account the GitHub CLI is signed in to on github.com.
public struct GitHubAccount: Sendable, Hashable {
    /// Its login; empty when the GitHub CLI doesn't know whose its token is.
    public var login: String
    /// The account `gh` uses unless it's told another: `gh auth switch` changes which.
    public var isActive: Bool
    /// Whether the GitHub CLI keeps its token, in the keychain or its own settings, rather than reading it from an
    /// environment variable such as `GH_TOKEN`: only a token it keeps can be asked for by its login.
    public var isKept: Bool

    public init(login: String, isActive: Bool, isKept: Bool = true) {
        self.login = login
        self.isActive = isActive
        self.isKept = isKept
    }

    /// The GitHub CLI's active account, whoever it is: the only one read when the GitHub CLI can't list its accounts.
    public static let active = GitHubAccount(login: "", isActive: true, isKept: false)

    /// The account to ask `gh auth token` for (`--user`): its login, or nil for the active account's token, when it can't
    /// be asked for by its login.
    public var tokenUser: String? {
        isKept && !login.isEmpty ? login : nil
    }

    /// Logins as a sentence names them: "robin", "robin and kai", "robin, kai and lee".
    public static func names(_ logins: [String]) -> String {
        guard let last = logins.last else { return "" }
        return logins.count == 1 ? last : logins.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Lists the accounts the GitHub CLI is signed in to on github.com, with `gh auth status --json hosts`, which the GitHub
/// CLI has from version 2.81. As it lists them, the GitHub CLI checks each one with GitHub, a request each, so a list is
/// kept for half an hour, as tokens are, unless it's asked to list them again. It never fails: when the GitHub CLI can't
/// list its accounts, as one that isn't installed, is signed out or is older than that can't, the list is its active
/// account alone, as BriefBar read before, and reading that says what's wrong.
public actor GitHubCLIAccounts {
    /// How long a list is used before `gh` is asked again, in case you signed in to another account or out of one.
    static let lifetime = GitHubCLITokenProvider.lifetime
    static let arguments = ["auth", "status", "--json", "hosts", "--hostname", GitHubCLITokenProvider.host]

    private let locator: GitHubCLILocator
    private let runner: any ProcessRunning
    private let now: @Sendable () -> Date
    private var executable: URL?
    /// The list, while it's kept: one the GitHub CLI gave, or the active account alone from one too old to give it.
    private var listed: (accounts: [GitHubAccount], at: Date)?
    /// The login of the account the GitHub CLI used, as the last list it gave said: one that `gh auth switch` can make
    /// active again. Nil when that list had none.
    public private(set) var activeLogin: String?

    public init(
        locator: GitHubCLILocator = GitHubCLILocator(), runner: any ProcessRunning = ProcessRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.runner = runner
        self.now = now
    }

    /// The accounts, the active one first, from memory or a run of `gh`.
    public func accounts() async throws -> [GitHubAccount] {
        try Task.checkCancellation()
        if let listed, now().timeIntervalSince(listed.at) < Self.lifetime { return listed.accounts }
        let (accounts, keeps) = try await list()
        try Task.checkCancellation()
        listed = keeps ? (accounts, now()) : nil
        if keeps, accounts != [.active] {
            activeLogin = accounts.first { $0.isActive }?.tokenUser
        }
        return accounts
    }

    /// Forgets the list, so the next call lists the accounts again.
    public func invalidate() {
        listed = nil
    }

    /// The `gh` executable this lists the accounts with, once it has looked for it.
    public var executablePath: String? { executable?.path }

    private func list() async throws -> (accounts: [GitHubAccount], keeps: Bool) {
        if executable == nil {
            executable = await locator.locate()
        }
        guard let executable else { return ([.active], false) }
        let result: ProcessResult
        do {
            result = try await runner.run(
                executable, arguments: Self.arguments, environment: GitHubCLITokenProvider.environment(), timeout: 30
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            // It may have been uninstalled or moved: look again next time.
            self.executable = nil
            return ([.active], false)
        }
        return Self.accounts(from: result)
    }

    /// What `gh auth status --json hosts` printed: github.com's accounts, each once, the active one first, and whether to
    /// keep them. Not when it printed none, as a signed-out GitHub CLI does, or couldn't say: until it does, the active
    /// account is read, and reading it says what's wrong. A GitHub CLI too old to list them (`unknown flag`) has its active
    /// account read until it's updated.
    static func accounts(from result: ProcessResult) -> (accounts: [GitHubAccount], keeps: Bool) {
        guard result.status == 0 else {
            return ([.active], String(decoding: result.stderr, as: UTF8.self).lowercased().contains("unknown flag"))
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: result.stdout) else { return ([.active], false) }
        let entries = (status.hosts[GitHubCLITokenProvider.host] ?? []).compactMap(\.value)
        var seen = Set<String>()
        // Two entries for one login, as when GH_TOKEN holds a token of an account the GitHub CLI keeps too: the first.
        let accounts = (entries.filter(\.isActive) + entries.filter { !$0.isActive })
            .map { GitHubAccount(login: $0.login ?? "", isActive: $0.isActive, isKept: !isEnvironmentVariable($0.tokenSource)) }
            .filter { seen.insert($0.login).inserted }
        return accounts.isEmpty ? ([.active], false) : (accounts, true)
    }

    /// Whether the GitHub CLI read a token from an environment variable, which it names, such as `GH_TOKEN`, rather than
    /// from the keychain (`keyring`) or its settings file (a path).
    static func isEnvironmentVariable(_ source: String?) -> Bool {
        guard let source, !source.isEmpty else { return false }
        return source.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }

    /// What `gh auth status --json hosts` prints: each host's accounts, with what BriefBar needs of them.
    struct Status: Decodable {
        struct Entry: Decodable {
            var login: String?
            var active: Bool?
            /// Where its token comes from: `keyring`, the settings file's path, or an environment variable's name.
            var tokenSource: String?

            var isActive: Bool { active ?? false }
        }

        var hosts: [String: [Lossy<Entry>]]
    }
}

/// Finds `gh` without relying on PATH: apps opened from Finder or as login items get only the system's.
public struct GitHubCLILocator: Sendable {
    /// The variable that names another `gh` to use.
    public static let overrideVariable = "BRIEFBAR_GH"

    public var override: String?
    public var candidates: [String]
    /// Ask a login shell (`command -v gh`) when it isn't in a usual place.
    public var useLoginShell: Bool
    public var isExecutable: @Sendable (String) -> Bool
    private let runner: any ProcessRunning

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidates: [String] = GitHubCLILocator.defaultCandidates,
        useLoginShell: Bool = true,
        runner: any ProcessRunning = ProcessRunner(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        override = environment[Self.overrideVariable].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        self.candidates = candidates
        self.useLoginShell = useLoginShell
        self.runner = runner
        self.isExecutable = isExecutable
    }

    public static let defaultCandidates: [String] = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
        "/opt/local/bin/gh",
        UserHome.url.appendingPathComponent(".local/bin/gh").path,
    ]

    public func locate() async -> URL? {
        if let override, isExecutable(override) {
            return URL(fileURLWithPath: override)
        }
        if let found = candidates.first(where: isExecutable) {
            return URL(fileURLWithPath: found)
        }
        guard useLoginShell else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard let result = try? await runner.run(
            URL(fileURLWithPath: shell), arguments: ["-l", "-c", "command -v gh"], environment: nil, timeout: 15
        ), result.status == 0 else { return nil }
        let path = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let path, isExecutable(path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
