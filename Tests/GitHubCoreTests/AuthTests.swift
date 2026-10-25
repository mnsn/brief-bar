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
