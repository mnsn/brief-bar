import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotCore
import CopilotTasks
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// `BriefBar --push-guard`, which the Copilot CLI's hook runs before each shell command of BriefBar's own Push & Reply
/// tasks: what it takes, when it checks, and what it says when it can't. With stand-ins for the check, which never use
/// git, the Azure CLI or Azure DevOps.
@Suite struct PushGuardCLITests {
    private let pullRequest = TaskPullRequest(
        organization: "contoso", project: "Storefront", repository: "checkout", id: 4071, title: "Fix the checkout total",
        url: URL(string: "https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071")!,
        sourceBranch: "users/robin/it's-total", targetBranch: "main"
    )
    private let worktree = URL(fileURLWithPath: "/Users/robin/copilot-worktrees/checkout/pr 4071", isDirectory: true)
    private var arguments: [String] {
        words(PushGuardPlugin.command(executable: URL(fileURLWithPath: "/B/BriefBar"), pullRequest: pullRequest, worktree: worktree))
    }

    /// The words a shell reads in a command whose every word is in single quotes, a quote in one written `'\''`.
    private func words(_ command: String) -> [String] {
        var words: [String] = []
        var word: String?
        var quoted = false
        var characters = command.makeIterator()
        while let character = characters.next() {
            switch (quoted, character) {
            case (true, "'"): quoted = false
            case (true, _): word?.append(character)
            case (false, "'"):
                quoted = true
                word = word ?? ""
            case (false, "\\"): word = (word ?? "") + String(characters.next().map { String($0) } ?? "")
            case (false, " "):
                if let done = word { words.append(done) }
                word = nil
            case (false, _): word = (word ?? "") + String(character)
            }
        }
        if let word { words.append(word) }
        return words
    }

    private static func payload(_ command: String) -> Data {
        let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: ["command": command]), as: UTF8.self)
        return try! JSONSerialization.data(withJSONObject: ["toolName": "bash", "toolArgs": arguments, "cwd": "/tmp"])
    }

    private static let push = payload("git push origin 0123456789abcdef0123456789abcdef01234567:refs/heads/users/robin/fix")
    private static let tests = payload("swift test")

    private func stop(_ why: String) -> PushGuard.Verdict {
        .stop(PushStop.marker + why + PushStop.ending)
    }

    /// The checks it was asked for.
    private final class Checks: Sendable {
        let requests = Mutex<[PushGuardCLI.Request]>([])

        /// A check that records its request, and whose git and Azure DevOps aren't there: enough for what pushes nothing,
        /// and what's stopped before anything's read.
        func check(_ request: PushGuardCLI.Request) -> PushGuard {
            requests.withLock { $0.append(request) }
            return PushGuard(
                worktree: request.worktree, source: request.source, target: request.target,
                git: Git(executable: URL(fileURLWithPath: "/nonexistent/git"), environment: [:])
            ) { throw PullRequestNotActive(status: "completed") }
        }
    }

    // MARK: Arguments

    /// What the plugin writes, its words as the shell gives them: the pull request, its worktree and branches, a branch
    /// named like an option or with an equals sign included.
    @Test func takesWhatThePluginWrites() throws {
        #expect(try PushGuardCLI.request(arguments).get() == PushGuardCLI.Request(
            key: PRKey("contoso", 4071), worktree: worktree, source: "users/robin/it's-total", target: "main"
        ))
        var odd = pullRequest
        odd.sourceBranch = "--help"
        odd.targetBranch = "release/a=b"
        let words = words(PushGuardPlugin.command(executable: URL(fileURLWithPath: "/B/BriefBar"), pullRequest: odd, worktree: worktree))
        #expect(!words.contains("--help"))
        let request = try PushGuardCLI.request(words).get()
        #expect(request.source == "--help" && request.target == "release/a=b")
    }

    @Test func refusesWhatsMissing() {
        let link = pullRequest.url.absoluteString
        for broken in [
            ["--push-guard"],
            ["--push-guard", "4071", "--worktree=/w", "--source-branch=a", "--target-branch=main"],
            ["--push-guard", link, "--source-branch=a", "--target-branch=main"],
            ["--push-guard", link, "--worktree=w", "--source-branch=a", "--target-branch=main"],
            ["--push-guard", link, "--worktree=/w", "--target-branch=main"],
            ["--push-guard", link, "--worktree=/w", "--source-branch=a", "--target-branch="],
            ["--push-guard", link, "--worktree=/w", "--source-branch=a", "--source-branch=b", "--target-branch=main"],
        ] {
            guard case .failure = PushGuardCLI.request(broken) else {
                Issue.record("\(broken)")
                continue
            }
        }
    }

    /// One of Azure DevOps' own modes, which `--help` lists.
    @Test func isAzureDevOpsMode() {
        #expect(AzureDevOpsCommandLine.flags.contains(PushGuardCLI.flag))
        #expect(AzureDevOpsCommandLine.usage.contains("--push-guard <pull request>"))
    }

    // MARK: Checking

    /// While Azure DevOps is on in the app, whether or not agents may use BriefBar: it's BriefBar's own check of a task you
    /// sent.
    @Test func checksOnlyWhileAzureDevOpsIsOn() {
        let off = "Azure DevOps is off in BriefBar, so it can't read the pull request."
        #expect(PushGuardCLI.refusal(nil) == off)
        let defaults = MemoryDefaults()
        #expect(PushGuardCLI.refusal(defaults) == off)
        var choices = SourceChoices.load(from: defaults)
        choices.turnOn(.azureDevOps, version: AzureDevOpsSource.descriptionVersion, at: Date())
        choices.save(to: defaults)
        #expect(PushGuardCLI.refusal(defaults) == nil)
    }

    /// With what it was started with, the check for them; nothing else checks: a push is stopped, with why, when it can't
    /// check, and in the demo; anything else runs.
    @Test func checksWithWhatItWasStartedWith() async {
        let checks = Checks()
        let arguments = arguments
        func verdict(_ payload: Data, arguments: [String]? = nil, demo: Bool = false, refusal: String? = nil) async -> PushGuard.Verdict {
            await PushGuardCLI.verdict(
                for: payload, arguments: arguments ?? self.arguments, demo: demo, refusal: { refusal }, check: checks.check
            )
        }
        #expect(await verdict(Self.tests) == .allow)
        #expect(await verdict(Self.payload("git push --force origin HEAD")) == stop("it would force the pull request's branch, which can drop what's on it."))
        #expect(checks.requests.withLock { $0 } == Array(repeating: try! PushGuardCLI.request(arguments).get(), count: 2))

        checks.requests.withLock { $0 = [] }
        let off = "Azure DevOps is off in BriefBar, so it can't read the pull request."
        #expect(await verdict(Self.push, refusal: off) == stop(off))
        #expect(await verdict(Self.tests, refusal: off) == .allow)
        #expect(await verdict(Self.push, demo: true) == stop("BriefBar's demo pushes nothing."))
        #expect(await verdict(Self.tests, demo: true) == .allow)
        #expect(await verdict(Self.push, arguments: ["--push-guard"])
            == stop("BriefBar's check didn't get what it needs: Name the pull request by its link."))
        #expect(await verdict(Self.tests, arguments: ["--push-guard"]) == .allow)
        #expect(checks.requests.withLock { $0 }.isEmpty)
    }

    /// The CLI's input, to its end, so that the CLI's writing ends: all of it, or, past a mebibyte, the first mebibyte, and
    /// that it isn't all, so that the command doesn't run. Written from a queue, and read on the tests' own threads, outside
    /// Swift's cooperative pool, which `make test` gives one thread.
    @Test func readsItsInputToTheEnd() async throws {
        func read(_ count: Int) async throws -> (data: Data, isWhole: Bool) {
            let pipe = Pipe()
            let written = Data(repeating: UInt8(ascii: "a"), count: count)
            let writer = pipe.fileHandleForWriting
            DispatchQueue.global().async {
                writer.write(written)
                try? writer.close()
            }
            let reader = pipe.fileHandleForReading
            let read = await withTaskExecutorPreference(TestThreads.shared) { PushGuardCLI.input(reader) }
            try reader.close()
            return read
        }
        let whole = try await read(PushGuardCLI.mostInput)
        #expect(whole.data.count == PushGuardCLI.mostInput && whole.isWhole)
        let tooLong = try await read(PushGuardCLI.mostInput + 70_000)
        #expect(tooLong.data.count == PushGuardCLI.mostInput && !tooLong.isWhole)
        // What isn't all there doesn't run, whatever it says.
        let verdict = await PushGuardCLI.verdict(
            for: Self.tests, isWhole: false, arguments: arguments, demo: false, refusal: { nil }, check: Checks().check
        )
        #expect(verdict == PushGuard.tooLong(PushGuardCLI.mostInput))
    }
}
