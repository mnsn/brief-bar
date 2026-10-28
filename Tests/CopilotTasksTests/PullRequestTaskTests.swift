import BriefBarCore
import CopilotCore
import Foundation
import Synchronization
import Testing
@testable import CopilotTasks

/// Tasks on a pull request: a worktree at its branch's latest commit, which a later task goes on with, in the same
/// session.
@Suite struct PullRequestTaskTests {
    private let pullRequest = TaskPullRequest(
        organization: "contoso", project: "Storefront", repository: "checkout", id: 4071, title: "Fix the checkout total",
        url: URL(string: "https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071")!,
        sourceBranch: "users/robin/fix-total", targetBranch: "main"
    )

    /// The fixture's origin with the pull request's branch, one commit ahead of main.
    private func repositoryWithBranch() async throws -> RepositoryFixture {
        let fixture = try await RepositoryFixture()
        let seed = fixture.folder.appendingPathComponent("seed")
        try await fixture.git(["-C", seed.path, "checkout", "--quiet", "-b", pullRequest.sourceBranch])
        try "Storefront, with totals\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await fixture.git(["-C", seed.path, "-c", "user.name=Robin Diaz", "-c", "user.email=robin@example.com", "commit", "--quiet", "-am", "Totals"])
        try await fixture.git(["-C", seed.path, "push", "--quiet", fixture.origin.path, pullRequest.sourceBranch])
        let remote = "https://dev.azure.com/contoso/Storefront/_git/checkout"
        try await fixture.git(["-C", fixture.checkout.path, "remote", "set-url", "origin", remote])
        // Use a real Azure DevOps URL for identity, but fetch only from the fixture on disk.
        try await fixture.git(["-C", fixture.checkout.path, "config", "url.\(fixture.origin.path).insteadOf", remote])
        return fixture
    }

    private func launcher(_ fixture: RepositoryFixture, runner: any ProcessRunning = ProcessRunner()) throws -> (CopilotLauncher, arguments: URL) {
        let copilot = fixture.folder.appendingPathComponent("bin/copilot")
        try FileManager.default.createDirectory(at: copilot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CopilotLauncherTests.fakeCopilot.write(to: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)
        let argumentsFile = fixture.folder.appendingPathComponent("arguments")
        var environment = fixture.environment
        environment["COPILOT_HOME"] = fixture.folder.appendingPathComponent("copilot-home").path
        environment["FAKE_COPILOT_ARGUMENTS"] = argumentsFile.path
        let launchEnvironment = environment
        let launcher = CopilotLauncher(
            outputFolder: fixture.folder.appendingPathComponent("output"), runner: runner, environment: { launchEnvironment },
            locate: { _ in copilot }
        )
        return (launcher, argumentsFile)
    }

    private func launch(_ launcher: CopilotLauncher, _ request: CopilotLauncher.Request, id: String) async throws -> CopilotRun {
        let (exits, sink) = AsyncStream.makeStream(of: Int32.self)
        let run = try await launcher.launch(request, id: id) { status in
            sink.yield(status)
            sink.finish()
        }
        var iterator = exits.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        return run
    }

    @Test(.timeLimit(.minutes(1)))
    func worksAtThePullRequestsLatestCommitThenGoesOnInTheSameSession() async throws {
        let fixture = try await repositoryWithBranch()
        defer { fixture.remove() }
        let (launcher, argumentsFile) = try launcher(fixture)
        let id = "6a1f0e2c-3b8d-4d9e-8b4f-2e3d4c5b6a7f"

        let fix = try await launch(launcher, CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .fixComments), prompt: "Fix the comments", options: CopilotModel.standard,
            repository: fixture.checkout, worktreesFolder: nil
        ), id: id)
        let worktree = fixture.folder.appendingPathComponent("copilot-worktrees/checkout/pr-4071")
        #expect(fix.worktree.path == worktree.path)
        #expect(fix.workItem == nil)
        #expect(fix.onPullRequest == pullRequest.reference)
        #expect(fix.action == .fixComments)
        #expect(fix.pullRequest == pullRequest.url)
        #expect(fix.isValid)
        #expect(fix.subjectName == "pull request 4071")
        // The pull request's commit, detached, not main's: the branch stays free for any checkout that has it.
        #expect(try String(contentsOf: worktree.appendingPathComponent("README.md"), encoding: .utf8) == "Storefront, with totals\n")
        var arguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments.contains("--name"))
        #expect(arguments.contains("Fix Comments: !4071 Fix the checkout total"))
        // It can't push or commit, whatever the prompt says.
        #expect(arguments.joined(separator: " ").contains("--deny-tool shell(git commit) --deny-tool shell(git push)"))

        // Push & Reply goes on with the same session, in the same worktree, under the session's own name.
        let ship = try await launch(launcher, CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .pushAndReply), prompt: "Push and reply", options: CopilotModel.standard,
            repository: fixture.checkout, worktreesFolder: nil, continuing: fix
        ), id: "7b2f1e3d-4c9e-4e0f-9c5a-3f4e5d6c7b8a")
        #expect(ship.id == id)
        #expect(ship.worktree.path == worktree.path)
        #expect(ship.action == .pushAndReply)
        arguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments.first(where: { $0 == "Push and reply" }) != nil)
        #expect(arguments.contains(id))
        #expect(!arguments.contains("--name"))
        #expect(!arguments.contains("--deny-tool"))
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("copilot-worktrees/checkout/pr-4071-2").path))
    }

    @Test func goesOnOnlyWhereTheEarlierRunsWorktreeStillIs() async throws {
        let fixture = try await repositoryWithBranch()
        defer { fixture.remove() }
        let (launcher, _) = try launcher(fixture)
        let gone = CopilotRun(
            id: "8c3f2e4d-5d0e-4f1a-8d6b-4a5b6c7d8e9f", workItem: nil, onPullRequest: pullRequest.reference, action: .fixBuild,
            options: CopilotModel.standard, repository: fixture.checkout, worktree: fixture.folder.appendingPathComponent("nowhere"),
            startedAt: Date(), process: DetachedProgram.Handle(pid: 0, startedAt: nil)
        )
        let request = CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .pushAndReply), prompt: "Push", options: CopilotModel.standard,
            repository: fixture.checkout, worktreesFolder: nil, continuing: gone
        )
        await #expect(throws: LaunchError.self) { try await launcher.launch(request) { _ in } }
    }

    /// One of the Copilot app's sessions, such as the one that opened the pull request, goes on in the folder it works in,
    /// under its own name: never while the app has it open, which keeps its history in memory and wouldn't see the turn.
    @Test(.timeLimit(.minutes(1)))
    func goesOnWithACopilotAppSessionInItsFolderOnlyWhileTheAppDoesntHaveItOpen() async throws {
        let fixture = try await repositoryWithBranch()
        defer { fixture.remove() }
        let (launcher, argumentsFile) = try launcher(fixture)
        let id = "0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01"
        let state = fixture.folder.appendingPathComponent("copilot-home/session-state/\(id)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data((Line.userMessage("Open the pull request") + "\n").utf8).write(to: state.appendingPathComponent("events.jsonl"))
        let session = CopilotRun(
            id: id, workItem: nil, onPullRequest: pullRequest.reference, action: .fixComments, options: CopilotModel.standard,
            repository: fixture.checkout, worktree: fixture.checkout, startedAt: Date(),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), pullRequest: pullRequest.url, isAppSession: true
        )
        let request = CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .fixComments), prompt: "Fix the comments", options: CopilotModel.standard,
            repository: fixture.checkout, worktreesFolder: nil, continuing: session
        )

        // This test's own process stands in for the app's.
        let lock = state.appendingPathComponent("inuse.\(getpid()).lock")
        try Data().write(to: lock)
        await #expect(throws: LaunchError.openInApp) { try await launcher.launch(request) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: argumentsFile.path))

        try FileManager.default.removeItem(at: lock)
        let run = try await launch(launcher, request, id: "7b2f1e3d-4c9e-4e0f-9c5a-3f4e5d6c7b8a")
        #expect(run.id == id)
        #expect(run.isAppSession == true)
        #expect(run.worktree.path == fixture.checkout.path)
        #expect(run.onPullRequest == pullRequest.reference)
        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments.contains(id))
        #expect(arguments.suffix(3) == ["-C", fixture.checkout.path, "--silent"])
        #expect(!arguments.contains("--name"))
        // Whatever the session could do in the app, here it can't commit or push.
        #expect(arguments.joined(separator: " ").contains("--deny-tool shell(git commit) --deny-tool shell(git push)"))
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("copilot-worktrees").path))
    }

    /// The Copilot app may open a session while BriefBar gets ready to go on with it, as git runs: the launcher looks again
    /// right before it starts the CLI, and doesn't start it then.
    @Test(.timeLimit(.minutes(1)))
    func looksAgainWhetherTheAppOpenedTheSessionRightBeforeStarting() async throws {
        let fixture = try await repositoryWithBranch()
        defer { fixture.remove() }
        let id = "6a1f0e2c-3b8d-4d9e-8b4f-2e3d4c5b6a7f"
        let state = fixture.folder.appendingPathComponent("copilot-home/session-state/\(id)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        // The app opens it as soon as git runs: this test's own process stands in for the app's.
        let runner = OpensSessionRunner(lock: state.appendingPathComponent("inuse.\(getpid()).lock"))
        let (launcher, argumentsFile) = try launcher(fixture, runner: runner)
        let worktree = fixture.folder.appendingPathComponent("copilot-worktrees/checkout/pr-4071")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let fix = CopilotRun(
            id: id, workItem: nil, onPullRequest: pullRequest.reference, action: .fixComments, options: CopilotModel.standard,
            repository: fixture.checkout, worktree: worktree, startedAt: Date(), process: DetachedProgram.Handle(pid: 0, startedAt: nil),
            ended: .finished, pullRequest: pullRequest.url
        )
        let request = CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .pushAndReply), prompt: "Push and reply", options: CopilotModel.standard,
            repository: fixture.checkout, worktreesFolder: nil, continuing: fix
        )
        await #expect(throws: LaunchError.openInApp) { try await launcher.launch(request) { _ in } }
        // Nothing held it when the launch began: the lock came while git ran, and Copilot never started.
        #expect(runner.ran)
        #expect(!FileManager.default.fileExists(atPath: argumentsFile.path))
    }

    /// The CLI keeps its sessions in its own folder: one of the app's that isn't there can't be gone on with.
    @Test func doesNotStartAnAppSessionTheCLIDoesntHave() async throws {
        let fixture = try await repositoryWithBranch()
        defer { fixture.remove() }
        let (launcher, argumentsFile) = try launcher(fixture)
        let session = CopilotRun(
            id: "0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01", workItem: nil, onPullRequest: pullRequest.reference, action: .review,
            options: CopilotModel.standard, repository: fixture.checkout, worktree: fixture.checkout, startedAt: Date(),
            process: DetachedProgram.Handle(pid: 0, startedAt: nil), isAppSession: true
        )
        let request = CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .review), prompt: "Review it", options: CopilotModel.standard,
            repository: fixture.checkout, worktreesFolder: nil, continuing: session
        )
        await #expect(throws: LaunchError.self) { try await launcher.launch(request) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: argumentsFile.path))
    }

    /// Going on with the session of the work item's task that opened the pull request, the task stays that work item's.
    @Test(.timeLimit(.minutes(1)))
    func aTaskOnThePullRequestAWorkItemsTaskOpenedStaysTheWorkItems() async throws {
        let fixture = try await repositoryWithBranch()
        defer { fixture.remove() }
        let (launcher, _) = try launcher(fixture)
        let opened = CopilotRun(
            id: "6a1f0e2c-3b8d-4d9e-8b4f-2e3d4c5b6a7f", workItem: sampleItem.reference, options: CopilotModel.standard,
            repository: fixture.checkout, worktree: fixture.checkout, startedAt: Date(), process: DetachedProgram.Handle(pid: 0, startedAt: nil),
            ended: .finished, pullRequest: pullRequest.url
        )
        let run = try await launch(launcher, CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .fixComments), prompt: "Fix the comments", options: CopilotModel.standard,
            repository: fixture.checkout, worktreesFolder: nil, continuing: opened
        ), id: "7b2f1e3d-4c9e-4e0f-9c5a-3f4e5d6c7b8a")
        #expect(run.id == opened.id)
        #expect(run.workItem == sampleItem.reference)
        #expect(run.onPullRequest == pullRequest.reference)
        #expect(run.action == .fixComments)
        #expect(run.isAppSession == nil)
        #expect(run.subjectName == "pull request 4071")
    }

    @Test func onlyPushAndReplyMayPushAndAReviewWritesNothing() {
        #expect(PullRequestAction.review.deniedTools == ["write", "shell(git commit)", "shell(git push)"])
        #expect(PullRequestAction.allCases.filter { !$0.deniedTools.contains("shell(git push)") } == [.pushAndReply])
        #expect(PullRequestAction.resolveConflicts.deniedTools == ["shell(git push)"])
        #expect(TaskSubject.workItem(sampleItem).deniedTools.isEmpty)
    }

    @Test func takesOnlyBranchNamesGitWouldntReadAsSomethingElse() {
        #expect(Git.isBranchName("users/robin/fix-total"))
        for name in ["", "-x", "--upload-pack=evil", "a..b", "a b", "a:b"] {
            #expect(!Git.isBranchName(name), "\(name)")
        }
    }

    @Test(arguments: [
        "https://dev.azure.com/contoso/Storefront/_git/checkout",
        "https://contoso@dev.azure.com/CONTOSO/storefront/_git/CHECKOUT/",
        "https://contoso.visualstudio.com/Storefront/_git/checkout",
        "https://contoso.visualstudio.com/DefaultCollection/Storefront/_git/checkout",
        "git@ssh.dev.azure.com:v3/contoso/Storefront/checkout",
        "ssh://git@ssh.dev.azure.com/v3/contoso/Storefront/checkout",
        "contoso@vs-ssh.visualstudio.com:v3/contoso/Storefront/checkout",
    ])
    func recognizesItsCloneURLs(_ remote: String) {
        #expect(pullRequest.matches(remote: remote))
    }

    @Test(arguments: [
        "https://dev.azure.com/another-org/Storefront/_git/checkout",
        "https://dev.azure.com/contoso/another-project/_git/checkout",
        "https://dev.azure.com/contoso/Storefront/_git/another-repo",
        "https://dev.azure.com/contoso/Storefront/_git/checkout.git",
        "https://github.com/contoso/checkout.git",
        "https://dev.azure.com.example.com/contoso/Storefront/_git/checkout",
        "https://contoso.visualstudio.com.example.com/Storefront/_git/checkout",
        "git@ssh.dev.azure.com:v3/another-org/Storefront/checkout",
        "git@ssh.dev.azure.com:v3/contoso/another-project/checkout",
        "git@ssh.dev.azure.com:v3/contoso/Storefront/checkout/extra",
        "https://dev.azure.com/contoso/Storefront/_git/checkout?repository=another",
        "/Users/robin/checkout",
        "",
    ])
    func doesNotMistakeAnotherRepositoryForItsClone(_ remote: String) {
        #expect(!pullRequest.matches(remote: remote))
    }

    @Test func recognizesEncodedNamesAndRepositoryIDs() {
        var pr = pullRequest
        pr.project = "Online Store"
        pr.repository = "Shop Web"
        pr.projectId = "11111111-1111-4111-8111-111111111111"
        pr.repositoryId = "22222222-2222-4222-8222-222222222222"
        #expect(pr.matches(remote: "https://dev.azure.com/contoso/Online%20Store/_git/Shop%20Web"))
        #expect(pr.matches(remote: "git@ssh.dev.azure.com:v3/contoso/Online%20Store/Shop%20Web"))
        #expect(pr.matches(remote: "https://dev.azure.com/contoso/\(pr.projectId!)/_git/\(pr.repositoryId!)"))
        #expect(pr.matches(remote: "https://dev.azure.com/contoso/Online%20Store/_git/\(pr.repositoryId!)"))
    }

    @Test func refusesTheWrongCloneBeforeFetchingOrStartingCopilot() async throws {
        let fixture = try await repositoryWithBranch()
        defer { fixture.remove() }
        try await fixture.git(["-C", fixture.checkout.path, "remote", "set-url", "origin",
                               "https://dev.azure.com/another-org/Storefront/_git/checkout"])
        let (launcher, argumentsFile) = try launcher(fixture)
        let request = CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .fixComments), prompt: "Fix", options: CopilotModel.standard,
            repository: fixture.checkout, worktreesFolder: nil
        )
        await #expect(throws: LaunchError.git(.wrongRepository("contoso/Storefront/checkout"))) {
            try await launcher.launch(request) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: argumentsFile.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("copilot-worktrees").path))
    }

    @Test func keepsWhichPullRequestAndWhatForButNotItsTitle() throws {
        let run = CopilotRun(
            id: "8c3f2e4d-5d0e-4f1a-8d6b-4a5b6c7d8e9f", workItem: nil, onPullRequest: pullRequest.reference, action: .review,
            options: CopilotModel.standard, repository: URL(fileURLWithPath: "/r"), worktree: URL(fileURLWithPath: "/w"),
            startedAt: Date(timeIntervalSince1970: 0), process: DetachedProgram.Handle(pid: 0, startedAt: nil), pullRequest: pullRequest.url
        )
        let text = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
        #expect(!text.contains("Fix the checkout total"))
        #expect(try JSONDecoder().decode(CopilotRun.self, from: Data(text.utf8)) == run)
        // A run kept by an earlier version, for a work item, still reads.
        let earlier = #"{"id":"8c3f2e4d-5d0e-4f1a-8d6b-4a5b6c7d8e9f","workItem":{"organization":"contoso","project":"Storefront","id":7},"options":{"model":"auto"},"repository":"file:///r","worktree":"file:///w","startedAt":0,"process":{"pid":0}}"#
        let decoded = try JSONDecoder().decode(CopilotRun.self, from: Data(earlier.utf8))
        #expect(decoded.workItem?.id == 7)
        #expect(decoded.onPullRequest == nil)
        #expect(decoded.isValid)
    }
}

/// Runs programs as `ProcessRunner` does, and leaves a lock in a session's folder as the first one starts, as the Copilot app
/// does when it opens the session.
private final class OpensSessionRunner: ProcessRunning {
    let lock: URL
    private let inner = ProcessRunner()
    private let calls = Mutex(0)

    init(lock: URL) {
        self.lock = lock
    }

    var ran: Bool { calls.withLock { $0 } > 0 }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        calls.withLock { $0 += 1 }
        try? Data().write(to: lock)
        return try await inner.run(executable, arguments: arguments, environment: environment, timeout: timeout)
    }
}
