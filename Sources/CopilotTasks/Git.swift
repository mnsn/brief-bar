import BriefBarCore
import Foundation

/// A repository a task's work goes in: its main checkout, and the branch new work starts from.
public struct GitRepository: Sendable, Equatable {
    public var root: URL
    /// Such as `main`: the branch `origin/HEAD` points at.
    public var baseBranch: String

    public init(root: URL, baseBranch: String) {
        self.root = root
        self.baseBranch = baseBranch
    }

    public var name: String { root.lastPathComponent }
}

public enum GitError: Error, Sendable, Equatable, CustomStringConvertible {
    case notARepository(String)
    case noOrigin(String)
    case failed(String)

    public var description: String {
        switch self {
        case .notARepository(let folder): return "\(folder) isn't a git repository."
        case .noOrigin(let name): return "\(name) has no origin remote to start the work from."
        case .failed(let message): return message
        }
    }
}

/// The git commands a task needs, run with your environment, so credential helpers and Git LFS work as they do in
/// Terminal.
public struct Git: Sendable {
    public var executable: URL
    public var environment: [String: String]?
    let runner: any ProcessRunning

    public init(executable: URL, environment: [String: String]?, runner: any ProcessRunning = ProcessRunner()) {
        self.executable = executable
        self.environment = environment
        self.runner = runner
    }

    /// The repository a folder is in, and the branch its work starts from.
    public func repository(at folder: URL) async throws -> GitRepository {
        guard let root = try? await run(["-C", folder.path, "rev-parse", "--show-toplevel"], timeout: 30), !root.isEmpty else {
            throw GitError.notARepository(folder.path)
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        return GitRepository(root: rootURL, baseBranch: try await baseBranch(of: rootURL))
    }

    /// Where `origin/HEAD` points, or `origin/main` or `origin/master` if it isn't set.
    func baseBranch(of root: URL) async throws -> String {
        if let head = try? await run(["-C", root.path, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], timeout: 30),
           head.hasPrefix("origin/"), head.count > "origin/".count {
            return String(head.dropFirst("origin/".count))
        }
        for branch in ["main", "master"] {
            if (try? await run(["-C", root.path, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], timeout: 30)) != nil {
                return branch
            }
        }
        throw GitError.noOrigin(root.lastPathComponent)
    }

    /// Brings `origin/<base branch>` up to date, so the work starts from the latest.
    public func fetch(_ repository: GitRepository) async throws {
        _ = try await run(["-C", repository.root.path, "fetch", "--quiet", "--no-tags", "origin", repository.baseBranch], timeout: 300)
    }

    /// A new worktree at `path`, detached at `origin/<base branch>`: Copilot makes the branch, named the repository's way.
    public func addWorktree(of repository: GitRepository, at path: URL) async throws {
        _ = try await run(
            ["-C", repository.root.path, "worktree", "add", "--detach", path.path, "origin/\(repository.baseBranch)"], timeout: 900
        )
    }

    /// Removes a worktree. Without `force`, git keeps one with changes that aren't committed.
    public func removeWorktree(at path: URL, of root: URL, force: Bool = false) async throws {
        _ = try await run(["-C", root.path, "worktree", "remove"] + (force ? ["--force"] : []) + [path.path], timeout: 120)
    }

    /// Its output, trimmed; throws with what git said when it fails.
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        let result = try await runner.run(executable, arguments: arguments, environment: environment, timeout: timeout)
        guard result.status == 0 else {
            throw GitError.failed(Self.message(String(decoding: result.stderr, as: UTF8.self)))
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// git's own words, its `fatal:` or `error:` line if it has one.
    static func message(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.last ?? "git failed."
        let text = line.replacingOccurrences(of: #"^(fatal|error): "#, with: "", options: .regularExpression)
        return String(text.prefix(300))
    }
}

/// Where tasks' worktrees go.
public enum WorktreeLocation {
    /// Next to the repository, in `copilot-worktrees`, by default.
    public static func defaultFolder(for root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent("copilot-worktrees", isDirectory: true)
    }

    /// `<folder>/<repository>/wi-<id>`, or `wi-<id>-2` and on when that's taken.
    public static func path(in folder: URL, repository: String, workItem: Int, exists: (URL) -> Bool) -> URL {
        let parent = folder.appendingPathComponent(repository, isDirectory: true)
        var candidate = parent.appendingPathComponent("wi-\(workItem)", isDirectory: true)
        var number = 2
        while exists(candidate) {
            candidate = parent.appendingPathComponent("wi-\(workItem)-\(number)", isDirectory: true)
            number += 1
        }
        return candidate
    }
}
