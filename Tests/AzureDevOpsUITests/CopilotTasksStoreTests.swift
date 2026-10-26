import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// Send Work to Copilot: off until you turn it on, and what BriefBar keeps about a send: which work item, where and with
/// which model, never the work item's title or what Copilot wrote.
@MainActor
@Suite struct CopilotTasksStoreTests {
    private let now = Date(timeIntervalSince1970: 1_792_317_600)
    private let item = WorkItem(
        id: 4217, organization: "Contoso", project: "Storefront", type: "Task", title: "Show the order total in the cart",
        state: "Active", category: .inProgress
    )

    /// Sessions' IDs, which name their files.
    private let first = "11111111-1111-4111-8111-111111111111"
    private let second = "22222222-2222-4222-8222-222222222222"
    private let third = "33333333-3333-4333-8333-333333333333"

    private func run(
        _ id: String, workItem: Int = 4217, startedAt: Date, ended: RunPhase? = nil,
        process: DetachedProgram.Handle = DetachedProgram.Handle(pid: 0, startedAt: nil)
    ) -> CopilotRun {
        CopilotRun(
            id: id, workItem: WorkItemReference(organization: "contoso", project: "Storefront", id: workItem),
            options: CopilotModel.standard, repository: URL(fileURLWithPath: "/Users/robin/dev/Storefront"),
            worktree: URL(fileURLWithPath: "/Users/robin/dev/copilot-worktrees/Storefront/wi-\(workItem)"),
            startedAt: startedAt, process: process, ended: ended
        )
    }

    /// Everything the preferences hold, as text: what any program running as you could read there.
    private func readable(_ defaults: MemoryDefaults) -> String {
        defaults.dictionaryRepresentation().map { key, value in
            "\(key)=" + ((value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)")
        }.sorted().joined(separator: "\n").replacingOccurrences(of: "\\/", with: "/")
    }

    @Test func isOffUntilYouTurnItOn() {
        let settings = AppSettings(defaults: MemoryDefaults())
        #expect(!settings.copilotEnabled)
        #expect(settings.copilotOptions == CopilotModel.standard)
        #expect(settings.copilotQuickOptions == CopilotModel.quick)
        #expect(settings.copilotPromptTemplate == PromptTemplate.standard)
        #expect(!CopilotTasksStore(settings: settings, mode: .live, notifier: nil).isOn)
    }

    @Test func keepsYourChoicesAndSends() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.copilotEnabled = true
        settings.copilotOptions = CopilotRunOptions(model: "gpt-6.1-sol", effort: "xhigh")
        settings.copilotQuickOptions = CopilotRunOptions(model: "claude-haiku-5.5", effort: nil)
        settings.copilotPrompt = "Fix {id}"
        settings.copilotRepositories = ["contoso/storefront": "/Users/robin/dev/Storefront"]
        settings.copilotWorktreesFolder = "/Users/robin/worktrees"
        settings.copilotRuns = [run(first, startedAt: now)]

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.copilotEnabled)
        #expect(reloaded.copilotOptions == CopilotRunOptions(model: "gpt-6.1-sol", effort: "xhigh"))
        #expect(reloaded.copilotQuickOptions == CopilotRunOptions(model: "claude-haiku-5.5", effort: nil))
        #expect(reloaded.copilotPromptTemplate == "Fix {id}")
        #expect(reloaded.copilotRepositories == ["contoso/storefront": "/Users/robin/dev/Storefront"])
        #expect(reloaded.copilotWorktreesFolder == "/Users/robin/worktrees")
        #expect(reloaded.copilotRuns == [run(first, startedAt: now)])

        // Back to the standard prompt, which then follows updates.
        reloaded.copilotPrompt = nil
        #expect(AppSettings(defaults: defaults).copilotPrompt == nil)
    }

    /// Any program running as you can read the preferences: they say which work item was sent, not what it's about.
    @Test func keepsNoTitlesInThePreferences() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        var sent = run(first, startedAt: now, ended: .finished)
        sent.pullRequest = URL(string: "https://dev.azure.com/contoso/Storefront/_git/web/pullrequest/77")
        settings.copilotRuns = [sent]
        let text = readable(defaults)
        #expect(text.contains("4217"))
        #expect(text.contains("pullrequest/77"))
        #expect(!text.contains(item.title))
    }

    /// Turning Azure DevOps off forgets the sends and their repositories. Your choices stay, and so does Copilot's work.
    @Test func forgetsSendsWhenAzureDevOpsIsTurnedOff() {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        settings.copilotOptions = CopilotModel.quick
        settings.copilotRepositories = ["contoso/storefront": "/Users/robin/dev/Storefront"]
        settings.copilotRuns = [run(first, startedAt: now)]
        settings.forgetCopilotRuns()
        #expect(settings.copilotRuns.isEmpty)
        #expect(settings.copilotRepositories.isEmpty)
        #expect(settings.copilotEnabled)
        #expect(settings.copilotOptions == CopilotModel.quick)
    }

    /// A work item's row shows its latest send, whatever case its organization is written in.
    @Test func showsEachWorkItemsLatestSend() {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        settings.copilotRuns = [
            run(first, startedAt: now.addingTimeInterval(-3_600), ended: .failed),
            run(second, startedAt: now, ended: .finished),
            run(third, workItem: 9, startedAt: now.addingTimeInterval(-60)),
        ]
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        #expect(store.isOn)
        #expect(store.entries.map(\.id) == [second, third, first])
        #expect(store.latest(for: item)?.id == second)
        #expect(store.latest(for: item)?.status.phase == .finished)
        // Not looked at yet, and not ended: working.
        #expect(store.activeCount == 1)
    }

    @Test func remembersTheRepositoryEachProjectsWorkWentIn() {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotRepositories = ["contoso/storefront": "/Users/robin/dev/Storefront", "contoso/payments": "/Users/robin/dev/Payments"]
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        #expect(store.repository(for: item.copilotTask)?.path == "/Users/robin/dev/Storefront")
        #expect(store.knownRepositories.map(\.path) == ["/Users/robin/dev/Payments", "/Users/robin/dev/Storefront"])
        var elsewhere = item
        elsewhere.project = "Search"
        #expect(store.repository(for: elsewhere.copilotTask) == nil)
    }

    private var pullRequest: TaskPullRequest {
        TaskPullRequest(
            organization: "Contoso", project: "Storefront", repository: "shop-web", id: 4071, title: "Fix totals",
            url: URL(string: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4071")!,
            sourceBranch: "fix-totals", targetBranch: "main"
        )
    }

    private final class CloneRunner: ProcessRunning, Sendable {
        let remotes: [String: String]
        let calls = Mutex(0)

        init(_ remotes: [String: String]) { self.remotes = remotes }

        var git: Git { Git(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:], runner: self) }

        func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
            calls.withLock { $0 += 1 }
            guard arguments.count > 2, let remote = remotes[arguments[1]] else {
                return ProcessResult(status: 128, stderr: Data("fatal: not a repository".utf8))
            }
            let result: String
            if arguments.contains("--show-toplevel") { result = arguments[1] }
            else if arguments.contains("symbolic-ref") { result = "origin/main" }
            else if arguments.last == "remote.origin.url" { result = remote }
            else { return ProcessResult(status: 1) }
            return ProcessResult(status: 0, stdout: Data(result.utf8))
        }
    }

    @Test func remembersAVerifiedCloneBeforeSendingAndReusesItForAnotherPR() async throws {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.copilotEnabled = true
        let folder = URL(fileURLWithPath: "/dev/my-renamed-checkout", isDirectory: true)
        let runner = CloneRunner([folder.path: "git@ssh.dev.azure.com:v3/contoso/Storefront/shop-web"])
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        #expect(try await store.checkRepository(at: folder, for: pullRequest, using: runner.git).root == folder)
        #expect(settings.copilotRuns.isEmpty)

        var anotherPR = pullRequest
        anotherPR.id = 5000
        anotherPR.organization = "CONTOSO"
        anotherPR.project = "storefront"
        let reloaded = CopilotTasksStore(settings: AppSettings(defaults: defaults), mode: .live, notifier: nil)
        #expect(try await reloaded.repository(for: anotherPR, using: runner.git)?.root == folder)
        #expect(reloaded.settings.copilotRepositories[pullRequest.reference.repositoryKey] == folder.path)
    }

    @Test func findsAKnownCloneByOriginRatherThanItsFolderName() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        settings.copilotRepositories = ["another/project": "/a/shop-web", "contoso/storefront": "/b/renamed"]
        let runner = CloneRunner([
            "/a/shop-web": "https://dev.azure.com/another/Storefront/_git/shop-web",
            "/b/renamed": "https://dev.azure.com/contoso/Storefront/_git/shop-web",
        ])
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        #expect(try await store.repository(for: pullRequest, using: runner.git)?.root.path == "/b/renamed")
        #expect(settings.copilotRepositories[pullRequest.reference.repositoryKey] == "/b/renamed")
    }

    @Test func asksForALocalCloneWhenOnlyUnrelatedRepositoriesAreKnown() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        settings.copilotRepositories = ["another/project": "/dev/shop-web", "old/project": "/gone"]
        let runner = CloneRunner(["/dev/shop-web": "https://dev.azure.com/another/Storefront/_git/shop-web"])
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        #expect(try await store.repository(for: pullRequest, using: runner.git) == nil)
        #expect(settings.copilotRepositories[pullRequest.reference.repositoryKey] == nil)
        await #expect(throws: GitError.wrongRepository("Contoso/Storefront/shop-web")) {
            try await store.checkRepository(at: URL(fileURLWithPath: "/dev/shop-web"), for: pullRequest, using: runner.git)
        }
        #expect(settings.copilotRepositories[pullRequest.reference.repositoryKey] == nil)
    }

    @Test func reportsARememberedCloneThatMovedOrChangedItsOrigin() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        settings.copilotRepositories[pullRequest.reference.repositoryKey] = "/dev/clone"
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        await #expect(throws: GitError.notARepository("/dev/clone")) {
            try await store.repository(for: pullRequest, using: CloneRunner([:]).git)
        }
        let runner = CloneRunner(["/dev/clone": "https://dev.azure.com/contoso/OtherProject/_git/shop-web"])
        await #expect(throws: GitError.wrongRepository("Contoso/Storefront/shop-web")) {
            try await store.repository(for: pullRequest, using: runner.git)
        }
    }

    @Test func doesNotDiscoverClonesWhileOffOrInTheDemo() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotRepositories[pullRequest.reference.repositoryKey] = "/dev/shop-web"
        let runner = CloneRunner(["/dev/shop-web": "https://dev.azure.com/contoso/Storefront/_git/shop-web"])
        let off = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        #expect(try await off.repository(for: pullRequest, using: runner.git) == nil)
        let demo = CopilotTasksStore(settings: settings, mode: .demo, notifier: nil)
        #expect(try await demo.repository(for: pullRequest, using: runner.git) == nil)
        #expect(runner.calls.withLock { $0 } == 0)
    }

    /// Waits for the store's reads, which run on the main actor between this test's awaits.
    private func settle(until done: () -> Bool) async throws {
        for _ in 0..<100 where !done() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// While Send Work to Copilot is off, nothing of Copilot's is read; turned on, the runs are followed again.
    @Test func readsNothingWhileOff() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotRuns = [run(first, startedAt: now)]
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        store.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        store.refresh()
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.statuses.isEmpty)
        #expect(settings.copilotRuns.first?.ended == nil)

        settings.copilotEnabled = true
        store.refresh()
        try await settle { !store.statuses.isEmpty }
        // Gone, without a log: it never started working.
        #expect(store.statuses[first]?.phase == .failed)
        #expect(settings.copilotRuns.first?.ended == .failed)
    }

    /// While its process runs, a task is working, and isn't taken for ended.
    @Test func keepsFollowingARunWhileItsProcessRuns() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.copilotEnabled = true
        // This test's own process stands in for Copilot's.
        settings.copilotRuns = [run(first, startedAt: now, process: DetachedProgram.Handle(pid: getpid(), startedAt: nil))]
        let store = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        store.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        store.refresh()
        try await settle { !store.statuses.isEmpty }
        #expect(store.statuses[first]?.phase == .working)
        #expect(settings.copilotRuns.first?.ended == nil)
        #expect(store.activeCount == 1)
        store.stop()
    }

    /// The demo shows made-up sends of its own tasks, and never starts anything.
    @Test func theDemoSendsNothing() {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = CopilotTasksStore(settings: settings, mode: .demo, notifier: nil)
        #expect(store.isOn)
        #expect(!store.canSend)
        #expect(store.entries.map(\.status.phase) == [.working, .working, .finished])
        // One of them fixes the demo's failing pull request.
        #expect(store.latest(forPullRequest: PRKey(DemoData.organization, 4088))?.action == .fixBuild)
        store.send(item.copilotTask, prompt: "Fix it", options: CopilotModel.standard, repository: URL(fileURLWithPath: "/tmp"))
        #expect(store.pending.isEmpty)
        #expect(settings.copilotRepositories.isEmpty)
    }
}
