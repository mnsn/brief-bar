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

    /// The options a push needs to push only its branch, as git's configuration has it, the repository's and yours.
    @Test(.timeLimit(.minutes(5)))
    func findsWhatGitsConfigurationWouldPushMore() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        let git = Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: fixture.environment)
        let checkout = fixture.checkout.path
        #expect(try await git.pushOptions(in: fixture.checkout) == [])
        try await fixture.git(["config", "--global", "push.followTags", "true"])
        #expect(try await git.pushOptions(in: fixture.checkout) == ["--no-follow-tags"])
        try await fixture.git(["-C", checkout, "config", "push.followTags", "false"])
        #expect(try await git.pushOptions(in: fixture.checkout) == [])
        // A name with no value is on, as git reads it.
        let config = fixture.checkout.appendingPathComponent(".git/config")
        let configured = try String(contentsOf: config, encoding: .utf8)
        try (configured + "[push]\n\tfollowTags\n").write(to: config, atomically: true, encoding: .utf8)
        #expect(try await git.pushOptions(in: fixture.checkout) == ["--no-follow-tags"])
        try configured.write(to: config, atomically: true, encoding: .utf8)
        try await fixture.git(["-C", checkout, "config", "submodule.recurse", "true"])
        #expect(try await git.pushOptions(in: fixture.checkout) == ["--no-recurse-submodules"])
        // push.recurseSubmodules, set, decides.
        try await fixture.git(["-C", checkout, "config", "push.recurseSubmodules", "check"])
        #expect(try await git.pushOptions(in: fixture.checkout) == [])
        try await fixture.git(["-C", checkout, "config", "push.recurseSubmodules", "on-demand"])
        try await fixture.git(["-C", checkout, "config", "push.followTags", "1"])
        #expect(try await git.pushOptions(in: fixture.checkout) == ["--no-follow-tags", "--no-recurse-submodules"])
        // Outside a repository, git still reads yours; somewhere that isn't there, it can't say.
        await #expect(throws: GitError.self) { try await git.pushOptions(in: fixture.folder.appendingPathComponent("gone")) }
    }

    @Test func readsGitsBooleansAsGitDoes() {
        for on in [nil, "true", "Yes", "on", "1", "2", "-1", "maybe"] as [String?] { #expect(Git.isOn(on), "\(String(describing: on))") }
        for off in ["false", "No", "off", "0", ""] { #expect(!Git.isOn(off), "\(off)") }
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
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: next) == false)
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
        #expect(await git.tracksPushes(to: Self.source, in: clone) == false)
        #expect(try await git.run(["-C", clone.path, "rev-parse", "refs/remotes/origin/\(Self.source)"], timeout: 30) == start)
        // Its turn ends once it replied, a second or two later.
        #expect(await git.pushedItsOwn(in: clone, branch: Self.source, since: start, at: Date().addingTimeInterval(2)) == true)
    }

    /// As things stood when a turn ended, from git's logs of where HEAD and origin/<branch> were: its own push then counts,
    /// whatever's done there since; a commit it didn't push doesn't, though a later turn there pushes it along.
    @Test(.timeLimit(.minutes(5)))
    func tellsWhatItPushedAsItsTurnEnded() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        let checkout = fixture.checkout
        _ = try await git.checkPush(in: checkout, source: Self.source, target: "main")
        let start = try #require(await git.remoteHead(of: checkout, branch: Self.source))
        // After all git has logged by the clock so far.
        let base = Int(Date().timeIntervalSince1970) + 1_000
        func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(base + seconds)) }
        func commit(_ text: String, at seconds: Int) async throws {
            try "\(text)\n".write(to: checkout.appendingPathComponent("\(text).txt"), atomically: true, encoding: .utf8)
            try await fixture.git(["-C", checkout.path, "add", "\(text).txt"])
            try await fixture.git(["-C", checkout.path] + Self.identity + ["commit", "--quiet", "-m", text], at: base + seconds)
        }
        func push(at seconds: Int) async throws {
            let head = try await git.run(["-C", checkout.path, "rev-parse", "HEAD"], timeout: 30)
            try await fixture.git(["-C", checkout.path, "push", "--quiet", "origin", "\(head):refs/heads/\(Self.source)"], at: base + seconds)
        }
        // A fix commits and pushes, then its turn ends; a later turn there commits and pushes more.
        try await commit("The fix", at: 10)
        try await push(at: 20)
        try await commit("Later", at: 40)
        try await push(at: 50)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: start, at: at(30)) == true)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: start, at: at(15)) == false)
        // The next fix commits and doesn't push, then its turn ends; a later turn there pushes it along with its own.
        let next = try #require(await git.remoteHead(of: checkout, branch: Self.source))
        try await commit("Another fix", at: 60)
        try await commit("Yet another", at: 80)
        try await push(at: 90)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: next, at: at(70)) == false)
        // As things are now, it would look pushed.
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: next) == true)

        // git's logs keep whole seconds: a push of its commit in the second its turn ended may be a later turn's, just after
        // it; so may a move of HEAD to a commit pushed before.
        let last = try #require(await git.remoteHead(of: checkout, branch: Self.source))
        try await commit("Unpushed", at: 100)
        try await push(at: 110)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: last, at: at(110).addingTimeInterval(0.5)) == nil)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: last, at: at(111)) == true)
        let pushed = try await git.run(["-C", checkout.path, "rev-parse", "HEAD"], timeout: 30)
        try await commit("Not yet", at: 120)
        try await fixture.git(["-C", checkout.path, "checkout", "--quiet", "--detach", pushed], at: base + 130)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: last, at: at(130).addingTimeInterval(0.5)) == nil)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: last, at: at(129)) == false)

        // origin/<branch>'s log can go back in time too. Someone else's commit came to it by a fetch, and the checkout checked
        // it out; then a push from another worktree of the clone, which shares origin/<branch>, took that commit along, at an
        // earlier time, as a clock set back would have it. Its turn ending between the two, git can't tell which came first,
        // rather than take the push for that commit's arrival; after both, it came by the fetch.
        let before = try #require(await git.remoteHead(of: checkout, branch: Self.source))
        try await pushFromElsewhere("Theirs", fixture)
        try await fixture.git(["-C", checkout.path, "fetch", "--quiet", "origin"], at: base + 300)
        let theirs = try #require(await git.remoteHead(of: checkout, branch: Self.source))
        try await fixture.git(["-C", checkout.path, "checkout", "--quiet", "--detach", theirs], at: base + 150)
        let other = fixture.folder.appendingPathComponent("other-worktree")
        try await fixture.git(["-C", checkout.path, "worktree", "add", "--quiet", "--detach", other.path, theirs], at: base + 155)
        try "On theirs\n".write(to: other.appendingPathComponent("on-theirs.txt"), atomically: true, encoding: .utf8)
        try await fixture.git(["-C", other.path, "add", "on-theirs.txt"], at: base + 160)
        try await fixture.git(["-C", other.path] + Self.identity + ["commit", "--quiet", "-m", "On theirs"], at: base + 160)
        try await fixture.git(["-C", other.path, "push", "--quiet", "origin", "HEAD:refs/heads/\(Self.source)"], at: base + 170)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: before, at: at(200)) == nil)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: before, at: at(400)) == false)
        try await fixture.git(["-C", checkout.path, "checkout", "--quiet", "--detach", pushed], at: base + 410)

        // The other way about: someone else's commit came to it by a fetch in the second the turn ended, then the checkout's
        // own, pushed over theirs, at an earlier time. The push came after what may have come after the end: git can't tell
        // whether it came before it, until after both.
        let again = try #require(await git.remoteHead(of: checkout, branch: Self.source))
        try await commit("Over theirs", at: 500)
        try await pushFromElsewhere("Theirs again", fixture)
        try await fixture.git(["-C", checkout.path, "fetch", "--quiet", "origin"], at: base + 600)
        let over = try await git.run(["-C", checkout.path, "rev-parse", "HEAD"], timeout: 30)
        try await fixture.git(["-C", checkout.path, "push", "--quiet", "--force", "origin", "\(over):refs/heads/\(Self.source)"], at: base + 550)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: again, at: at(600).addingTimeInterval(0.5)) == nil)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: again, at: at(700)) == true)
        try await fixture.git(["-C", checkout.path, "checkout", "--quiet", "--detach", pushed], at: base + 710)

        // Without git's log of where HEAD was, it can't tell where the checkout was as the turn ended, only where it is now;
        // without origin/<branch>'s, how the commit came to the branch, or when, whatever the branch has now.
        func log(of ref: String) async throws -> URL {
            let path = try await git.run(["-C", checkout.path, "rev-parse", "--git-path", "logs/\(ref)"], timeout: 30)
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : checkout.appendingPathComponent(path)
        }
        try FileManager.default.removeItem(at: try await log(of: "HEAD"))
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: last, at: at(140)) == nil)
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: last) == true)
        try FileManager.default.removeItem(at: try await log(of: "refs/remotes/origin/\(Self.source)"))
        #expect(await git.pushedItsOwn(in: checkout, branch: Self.source, since: last) == nil)
    }

    /// Whether a fix was partway through a rebase, a merge or a cherry-pick as its turn ended, from git's log of where HEAD
    /// was: a rebase on what others pushed that stopped then, called off since, stopped it short of its push, while one a
    /// later turn starts doesn't; nor a merge a later turn starts once HEAD moved. git doesn't log when a merge or a
    /// cherry-pick starts: one going on since HEAD's last move before the end leaves it unknown, and so does calling one off
    /// since, which git logs on a branch. Others' commit, which the checkout fetched, isn't its push, whatever it did there;
    /// nor is one pushed from another worktree of the clone, which shares origin/<branch>, where a rebase on it stopped. A
    /// rebase on a detached HEAD logs no finish: one that went through, then pushed, isn't partway after its last step. What
    /// git logs in the second the turn ended may have come after it.
    @Test(.timeLimit(.minutes(5)))
    func tellsWhatItWasPartwayThroughAsItsTurnEnded() async throws {
        let (fixture, git) = try await retargetable()
        defer { fixture.remove() }
        let checkout = fixture.checkout
        _ = try await git.checkPush(in: checkout, source: Self.source, target: "main")
        // After all git has logged by the clock so far.
        let base = Int(Date().timeIntervalSince1970) + 1_000
        func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(base + seconds)) }
        func run(_ arguments: [String], at seconds: Int) async throws {
            try await fixture.git(["-C", checkout.path] + Self.identity + arguments, at: base + seconds)
        }
        func head() async throws -> String { try await git.run(["-C", checkout.path, "rev-parse", "HEAD"], timeout: 30) }
        func remote() async throws -> String { try #require(await git.remoteHead(of: checkout, branch: Self.source)) }
        func commit(_ text: String, to file: String = "fix.txt", at seconds: Int) async throws {
            try "\(text)\n".write(to: checkout.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try await run(["add", file], at: seconds)
            try await run(["commit", "--quiet", "-m", text], at: seconds)
        }
        func push(at seconds: Int) async throws {
            try await run(["push", "--quiet", "origin", "\(try await head()):refs/heads/\(Self.source)"], at: seconds)
        }
        // Someone pushes a change to the same lines, which the checkout fetches.
        func theirs(_ text: String, at seconds: Int) async throws {
            try await pushFromElsewhere(text, to: "fix.txt", fixture)
            try await run(["fetch", "--quiet", "origin"], at: seconds)
        }
        func pushed(since start: String, at seconds: Int) async -> Bool? {
            await git.pushedItsOwn(in: checkout, branch: Self.source, since: start, at: at(seconds))
        }

        // Its push rejected, a fix pulls with a rebase, which stops on the conflict, at their commit, as its turn ends; a
        // later turn calls the rebase off.
        var start = try await remote()
        try await commit("Mine", at: 10)
        try await theirs("Theirs", at: 20)
        await #expect(throws: TestError.self) { try await run(["pull", "--rebase", "--quiet", "origin", Self.source], at: 30) }
        try await run(["rebase", "--abort"], at: 50)
        #expect(await git.stoppedPartway(checkout, at: at(40)) == true)
        #expect(await pushed(since: start, at: 40) == false)

        // The next fix commits on theirs and pushes, and its turn ends; a later turn commits more, then someone pushes over
        // it, and the later turn's rebase on that stops on the conflict, after it picked one commit.
        start = try await remote()
        try await run(["checkout", "--quiet", "--detach", start], at: 60)
        try await commit("Fixed", at: 70)
        try await push(at: 80)
        try await commit("Aside", to: "aside.txt", at: 100)
        try await commit("More", at: 105)
        try await theirs("Over", at: 110)
        await #expect(throws: TestError.self) { try await run(["rebase", "--quiet", "origin/\(Self.source)"], at: 120) }
        #expect(await git.stoppedPartway(checkout, at: at(90)) == false)
        #expect(await pushed(since: start, at: 90) == true)
        #expect(await git.stoppedPartway(checkout, at: at(125)) == true)
        try await run(["rebase", "--abort"], at: 130)
        #expect(await git.stoppedPartway(checkout, at: at(125)) == true)
        #expect(await git.stoppedPartway(checkout, at: at(120).addingTimeInterval(0.5)) == nil)
        #expect(await git.stoppedPartway(checkout, at: at(130).addingTimeInterval(0.5)) == nil)
        #expect(await git.stoppedPartway(checkout, at: at(135)) == false)

        // The next fix resets to what's pushed, then someone pushes over it, and it resets to theirs, and cherry-picks its
        // fix there, which stops on the conflict, as its turn ends. Called off since, with HEAD where it was, which git
        // doesn't log on a detached HEAD, their commit still came by a fetch.
        start = try await remote()
        try await run(["reset", "--quiet", "--hard", start], at: 140)
        try await commit("Again", at: 150)
        let again = try await head()
        try await theirs("Twice", at: 160)
        try await run(["reset", "--quiet", "--hard", "origin/\(Self.source)"], at: 170)
        await #expect(throws: TestError.self) { try await run(["cherry-pick", again], at: 180) }
        #expect(await git.stoppedPartway(checkout, at: at(190)) == nil)
        #expect(await pushed(since: start, at: 190) == nil)
        try await run(["cherry-pick", "--abort"], at: 200)
        #expect(await pushed(since: start, at: 190) == false)

        // The next fix commits and pushes, and its turn ends; a later turn commits, then merges what someone pushed over
        // it, which stops on the conflict.
        start = try await remote()
        try await commit("Merged", at: 210)
        try await push(at: 220)
        try await theirs("Thrice", at: 240)
        try await commit("Later", at: 250)
        await #expect(throws: TestError.self) { try await run(["merge", "--quiet", "--no-edit", "origin/\(Self.source)"], at: 260) }
        #expect(await git.stoppedPartway(checkout) == true)
        #expect(await git.stoppedPartway(checkout, at: at(230)) == false)
        #expect(await pushed(since: start, at: 230) == true)
        try await run(["merge", "--abort"], at: 270)

        // On a branch, git logs calling a cherry-pick off, as a reset: one that was going on as the turn ended may have
        // ended so.
        try await run(["checkout", "--quiet", "-B", "work", "origin/\(Self.source)"], at: 280)
        await #expect(throws: TestError.self) { try await run(["cherry-pick", again], at: 290) }
        try await run(["cherry-pick", "--abort"], at: 310)
        #expect(await git.stoppedPartway(checkout, at: at(300)) == nil)

        // Someone pushes from another worktree of the clone, which shares origin/<branch>, so that their commit looks
        // pushed from here: the next fix's rebase on it, which stops on the conflict as its turn ends, still stops it short
        // of its push, though that's called off since.
        try await run(["checkout", "--quiet", "--detach", "origin/\(Self.source)"], at: 320)
        start = try await remote()
        try await commit("Ours", at: 330)
        let other = fixture.folder.appendingPathComponent("other-worktree")
        try await run(["worktree", "add", "--quiet", "--detach", other.path, start], at: 340)
        try "Yours\n".write(to: other.appendingPathComponent("fix.txt"), atomically: true, encoding: .utf8)
        try await fixture.git(["-C", other.path, "add", "fix.txt"], at: base + 340)
        try await fixture.git(["-C", other.path] + Self.identity + ["commit", "--quiet", "-m", "Yours"], at: base + 340)
        try await fixture.git(["-C", other.path, "push", "--quiet", "origin", "HEAD:refs/heads/\(Self.source)"], at: base + 350)
        await #expect(throws: TestError.self) { try await run(["rebase", "--quiet", "origin/\(Self.source)"], at: 360) }
        #expect(await pushed(since: start, at: 370) == false)
        try await run(["rebase", "--abort"], at: 380)
        #expect(await pushed(since: start, at: 370) == false)

        // The next fix's push is rejected, as someone pushed meanwhile, to another file, and its rebase on that goes
        // through, on a detached HEAD; it pushes, and its turn ends.
        try await run(["checkout", "--quiet", "--detach", "origin/\(Self.source)"], at: 390)
        start = try await remote()
        try await commit("Last", to: "last.txt", at: 400)
        try await pushFromElsewhere("Fourth", to: "fourth.txt", fixture)
        try await run(["fetch", "--quiet", "origin"], at: 410)
        try await run(["rebase", "--quiet", "origin/\(Self.source)"], at: 420)
        try await push(at: 430)
        #expect(await git.stoppedPartway(checkout, at: at(420).addingTimeInterval(0.5)) == nil)
        #expect(await git.stoppedPartway(checkout, at: at(440)) == false)
        #expect(await pushed(since: start, at: 440) == true)

        // The next fix's rebase on what someone pushed meanwhile stops on the conflict, on a detached HEAD, which logs no
        // finish; it goes on with it at an earlier time, as a clock set back would have it, which git logs before the
        // rebase's start. It pushes, and its turn ends after all that: it pushed. Had its turn ended between the two, git
        // couldn't tell.
        try await run(["checkout", "--quiet", "--detach", "origin/\(Self.source)"], at: 450)
        start = try await remote()
        try await commit("Dated", at: 460)
        try await theirs("Fifth", at: 470)
        await #expect(throws: TestError.self) { try await run(["rebase", "--quiet", "origin/\(Self.source)"], at: 480) }
        try "Dated and Fifth\n".write(to: checkout.appendingPathComponent("fix.txt"), atomically: true, encoding: .utf8)
        try await run(["add", "fix.txt"], at: 465)
        try await run(["-c", "core.editor=true", "rebase", "--continue"], at: 465)
        try await push(at: 490)
        #expect(await git.stoppedPartway(checkout, at: at(500)) == false)
        #expect(await pushed(since: start, at: 500) == true)
        #expect(await pushed(since: start, at: 475) == nil)
    }

    /// What git's log of where HEAD was says of a rebase, a merge, a cherry-pick or a revert going on at a time in a second,
    /// and where a ref was then, from how it moved alone.
    @Test func tellsFromHowHEADMovedWhatWasGoingOn() {
        let (a, b) = (String(repeating: "a", count: 40), String(repeating: "b", count: 40))
        func moves(_ entries: [(Int, String)]) -> [Git.Move] {
            entries.reversed().map { Git.Move(second: $0.0, commit: a, subject: $0.1) }
        }
        func partway(_ entries: [(Int, String)], _ now: Git.Partway = .nothing, at second: Int) -> Bool? {
            Git.stoppedPartway(moves(entries), now: now, at: second)
        }
        // A rebase, from its start to its calling off, or its finish; what it logs in that second may have come after it.
        let aborted = [(10, "rebase (start): checkout origin/main"), (10, "rebase (pick): Mine"), (30, "rebase (abort): returning to \(b)")]
        #expect(partway(aborted, at: 5) == false)
        #expect(partway(aborted, at: 10) == nil)
        #expect(partway(aborted, at: 20) == true)
        #expect(partway(aborted, at: 30) == nil)
        #expect(partway(aborted, at: 40) == false)
        #expect(partway([(10, "rebase (start): checkout x"), (20, "rebase (continue): Mine"), (25, "rebase (finish): returning to refs/heads/b")], at: 22) == true)
        // One on a detached HEAD logs no finish: its last step ends it, `git pull --rebase`'s too; one going on now hasn't
        // ended, and one going on now whose start isn't logged can't be told.
        #expect(partway([(10, "pull --rebase (start): checkout \(b)"), (12, "pull --rebase (pick): Mine"), (20, "commit: More")], at: 15) == false)
        #expect(partway([(10, "rebase (start): checkout x")], .rebase, at: 20) == true)
        #expect(partway([(10, "rebase (start): checkout x"), (12, "rebase (pick): Mine"), (30, "rebase (start): checkout y")], .rebase, at: 11) == true)
        #expect(partway([(10, "rebase (start): checkout x")], .rebase, at: 5) == false)
        #expect(partway([(5, "commit: Mine")], .rebase, at: 20) == nil)
        #expect(partway([(10, "rebase (continue): Mine"), (20, "rebase (finish): returning to refs/heads/b")], at: 15) == true)
        // git logs a move at the time GIT_COMMITTER_DATE says, as a rebase with --committer-date-is-author-date logs each of
        // its steps at its commit's author's, or as a clock set back has it: a rebase's step, or its end, may be logged
        // before its start. It was partway between the earliest and the latest of them; where HEAD's log goes back in time
        // past the end, git can't tell.
        let dated = [(100, "rebase (start): checkout x"), (40, "rebase (pick): Mine")]
        #expect(partway(dated, at: 200) == false)
        #expect(partway(dated, at: 20) == false)
        #expect(partway(dated, at: 70) == nil)
        #expect(partway(dated, .rebase, at: 200) == true)
        #expect(partway(dated + [(150, "rebase (start): checkout y")], at: 200) == false)
        let continued = [(100, "rebase (start): checkout x"), (40, "rebase (continue): Mine"), (40, "rebase (finish): returning to refs/heads/b")]
        #expect(partway(continued + [(150, "rebase (start): checkout y"), (160, "rebase (pick): More")], at: 155) == true)
        #expect(partway(continued, at: 200) == false)
        // Nor where it goes back from a later second to that one: what it logged then came after what it logged later.
        let stepped = [(100, "rebase (start): checkout x"), (40, "rebase (pick): Mine"), (60, "rebase (finish): returning to refs/heads/b")]
        #expect(partway(stepped, at: 40) == nil)
        #expect(partway(stepped, at: 39) == false)
        #expect(partway(stepped, at: 101) == false)
        #expect(partway(dated, .rebase, at: 40) == nil)
        #expect(partway(dated + [(60, "rebase (pick): More"), (150, "rebase (start): checkout y")], at: 40) == nil)
        // A merge, a cherry-pick or a revert going on now started since HEAD last moved; one going on then may have ended with
        // HEAD's first move since.
        #expect(partway([(10, "commit: Mine")], .other, at: 20) == nil)
        #expect(partway([(10, "commit: Mine"), (30, "commit: Later")], .other, at: 20) == false)
        #expect(partway([(10, "commit: Mine"), (30, "reset: moving to \(b)")], at: 20) == nil)
        #expect(partway([(10, "commit: Mine"), (30, "commit (cherry-pick): Mine")], at: 20) == nil)
        #expect(partway([], at: 20) == nil)
        #expect(Git.rebaseStep("rebase (start): checkout origin/main") == .start)
        #expect(Git.rebaseStep("pull (start): checkout \(b)") == .start)
        #expect(Git.rebaseStep("rebase (pick): Mine") == .step)
        #expect(Git.rebaseStep("rebase (update-ref): refs/heads/b") == .step)
        #expect(Git.rebaseStep("rebase (abort): returning to \(b)") == .end)
        #expect(Git.rebaseStep("commit (merge): Merge branch 'main'") == nil)
        #expect(Git.rebaseStep("commit (cherry-pick): Mine") == nil)
        #expect(Git.rebaseStep("checkout: moving from main to b") == nil)
        #expect(Git.rebaseStep("") == nil)

        // Where a ref was: as the second before ended, unless it moved to another commit in that second.
        let refMoves = [Git.Move(second: 20, commit: b, subject: "commit: Later"), Git.Move(second: 10, commit: a, subject: "commit: Mine")]
        #expect(Git.commit(at: 5, of: refMoves) == nil)
        #expect(Git.commit(at: 15, of: refMoves) == a)
        #expect(Git.commit(at: 20, of: refMoves) == nil)
        #expect(Git.commit(at: 25, of: refMoves) == b)
        #expect(Git.commit(at: 20, of: [Git.Move(second: 20, commit: a, subject: "checkout: moving from a to a")] + refMoves.dropFirst()) == a)
        // Its log going back in time past then, or from a later second to then, git can't tell where it was.
        let back = [Git.Move(second: 10, commit: b, subject: "commit: Later"), Git.Move(second: 20, commit: a, subject: "commit: Mine")]
        #expect(Git.commit(at: 15, of: back) == nil)
        #expect(Git.commit(at: 25, of: back) == b)
        let reset = [
            Git.Move(second: 40, commit: a, subject: "reset: moving to \(a)"), Git.Move(second: 45, commit: b, subject: "commit: Later"),
            Git.Move(second: 30, commit: a, subject: "commit: Mine"),
        ]
        #expect(Git.commit(at: 40, of: reset) == nil)
        #expect(Git.commit(at: 46, of: reset) == a)
        #expect(Git.isOrdered(back, around: 5))
        #expect(!Git.isOrdered(back, around: 10))
        #expect(!Git.isOrdered(back, around: 15))
        #expect(!Git.isOrdered(back, around: 20))
        #expect(Git.isOrdered(back, around: 25))
    }

    /// A push moves origin/<branch> as the remote's fetch settings map the branch to it: by default, but not in a clone of
    /// one other branch, one that maps it elsewhere, or one that leaves it out.
    @Test(.timeLimit(.minutes(5)))
    func tellsWhichBranchesAPushTracks() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        let git = Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: fixture.environment)
        let checkout = fixture.checkout
        func fetching(_ refspecs: [String]) async throws -> Bool? {
            _ = try? await git.run(["-C", checkout.path, "config", "--unset-all", "remote.origin.fetch"], timeout: 30)
            for refspec in refspecs {
                try await fixture.git(["-C", checkout.path, "config", "--add", "remote.origin.fetch", refspec])
            }
            return await git.tracksPushes(to: Self.source, in: checkout)
        }
        #expect(try await fetching(["+refs/heads/*:refs/remotes/origin/*"]) == true)
        #expect(try await fetching(["+refs/heads/main:refs/remotes/origin/main"]) == false)
        #expect(try await fetching(["+refs/heads/main:refs/remotes/origin/main", "refs/heads/\(Self.source):refs/remotes/origin/\(Self.source)"]) == true)
        #expect(try await fetching(["+refs/heads/users/*:refs/remotes/origin/users/*"]) == true)
        #expect(try await fetching(["+refs/heads/*:refs/remotes/upstream/*"]) == false)
        #expect(try await fetching(["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/users/*"]) == false)
        #expect(try await fetching([]) == false)
        #expect(await git.tracksPushes(to: Self.source, in: fixture.folder.appendingPathComponent("nowhere")) == nil)
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
