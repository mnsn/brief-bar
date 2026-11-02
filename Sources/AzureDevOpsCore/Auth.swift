import BriefBarCore
import Foundation

/// A bearer token for Azure DevOps.
public struct AccessToken: Sendable, Equatable {
    public var value: String
    public var expiresOn: Date
    /// Who it's for, when the token says: a different one means someone else signed in.
    public var account: String?
    /// The directory (a Microsoft Entra tenant's ID, lowercased) it's for, when known: Azure DevOps reads an
    /// organization only with a token from the organization's own directory.
    public var tenant: String?
    /// The directory the account itself is in, when known: for a guest from another directory, that one, or for one
    /// from elsewhere, such as a personal Microsoft account, its identity provider; otherwise the token's own.
    public var accountTenant: String?

    public init(value: String, expiresOn: Date, account: String? = nil, tenant: String? = nil, accountTenant: String? = nil) {
        self.value = value
        self.expiresOn = expiresOn
        self.account = account
        self.tenant = tenant
        self.accountTenant = accountTenant
    }

    /// The tenant and object ID in a Microsoft Entra token (a JWT), read without checking its signature: it
    /// only tells one sign-in from another. Nil for a token that isn't a JWT.
    public static func account(inJWT token: String) -> String? {
        guard let claims = claims(inJWT: token) else { return nil }
        let subject = (claims["oid"] as? String) ?? (claims["sub"] as? String)
        return subject.map { "\(claims["tid"] as? String ?? "")/\($0)".lowercased() }
    }

    /// The directory a Microsoft Entra token (a JWT) is for, lowercased, read without checking its signature. Nil when
    /// it doesn't say.
    public static func tenant(inJWT token: String) -> String? {
        guard let tenant = claims(inJWT: token)?["tid"] as? String, !tenant.isEmpty else { return nil }
        return tenant.lowercased()
    }

    /// The directory a Microsoft Entra token's account is in, lowercased: for a guest from another directory, the one
    /// its `idp` names, such as `https://sts.windows.net/<tenant>/`, or, for one from elsewhere, such as a personal
    /// Microsoft account, its identity provider (`live.com`); otherwise the token's own. Nil when it doesn't say.
    public static func accountTenant(inJWT token: String) -> String? {
        guard let claims = claims(inJWT: token) else { return nil }
        guard let idp = claims["idp"] as? String, !idp.isEmpty else { return tenant(inJWT: token) }
        let directory = idp.split(separator: "/").map(String.init).first(where: { UUID(uuidString: $0) != nil })
        return (directory ?? idp).lowercased()
    }

    /// The directory in an account, as `account(inJWT:)` writes it. Nil when it doesn't say.
    public static func tenant(ofAccount account: String) -> String? {
        guard let slash = account.firstIndex(of: "/"), slash > account.startIndex else { return nil }
        return String(account[..<slash])
    }

    private static func claims(inJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Valid for at least `margin` more seconds.
    public func isValid(at date: Date, margin: TimeInterval = 300) -> Bool {
        expiresOn.timeIntervalSince(date) > margin
    }
}

public enum AuthError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The Azure CLI isn't installed, or isn't where we look.
    case cliNotFound
    /// The sign-in is missing or has expired: `az login` fixes it. With `tenant`, your sign-in's directory wants you to
    /// sign in again while the Azure CLI is still signed in to you in another one: `az login --tenant` with it fixes it.
    case signedOut(String, tenant: String? = nil)
    case failed(String)

    public var description: String {
        switch self {
        case .cliNotFound: return "The Azure CLI (az) isn't installed."
        case .signedOut(let message, _): return message.isEmpty ? "Not signed in to the Azure CLI." : message
        case .failed(let message): return message
        }
    }
}

/// Where tokens come from. BriefBar ships the Azure CLI provider; an MSAL provider can implement
/// this too once there's an app registration (a client ID) to sign in with.
public protocol AccessTokenProvider: Sendable {
    /// A token for your sign-in's directory; with `tenant`, for that directory (a Microsoft Entra tenant's ID), which an
    /// organization in another directory needs.
    func token(tenant: String?) async throws -> AccessToken
    /// Forgets a token the server rejected, so the next call for the same directory gets a fresh one.
    func invalidate(tenant: String?) async
}

extension AccessTokenProvider {
    /// A token for your sign-in's directory.
    public func token() async throws -> AccessToken {
        try await token(tenant: nil)
    }

    /// Forgets the token for your sign-in's directory.
    public func invalidate() async {
        await invalidate(tenant: nil)
    }
}

/// Gets tokens from the Azure CLI's sign-in (`az login`), silently, the way `az` itself does: for your sign-in's
/// directory, and with `--tenant` for each other directory an organization is in.
public actor AzureCLITokenProvider: AccessTokenProvider {
    /// The application ID of Azure DevOps, the resource tokens are requested for.
    public static let azureDevOpsResource = "499b84ac-1321-427f-aa17-267ca6975798"

    private let locator: AzureCLILocator
    private let runner: any ProcessRunning
    private let now: @Sendable () -> Date
    private var executable: URL?
    /// Your sign-in's directory, once known. Tokens for it are asked for there with `--tenant`, rather than in the
    /// Azure CLI's default directory, which signing in to another directory changes: so who BriefBar reads as stays the
    /// same, and so do the organizations it reads in your directory. It follows the default directory only when that's
    /// someone else's.
    private var homeTenant: String?
    /// Whom the last token for your directory was for, and the directory that account is from, which its tokens from
    /// other directories name too: they tell your account from someone else's.
    private var homeAccount: (account: String?, tenant: String?)?
    /// By directory: nil for your sign-in's.
    private var cached: [String?: AccessToken] = [:]
    /// How many times the account your tokens are for has changed: a token fetched across a change is the last account's.
    private var accounts = 0
    /// The `az` run under way for each directory, which everyone asking for it then shares: with the account it was kept for.
    private var pending: [String?: Task<(token: AccessToken, account: Int), Error>] = [:]

    /// `homeTenant` is your sign-in's directory, when it's known from before: the one BriefBar last read your pull
    /// requests with; and `homeAccountTenant` is where that account is from (`AccessToken.accountTenant`), so that after a
    /// restart a sign-in your directory wants again, while the Azure CLI's default is another directory you're a guest in,
    /// isn't taken for someone else's.
    public init(
        homeTenant: String? = nil, homeAccountTenant: String? = nil, locator: AzureCLILocator = AzureCLILocator(),
        runner: any ProcessRunning = ProcessRunner(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.homeTenant = AzureCLITokenProvider.directory(homeTenant)
        if let origin = AzureCLITokenProvider.directory(homeAccountTenant) {
            homeAccount = (account: nil, tenant: origin)
        }
        self.locator = locator
        self.runner = runner
        self.now = now
    }

    public func token(tenant: String?) async throws -> AccessToken {
        let directory = Self.directory(tenant)
        if let cached = cached[directory], cached.isValid(at: now()) { return cached }
        // Callers asking for the same directory at the same time share one `az` run.
        let fetched: (token: AccessToken, account: Int)
        if let pending = pending[directory] {
            fetched = try await pending.value
        } else {
            let task = Task { try await self.fetchAndKeep(directory) }
            pending[directory] = task
            defer { pending[directory] = nil }
            fetched = try await task.value
        }
        // Someone else signed in to the Azure CLI since it was kept: it's the last account's, and nobody waiting gets it.
        guard fetched.account == accounts else { throw AuthError.failed("Someone else signed in to the Azure CLI.") }
        return fetched.token
    }

    public func invalidate(tenant: String?) {
        cached[Self.directory(tenant)] = nil
    }

    /// The `az` executable this provider runs, once it has looked for it.
    public var executablePath: String? { executable?.path }

    /// Where `account` (`AccessToken.account`) is from, while your sign-in's tokens are its: for the app to keep, and give
    /// back after a restart. For an account they aren't, or no longer are, nothing, so one account's is never kept for another.
    public func accountTenant(of account: String) -> String? {
        guard let homeAccount, homeAccount.account == account else { return nil }
        return homeAccount.tenant
    }

    /// Keeps a token until it nears its expiry. One for your directory that's another account's means someone else
    /// signed in to the Azure CLI: the other directories' tokens, the last account's, go, and so do those on their way.
    private func keep(_ token: AccessToken, for directory: String?) {
        if directory == nil {
            if let homeAccount, homeAccount.account != token.account {
                cached = [:]
                if homeAccount.account != nil { accounts += 1 }
            }
            homeAccount = (account: token.account, tenant: token.accountTenant)
        }
        cached[directory] = token
    }

    /// A token for `directory`, kept, with the account it was kept for. One that comes back after someone else signed in may
    /// be the last account's, whichever directory it's for, and one from another directory for an account from elsewhere
    /// than yours means someone else has: nobody gets either, and neither is kept.
    private func fetchAndKeep(_ directory: String?) async throws -> (token: AccessToken, account: Int) {
        let account = accounts
        let token = try await fetch(directory)
        if accounts != account { throw AuthError.failed("Someone else signed in to the Azure CLI.") }
        // Every token kept goes, the last account's, with any on its way: the next one for yours tells who's signed in,
        // and what's read as them starts over.
        if directory != nil, let yours = homeAccount?.tenant, let theirs = token.accountTenant, yours != theirs {
            cached = [:]
            accounts += 1
            throw AuthError.failed("Someone else signed in to the Azure CLI.")
        }
        keep(token, for: directory)
        return (token: token, account: accounts)
    }

    /// A token for `directory`, or for yours: in the directory BriefBar knows as yours. When the Azure CLI can't give one
    /// there, it's someone else's sign-in, if the CLI's default directory has another account: then that directory
    /// becomes yours. If it's your account there, as a guest, your directory only needs you to sign in again, there:
    /// a plain `az login` may sign in to another one without what yours asks for, such as multi-factor authentication.
    private func fetch(_ directory: String?) async throws -> AccessToken {
        if let directory { return try await run(tenant: directory) }
        guard let homeTenant else {
            let token = try await run(tenant: nil)
            self.homeTenant = token.tenant
            return token
        }
        do {
            return try await run(tenant: homeTenant)
        } catch AuthError.signedOut(let message, _) {
            let current = try await run(tenant: nil)
            // The directory your account is from, which a guest token names: the pinned one may be a guest's too.
            let yours = homeAccount?.tenant ?? homeTenant
            if current.tenant != homeTenant, current.accountTenant == yours { throw AuthError.signedOut(message, tenant: homeTenant) }
            if let tenant = current.tenant { self.homeTenant = tenant }
            return current
        }
    }

    private func run(tenant: String?) async throws -> AccessToken {
        if executable == nil {
            executable = await locator.locate()
        }
        guard let executable else { throw AuthError.cliNotFound }
        var arguments = ["account", "get-access-token", "--resource", Self.azureDevOpsResource, "--output", "json"]
        if let tenant {
            arguments += ["--tenant", tenant]
        }
        let result: ProcessResult
        do {
            result = try await runner.run(executable, arguments: arguments, environment: Self.environment(), timeout: 60)
        } catch {
            // It may have been uninstalled or moved: look again next time.
            self.executable = nil
            throw AuthError.failed("Couldn't run the Azure CLI: \(error.localizedDescription)")
        }
        guard result.status == 0 else {
            throw Self.error(fromOutput: String(decoding: result.stderr, as: UTF8.self))
        }
        return try Self.parseToken(result.stdout, now: now())
    }

    /// `az` is a Python program; a Mac app doesn't get the shell's PATH, so add the usual places, and keep
    /// these runs quiet and out of the CLI's telemetry.
    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let usual = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (path + usual.filter { !path.contains($0) }).joined(separator: ":")
        environment["AZURE_CORE_COLLECT_TELEMETRY"] = "false"
        environment["AZURE_CORE_ONLY_SHOW_ERRORS"] = "true"
        environment["AZURE_CORE_NO_COLOR"] = "true"
        return environment
    }

    /// A directory as tokens are kept by: its ID, lowercased; nil for none, which is your sign-in's.
    static func directory(_ tenant: String?) -> String? {
        guard let tenant = tenant?.trimmingCharacters(in: .whitespaces), !tenant.isEmpty else { return nil }
        return tenant.lowercased()
    }

    /// Parses `az account get-access-token --output json`.
    static func parseToken(_ data: Data, now: Date) throws -> AccessToken {
        struct Output: Decodable {
            var accessToken: String
            /// Seconds since 1970, in newer versions of the CLI.
            var expires_on: Double?
            /// Local time, such as `2026-10-21 10:31:46.000000`.
            var expiresOn: String?
            /// The directory it's for.
            var tenant: String?
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data), !output.accessToken.isEmpty else {
            throw AuthError.failed("The Azure CLI returned no token.")
        }
        let expiry = output.expires_on.map { Date(timeIntervalSince1970: $0) }
            ?? output.expiresOn.flatMap(parseLocalTime)
            ?? now.addingTimeInterval(30 * 60)
        return AccessToken(
            value: output.accessToken, expiresOn: expiry, account: AccessToken.account(inJWT: output.accessToken),
            tenant: AccessToken.tenant(inJWT: output.accessToken) ?? directory(output.tenant),
            accountTenant: AccessToken.accountTenant(inJWT: output.accessToken)
        )
    }

    static func parseLocalTime(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    /// Tells a missing or expired sign-in, which `az login` fixes, from other failures. What the Azure CLI says goes to
    /// the log, so it's kept without IDs, such as a directory's in `az login --tenant`, or names (`redacted(_:)`).
    static func error(fromOutput output: String) -> AuthError {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let message = redacted((lines.first { $0.hasPrefix("ERROR:") } ?? lines.first ?? "The Azure CLI failed.")
            .replacingOccurrences(of: "ERROR: ", with: ""))
        let lower = output.lowercased()
        let signedOutHints = [
            "az login", "please run", "aadsts", "interaction_required", "invalid_grant",
            "refresh token", "no subscription", "not logged in", "does not exist in msal token cache",
        ]
        if signedOutHints.contains(where: lower.contains) {
            return .signedOut(String(message.prefix(300)))
        }
        return .failed(String(message.prefix(300)))
    }

    /// What the Azure CLI says, without IDs (a directory's, a request's), email addresses, or the name of a tenant or
    /// directory it quotes: before it's cut short, so no part of one is left.
    static func redacted(_ message: String) -> String {
        message
            .replacingOccurrences(
                of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", with: "<id>",
                options: .regularExpression
            )
            .replacingOccurrences(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", with: "<account>", options: .regularExpression)
            .replacingOccurrences(of: "(?i)\\b(tenant|directory) '[^']*'", with: "$1 '<name>'", options: .regularExpression)
    }
}

/// Finds `az` without relying on PATH: apps opened from Finder or as login items get only the system's.
public struct AzureCLILocator: Sendable {
    public var override: String?
    public var candidates: [String]
    /// Ask a login shell (`command -v az`) when it isn't in a usual place.
    public var useLoginShell: Bool
    public var isExecutable: @Sendable (String) -> Bool
    private let runner: any ProcessRunning

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidates: [String] = AzureCLILocator.defaultCandidates,
        useLoginShell: Bool = true,
        runner: any ProcessRunning = ProcessRunner(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        override = environment["BRIEFBAR_AZ"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        self.candidates = candidates
        self.useLoginShell = useLoginShell
        self.runner = runner
        self.isExecutable = isExecutable
    }

    public static let defaultCandidates: [String] = [
        "/opt/homebrew/bin/az",
        "/usr/local/bin/az",
        "/usr/bin/az",
        "/opt/local/bin/az",
        UserHome.url.appendingPathComponent(".local/bin/az").path,
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
            URL(fileURLWithPath: shell), arguments: ["-l", "-c", "command -v az"], environment: nil, timeout: 15
        ), result.status == 0 else { return nil }
        let path = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let path, isExecutable(path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
