import BriefBarCore
import Foundation

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

/// Gets the token that the GitHub CLI signed in with (`gh auth login`), with `gh auth token`. It never asks for a
/// personal access token, and never stores the token: it keeps it in memory for a while, then asks `gh` again.
public actor GitHubCLITokenProvider: GitHubTokenProviding {
    /// BriefBar reads github.com only, not GitHub Enterprise Server.
    public static let host = "github.com"
    /// How long a token is used before `gh` is asked again, in case you signed in as someone else.
    static let lifetime: TimeInterval = 30 * 60

    private let locator: GitHubCLILocator
    private let runner: any ProcessRunning
    private let now: @Sendable () -> Date
    private var executable: URL?
    private var cached: GitHubToken?
    private var pending: Task<GitHubToken, Error>?

    public init(
        locator: GitHubCLILocator = GitHubCLILocator(), runner: any ProcessRunning = ProcessRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.runner = runner
        self.now = now
    }

    public func token() async throws -> GitHubToken {
        if let cached, now().timeIntervalSince(cached.fetchedAt) < Self.lifetime { return cached }
        // Callers asking at the same time share one `gh` run.
        if let pending { return try await pending.value }
        let task = Task { try await self.fetch() }
        pending = task
        defer { pending = nil }
        let token = try await task.value
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
            result = try await runner.run(
                executable, arguments: ["auth", "token", "--hostname", Self.host], environment: Self.environment(), timeout: 30
            )
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
