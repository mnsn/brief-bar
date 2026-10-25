import BriefBarCore
import BriefBarUI
import Foundation
import GitHubCore
import Testing
@testable import GitHubUI

@MainActor
@Suite struct StoreTests {
    @Test func theDemoReadsOnceAndNeverRefreshes() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.start()
        defer { store.stop() }

        #expect(store.isStarted)
        #expect(store.hasLoaded)
        #expect(store.login == GitHubDemoData.login)
        #expect(store.items.count == 8)
        #expect(store.counts.states == StateCounts(needsYou: 3, failing: 2, done: 1))
        #expect(store.tokens == nil)
        #expect(!store.isDue(at: Date().addingTimeInterval(86_400)))
        store.refresh()
        #expect(!store.isRefreshing)
    }

    @Test func stopForgetsEverything() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.start()
        store.fail(GitHubError.offline)
        store.stop()

        #expect(!store.isStarted)
        #expect(!store.hasLoaded)
        #expect(store.items.isEmpty)
        #expect(store.counts == GitHubGroupCounts())
        #expect(store.problem == nil)
        #expect(store.login == nil)
        #expect(store.notice == nil)
        #expect(!store.moreThanShown)
        #expect(store.refreshedAt == nil)
    }

    @Test func nothingRunsBeforeItStarts() {
        let made = Locked(0)
        let store = liveStore({
            made.update { $0 += 1 }
            return FakeCLI.missing()
        })
        store.refresh()
        store.refreshIfStale()
        #expect(made.value == 0)
        #expect(store.tokens == nil)
        #expect(!store.isRefreshing)
        #expect(!store.isDue(at: Date()))
    }

    @Test func withoutTheCLIItAsksYouToInstallIt() async {
        let store = liveStore(FakeCLI.missing)
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }

        #expect(store.problem == .cliNotFound)
        #expect(store.problem?.needsSignIn == true)
        #expect(store.items.isEmpty)
        #expect(!store.isRefreshing)
        #expect(store.tokens != nil)
    }

    @Test func aSignedOutCLIAsksYouToSignIn() async {
        let runner = FakeRunner(ProcessResult(status: 1, stderr: Data(FakeCLI.signedOut.utf8)))
        let store = liveStore({ FakeCLI.signedOut(runner) })
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }

        #expect(store.problem == .signedOut(FakeCLI.signedOut))
        #expect(runner.calls == [["auth", "token", "--hostname", "github.com"]])
        #expect(await store.tokens?.executablePath == FakeCLI.path)
    }

    /// While you need to sign in or you're offline, it tries again every minute, so a fix shows soon.
    @Test func triesAgainEveryMinuteWhileThereIsSomethingToFix() async {
        let store = liveStore(FakeCLI.missing)
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }
        let started = Date()

        #expect(!store.isDue(at: started.addingTimeInterval(30)))
        #expect(store.isDue(at: started.addingTimeInterval(61)))

        store.fail(GitHubError.offline)
        #expect(store.isDue(at: started.addingTimeInterval(61)))
    }

    @Test func otherwiseReadsAsOftenAsSet() async {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = liveStore(FakeCLI.missing, settings: settings)
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }
        let started = Date()

        store.fail(GitHubError.http(502))
        #expect(!store.isDue(at: started.addingTimeInterval(61)))
        #expect(store.isDue(at: started.addingTimeInterval(121)))

        settings.refreshMinutes = 5
        #expect(!store.isDue(at: started.addingTimeInterval(121)))
        #expect(store.isDue(at: started.addingTimeInterval(301)))
    }

    @Test func waitsAsLongAsGitHubAsked() async {
        let store = liveStore(FakeCLI.missing)
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }
        let started = Date()

        store.fail(GitHubError.throttled(retryAfter: 600))
        #expect(!store.isDue(at: started.addingTimeInterval(300)))
        #expect(store.isDue(at: started.addingTimeInterval(601)))
        store.refresh()
        #expect(!store.isRefreshing)
    }

    @Test func aPopoverOpeningReadsAgainOnlyAfterAWhile() async {
        let store = liveStore(FakeCLI.missing)
        let started = Date()
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }

        store.refreshIfStale()
        // A busy machine can take longer than the gap to get here, and then reading again is right.
        if Date().timeIntervalSince(started) < GitHubStore.minimumGap {
            #expect(!store.isRefreshing)
        }
        store.refresh()
        #expect(store.isRefreshing)
        await eventually { !store.isRefreshing }
    }

    /// A read that ends after GitHub is turned off changes nothing.
    @Test func aReadEndingAfterStopIsIgnored() async throws {
        let runner = FakeRunner(ProcessResult(status: 1, stderr: Data(FakeCLI.signedOut.utf8)), delay: .milliseconds(200))
        let store = liveStore({ FakeCLI.signedOut(runner) })
        store.start()
        #expect(store.isRefreshing)
        store.stop()

        try await Task.sleep(for: .milliseconds(400))
        #expect(store.problem == nil)
        #expect(!store.hasLoaded)
        #expect(!store.isRefreshing)
    }

    /// Signed out, or as someone else: the list was theirs.
    @Test func signingOutClearsTheList() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.start()
        defer { store.stop() }

        store.fail(GitHubAuthError.signedOut("not logged in"))
        #expect(store.problem == .signedOut("not logged in"))
        #expect(store.items.isEmpty)
        #expect(store.counts == GitHubGroupCounts())
        #expect(store.login == nil)
    }

    @Test func otherProblemsKeepTheLastList() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.start()
        defer { store.stop() }

        for error: Error in [GitHubError.offline, GitHubError.http(500), GitHubError.throttled(retryAfter: 60)] {
            store.fail(error)
            #expect(store.problem != nil)
            #expect(store.items.count == 8)
            #expect(store.login == GitHubDemoData.login)
        }

        store.receive(GitHubDemoData.load())
        #expect(store.problem == nil)
    }

    @Test func aCancelledReadIsNotAProblem() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.start()
        defer { store.stop() }

        store.fail(CancellationError())
        #expect(store.problem == nil)
        #expect(store.items.count == 8)
    }

    @Test func groupsTheList() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.start()
        defer { store.stop() }

        for group in GitHubPRGroup.allCases {
            #expect(store.items(in: group).count == store.counts[group])
            #expect(store.items(in: group).allSatisfy { $0.group == group })
        }
    }
}

@MainActor
@Suite struct SettingsTests {
    @Test func readsEveryTwoMinutesAtFirst() {
        let settings = AppSettings(defaults: MemoryDefaults())
        #expect(settings.refreshMinutes == 2)
        #expect(settings.refreshInterval == 120)
    }

    @Test func remembersTheChoice() {
        let defaults = MemoryDefaults()
        AppSettings(defaults: defaults).refreshMinutes = 5
        #expect(defaults.integer(forKey: AppSettings.Key.refreshMinutes) == 5)
        #expect(AppSettings(defaults: defaults).refreshMinutes == 5)
        #expect(AppSettings(defaults: defaults).refreshInterval == 300)
    }

    @Test func aChoiceItDoesntOfferIsTheDefault() {
        for saved in [0, 3, -1, 1_000] {
            let defaults = MemoryDefaults(values: [AppSettings.Key.refreshMinutes: saved])
            #expect(AppSettings(defaults: defaults).refreshMinutes == AppSettings.defaultRefreshMinutes)
        }
    }

    @Test func everyChoiceIsAtLeastAMinute() {
        #expect(AppSettings.refreshChoices.map(\.minutes) == [1, 2, 5, 15])
        #expect(AppSettings.refreshChoices.contains { $0.minutes == AppSettings.defaultRefreshMinutes })
    }
}

/// A tiny lock-protected value for test bookkeeping.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}
