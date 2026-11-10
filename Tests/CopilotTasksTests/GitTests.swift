import BriefBarCore
import Foundation
import Testing
@testable import CopilotTasks

@Suite struct GitTests {
    @Test func saysWhatGitSaid() {
        #expect(Git.message("hint: something\nfatal: 'origin' does not appear to be a git repository\n") == "'origin' does not appear to be a git repository")
        #expect(Git.message("error: pathspec 'x' did not match\n") == "pathspec 'x' did not match")
        #expect(Git.message("") == "git failed.")
    }

    /// Without origin/HEAD, origin's main or master.
    @Test func findsTheBaseBranchWithoutOriginHead() async throws {
        let runner = FakeRunner { arguments in
            if arguments.contains("symbolic-ref") { return .failure("", status: 1) }
            return arguments.last == "refs/remotes/origin/master" ? .ok("abc123") : .failure("", status: 1)
        }
        let git = Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: nil, runner: runner)
        #expect(try await git.baseBranch(of: URL(fileURLWithPath: "/repo")) == "master")

        let none = Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: nil, runner: FakeRunner { _ in .failure("", status: 1) })
        await #expect(throws: GitError.noOrigin("repo")) { try await none.baseBranch(of: URL(fileURLWithPath: "/repo")) }
    }

    @Test func refusesAFolderThatIsntARepository() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let git = Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: ["PATH": "/usr/bin:/bin", "HOME": folder.path])
        await #expect(throws: GitError.notARepository(folder.path)) { try await git.repository(at: folder) }
    }

    /// A worktree of a real repository, from a folder inside its checkout: detached at the latest origin/main, and gone
    /// once removed.
    @Test(.timeLimit(.minutes(5)))
    func makesADetachedWorktreeAtTheLatestBaseBranch() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        let git = Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: fixture.environment)
        let subfolder = fixture.checkout.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        let repository = try await git.repository(at: subfolder)
        #expect(repository.root.path == fixture.checkout.path)
        #expect(repository.baseBranch == "main")
        #expect(repository.name == "checkout")

        try await git.fetch(repository)
        let worktree = fixture.folder.appendingPathComponent("copilot-worktrees/checkout/wi-4217")
        try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git.addWorktree(of: repository, at: worktree)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("README.md").path))
        let head = try await git.run(["-C", worktree.path, "rev-parse", "HEAD"], timeout: 30)
        let base = try await git.run(["-C", fixture.checkout.path, "rev-parse", "origin/main"], timeout: 30)
        #expect(head == base)
        await #expect(throws: GitError.self) { try await git.run(["-C", worktree.path, "symbolic-ref", "-q", "HEAD"], timeout: 30) }

        try await git.removeWorktree(at: worktree, of: repository.root)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    // MARK: What Push & Reply would push

    private static let source = "users/robin/fix-total"
    private static let identity = ["-c", "user.name=Robin Diaz", "-c", "user.email=robin@example.com"]

    /// origin with release/x and the pull request's branch started from the first commit, the branch one commit further and
    /// main another; and the checkout detached at the branch, as a session's checkout of the pull request is.
    private func retargetable() async throws -> (RepositoryFixture, Git) {
        let fixture = try await RepositoryFixture()
        let seed = fixture.folder.appendingPathComponent("seed")
        try await fixture.git(["-C", seed.path, "branch", "release/x"])
        try await fixture.git(["-C", seed.path, "checkout", "--quiet", "-b", Self.source])
        try await commit("Totals", to: "totals.txt", in: seed, fixture)
        try await fixture.git(["-C", seed.path, "checkout", "--quiet", "main"])
        try await commit("Main's work", to: "main.txt", in: seed, fixture)
        try await fixture.git(["-C", seed.path, "push", "--quiet", fixture.origin.path, "main", "release/x", Self.source])
        try await fixture.git(["-C", fixture.checkout.path, "fetch", "--quiet", "origin"])
        try await fixture.git(["-C", fixture.checkout.path, "checkout", "--quiet", "--detach", "origin/\(Self.source)"])
        return (fixture, Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: fixture.environment))
    }

    private func commit(_ text: String, to file: String, in folder: URL, _ fixture: RepositoryFixture) async throws {
        try "\(text)\n".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try await fixture.git(["-C", folder.path, "add", file])
        try await fixture.git(["-C", folder.path] + Self.identity + ["commit", "--quiet", "-m", text])
    }

    /// Commits of its own, merges aside, are the work to push, whatever the target.
    @Test(.timeLimit(.minutes(5)))
    func takesTheBranchsOwnCommits() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") == .clean)
        try await commit("The fix", to: "fix.txt", in: fixture.checkout, fixture)
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") == .clean)
    }

    /// Resolved against main, then retargeted to release/x: the merge would bring main's work, which release/x doesn't
    /// have, until it does; as fetched, not as the checkout last saw it.
    @Test(.timeLimit(.minutes(5)))
    func findsAMergeOfWhatTheTargetDoesntHave() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        try await fixture.git(["-C", fixture.checkout.path] + Self.identity + ["merge", "--quiet", "--no-edit", "origin/main"])
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "main") == .clean)
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") == .foreignMerge)

        let seed = fixture.folder.appendingPathComponent("seed")
        try await fixture.git(["-C", seed.path, "push", "--quiet", fixture.origin.path, "main:release/x"])
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") == .clean)
    }

    /// A merge the pull request's branch has already, pushed before, which this push doesn't bring, as git fetches the branch
    /// now, whatever the checkout last saw of it: the commit on top of it is the work to push.
    @Test(.timeLimit(.minutes(5)))
    func takesAMergeTheBranchHasAlready() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        try await fixture.git(["-C", fixture.checkout.path] + Self.identity + ["merge", "--quiet", "--no-edit", "origin/main"])
        // Pushed by its URL, so the checkout's origin/<branch> stays where it was, until checkPush fetches it.
        try await fixture.git(["-C", fixture.checkout.path, "push", "--quiet", fixture.origin.path, "HEAD:refs/heads/\(Self.source)"])
        let merge = try await git.run(["-C", fixture.checkout.path, "rev-parse", "HEAD"], timeout: 30)
        let tracking = ["-C", fixture.checkout.path, "rev-parse", "refs/remotes/origin/\(Self.source)"]
        #expect(try await git.run(tracking, timeout: 30) != merge)
        try await commit("The fix", to: "fix.txt", in: fixture.checkout, fixture)
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") == .clean)
        #expect(try await git.run(tracking, timeout: 30) == merge)
    }

    /// An octopus merge, of release/x's work and main's at once: each branch it merged in has to be in the target, not only
    /// the first.
    @Test(.timeLimit(.minutes(5)))
    func findsAnOctopusMergeOfWhatTheTargetDoesntHave() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        let seed = fixture.folder.appendingPathComponent("seed")
        try await fixture.git(["-C", seed.path, "checkout", "--quiet", "release/x"])
        try await commit("A release fix", to: "release.txt", in: seed, fixture)
        try await fixture.git(["-C", seed.path, "push", "--quiet", fixture.origin.path, "release/x"])
        try await fixture.git(["-C", fixture.checkout.path, "fetch", "--quiet", "origin"])
        try await fixture.git(["-C", fixture.checkout.path] + Self.identity + ["merge", "--quiet", "--no-edit", "origin/release/x", "origin/main"])
        let parents = try await git.run(["-C", fixture.checkout.path, "rev-list", "--parents", "--max-count=1", "HEAD"], timeout: 30)
        #expect(parents.split(separator: " ").count == 4)
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") == .foreignMerge)
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "main") == .foreignMerge)
    }

    /// A merge of the pull request's own branch, whichever way, merges in what the target doesn't have: pulled into the
    /// work, or merged into main's latest, which on a target with no merges of its own looks the same in history, and
    /// would push main's work to the branch.
    @Test(.timeLimit(.minutes(5)))
    func findsAMergeOfThePullRequestsOwnBranch() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        try await fixture.git(["-C", fixture.checkout.path, "checkout", "--quiet", "--detach", "origin/main"])
        try await fixture.git(["-C", fixture.checkout.path] + Self.identity + ["merge", "--quiet", "--no-edit", "origin/\(Self.source)"])
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") == .foreignMerge)

        try await fixture.git(["-C", fixture.checkout.path, "checkout", "--quiet", "--detach", "origin/\(Self.source)"])
        try await commit("The fix", to: "fix.txt", in: fixture.checkout, fixture)
        let seed = fixture.folder.appendingPathComponent("seed")
        try await fixture.git(["-C", seed.path, "checkout", "--quiet", Self.source])
        try await commit("A reviewer's fix", to: "review.txt", in: seed, fixture)
        try await fixture.git(["-C", seed.path, "push", "--quiet", fixture.origin.path, Self.source])
        try await fixture.git(["-C", fixture.checkout.path, "fetch", "--quiet", "origin"])
        try await fixture.git(["-C", fixture.checkout.path] + Self.identity + ["merge", "--quiet", "--no-edit", "origin/\(Self.source)"])
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "main") == .foreignMerge)
        // Rebased, as a push that's rejected is, it's the work alone.
        try await fixture.git(["-C", fixture.checkout.path, "reset", "--quiet", "--hard", "HEAD^1"])
        try await fixture.git(["-C", fixture.checkout.path] + Self.identity + ["rebase", "--quiet", "origin/\(Self.source)"])
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "main") == .clean)
    }

    /// A merge not committed yet, in the checkout, whose `MERGE_HEAD` git names from where it is, and in a worktree of it,
    /// whose `MERGE_HEAD` is in the checkout's `.git`; and none, once it's aborted.
    @Test(.timeLimit(.minutes(5)))
    func findsAMergeStillInProgress() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        let worktree = fixture.folder.appendingPathComponent("worktree")
        try await fixture.git(["-C", fixture.checkout.path, "worktree", "add", "--quiet", "--detach", worktree.path, "origin/\(Self.source)"])
        for folder in [fixture.checkout, worktree] {
            try await fixture.git(["-C", folder.path] + Self.identity + ["merge", "--quiet", "--no-commit", "--no-ff", "origin/main"])
            #expect(try await git.checkPush(in: folder, source: Self.source, target: "release/x") == .foreignMerge)
            #expect(try await git.checkPush(in: folder, source: Self.source, target: "main") == .clean)
            try await fixture.git(["-C", folder.path, "merge", "--abort"])
            #expect(try await git.checkPush(in: folder, source: Self.source, target: "release/x") == .clean)
        }
    }

    /// A merge going on whose `MERGE_HEAD` it can't read, as when it's a link, which it doesn't follow, or lists anything but
    /// commits, may merge in anything: it can't tell, rather than taking it for none. Readable again, it's checked as before.
    @Test(.timeLimit(.minutes(5)))
    func cantTellAMergeGoingOnItCantRead() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        try await fixture.git(["-C", fixture.checkout.path] + Self.identity + ["merge", "--quiet", "--no-commit", "--no-ff", "origin/main"])
        let mergeHead = fixture.checkout.appendingPathComponent(".git/MERGE_HEAD")
        let kept = fixture.checkout.appendingPathComponent(".git/MERGE_HEAD.kept")
        try FileManager.default.moveItem(at: mergeHead, to: kept)
        let cantTell = GitError.failed(Git.unreadableMerge)

        try FileManager.default.createSymbolicLink(atPath: mergeHead.path, withDestinationPath: kept.lastPathComponent)
        await #expect(throws: cantTell) { try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") }
        try FileManager.default.removeItem(at: mergeHead)
        for text in ["", "\n", "origin/main\n"] {
            try Data(text.utf8).write(to: mergeHead)
            await #expect(throws: cantTell) { try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") }
            try FileManager.default.removeItem(at: mergeHead)
        }

        try FileManager.default.moveItem(at: kept, to: mergeHead)
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") == .foreignMerge)
        try await fixture.git(["-C", fixture.checkout.path, "merge", "--abort"])
        #expect(try await git.checkPush(in: fixture.checkout, source: Self.source, target: "release/x") == .clean)
    }

    /// In a shallow clone, where its history stops git takes a commit for a root, though it may be a merge, of anything:
    /// there, it can't tell what that brings in, whichever branch it's checked against. Once the clone has the rest of its
    /// history, it's checked as any other.
    @Test(.timeLimit(.minutes(5)))
    func cantTellWhatAShallowClonesHistoryHides() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        // A branch of the pull request's, with main merged in, which a clone of it alone, one commit deep, has as its root.
        let seed = fixture.folder.appendingPathComponent("seed")
        try await fixture.git(["-C", seed.path, "checkout", "--quiet", "-b", "with-main", Self.source])
        try await fixture.git(["-C", seed.path] + Self.identity + ["merge", "--quiet", "--no-edit", "main"])
        try await fixture.git(["-C", seed.path, "push", "--quiet", fixture.origin.path, "with-main"])
        let shallow = fixture.folder.appendingPathComponent("shallow")
        try await fixture.git(["clone", "--quiet", "--depth=1", "--branch", "with-main", "file://\(fixture.origin.path)", shallow.path])
        let cantTell = GitError.failed(Git.cutShort)

        for target in ["release/x", "main"] {
            await #expect(throws: cantTell) { try await git.checkPush(in: shallow, source: Self.source, target: target) }
        }
        try await fixture.git(["-C", shallow.path, "fetch", "--quiet", "--unshallow", "origin"])
        #expect(try await git.checkPush(in: shallow, source: Self.source, target: "release/x") == .foreignMerge)
        #expect(try await git.checkPush(in: shallow, source: Self.source, target: "main") == .clean)
    }

    /// Nothing runs for a target it doesn't know, or a name git would read as something else.
    @Test func checksOnlyBranchesGitTakes() async throws {
        let runner = FakeRunner { _ in .ok() }
        let git = Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: nil, runner: runner)
        let folder = URL(fileURLWithPath: "/repo")
        for (source, target) in [(Self.source, ""), (Self.source, "--upload-pack=touch"), ("main..HEAD", "main")] {
            await #expect(throws: GitError.self) { try await git.checkPush(in: folder, source: source, target: target) }
        }
        #expect(runner.arguments.isEmpty)
    }

    // MARK: Whether a session pushed

    /// Pushes a commit to the pull request's branch from another clone, as a teammate, or another session, would: `text`, in
    /// a file of its own unless `file` names one.
    private func pushFromElsewhere(_ text: String, to file: String? = nil, _ fixture: RepositoryFixture) async throws {
        let other = fixture.folder.appendingPathComponent("elsewhere")
        if !FileManager.default.fileExists(atPath: other.path) {
            try await fixture.git(["clone", "--quiet", fixture.origin.path, other.path])
        }
        try await fixture.git(["-C", other.path, "fetch", "--quiet", "origin"])
        try await fixture.git(["-C", other.path, "checkout", "--quiet", "--detach", "origin/\(Self.source)"])
        try await commit(text, to: file ?? "\(text).txt", in: other, fixture)
        try await fixture.git(["-C", other.path, "push", "--quiet", "origin", "HEAD:refs/heads/\(Self.source)"])
    }

    /// Pushes the checkout's HEAD as a fix's prompt has it, by its ID, to origin, which moves the checkout's origin/<branch>.
    private func pushAsThePromptSays(_ fixture: RepositoryFixture, _ git: Git) async throws {
        let head = try await git.run(["-C", fixture.checkout.path, "rev-parse", "HEAD"], timeout: 30)
        try await fixture.git(["-C", fixture.checkout.path, "push", "--quiet", "origin", "\(head):refs/heads/\(Self.source)"])
    }

    /// Where the branch was as the fix went, once BriefBar fetched it: a commit the checkout pushed of its own since is
    /// pushed, whatever was pushed after it; nothing committed, or a commit not pushed, or one whose push was rejected as
    /// someone else pushed first, isn't; nor is a commit others pushed, which the checkout fetched and checked out, or one it
    /// pushed itself before the fix went; nor what others pushed, where a rebase on it, or a cherry-pick, stopped partway.
    @Test(.timeLimit(.minutes(5)))
    func tellsWhetherACheckoutPushedACommitOfItsOwn() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        let checkout = fixture.checkout
        _ = try await git.checkPush(in: checkout, source: Self.source, target: "main")
        let start = try #require(await git.remoteHead(of: checkout, branch: Self.source))
        #expect(try await git.run(["-C", checkout.path, "rev-parse", "HEAD"], timeout: 30) == start)
        #expect(await git.remoteHead(of: checkout, branch: "nowhere") == nil)
        #expect(await git.remoteHead(of: checkout, branch: "--all") == nil)

        // Nothing committed: the tests failed, say.
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: start) == false)
        // Committed, then stopped before it pushed.
        try await commit("The fix", to: "fix.txt", in: checkout, fixture)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: start) == false)
        // Pushed.
        try await pushAsThePromptSays(fixture, git)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: start) == true)
        // Someone pushes on top of it since, which the checkout fetches: it still pushed its own.
        try await pushFromElsewhere("Theirs", fixture)
        try await fixture.git(["-C", checkout.path, "fetch", "--quiet", "origin"])
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: start) == true)

        // The next fix goes from there: what the checkout pushed before it went isn't its push, nor what it fetches and
        // checks out of what others pushed.
        let next = try #require(await git.remoteHead(of: checkout, branch: Self.source))
        try await fixture.git(["-C", checkout.path, "checkout", "--quiet", "--detach", "origin/\(Self.source)"])
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: next) == false)
        // Someone pushes while it fixes, the same lines: its push is rejected, as the branch moved, and it stops.
        try await commit("Another fix", to: "another.txt", in: checkout, fixture)
        let fixed = try await git.run(["-C", checkout.path, "rev-parse", "HEAD"], timeout: 30)
        try await pushFromElsewhere("First", to: "another.txt", fixture)
        try await fixture.git(["-C", checkout.path, "fetch", "--quiet", "origin"])
        await #expect(throws: TestError.self) { try await self.pushAsThePromptSays(fixture, git) }
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: next) == false)
        // A task's prompt has it rebase on what's pushed then, and stop when that conflicts, which leaves it at their commit
        // until the rebase is done or called off; a cherry-pick of its fix there, the same.
        let theirs = try #require(await git.remoteHead(of: checkout, branch: Self.source))
        await #expect(throws: TestError.self) {
            try await fixture.git(["-C", checkout.path] + Self.identity + ["rebase", "--quiet", "origin/\(Self.source)"])
        }
        #expect(try await git.run(["-C", checkout.path, "rev-parse", "HEAD"], timeout: 30) == theirs)
        #expect(await git.stoppedPartway(checkout) == true)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: next) == false)
        try await fixture.git(["-C", checkout.path, "rebase", "--abort"])
        #expect(await git.stoppedPartway(checkout) == false)
        try await fixture.git(["-C", checkout.path, "checkout", "--quiet", "--detach", theirs])
        await #expect(throws: TestError.self) { try await fixture.git(["-C", checkout.path] + Self.identity + ["cherry-pick", fixed]) }
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: next) == false)
        try await fixture.git(["-C", checkout.path, "cherry-pick", "--abort"])

        // What git can't tell: a folder that isn't a checkout, or a start that isn't a commit, or a branch git would read as
        // something else.
        let nowhere = fixture.folder.appendingPathComponent("nowhere")
        try FileManager.default.createDirectory(at: nowhere, withIntermediateDirectories: true)
        #expect(await git.pushedItsOwn(in: nowhere, branch: Self.source, since: start) == nil)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: "c1") == nil)
        #expect(await git.pushedItsOwn(in: checkout, branch: "main..HEAD", since: start) == nil)
        #expect(await git.pushedItsOwn(in: checkout, branch: "gone", since: start) == nil)
    }

    /// A clone of one branch, whose fetch settings name only that one, isn't told its push moved the pull request's branch:
    /// git fetches the branch there as it tells, as before the fix went.
    @Test(.timeLimit(.minutes(5)))
    func tellsAPushFromACloneOfAnotherBranch() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        let clone = fixture.folder.appendingPathComponent("one-branch")
        try await fixture.git(["clone", "--quiet", "--single-branch", "--branch", "main", fixture.origin.path, clone.path])
        _ = try await git.checkPush(in: clone, source: Self.source, target: "main")
        let start = try #require(await git.remoteHead(of: clone, branch: Self.source))
        try await fixture.git(["-C", clone.path, "checkout", "--quiet", "--detach", "origin/\(Self.source)"])
        try await commit("The fix", to: "fix.txt", in: clone, fixture)
        let head = try await git.run(["-C", clone.path, "rev-parse", "HEAD"], timeout: 30)
        try await fixture.git(["-C", clone.path, "push", "--quiet", "origin", "\(head):refs/heads/\(Self.source)"])
        // The push left origin/<branch> where it was.
        #expect(try await git.run(["-C", clone.path, "rev-parse", "refs/remotes/origin/\(Self.source)"], timeout: 30) == start)
        #expect(await git.pushedItsOwn(in: clone, branch: Self.source, since: start) == true)
    }

    @Test func putsWorktreesNextToTheRepositoryEachInAFolderOfItsOwn() {
        let root = URL(fileURLWithPath: "/Users/robin/dev/repos/Storefront")
        let folder = WorktreeLocation.defaultFolder(for: root)
        #expect(folder.path == "/Users/robin/dev/repos/copilot-worktrees")
        let taken: Set<String> = [
            "/Users/robin/dev/repos/copilot-worktrees/Storefront/wi-4217",
            "/Users/robin/dev/repos/copilot-worktrees/Storefront/wi-4217-2",
        ]
        let path = WorktreeLocation.path(in: folder, repository: "Storefront", workItem: 4217) { taken.contains($0.path) }
        #expect(path.path == "/Users/robin/dev/repos/copilot-worktrees/Storefront/wi-4217-3")
        #expect(WorktreeLocation.path(in: folder, repository: "Storefront", workItem: 9) { _ in false }.lastPathComponent == "wi-9")
    }
}
