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
        #expect(store.logins == [GitHubDemoData.login])
        #expect(store.items.count == 8)
        #expect(store.counts.states == StateCounts(needsYou: 3, failing: 2, done: 1))
        #expect(store.reader == nil)
        #expect(!store.isDue(at: Date().addingTimeInterval(86_400)))
        store.refresh()
        #expect(!store.isRefreshing)
    }

    @Test func stopForgetsEverything() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.start()
        store.fail(GitHubError.offline)
        store.fail(GitHubError.throttled(retryAfter: 600))
        store.stop()

        #expect(!store.isStarted)
        #expect(!store.hasLoaded)
        #expect(store.items.isEmpty)
        #expect(store.counts == GitHubGroupCounts())
        #expect(store.problem == nil)
        #expect(store.waitsUntil == nil)
        #expect(store.login == nil)
        #expect(store.logins.isEmpty)
        #expect(store.notice == nil)
        #expect(!store.moreThanShown)
        #expect(store.refreshedAt == nil)
        #expect(store.listsAccountsUntil == nil)
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
        #expect(store.reader == nil)
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
        #expect(store.reader != nil)
    }

    @Test func aSignedOutCLIAsksYouToSignIn() async {
        let runner = FakeRunner(ProcessResult(status: 1, stderr: Data(FakeCLI.signedOut.utf8)))
        let store = liveStore({ FakeCLI.signedOut(runner) })
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }

        #expect(store.problem == .signedOut(FakeCLI.signedOut))
        // It lists no account, so it reads the active one, which says to sign in.
        #expect(runner.calls == [FakeCLI.listing, FakeCLI.token])
        #expect(await store.reader?.executablePath == FakeCLI.path)
    }

    /// While you need to sign in or you're offline, it tries again every minute, so a fix shows soon.
    @Test func triesAgainEveryMinuteWhileThereIsSomethingToFix() async throws {
        let store = liveStore(FakeCLI.missing)
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }
        // From when the read started, as `isDue` counts, however late the wait for it ends.
        let started = try #require(store.lastAttempt)

        #expect(!store.isDue(at: started.addingTimeInterval(30)))
        #expect(store.isDue(at: started.addingTimeInterval(61)))

        store.fail(GitHubError.offline)
        #expect(store.isDue(at: started.addingTimeInterval(61)))
    }

    @Test func otherwiseReadsAsOftenAsSet() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = liveStore(FakeCLI.missing, settings: settings)
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }
        // From when the read started, as `isDue` counts, however late the wait for it ends.
        let started = try #require(store.lastAttempt)

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
        // GitHub's wait counts from when it asks, which is now, rather than from the read.
        let started = Date()

        store.fail(GitHubError.throttled(retryAfter: 600))
        #expect(!store.isDue(at: started.addingTimeInterval(300)))
        #expect(store.isDue(at: started.addingTimeInterval(601)))
        store.refresh()
        #expect(!store.isRefreshing)
    }

    /// GitHub asked the first account to slow down, and another couldn't be read for something else: it reads again as
    /// often as set, as that one may be read sooner. It waits as long as GitHub asked only when it asked that as each.
    @Test func waitsForGitHubOnlyWhenItAskedThatAsEveryAccount() async throws {
        let store = liveStore(FakeCLI.missing)
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }
        // From when the read started, as `isDue` counts, however late the wait for it ends.
        let started = try #require(store.lastAttempt)
        let load = GitHubLoad(login: "robin", logins: ["robin", "robin-oss"], items: [])

        store.fail(GitHubAccountsReader.Failure(error: GitHubError.throttled(retryAfter: 3_600), load: load))
        #expect(store.problem?.message.hasPrefix("GitHub asked BriefBar to slow down") == true)
        #expect(store.waitsUntil == nil)
        #expect(store.isDue(at: started.addingTimeInterval(121)))

        let asked = Date()
        store.fail(GitHubAccountsReader.Failure(
            error: GitHubError.throttled(retryAfter: 3_600), load: load, waitsUntil: asked.addingTimeInterval(600)
        ))
        #expect(!store.isDue(at: asked.addingTimeInterval(300)))
        #expect(store.isDue(at: asked.addingTimeInterval(601)))
        store.refresh()
        #expect(!store.isRefreshing)
    }

    /// GitHub asked every account to slow down: Refresh Now, and the wait after you choose to sign in, still list the
    /// accounts and read, so that one you sign in to shows. Each account's own wait holds what it would send.
    @Test func listingTheAccountsAgainReadsWhileGitHubAskedEveryAccountToSlowDown() async throws {
        let store = liveStore(FakeCLI.missing)
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded && !store.isRefreshing }
        let load = GitHubLoad(login: "robin", logins: ["robin", "robin-oss"], items: [])
        func slowDown() -> Date {
            let asked = Date()
            store.fail(GitHubAccountsReader.Failure(
                error: GitHubError.throttled(retryAfter: 3_600), load: load, waitsUntil: asked.addingTimeInterval(3_600)
            ))
            return asked
        }

        _ = slowDown()
        store.refresh(listingAccounts: true)
        #expect(store.isRefreshing)
        await eventually { !store.isRefreshing }

        let asked = slowDown()
        #expect(!store.isDue(at: asked.addingTimeInterval(61)))
        store.waitForSignIn()
        let started = try #require(store.lastAttempt)
        #expect(store.isDue(at: started.addingTimeInterval(61)))
        store.refresh()
        #expect(store.isRefreshing)
        await eventually { !store.isRefreshing }
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

    /// Turning GitHub off stops a run of `gh` that's under way, so what it would print reaches nothing. The run would take
    /// longer than the test may, so it ends only when it's stopped, however slow the machine.
    @Test(.timeLimit(.minutes(1)))
    func stoppingStopsTheCLIRunUnderWay() async throws {
        let runner = FakeRunner(ProcessResult(status: 1, stderr: Data(FakeCLI.signedOut.utf8)), delay: .seconds(3_600))
        let store = liveStore({ FakeCLI.signedOut(runner) })
        store.start()
        while runner.calls.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.stop()

        while runner.stopped == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(runner.calls.count == 1)
        #expect(runner.stopped == 1)
        #expect(store.problem == nil)
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
        #expect(store.logins.isEmpty)
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
            #expect(store.logins == [GitHubDemoData.login])
        }

        store.receive(GitHubDemoData.load())
        #expect(store.problem == nil)
    }

    /// None of its accounts could be read, and some not for a sign-in: it shows what's left of each one's list, with that
    /// problem. One that takes signing in again empties the list, which every view hides then.
    @Test func whenNoAccountCanBeReadItShowsWhatsLeftOfEach() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.start()
        defer { store.stop() }
        let items = GitHubDemoData.load().items
        let notice = "Sign in to the GitHub CLI again to see robin-oss's pull requests."
        let offline = GitHubLoad(login: "robin", logins: ["robin", "robin-oss"], items: Array(items.prefix(3)), notice: notice)

        store.fail(GitHubAccountsReader.Failure(error: GitHubError.offline, load: offline))
        #expect(store.problem == .offline)
        #expect(store.items == offline.items)
        #expect(store.counts == offline.counts)
        #expect(store.login == "robin")
        #expect(store.logins == ["robin", "robin-oss"])
        #expect(store.notice == notice)

        let left = GitHubLoad(login: "robin", logins: ["robin", "robin-oss"], items: Array(items.suffix(2)))
        store.fail(GitHubAccountsReader.Failure(error: GitHubAuthError.signedOut("not logged in"), load: left))
        #expect(store.problem == .signedOut("not logged in"))
        #expect(store.items.isEmpty)
        #expect(store.counts == GitHubGroupCounts())
        #expect(store.logins.isEmpty)
        #expect(store.notice == nil)
    }

    @Test func aCancelledReadIsNotAProblem() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.start()
        defer { store.stop() }

        store.fail(CancellationError())
        #expect(store.problem == nil)
        #expect(store.items.count == 8)
    }

    /// An empty list is "All quiet" only once a read has worked and read every pull request there is.
    @Test func itsAllQuietOnlyWhenItReadThemAll() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        let none = GitHubLoad(login: "robin", items: [])
        #expect(!store.isAllQuiet)

        // Before any read has worked.
        store.fail(GitHubError.offline)
        #expect(store.items.isEmpty)
        #expect(!store.isAllQuiet)
        store.receive(none)
        #expect(store.isAllQuiet)

        // Offline, GitHub out of reach or asking to slow down, or signed out: the list may not be empty.
        let problems: [Error] = [
            GitHubError.offline, GitHubError.http(502), GitHubError.throttled(retryAfter: 60), GitHubAuthError.signedOut("not logged in"),
        ]
        for error in problems {
            store.fail(error)
            #expect(store.items.isEmpty)
            #expect(!store.isAllQuiet, "\(error)")
            store.receive(none)
        }

        // Some pull requests couldn't be read, or more matched than it reads.
        store.receive(GitHubLoad(login: "robin", items: [], notice: "Some pull requests couldn't be read: no access"))
        #expect(!store.isAllQuiet)
        store.receive(GitHubLoad(login: "robin", items: [], moreThanShown: true))
        #expect(!store.isAllQuiet)

        store.receive(none)
        #expect(store.isAllQuiet)
        store.receive(GitHubDemoData.load())
        #expect(!store.isAllQuiet)
    }

    /// After you choose to sign in, it reads every minute, until an account it didn't read as shows, or for ten minutes.
    @Test func waitingForASignInReadsEveryMinuteUntilItShows() async throws {
        let store = liveStore(FakeCLI.missing)
        store.start()
        defer { store.stop() }
        await eventually { store.hasLoaded }
        store.receive(GitHubLoad(login: "robin", logins: ["robin", "kai"], items: []))
        // From when the read started, as `isDue` counts, however late the wait for it ends.
        let started = try #require(store.lastAttempt)
        #expect(!store.isDue(at: started.addingTimeInterval(61)))

        store.waitForSignIn()
        #expect(store.isDue(at: started.addingTimeInterval(61)))
        #expect(!store.isListingAccounts(at: Date().addingTimeInterval(GitHubStore.signInWait + 1)))
        // The same accounts, in another order, as `gh auth login` and `gh auth switch` leave them, or fewer: it goes on.
        for logins in [["robin", "kai"], ["kai", "robin"], ["robin"]] {
            store.receive(GitHubLoad(login: logins[0], logins: logins, items: []))
            #expect(store.isListingAccounts(at: Date()), "\(logins)")
        }
        // One it didn't read as shows: every two minutes again.
        store.receive(GitHubLoad(login: "robin", logins: ["robin", "robin-oss"], items: []))
        #expect(store.listsAccountsUntil == nil)
        #expect(!store.isDue(at: started.addingTimeInterval(61)))
        #expect(store.logins == ["robin", "robin-oss"])
    }

    @Test func theDemoWaitsForNoSignIn() {
        let store = GitHubStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        store.start()
        defer { store.stop() }

        store.waitForSignIn()
        #expect(store.listsAccountsUntil == nil)
    }

    /// It keeps the list of the GitHub CLI's accounts for half an hour, but lists them again at each read while it waits
    /// for you to sign in, and when you refresh now.
    @Test func listsTheAccountsAgainWhenAskedTo() async throws {
        // Lists an account, but can't get its token, so nothing connects.
        let runner = FakeRunner { arguments in
            arguments == FakeCLI.listing
                ? ProcessResult(status: 0, stdout: Data(FakeCLI.robin.utf8)) : ProcessResult(status: 1, stderr: Data("something broke".utf8))
        }
        let store = liveStore({ FakeCLI.installed(runner) })
        store.start()
        defer { store.stop() }
        func read(listingAccounts: Bool = false) async {
            await eventually { !store.isRefreshing }
            store.refresh(listingAccounts: listingAccounts)
            await eventually { !store.isRefreshing }
        }
        func listed() -> Int { runner.calls.filter { $0 == FakeCLI.listing }.count }

        await eventually { store.hasLoaded && !store.isRefreshing }
        #expect(store.problem == .authFailed("something broke"))
        #expect(listed() == 1)
        await read()
        #expect(listed() == 1)
        await read(listingAccounts: true)
        #expect(listed() == 2)
        store.waitForSignIn()
        await read()
        #expect(listed() == 3)
        #expect(runner.calls.filter { $0 == FakeCLI.token + ["--user", "robin"] }.count == 4)
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
