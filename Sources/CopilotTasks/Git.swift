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
    case wrongRepository(String)
    case failed(String)

    public var description: String {
        switch self {
        case .notARepository(let folder): return "\(folder) isn't a git repository."
        case .noOrigin(let name): return "\(name) has no origin remote to start the work from."
        case .wrongRepository(let name): return "This folder's origin isn't \(name). Choose a local clone of that repository."
        case .failed(let message): return message
        }
    }
}

/// What pushing a checkout to a pull request's branch would merge in (`Git.checkPush(in:source:target:)`).
public enum PushCheck: Sendable, Equatable {
    /// No merge, or merges only of what the branch it merges into has.
    case clean
    /// A merge of commits the branch it merges into doesn't have, such as another branch's, as when the pull request was
    /// retargeted after its conflicts were resolved there: the push would bring that branch's work into the pull request.
    case foreignMerge
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

    /// A local clone of the PR's repository, checked without fetching or changing the checkout.
    public func repository(at folder: URL, for pullRequest: TaskPullRequest) async throws -> GitRepository {
        let repository = try await repository(at: folder)
        try await validate(repository, for: pullRequest)
        return repository
    }

    /// Fails unless the folder is in a local clone of the PR's repository, by its origin, whatever branch new work would
    /// start from there, which a check of what it would push doesn't need (`checkPush(in:source:target:)`).
    public func checkClone(at folder: URL, of pullRequest: TaskPullRequest) async throws {
        guard let root = try? await run(["-C", folder.path, "rev-parse", "--show-toplevel"], timeout: 30), !root.isEmpty else {
            throw GitError.notARepository(folder.path)
        }
        try await validate(root: URL(fileURLWithPath: root, isDirectory: true), for: pullRequest)
    }

    func validate(_ repository: GitRepository, for pullRequest: TaskPullRequest) async throws {
        try await validate(root: repository.root, for: pullRequest)
    }

    private func validate(root: URL, for pullRequest: TaskPullRequest) async throws {
        // Read the configured URL, before a credential helper's insteadOf rewrite.
        let remote = try await run(["-C", root.path, "config", "--get", "remote.origin.url"], timeout: 30)
        guard pullRequest.matches(remote: remote) else {
            throw GitError.wrongRepository("\(pullRequest.organization)/\(pullRequest.project)/\(pullRequest.repository)")
        }
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

    /// Brings `origin/<branch>` up to date, such as a pull request's.
    public func fetch(_ repository: GitRepository, branch: String) async throws {
        guard Self.isBranchName(branch) else { throw GitError.failed("“\(branch)” isn't a branch name git takes.") }
        _ = try await run(
            ["-C", repository.root.path, "fetch", "--quiet", "--no-tags", "origin",
             "+refs/heads/\(branch):refs/remotes/origin/\(branch)"],
            timeout: 300
        )
    }

    /// A new worktree at `path`, detached at `origin/<base branch>`: Copilot makes the branch, named the repository's way.
    public func addWorktree(of repository: GitRepository, at path: URL) async throws {
        _ = try await run(
            ["-C", repository.root.path, "worktree", "add", "--detach", path.path, "origin/\(repository.baseBranch)"], timeout: 900
        )
    }

    /// A new worktree at `path`, detached at `origin/<branch>`: a pull request's work is pushed back to its branch from
    /// there, without taking the branch from a checkout that has it.
    public func addWorktree(of repository: GitRepository, at path: URL, branch: String) async throws {
        guard Self.isBranchName(branch) else { throw GitError.failed("“\(branch)” isn't a branch name git takes.") }
        _ = try await run(["-C", repository.root.path, "worktree", "add", "--detach", path.path, "origin/\(branch)"], timeout: 900)
    }

    /// A new worktree at `path`, detached at a commit, such as the one a session's checkout has (`head(of:in:)`).
    public func addWorktree(of repository: GitRepository, at path: URL, commit: String) async throws {
        guard Self.isCommit(commit) else { throw GitError.failed("“\(commit)” isn't a commit's ID.") }
        _ = try await run(["-C", repository.root.path, "worktree", "add", "--detach", path.path, commit], timeout: 900)
    }

    /// The commit a folder's checkout has checked out, when the repository has it too, as each of its worktrees' does:
    /// where a fork of the session that works there starts. Nil when the folder isn't in a checkout, or its commit isn't in
    /// the repository, as a local commit of another clone isn't.
    public func head(of folder: URL, in repository: GitRepository) async -> String? {
        guard let commit = try? await run(["-C", folder.path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"], timeout: 30),
              Self.isCommit(commit),
              (try? await run(["-C", repository.root.path, "cat-file", "-e", "\(commit)^{commit}"], timeout: 30)) != nil
        else { return nil }
        return commit
    }

    /// The commit `origin/<branch>` is at in a folder's checkout, as git there last fetched or pushed it: where a push to the
    /// branch from there starts, once BriefBar fetched it (`checkPush(in:source:target:)`), for `pushedItsOwn(in:branch:since:)`
    /// to tell what it pushed. Nil when it can't be read.
    public func remoteHead(of folder: URL, branch: String) async -> String? {
        guard Self.isBranchName(branch),
              let commit = try? await run(
                  ["-C", folder.path, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)^{commit}"], timeout: 30
              ),
              Self.isCommit(commit)
        else { return nil }
        return commit
    }

    /// Whether a folder's checkout pushed a commit of its own to `branch` since `start`, the commit `origin/<branch>` was at
    /// there as it started (`remoteHead(of:branch:)`): the commit it has checked out is in `origin/<branch>` now, which its
    /// push moves, and wasn't in `start`. The branch is fetched there first, as `checkPush(in:source:target:)` fetches it:
    /// a push moves `origin/<branch>` only when the clone's fetch settings name the branch, which a clone of one branch's
    /// don't; when it can't be fetched, as offline, it goes by what the push moved. False when it isn't: when it committed
    /// nothing, or only fetched and checked out what others pushed, or its push was rejected, or it stopped before it, or
    /// partway through a rebase, a merge, a cherry-pick or a revert, as when one on what others pushed conflicts, which
    /// leaves it at their commit (`stoppedPartway`). Nil when git can't tell, as when the folder isn't a checkout any more.
    public func pushedItsOwn(in folder: URL, branch: String, since start: String) async -> Bool? {
        guard Self.isBranchName(branch), Self.isCommit(start),
              let head = try? await run(["-C", folder.path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"], timeout: 30),
              Self.isCommit(head),
              let partway = await stoppedPartway(folder)
        else { return nil }
        if partway { return false }
        _ = try? await run(
            ["-C", folder.path, "fetch", "--quiet", "--no-tags", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"],
            timeout: 60
        )
        guard let pushed = await isAncestor(head, of: "refs/remotes/origin/\(branch)", in: folder) else { return nil }
        guard pushed else { return false }
        return await isAncestor(head, of: start, in: folder).map { !$0 }
    }

    /// Whether a folder's checkout stopped partway through a rebase, a merge, a cherry-pick or a revert, as git there keeps
    /// it until it's done or called off; nil when git can't tell.
    func stoppedPartway(_ folder: URL) async -> Bool? {
        let names = ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
        guard let paths = try? await run(["-C", folder.path, "rev-parse"] + names.flatMap { ["--git-path", $0] }, timeout: 30) else {
            return nil
        }
        let lines = paths.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == names.count else { return nil }
        return lines.contains { path in
            let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            // There, whatever it is, without following a link.
            return (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil
        }
    }

    /// Whether `commit` is in `other`'s history, `other` included; nil when git can't tell, as when either isn't there.
    private func isAncestor(_ commit: String, of other: String, in folder: URL) async -> Bool? {
        guard let result = try? await runner.run(
            executable, arguments: ["-C", folder.path, "merge-base", "--is-ancestor", commit, other], environment: environment, timeout: 120
        ) else { return nil }
        switch result.status {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    /// Whether pushing a folder's checkout to a pull request's branch, `source`, would merge in only what the branch it
    /// merges into, `target`, has: what every merge it would push, in what `origin/<source>` doesn't have yet, merged in,
    /// and what a merge still going on merges in, has to be in `origin/<target>`. A merge of the pull request's own branch,
    /// as `git pull` makes, doesn't pass either: from history alone it can't be told from one of the pull request's branch
    /// into another, which would push that other branch's work. Both branches are fetched first, so it goes by where they
    /// are now. Commits made on the branch, merges aside, are the work to push. Throws when it can't tell: as when what it
    /// would push has a commit without parents, as where a shallow clone's history stops, which hides whether it's a merge;
    /// or a merge is going on that it can't read (`mergingIn`).
    public func checkPush(in folder: URL, source: String, target: String) async throws -> PushCheck {
        guard !target.isEmpty else { throw GitError.failed("BriefBar doesn't know which branch the pull request merges into.") }
        for branch in [source, target] where !Self.isBranchName(branch) {
            throw GitError.failed("“\(branch)” isn't a branch name git takes.")
        }
        let sourceRef = "refs/remotes/origin/\(source)"
        let targetRef = "refs/remotes/origin/\(target)"
        _ = try await run(
            ["-C", folder.path, "fetch", "--quiet", "--no-tags", "origin",
             "+refs/heads/\(source):\(sourceRef)", "+refs/heads/\(target):\(targetRef)"],
            timeout: 300
        )
        // A commit without parents: where a shallow clone's history stops, which git takes for a root, though it may be a
        // merge, of anything; or the start of history the branch doesn't come from.
        let parentless = try await run(
            ["-C", folder.path, "rev-list", "--max-parents=0", "--max-count=1", "HEAD", "^\(sourceRef)", "^\(targetRef)", "--"], timeout: 120
        )
        guard parentless.isEmpty else { throw GitError.failed(Self.cutShort) }
        // Each merge with its parents: the first is the branch it merged into, the others what it merged in. One the target
        // has merged in only what the target has.
        let merges = try await run(
            ["-C", folder.path, "rev-list", "--merges", "--parents", "HEAD", "^\(sourceRef)", "^\(targetRef)", "--"], timeout: 120
        )
        let mergedIn = merges.split(whereSeparator: \.isNewline).flatMap { $0.split(separator: " ").dropFirst(2).map(String.init) }
        var seen = Set<String>()
        let commits = (mergedIn + (try await mergingIn(folder))).filter { Self.isCommit($0) && seen.insert($0).inserted }
        // A few hundred at a time, however long the history it would push: any of them the target doesn't have.
        for start in stride(from: 0, to: commits.count, by: 200) {
            let outside = try await run(
                ["-C", folder.path, "rev-list", "--max-count=1"] + commits[start..<min(start + 200, commits.count)] + ["^\(targetRef)", "--"],
                timeout: 120
            )
            if !outside.isEmpty { return .foreignMerge }
        }
        return .clean
    }

    /// Why `checkPush` can't tell what a commit without parents brings in.
    static let cutShort = "What it would push has a commit without parents, as where a shallow clone's history stops, so BriefBar can't tell what that commit brings in. If it's a shallow clone, fetch the rest of its history first: git fetch --unshallow."

    /// Why `checkPush` can't tell what a merge going on brings in.
    static let unreadableMerge = "A merge is going on in it, and BriefBar couldn't read what it merges in."

    /// What a merge still going on in a folder's checkout merges in, as its `MERGE_HEAD` lists it: nothing when there's
    /// none. Throws when one may be going on that BriefBar can't read: a `MERGE_HEAD` that isn't a file it can read, such as
    /// a link, which it doesn't follow, or that lists anything but commits.
    func mergingIn(_ folder: URL) async throws -> [String] {
        let path = try await run(["-C", folder.path, "rev-parse", "--git-path", "MERGE_HEAD"], timeout: 30)
        let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
        guard let data = LocalFile.tail(of: file, maxBytes: 64 * 1024) else {
            // Nothing there, not even a link: no merge is going on.
            guard (try? FileManager.default.attributesOfItem(atPath: file.path)) == nil else { throw GitError.failed(Self.unreadableMerge) }
            return []
        }
        let commits = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !commits.isEmpty, commits.allSatisfy(Self.isCommit) else { throw GitError.failed(Self.unreadableMerge) }
        return commits
    }

    /// A commit's full ID, as git writes it: 40 hexadecimal digits, or 64 in a SHA-256 repository.
    static func isCommit(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// A branch's name as a pull request reports it: nothing git would read as an option or a range.
    static func isBranchName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.contains("..") && !name.contains(where: { $0.isWhitespace || $0 == ":" })
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
        path(in: folder, repository: repository, name: "wi-\(workItem)", exists: exists)
    }

    /// `<folder>/<repository>/<name>`, or `<name>-2` and on when that's taken.
    public static func path(in folder: URL, repository: String, name: String, exists: (URL) -> Bool) -> URL {
        let parent = folder.appendingPathComponent(repository, isDirectory: true)
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var number = 2
        while exists(candidate) {
            candidate = parent.appendingPathComponent("\(name)-\(number)", isDirectory: true)
            number += 1
        }
        return candidate
    }
}
