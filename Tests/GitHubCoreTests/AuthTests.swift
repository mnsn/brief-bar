import BriefBarCore
import Foundation
import Testing
@testable import GitHubCore

@Suite struct TokenTests {
    @Test func readsTheTokenOnItsOwnLine() throws {
        #expect(try GitHubCLITokenProvider.parseToken(Data("gho_abc123\n".utf8), now: referenceDate) == GitHubToken(value: "gho_abc123", fetchedAt: referenceDate))
        #expect(try GitHubCLITokenProvider.parseToken(Data("\n   gho_abc123  \n".utf8), now: referenceDate).value == "gho_abc123")
    }

    @Test func noTokenIsAFailure() {
        for output in ["", "\n  \n", "two words\n"] {
            #expect(throws: GitHubAuthError.failed("The GitHub CLI returned no token.")) {
                try GitHubCLITokenProvider.parseToken(Data(output.utf8), now: referenceDate)
            }
        }
    }

    @Test func tellsASignedOutCLIFromOtherFailures() {
        let notLoggedIn = "You are not logged into any GitHub hosts. To log in, run: gh auth login\n"
        #expect(GitHubCLITokenProvider.error(fromOutput: notLoggedIn) == .signedOut(notLoggedIn.trimmingCharacters(in: .newlines)))
        #expect(GitHubCLITokenProvider.error(fromOutput: "no oauth token found for github.com") == .signedOut("no oauth token found for github.com"))
        #expect(GitHubCLITokenProvider.error(fromOutput: "HTTP 401: Authentication required").description == "HTTP 401: Authentication required")
        #expect(GitHubCLITokenProvider.error(fromOutput: "HTTP 401: Authentication required") == .signedOut("HTTP 401: Authentication required"))

        #expect(GitHubCLITokenProvider.error(fromOutput: "\n  something broke  \nmore detail") == .failed("something broke"))
        #expect(GitHubCLITokenProvider.error(fromOutput: "") == .failed("The GitHub CLI failed."))
        #expect(GitHubCLITokenProvider.error(fromOutput: String(repeating: "x", count: 500)) == .failed(String(repeating: "x", count: 300)))
    }

    @Test func anOldCLIIsNamedAsSuch() {
        let tooOld = GitHubAuthError.failed("This GitHub CLI is too old for BriefBar: update it to version 2.17 or later.")
        #expect(GitHubCLITokenProvider.error(fromOutput: "unknown command \"token\" for \"gh auth\"") == tooOld)
        #expect(GitHubCLITokenProvider.error(fromOutput: "unknown flag: --hostname") == tooOld)
    }

    @Test func runsTheCLIWithTheUsualPlacesAndNoPrompts() {
        let environment = GitHubCLITokenProvider.environment(base: ["PATH": "/usr/bin:/custom/bin", "HOME": "/Users/robin"])
        #expect(environment["PATH"] == "/usr/bin:/custom/bin:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"] == "/Users/robin")
        for name in ["GH_PROMPT_DISABLED", "GH_NO_UPDATE_NOTIFIER", "GH_SPINNER_DISABLED", "NO_COLOR"] {
            #expect(environment[name] == "1")
        }
        #expect(GitHubCLITokenProvider.environment(base: [:])["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func errorsSayWhatToDo() {
        #expect(GitHubAuthError.cliNotFound.description == "The GitHub CLI (gh) isn't installed.")
        #expect(GitHubAuthError.signedOut("").description == "Not signed in to the GitHub CLI.")
        #expect(GitHubAuthError.signedOut("Run gh auth login").description == "Run gh auth login")
    }
}

@Suite struct TokenProviderTests {
    private let gh = "/opt/homebrew/bin/gh"

    @Test func asksTheCLIForGitHubDotComsToken() async throws {
        let runner = FakeRunner([.output("gho_first\n")])
        let provider = GitHubCLITokenProvider(locator: .fixed(gh), runner: runner, now: { referenceDate })

        #expect(try await provider.token() == GitHubToken(value: "gho_first", fetchedAt: referenceDate))
        let call = try #require(runner.calls.first)
        #expect(call.executable == gh)
        #expect(call.arguments == ["auth", "token", "--hostname", "github.com"])
        #expect(call.timeout == 30)
        #expect(call.environment?["GH_PROMPT_DISABLED"] == "1")
        #expect(await provider.executablePath == gh)
    }

    @Test func keepsTheTokenForHalfAnHour() async throws {
        let now = Locked(referenceDate)
        let runner = FakeRunner([.output("gho_first"), .output("gho_second")])
        let provider = GitHubCLITokenProvider(locator: .fixed(gh), runner: runner, now: { now.value })

        #expect(try await provider.token().value == "gho_first")
        now.set(t(29 * minute))
        #expect(try await provider.token().value == "gho_first")
        #expect(runner.calls.count == 1)

        now.set(t(30 * minute))
        #expect(try await provider.token().value == "gho_second")
        #expect(runner.calls.count == 2)
    }

    @Test func asksAgainOnceInvalidated() async throws {
        let runner = FakeRunner([.output("gho_first"), .output("gho_second")])
        let provider = GitHubCLITokenProvider(locator: .fixed(gh), runner: runner, now: { referenceDate })

        #expect(try await provider.token().value == "gho_first")
        await provider.invalidate()
        #expect(try await provider.token().value == "gho_second")
        #expect(runner.calls.count == 2)
    }

    @Test func callersAtTheSameTimeShareOneRun() async throws {
        let runner = FakeRunner([.output("gho_shared")], delay: .milliseconds(100))
        let provider = GitHubCLITokenProvider(locator: .fixed(gh), runner: runner, now: { referenceDate })

        async let first = provider.token()
        async let second = provider.token()
        let tokens = try await [first, second]
        #expect(tokens.map(\.value) == ["gho_shared", "gho_shared"])
        #expect(runner.calls.count == 1)
    }

    /// Turning GitHub off cancels the read waiting for a token: the run of `gh` under way stops, and what it would have
    /// printed reaches nothing, not even the next read. The run goes on until it's stopped, however slow the machine.
    @Test(.timeLimit(.minutes(5)))
    func aCallerThatGivesUpStopsTheRunItWaitsFor() async throws {
        let runner = FakeRunner([.output("gho_late"), .output("gho_next")], held: true)
        let provider = GitHubCLITokenProvider(locator: .fixed(gh), runner: runner, now: { referenceDate })

        let reading = Task { try await provider.token() }
        while runner.calls.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        reading.cancel()
        // Until the run stops: if it never did, the time limit would end the test here.
        while runner.stopped == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(runner.stopped == 1)
        runner.release()
        #expect(try await provider.token().value == "gho_next")
        #expect(runner.calls.count == 2)
    }

    /// A caller that gives up gets no token, but the run goes on for another that still waits for it. The run lasts until
    /// the test lets it end, once the caller has given up, however slow the machine.
    @Test(.timeLimit(.minutes(5)))
    func aRunGoesOnForTheCallersStillWaiting() async throws {
        let runner = FakeRunner([.output("gho_shared")], held: true)
        let provider = GitHubCLITokenProvider(locator: .fixed(gh), runner: runner, now: { referenceDate })

        let staying = Task { try await provider.token() }
        while runner.calls.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let leaving = Task { try await provider.token() }
        // Time to join the run; joined or not, it gives up while the run goes on.
        try await Task.sleep(for: .milliseconds(50))
        leaving.cancel()
        runner.release()

        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(try await staying.value.value == "gho_shared")
        #expect(runner.calls.count == 1)
        #expect(runner.stopped == 0)
    }

    @Test func noCLIRunsNothing() async {
        let runner = FakeRunner()
        let provider = GitHubCLITokenProvider(locator: .fixed(nil), runner: runner, now: { referenceDate })

        await #expect(throws: GitHubAuthError.cliNotFound) { try await provider.token() }
        #expect(runner.calls.isEmpty)
        #expect(await provider.executablePath == nil)
    }

    @Test func aSignedOutCLIIsSignedOut() async {
        let runner = FakeRunner([.output("", status: 1, stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login")])
        let provider = GitHubCLITokenProvider(locator: .fixed(gh), runner: runner, now: { referenceDate })

        await #expect(throws: GitHubAuthError.signedOut("You are not logged into any GitHub hosts. To log in, run: gh auth login")) {
            try await provider.token()
        }
    }

    @Test func aFailureIsNotKept() async throws {
        let runner = FakeRunner([.output("", status: 1, stderr: "not logged in"), .output("gho_after_sign_in")])
        let provider = GitHubCLITokenProvider(locator: .fixed(gh), runner: runner, now: { referenceDate })

        await #expect(throws: GitHubAuthError.self) { try await provider.token() }
        #expect(try await provider.token().value == "gho_after_sign_in")
    }

    /// If `gh` can't run, it may have been uninstalled or moved: look for it again next time.
    @Test func looksForTheCLIAgainWhenItCantRun() async throws {
        let looked = Locked(0)
        let gh = gh
        let locator = GitHubCLILocator(environment: [:], candidates: [gh], useLoginShell: false, runner: FakeRunner()) { path in
            looked.update { $0 += 1 }
            return path == gh
        }
        let runner = FakeRunner([.error("launch failed"), .output("gho_found"), .output("gho_again")])
        let provider = GitHubCLITokenProvider(locator: locator, runner: runner, now: { referenceDate })

        await #expect(throws: GitHubAuthError.failed("Couldn't run the GitHub CLI: launch failed")) { try await provider.token() }
        #expect(await provider.executablePath == nil)
        #expect(looked.value == 1)

        #expect(try await provider.token().value == "gho_found")
        #expect(looked.value == 2)

        await provider.invalidate()
        #expect(try await provider.token().value == "gho_again")
        #expect(looked.value == 2)
    }
}

@Suite struct AccountTokenTests {
    private let gh = "/opt/homebrew/bin/gh"

    @Test func asksForAnotherAccountsTokenByItsLogin() async throws {
        let runner = FakeRunner([.output("gho_other\n")])
        let provider = GitHubCLITokenProvider(user: "robin-oss", locator: .fixed(gh), runner: runner, now: { referenceDate })

        #expect(try await provider.token() == GitHubToken(value: "gho_other", fetchedAt: referenceDate))
        #expect(runner.calls.first?.arguments == ["auth", "token", "--hostname", "github.com", "--user", "robin-oss"])
        #expect(provider.user == "robin-oss")
    }

    /// `gh auth logout --user` signed the GitHub CLI out of an account it still lists.
    @Test func anAccountTheCLIHasNoTokenForIsSignedOut() async {
        let message = "no oauth token found for github.com account robin-oss"
        let runner = FakeRunner([.output("", status: 1, stderr: message)])
        let provider = GitHubCLITokenProvider(user: "robin-oss", locator: .fixed(gh), runner: runner, now: { referenceDate })

        await #expect(throws: GitHubAuthError.signedOut(message)) { try await provider.token() }
    }

    @Test func asksForEachTokenByItsLoginUnlessItsInAnEnvironmentVariable() {
        #expect(GitHubAccount(login: "robin", isActive: true).tokenUser == "robin")
        #expect(GitHubAccount(login: "kai", isActive: false).tokenUser == "kai")
        #expect(GitHubAccount(login: "robin", isActive: true, isKept: false).tokenUser == nil)
        #expect(GitHubAccount(login: "", isActive: true).tokenUser == nil)
        #expect(GitHubAccount.active.tokenUser == nil)
    }

    @Test func namesAccountsAsASentenceDoes() {
        #expect(GitHubAccount.names([]).isEmpty)
        #expect(GitHubAccount.names(["robin"]) == "robin")
        #expect(GitHubAccount.names(["robin", "kai"]) == "robin and kai")
        #expect(GitHubAccount.names(["robin", "kai", "lee"]) == "robin, kai and lee")
    }
}

@Suite struct AccountListTests {
    private let gh = "/opt/homebrew/bin/gh"

    private func list(_ status: Int32, _ stdout: String, _ stderr: String = "") -> (accounts: [GitHubAccount], keeps: Bool)? {
        GitHubCLIAccounts.accounts(from: ProcessResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)))
    }

    @Test func listsGitHubDotComsAccountsTheActiveOneFirst() async throws {
        let runner = FakeRunner([.output(Fixture.accounts([("kai", false, "keyring"), ("robin", true, "/Users/robin/.config/gh/hosts.yml")]))])
        let accounts = GitHubCLIAccounts(locator: .fixed(gh), runner: runner, now: { referenceDate })

        #expect(try await accounts.accounts() == [GitHubAccount(login: "robin", isActive: true), GitHubAccount(login: "kai", isActive: false)])
        let call = try #require(runner.calls.first)
        #expect(call.executable == gh)
        #expect(call.arguments == ["auth", "status", "--json", "hosts", "--hostname", "github.com"])
        #expect(call.timeout == 30)
        #expect(call.environment?["GH_PROMPT_DISABLED"] == "1")
        #expect(await accounts.executablePath == gh)
    }

    @Test func onlyGitHubDotComsAccountsAreListed() {
        let output = #"{"hosts":{"ghe.example.com":[{"login":"robin-ghe","active":true,"tokenSource":"keyring"}],"github.com":[{"login":"robin","active":true,"tokenSource":"keyring"}]}}"#
        #expect(list(0, output)?.accounts.map(\.login) == ["robin"])
    }

    /// GH_TOKEN holds a token: its account is the active one, and those the GitHub CLI keeps follow, each login once.
    @Test func aTokenInAnEnvironmentVariableIsTheActiveAccounts() throws {
        let listed = try #require(list(0, Fixture.accounts([("robin", true, "GH_TOKEN"), ("kai", false, "keyring"), ("robin", false, "keyring")])))
        #expect(listed.keeps)
        #expect(listed.accounts == [GitHubAccount(login: "robin", isActive: true, isKept: false), GitHubAccount(login: "kai", isActive: false)])
        #expect(listed.accounts.map(\.tokenUser) == [nil, "kai"])
    }

    @Test func tellsATokenInAnEnvironmentVariableFromOneTheCLIKeeps() {
        for source in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN"] {
            #expect(GitHubCLIAccounts.isEnvironmentVariable(source))
        }
        for source in ["keyring", "/Users/robin/.config/gh/hosts.yml", "", nil] as [String?] {
            #expect(!GitHubCLIAccounts.isEnvironmentVariable(source))
        }
    }

    /// A token in the keychain without a user in the GitHub CLI's settings: it can't say whose it is.
    @Test func anUnnamedActiveAccountIsReadWithoutALogin() throws {
        let listed = try #require(list(0, Fixture.accounts([("", true, "keyring")])))
        #expect(listed.keeps)
        #expect(listed.accounts == [GitHubAccount(login: "", isActive: true)])
        #expect(listed.accounts.first?.tokenUser == nil)
    }

    @Test func withoutAListTheActiveAccountIsRead() throws {
        // Signed out: it lists none, and reading the active account says to sign in.
        for output in [#"{"hosts":{}}"#, #"{"hosts":{"github.com":[]}}"#] {
            let none = try #require(list(0, output))
            #expect(none.accounts == [.active])
            #expect(!none.keeps)
        }
        // Too old to list them: its active account, until it's updated.
        let old = try #require(list(1, "", "unknown flag: --json\n\nUsage:  gh auth status [flags]"))
        #expect(old.accounts == [.active])
        #expect(old.keeps)
        // It failed, as when it took longer than it may and was stopped, or printed something else.
        for (status, output) in [(Int32(1), ""), (15, ""), (0, ""), (0, "not JSON")] {
            #expect(list(status, output, "something broke") == nil, "\(status) \(output)")
        }
    }

    /// Listing them failed, as when `gh` took longer than it may on a network that doesn't answer, or couldn't run: the
    /// accounts the last listing that worked gave, and they're listed again at the next call.
    @Test func aListingThatFailsGivesTheAccountsLastListed() async throws {
        let runner = FakeRunner([
            .output(Fixture.accounts(["robin", "kai"])), .output("", status: 15), .error("launch failed"),
            .output(Fixture.accounts(["robin"])),
        ])
        let accounts = GitHubCLIAccounts(locator: .fixed(gh), runner: runner, now: { referenceDate })

        #expect(try await accounts.accounts().map(\.login) == ["robin", "kai"])
        await accounts.invalidate()
        #expect(try await accounts.accounts().map(\.login) == ["robin", "kai"])
        #expect(try await accounts.accounts().map(\.login) == ["robin", "kai"])
        #expect(try await accounts.accounts().map(\.login) == ["robin"])
        #expect(runner.calls.count == 4)
    }

    @Test func keepsTheListForHalfAnHour() async throws {
        let now = Locked(referenceDate)
        let runner = FakeRunner([.output(Fixture.accounts(["robin"])), .output(Fixture.accounts(["robin", "kai"]))])
        let accounts = GitHubCLIAccounts(locator: .fixed(gh), runner: runner, now: { now.value })

        #expect(try await accounts.accounts().map(\.login) == ["robin"])
        now.set(t(29 * minute))
        #expect(try await accounts.accounts().map(\.login) == ["robin"])
        #expect(runner.calls.count == 1)

        now.set(t(30 * minute))
        #expect(try await accounts.accounts().map(\.login) == ["robin", "kai"])
        #expect(runner.calls.count == 2)
    }

    @Test func listsAgainOnceInvalidated() async throws {
        let runner = FakeRunner([.output(Fixture.accounts(["robin"])), .output(Fixture.accounts(["kai", "robin"]))])
        let accounts = GitHubCLIAccounts(locator: .fixed(gh), runner: runner, now: { referenceDate })

        #expect(try await accounts.accounts().map(\.login) == ["robin"])
        await accounts.invalidate()
        #expect(try await accounts.accounts().map(\.login) == ["kai", "robin"])
        #expect(runner.calls.count == 2)
    }

    /// Signed out, it's asked again each time, so a sign-in shows at the next read.
    @Test func aListThatDidntWorkIsntKept() async throws {
        let runner = FakeRunner([.output(#"{"hosts":{}}"#), .output(Fixture.accounts(["robin"]))])
        let accounts = GitHubCLIAccounts(locator: .fixed(gh), runner: runner, now: { referenceDate })

        #expect(try await accounts.accounts() == [.active])
        #expect(try await accounts.accounts().map(\.login) == ["robin"])
        #expect(runner.calls.count == 2)
    }

    @Test func anOldCLIsActiveAccountIsKept() async throws {
        let runner = FakeRunner([.output("", status: 1, stderr: "unknown flag: --json")])
        let accounts = GitHubCLIAccounts(locator: .fixed(gh), runner: runner, now: { referenceDate })

        #expect(try await accounts.accounts() == [.active])
        #expect(try await accounts.accounts() == [.active])
        #expect(runner.calls.count == 1)
    }

    /// Reading the active account then says the GitHub CLI isn't installed.
    @Test func withoutTheCLIItRunsNothing() async throws {
        let runner = FakeRunner()
        let accounts = GitHubCLIAccounts(locator: .fixed(nil), runner: runner, now: { referenceDate })

        #expect(try await accounts.accounts() == [.active])
        #expect(runner.calls.isEmpty)
        #expect(await accounts.executablePath == nil)
    }

    /// If `gh` can't run, it may have been uninstalled or moved: look for it again next time.
    @Test func looksForTheCLIAgainWhenItCantRun() async throws {
        let looked = Locked(0)
        let gh = gh
        let locator = GitHubCLILocator(environment: [:], candidates: [gh], useLoginShell: false, runner: FakeRunner()) { path in
            looked.update { $0 += 1 }
            return path == gh
        }
        let runner = FakeRunner([.error("launch failed"), .output(Fixture.accounts(["robin"]))])
        let accounts = GitHubCLIAccounts(locator: locator, runner: runner, now: { referenceDate })

        #expect(try await accounts.accounts() == [.active])
        #expect(await accounts.executablePath == nil)
        #expect(try await accounts.accounts().map(\.login) == ["robin"])
        #expect(looked.value == 2)
    }

    /// Turning GitHub off cancels a read while it lists the accounts: the run of `gh` stops, and nothing is kept.
    @Test(.timeLimit(.minutes(5)))
    func aCallerThatGivesUpStopsTheRun() async throws {
        let runner = FakeRunner([.output(Fixture.accounts(["robin"])), .output(Fixture.accounts(["kai"]))], held: true)
        let accounts = GitHubCLIAccounts(locator: .fixed(gh), runner: runner, now: { referenceDate })

        let listing = Task { try await accounts.accounts() }
        while runner.calls.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        listing.cancel()
        while runner.stopped == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await #expect(throws: CancellationError.self) { try await listing.value }
        runner.release()
        #expect(try await accounts.accounts().map(\.login) == ["kai"])
    }
}

@Suite struct LocatorTests {
    @Test func anOverrideComesFirst() async {
        let locator = GitHubCLILocator(
            environment: [GitHubCLILocator.overrideVariable: "/custom/gh"], candidates: ["/opt/homebrew/bin/gh"],
            useLoginShell: false, runner: FakeRunner()
        ) { _ in true }
        #expect(await locator.locate()?.path == "/custom/gh")
    }

    @Test func anOverrideMayStartAtHome() {
        let locator = GitHubCLILocator(environment: [GitHubCLILocator.overrideVariable: "~/bin/gh"], runner: FakeRunner())
        #expect(locator.override == (("~/bin/gh" as NSString).expandingTildeInPath))
        #expect(GitHubCLILocator(environment: [GitHubCLILocator.overrideVariable: ""], runner: FakeRunner()).override == nil)
    }

    @Test func aMissingOverrideFallsBackToTheUsualPlaces() async {
        let locator = GitHubCLILocator(
            environment: [GitHubCLILocator.overrideVariable: "/missing/gh"], candidates: ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"],
            useLoginShell: false, runner: FakeRunner()
        ) { $0 == "/usr/local/bin/gh" }
        #expect(await locator.locate()?.path == "/usr/local/bin/gh")
    }

    @Test func looksInTheUsualPlaces() {
        #expect(GitHubCLILocator.defaultCandidates.contains("/opt/homebrew/bin/gh"))
        #expect(GitHubCLILocator.defaultCandidates.contains("/usr/local/bin/gh"))
    }

    @Test func asksALoginShellLast() async throws {
        let runner = FakeRunner([.output("Welcome!\n/Users/robin/.nix-profile/bin/gh\n")])
        let locator = GitHubCLILocator(environment: [:], candidates: ["/opt/homebrew/bin/gh"], runner: runner) {
            $0 == "/Users/robin/.nix-profile/bin/gh"
        }
        #expect(await locator.locate()?.path == "/Users/robin/.nix-profile/bin/gh")
        let call = try #require(runner.calls.first)
        #expect(call.arguments == ["-l", "-c", "command -v gh"])
    }

    @Test func findsNothingWhenTheShellDoesnt() async {
        let failed = GitHubCLILocator(environment: [:], candidates: [], runner: FakeRunner([.output("", status: 1)])) { _ in true }
        #expect(await failed.locate() == nil)

        let notExecutable = GitHubCLILocator(environment: [:], candidates: [], runner: FakeRunner([.output("/tmp/gh\n")])) { _ in false }
        #expect(await notExecutable.locate() == nil)

        let notAPath = GitHubCLILocator(environment: [:], candidates: [], runner: FakeRunner([.output("gh not found\n")])) { _ in true }
        #expect(await notAPath.locate() == nil)

        let runner = FakeRunner()
        let noShell = GitHubCLILocator(environment: [:], candidates: [], useLoginShell: false, runner: runner) { _ in true }
        #expect(await noShell.locate() == nil)
        #expect(runner.calls.isEmpty)
    }
}
