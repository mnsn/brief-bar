import BriefBarCore
import CopilotCore
import Foundation
import Synchronization
import Testing
@testable import CopilotTasks

@Suite struct PushGuardTests {
    private static let source = "users/robin/fix-total"
    private static let head = "0123456789abcdef0123456789abcdef01234567"
    private static let other = "89abcdef0123456789abcdef0123456789abcdef"
    /// A folder that isn't there: git's answers come from the stand-in.
    private let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarTests-\(UUID().uuidString)/wt", isDirectory: true)

    /// What the CLI gives the hook for a shell command: `toolArgs` as a JSON string, as the CLI sends it, or an object.
    private static func payload(_ command: String, tool: String = "bash", asString: Bool = true) -> Data {
        let arguments: [String: Any] = ["command": command, "description": "Push the fix"]
        let toolArgs: Any = asString
            ? String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self) : arguments
        return try! JSONSerialization.data(withJSONObject: [
            "sessionId": "4f0e2c0a-1d1b-4b8e-9a51-2f0f3c9d7e11", "timestamp": 1_792_000_000_000, "cwd": "/tmp",
            "toolName": tool, "toolArgs": toolArgs,
        ])
    }

    /// git as the stand-in answers: the worktree at `head`, merges as `merges` lists them, and `outside`, what the target
    /// doesn't have of them; `config`, what `git config --get-regexp` lists of what pushes more; `failing`, a git command
    /// that fails.
    private static func repository(
        head: String = head, merges: String = "", outside: String = "", config: String? = nil, failing: String? = nil
    ) -> FakeRunner {
        FakeRunner { arguments in
            if let failing, arguments.contains(failing) { return .failure("fatal: couldn't \(failing)") }
            if arguments.contains("--get-regexp") { return config.map { .ok($0) } ?? .failure("", status: 1) }
            if arguments.contains("--git-path") { return .ok(".git/MERGE_HEAD") }
            if arguments.contains("rev-parse") { return .ok(head) }
            if arguments.contains("--max-parents=0") { return .ok() }
            if arguments.contains("--merges") { return .ok(merges) }
            if arguments.contains("rev-list") { return .ok(outside) }
            return .ok()
        }
    }

    private func check(
        _ command: String, runner: FakeRunner = repository(), limit: TimeInterval = PushGuard.limit,
        targetNow: @escaping @Sendable () async throws -> String = { "main" }
    ) async -> PushGuard.Verdict {
        await guarding(runner, limit: limit, targetNow: targetNow).check(Self.payload(command))
    }

    private func guarding(
        _ runner: FakeRunner, limit: TimeInterval = PushGuard.limit, targetNow: @escaping @Sendable () async throws -> String = { "main" }
    ) -> PushGuard {
        PushGuard(
            worktree: worktree, source: Self.source, target: "main",
            git: Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: nil, runner: runner), limit: limit, targetNow: targetNow
        )
    }

    private var exact: String { "git push origin \(Self.head):refs/heads/\(Self.source)" }
    private var retryWithHead: String { "Once your changes are committed, run exactly: \(guarding(Self.repository()).command(Self.head))." }

    private func stop(_ why: String) -> PushGuard.Verdict {
        .stop(PushStop.marker + why + PushStop.ending)
    }

    // MARK: What runs

    /// Anything that pushes nothing runs at once, without git: another tool, a command that only says push, a dry run.
    @Test func letsThroughWhatPushesNothing() async {
        let runner = Self.repository()
        let guarding = guarding(runner)
        #expect(await guarding.check(Self.payload("git status && swift test", asString: false)) == .allow)
        #expect(await guarding.check(Self.payload("git push --force", tool: "view")) == .allow)
        #expect(await guarding.check(Self.payload(#"git commit -m "Push the total to the cart""#)) == .allow)
        #expect(await guarding.check(Self.payload("echo git push origin HEAD")) == .allow)
        #expect(await guarding.check(Self.payload("git push --dry-run origin HEAD:refs/heads/main")) == .allow)
        #expect(await guarding.check(Self.payload("git push --help")) == .allow)
        #expect(runner.arguments.isEmpty)
    }

    /// The push the prompt names, as a command of its own, from the shell's folder or with -C, toolArgs as a string or an
    /// object: checked against the worktree's commit, the pull request's branches as fetched now, and what it would merge in.
    @Test func letsThroughThePushThePromptNames() async {
        for command in [
            exact, "git -C \(QuotedText.commandWord(worktree.path)) push origin \(Self.head):refs/heads/\(Self.source)",
            "\(exact) 2>&1",
        ] {
            for asString in [true, false] {
                let runner = Self.repository()
                #expect(await guarding(runner).check(Self.payload(command, asString: asString)) == .allow)
                #expect(runner.arguments.contains { $0.contains("fetch") && $0.contains("+refs/heads/\(Self.source):refs/remotes/origin/\(Self.source)") })
                #expect(runner.arguments.contains { $0.contains("--merges") && $0.contains(Self.head) })
            }
        }
    }

    // MARK: Asked to push as the prompt says

    @Test func asksForThePushThePromptNamesInstead() async {
        for command in [
            "git push", "git push origin HEAD", "git push origin HEAD:refs/heads/\(Self.source)", "git push -u origin \(Self.source)",
            "git push --follow-tags origin \(Self.head):refs/heads/\(Self.source)", "/usr/bin/git push origin \(Self.head):refs/heads/\(Self.source)",
            "git -C /somewhere/else push origin \(Self.head):refs/heads/\(Self.source)", "GIT_TRACE=1 \(exact)",
        ] {
            let verdict = await check(command)
            guard case .retry(let why) = verdict else {
                Issue.record("\(command): \(verdict)")
                continue
            }
            #expect(why.hasPrefix(PushGuard.retryMarker))
            #expect(why.hasSuffix(retryWithHead), "\(command)")
        }
    }

    /// The push the prompt names with other commands, which could change what it does before it runs, as a `cd` to another
    /// clone, even in a subshell, or `git config`: it's asked for as a command of its own.
    @Test func asksForThePushAsACommandOfItsOwn() async {
        let folder = QuotedText.commandWord(worktree.path)
        for command in [
            "cd /Users/robin/src/another-clone; (cd \(folder)); \(exact)",
            "git config push.followTags true && \(exact)",
            "cd \(folder) && \(exact)",
            "\(exact) 2>&1 | tail -5",
            "sh -c '\(exact)'",
            "cd /Users/robin/src/another-clone && git -C \(folder) push origin \(Self.head):refs/heads/\(Self.source)",
        ] {
            let verdict = await check(command)
            guard case .retry(let why) = verdict else {
                Issue.record("\(command): \(verdict)")
                continue
            }
            #expect(why == PushGuard.retryMarker + "push in a command of its own, with nothing else in it. " + retryWithHead, "\(command)")
        }
    }

    /// git's configuration that would push more than the branch with it, as `push.followTags` or `submodule.recurse`: the
    /// push needs the options that keep it to the branch, and the command it's asked for has them.
    @Test func asksForWhatKeepsThePushToTheBranch() async {
        let tags = Self.repository(config: "push.followtags true\nsubmodule.recurse true")
        let verdict = await check(exact, runner: tags)
        guard case .retry(let why) = verdict else {
            Issue.record("\(verdict)")
            return
        }
        let narrowed = "git -C \(QuotedText.commandWord(worktree.path)) push --no-follow-tags --no-recurse-submodules origin \(Self.head):refs/heads/\(Self.source)"
        #expect(why.contains("so it needs --no-follow-tags and --no-recurse-submodules. Run exactly: \(narrowed)."))
        #expect(await check(narrowed, runner: Self.repository(config: "push.followtags true\nsubmodule.recurse true")) == .allow)
        #expect(await check("git push --no-follow-tags origin \(Self.head):refs/heads/\(Self.source)", runner: Self.repository(config: "push.followtags yes")) == .allow)
        // Another push is asked for with them too.
        let other = await check("git push", runner: Self.repository(config: "push.followtags"))
        guard case .retry(let otherWhy) = other else {
            Issue.record("\(other)")
            return
        }
        #expect(otherWhy.contains("push --no-follow-tags origin \(Self.head)"))
        // When git can't say, the push isn't checked.
        #expect(await check(exact, runner: Self.repository(failing: "--get-regexp"))
            == stop("BriefBar couldn't read git's configuration in the worktree: couldn't --get-regexp"))
    }

    /// What was asked, in order: git's commands, by what they do, and Azure DevOps.
    private final class Asked: Sendable {
        let list = Mutex<[String]>([])

        func append(_ what: String) {
            list.withLock { $0.append(what) }
        }
    }

    /// Azure DevOps last, after git's fetch and history, which can take a while: so the pull request is as late as can be.
    @Test func readsAzureDevOpsLast() async {
        let asked = Asked()
        let runner = FakeRunner { arguments in
            asked.append(arguments.first { ["rev-parse", "config", "fetch", "rev-list"].contains($0) } ?? "git")
            if arguments.contains("--get-regexp") { return .failure("", status: 1) }
            if arguments.contains("--git-path") { return .ok(".git/MERGE_HEAD") }
            if arguments.contains("rev-parse") { return .ok(Self.head) }
            return .ok()
        }
        let verdict = await check(exact, runner: runner) {
            asked.append("azure devops")
            return "main"
        }
        #expect(verdict == .allow)
        let calls = asked.list.withLock { $0 }
        #expect(calls.last == "azure devops")
        #expect(calls.contains("fetch") && calls.firstIndex(of: "fetch")! < calls.firstIndex(of: "azure devops")!)
        // So a pull request completed while git checked is still found completed.
        let completed = await check(exact, runner: Self.repository()) { throw PullRequestNotActive(status: "completed") }
        #expect(completed == stop("the pull request was completed."))
    }

    /// A command longer than BriefBar reads doesn't run.
    @Test func doesntRunWhatsTooLongToRead() {
        guard case .retry(let why) = PushGuard.tooLong(1 << 20) else {
            Issue.record("not denied")
            return
        }
        #expect(why == PushGuard.retryMarker + "this command is longer than BriefBar reads (1 MiB), so it didn't run. Run it in smaller parts.")
    }

    @Test func asksForTheCommitTheWorktreeHas() async {
        let verdict = await check("git push origin \(Self.other):refs/heads/\(Self.source)")
        guard case .retry(let why) = verdict else {
            Issue.record("\(verdict)")
            return
        }
        #expect(why.contains("\(Self.other) isn't the commit the worktree has checked out"))
        #expect(why.contains(guarding(Self.repository()).command(Self.head)))
    }

    /// Two pushes in one command, or one it can't read, don't run either: one push, on its own, does.
    @Test func asksForOnePushOnItsOwn() async {
        let several = await check("\(exact) && \(exact)")
        guard case .retry(let why) = several else {
            Issue.record("\(several)")
            return
        }
        #expect(why.contains("push once, in a command of its own."))
        #expect(why.hasSuffix(retryWithHead))

        let unreadable = await check("git $(echo push) origin HEAD")
        guard case .retry(let unread) = unreadable else {
            Issue.record("\(unreadable)")
            return
        }
        #expect(unread.contains("BriefBar couldn't read this command, so it didn't run."))
    }

    /// Without the worktree's commit, a push in another form is still asked for, with `<commit>` to fill in; in the form the
    /// prompt names, it's stopped, since it can't be checked.
    @Test func goesWithoutTheWorktreesCommitOnlyToAskForThePush() async {
        let runner = Self.repository(failing: "rev-parse")
        let other = await check("git push", runner: runner)
        guard case .retry(let why) = other else {
            Issue.record("\(other)")
            return
        }
        #expect(why.hasSuffix("run exactly: \(guarding(runner).command(nil)), where <commit> is what git rev-parse HEAD says there."))
        #expect(await check(exact, runner: runner) == stop("BriefBar couldn't read which commit the worktree has checked out: couldn't rev-parse"))
    }

    // MARK: Stopped

    /// What would force, delete or push more is stopped before anything's read.
    @Test func stopsWhatWouldForceDeleteOrPushMore() async {
        let force = stop("it would force the pull request's branch, which can drop what's on it.")
        let cases: [(String, PushGuard.Verdict)] = [
            ("git push --force origin \(Self.head):refs/heads/\(Self.source)", force),
            ("git push origin +\(Self.head):refs/heads/\(Self.source)", force),
            ("git push --force-with-lease origin HEAD", force),
            ("git push origin --delete \(Self.source)", stop("it would delete what's on the remote.")),
            ("git push origin :refs/heads/\(Self.source)", stop("it would delete what's on the remote.")),
            ("git push --all origin", stop("it would push more than the pull request's branch.")),
            ("git push --mirror origin", stop("it would push more than the pull request's branch.")),
            ("\(exact) && git push --tags origin", stop("it would push more than the pull request's branch.")),
            // A dry run that a later option undoes, and a push after a variable set in a loop, or by a name macOS finds.
            ("git push -n --no-dry-run --force origin main", force),
            ("for i in 1 2 3; do GIT_TERMINAL_PROMPT=0 git push --force origin HEAD && break; sleep 5; done", force),
            ("GIT push -d origin main", stop("it would delete what's on the remote.")),
        ]
        for (command, expected) in cases {
            let runner = Self.repository()
            #expect(await check(command, runner: runner) == expected, "\(command)")
            #expect(runner.arguments.isEmpty, "\(command)")
        }
    }

    /// As Azure DevOps says now: retargeted, without naming the branch; over; or unreadable.
    @Test func stopsWhatAzureDevOpsDoesntLetThrough() async {
        #expect(await check(exact) { "release/2026" }
            == stop("the pull request merges into another branch now than the one this task's prompt names."))
        #expect(await check(exact) { throw PullRequestNotActive(status: "completed") } == stop("the pull request was completed."))
        #expect(await check(exact) { throw PullRequestNotActive(status: "abandoned") } == stop("the pull request was abandoned."))
        #expect(await check(exact) { throw PullRequestNotActive(status: "notSet") } == stop("the pull request isn't active."))
        #expect(await check(exact) { throw TestError("You're signed out of the Azure CLI. Run az login.") }
            == stop("BriefBar couldn't read which branch the pull request merges into: You're signed out of the Azure CLI. Run az login."))
    }

    /// A merge of what main doesn't have, or what git can't check.
    @Test func stopsWhatWouldBringInAnotherBranchsWork() async {
        let merge = "\(Self.head) \(Self.other) fedcba9876543210fedcba9876543210fedcba98"
        #expect(await check(exact, runner: Self.repository(merges: merge, outside: "fedcba9876543210fedcba9876543210fedcba98"))
            == stop("what it would push has a merge of commits that main doesn't have, which would bring another branch's work into the pull request."))
        #expect(await check(exact, runner: Self.repository(merges: merge)) == .allow)
        #expect(await check(exact, runner: Self.repository(failing: "fetch")) == stop("BriefBar couldn't check what it would push: couldn't fetch"))
    }

    /// What it can't read as a shell command is stopped when it says push, and runs otherwise.
    @Test func stopsInputItCantReadThatSaysPush() async {
        let guarding = guarding(Self.repository())
        let unread = stop("BriefBar couldn't read the command.")
        #expect(await guarding.check(Data("{\"toolName\":\"bash\",\"toolArgs\":\"git push".utf8)) == unread)
        #expect(await guarding.check(Data("not json".utf8)) == .allow)
        #expect(await guarding.check(Data(#"{"toolName":"bash","toolArgs":{"script":"git push"}}"#.utf8)) == unread)
        #expect(await guarding.check(Data(#"{"toolName":"bash","toolArgs":{"script":"ls"}}"#.utf8)) == .allow)
    }

    /// Stopped in time when the check takes too long, since the CLI would let it through after its limit.
    @Test func answersInTime() async {
        let late = await check(exact, limit: 0.2) {
            try await Task.sleep(for: .seconds(60))
            return "main"
        }
        #expect(late == stop("BriefBar couldn't check it in time."))
        #expect(await PushGuard.first(within: 60, otherwise: .allow) { .retry("x") } == .retry("x"))
    }

    // MARK: Without checking

    /// Without Azure DevOps, a push, or what it can't read that may be one, is stopped with why; anything else runs.
    @Test func stopsEveryPushWhenItCantCheck() {
        let why = "Azure DevOps is off in BriefBar, so it can't read the pull request."
        #expect(PushGuard.check(Self.payload(exact), cantCheck: why) == stop(why))
        #expect(PushGuard.check(Self.payload("git $(echo push)"), cantCheck: why) == stop(why))
        #expect(PushGuard.check(Self.payload("swift test"), cantCheck: why) == .allow)
        #expect(PushGuard.check(Self.payload("[ -x .git/hooks/pre-push ] && cat .git/hooks/pre-push"), cantCheck: why) == .allow)
        #expect(PushGuard.check(Self.payload("find . -name '*.swift' -exec grep -n push {} +"), cantCheck: why) == .allow)
        #expect(PushGuard.check(Self.payload("git push -n --no-dr --force origin main"), cantCheck: why) == stop(why))
        #expect(PushGuard.check(Self.payload("git push -n origin HEAD"), cantCheck: why) == .allow)
        #expect(PushGuard.check(Self.payload("git push", tool: "edit"), cantCheck: why) == .allow)
    }

    // MARK: What the hook prints

    @Test func printsTheCLIsDecisionToDenyIt() throws {
        #expect(PushGuard.Verdict.allow.output == nil)
        for reason in [PushGuard.retryMarker + "push as https://x/y says.", PushStop.marker + "why." + PushStop.ending] {
            for verdict in [PushGuard.Verdict.retry(reason), .stop(reason)] {
                let output = try #require(verdict.output)
                let decision = try #require(try JSONSerialization.jsonObject(with: output) as? [String: String])
                #expect(decision == ["permissionDecision": "deny", "permissionDecisionReason": reason])
                #expect(!String(decoding: output, as: UTF8.self).contains("\\/"))
            }
        }
        // The log finds a stop's reason in the CLI's message, without the marker or the ending; a retry has none.
        #expect(PushStop.reason(in: "Denied by preToolUse hook: " + PushStop.marker + "why." + PushStop.ending) == "why.")
        #expect(PushStop.reason(in: "Denied by preToolUse hook: " + PushGuard.retryMarker + "push once.") == nil)
    }

    // MARK: On a real repository

    /// origin with main, and the pull request's branch one commit on from it, which the checkout has detached, as a
    /// session's worktree has it; then main a commit further, which the checkout merges in, and release/x, at main's first
    /// commit, which the pull request merges into from then on.
    @Test(.timeLimit(.minutes(5)))
    func checksAPushOnARealRepository() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        let identity = ["-c", "user.name=Robin Diaz", "-c", "user.email=robin@example.com"]
        let seed = fixture.folder.appendingPathComponent("seed")
        func commit(_ file: String, in folder: URL) async throws {
            try "\(file)\n".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try await fixture.git(["-C", folder.path, "add", file])
            try await fixture.git(["-C", folder.path] + identity + ["commit", "--quiet", "-m", file])
        }
        try await fixture.git(["-C", seed.path, "branch", "release/x"])
        try await fixture.git(["-C", seed.path, "checkout", "--quiet", "-b", Self.source])
        try await commit("totals.txt", in: seed)
        try await fixture.git(["-C", seed.path, "checkout", "--quiet", "main"])
        try await commit("main.txt", in: seed)
        try await fixture.git(["-C", seed.path, "push", "--quiet", fixture.origin.path, "main", "release/x", Self.source])
        try await fixture.git(["-C", fixture.checkout.path, "fetch", "--quiet", "origin"])
        try await fixture.git(["-C", fixture.checkout.path, "checkout", "--quiet", "--detach", "origin/\(Self.source)"])
        try await commit("fix.txt", in: fixture.checkout)

        let git = Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: fixture.environment)
        func check(target: String) async throws -> PushGuard.Verdict {
            let head = try await git.commit(checkedOutIn: fixture.checkout)
            let guarding = PushGuard(worktree: fixture.checkout, source: Self.source, target: target, git: git) { target }
            return await guarding.check(Self.payload("git -C \(fixture.checkout.path) push origin \(head):refs/heads/\(Self.source)"))
        }
        #expect(try await check(target: "release/x") == .allow)
        try await fixture.git(["-C", fixture.checkout.path] + identity + ["merge", "--quiet", "--no-edit", "origin/main"])
        #expect(try await check(target: "main") == .allow)
        #expect(try await check(target: "release/x")
            == stop("what it would push has a merge of commits that release/x doesn't have, which would bring another branch's work into the pull request."))
    }
}
