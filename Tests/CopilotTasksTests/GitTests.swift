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
    @Test(.timeLimit(.minutes(1)))
    func makesADetachedWorktreeAtTheLatestBaseBranch() async throws {
        let fixture = try RepositoryFixture()
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
