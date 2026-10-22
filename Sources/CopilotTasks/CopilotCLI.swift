import BriefBarCore
import Foundation

/// The environment your login shell sets up, such as a PATH with Homebrew, .NET and Node in it. Copilot, and the
/// commands it runs, need it, and an app started from Finder or at login doesn't get it. Like VS Code, BriefBar asks
/// an interactive login shell, which reads the same files a Terminal window does.
public enum LoginEnvironment {
    /// Comes before the environment in the shell's output, so whatever its startup files print is left out.
    static let marker = "BRIEFBAR-ENVIRONMENT"

    /// - Parameter base: what the shell starts from; by default BriefBar's own (`base(_:attribution:)`).
    public static func load(
        runner: any ProcessRunning = ProcessRunner(), base: [String: String] = base()
    ) async -> [String: String] {
        let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let command = "printf '\\0\(marker)\\0'; /usr/bin/env -0"
        guard let result = try? await runner.run(
            URL(fileURLWithPath: shell), arguments: ["-i", "-l", "-c", command], environment: base, timeout: 20
        ), result.status == 0, let environment = parse(result.stdout), environment["PATH"] != nil else {
            return fallback(base)
        }
        return environment
    }

    /// BriefBar's own environment, for the shell to start from. Started as an app, BriefBar got it from whoever started
    /// it (`Attribution`), so the variables that steer Copilot, such as COPILOT_HOME, which says where its sessions and
    /// trusted folders are, are left out; your shell's startup files still set them.
    public static func base(
        _ environment: [String: String] = ProcessInfo.processInfo.environment, attribution: Attribution = .current
    ) -> [String: String] {
        attribution == .caller ? environment : environment.filter { !$0.key.hasPrefix("COPILOT_") }
    }

    /// The variables after the marker, each `NAME=value` and ended by a NUL.
    static func parse(_ output: Data) -> [String: String]? {
        let fields = output.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard let start = fields.lastIndex(of: marker) else { return nil }
        var environment: [String: String] = [:]
        for field in fields[(start + 1)...] {
            guard let equals = field.firstIndex(of: "="), equals != field.startIndex else { continue }
            environment[String(field[..<equals])] = String(field[field.index(after: equals)...])
        }
        return environment.isEmpty ? nil : environment
    }

    /// BriefBar's own, with the usual places added to PATH, when the shell can't say.
    static func fallback(_ base: [String: String]) -> [String: String] {
        var environment = base
        let path = (base["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let usual = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (path + usual.filter { !path.contains($0) }).joined(separator: ":")
        return environment
    }

    /// Where a program is on the environment's PATH, as the shell would find it.
    public static func which(
        _ name: String, in environment: [String: String], home: URL = UserHome.url,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = (UserPath.expand(String(directory), home: home) as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}

/// Paths that start with `~`, in your home folder as the user database names it (`UserHome`), never FileManager's or
/// `NSHomeDirectory`, which whoever starts BriefBar can move.
public enum UserPath {
    /// `~` and `~/…` in your home folder; any other path as it is.
    public static func expand(_ path: String, home: URL = UserHome.url) -> String {
        guard path.first == "~", path.count == 1 || path.dropFirst().first == "/" else { return path }
        return home.path + path.dropFirst()
    }

    /// A path in your home folder with `~` for it, to show.
    public static func abbreviate(_ path: String, home: URL = UserHome.url) -> String {
        path == home.path ? "~" : path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }
}

/// Finds the Copilot CLI, and reads what of its settings a run depends on.
public enum CopilotCLI {
    /// Points BriefBar at another `copilot`, from the command line only (see `Attribution.environment`).
    public static let overrideVariable = "BRIEFBAR_COPILOT_CLI"

    /// `copilot`: the one the override names, the one on your PATH, one in the usual places, or the newest one the
    /// GitHub Copilot app keeps for itself.
    public static func locate(
        environment: [String: String], overrides: [String: String] = Attribution.environment, home: URL = UserHome.url,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        appVersions: (URL) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
    ) -> URL? {
        if let override = overrides[overrideVariable].flatMap({ $0.isEmpty ? nil : UserPath.expand($0, home: home) }),
           isExecutable(override) {
            return URL(fileURLWithPath: override)
        }
        if let found = LoginEnvironment.which("copilot", in: environment, home: home, isExecutable: isExecutable) {
            return found
        }
        let usual = ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot", home.appendingPathComponent(".local/bin/copilot").path]
        if let found = usual.first(where: isExecutable) {
            return URL(fileURLWithPath: found)
        }
        let appCLIs = home.appendingPathComponent("Library/Caches/github-copilot-sdk/cli", isDirectory: true)
        return appVersions(appCLIs)
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { appCLIs.appendingPathComponent($0).appendingPathComponent("copilot") }
            .first { isExecutable($0.path) }
    }

    /// Where the CLI keeps its settings and sessions: COPILOT_HOME, or ~/.copilot.
    public static func home(environment: [String: String], userHome: URL = UserHome.url) -> URL {
        if let home = environment["COPILOT_HOME"].flatMap({ $0.isEmpty ? nil : UserPath.expand($0, home: userHome) }) {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return userHome.appendingPathComponent(".copilot", isDirectory: true)
    }

    /// The folders you've trusted Copilot with (`trustedFolders` in its config.json), whose skills, MCP servers and hooks
    /// it loads. Its config allows comments.
    public static func trustedFolders(config: Data) -> [String] {
        let text = String(decoding: config, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        return (object["trustedFolders"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// Whether a folder is one of them, or inside one.
    public static func isTrusted(_ folder: URL, trusted: [String], home: URL = UserHome.url) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return trusted.contains { entry in
            let root = URL(fileURLWithPath: UserPath.expand(entry, home: home)).standardizedFileURL.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }
}
