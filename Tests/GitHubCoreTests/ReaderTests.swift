import BriefBarCore
import Foundation
import Testing
@testable import GitHubCore

@Suite struct ReaderTests {
    @Test func readsTheListFromTheAnswer() throws {
        let shared = Fixture.pullRequest(5, repository: "octo/shared", author: Fixture.me, reviewDecision: "APPROVED")
        let data = try Fixture.queryData(Fixture.answer(
            reviewing: [Fixture.pullRequest(1, updated: t(minute)), shared],
            authored: [shared, Fixture.pullRequest(2, author: Fixture.me, rollup: "FAILURE")]
        ))

        let load = GitHubReader.load(from: data)
        #expect(load.login == Fixture.me)
        #expect(load.items.map(\.id) == ["PR_octo/app_1", "PR_octo/app_2", "PR_octo/shared_5"])
        #expect(load.items.map(\.group) == [.toReview, .failing, .ready])
        #expect(load.notice == nil)
        #expect(!load.moreThanShown)
        #expect(load.counts.states == StateCounts(needsYou: 1, failing: 1, done: 1))
    }

    @Test func saysWhenMoreMatchThanItReads() throws {
        let reviewing = try Fixture.queryData(Fixture.answer(reviewing: [Fixture.pullRequest(1)], reviewingCount: 51))
        #expect(GitHubReader.load(from: reviewing).moreThanShown)
        let authored = try Fixture.queryData(Fixture.answer(authored: [Fixture.pullRequest(1)], authoredCount: 2))
        #expect(GitHubReader.load(from: authored).moreThanShown)
    }

    @Test func singleSignOnGetsItsOwnNotice() {
        let errors = [
            GraphQLError(type: "NOT_FOUND", message: "Could not resolve"),
            GraphQLError(type: "FORBIDDEN", message: "Resource protected by organization SAML enforcement. You must grant your OAuth token access."),
        ]
        #expect(GitHubReader.notice(for: errors) == "Some organizations use single sign-on: authorize the GitHub CLI for them to see their pull requests.")
    }

    @Test func otherErrorsSayWhatCouldntBeRead() {
        #expect(GitHubReader.notice(for: []) == nil)
        #expect(GitHubReader.notice(for: [GraphQLError(message: "Something odd")]) == "Some pull requests couldn't be read: Something odd")
        let long = String(repeating: "y", count: 400)
        #expect(GitHubReader.notice(for: [GraphQLError(message: long)]) == "Some pull requests couldn't be read: \(String(repeating: "y", count: 200))")
    }

    @Test func readsFromGitHubInOneRequest() async throws {
        let server = StubServer()
        server.reply(.json(Fixture.answer(
            reviewing: [Fixture.pullRequest(1)], authored: [Fixture.pullRequest(2, author: Fixture.me, reviewDecision: "CHANGES_REQUESTED")],
            errors: [["type": "FORBIDDEN", "message": "SAML enforcement"]]
        )))

        let load = try await GitHubReader.load(client: server.client())
        #expect(server.received.count == 1)
        #expect(load.counts.toReview == 1)
        #expect(load.counts.changesRequested == 1)
        #expect(load.notice?.contains("single sign-on") == true)
    }

    @Test func theDemoMatchesWhatItsChecksExpect() {
        let now = referenceDate
        let load = GitHubDemoData.load(now: now)
        #expect(load.login == GitHubDemoData.login)
        let counts = load.counts
        #expect(Dictionary(uniqueKeysWithValues: GitHubPRGroup.allCases.map { ($0.rawValue, counts[$0]) }) == GitHubDemoData.expectedCounts)
        #expect(counts.states == StateCounts(needsYou: 3, failing: 2, done: 1))
        #expect(load.items.allSatisfy { $0.since <= now })
        #expect(Set(load.items.map(\.id)).count == load.items.count)
        #expect(load.items.allSatisfy { $0.pullRequest.url.host == "github.com" })
    }
}

@Suite struct ProblemTests {
    @Test func mapsErrorsToWhatTheUserCanDo() {
        let now = referenceDate
        #expect(GitHubProblem.from(GitHubAuthError.cliNotFound, now: now) == .cliNotFound)
        #expect(GitHubProblem.from(GitHubError.auth(.cliNotFound), now: now) == .cliNotFound)
        #expect(GitHubProblem.from(GitHubAuthError.signedOut("not logged in"), now: now) == .signedOut("not logged in"))
        #expect(GitHubProblem.from(GitHubError.auth(.failed("boom")), now: now) == .authFailed("boom"))
        #expect(GitHubProblem.from(GitHubError.unauthorized, now: now) == .signedOut(GitHubError.unauthorized.description))
        #expect(GitHubProblem.from(GitHubError.offline, now: now) == .offline)
        #expect(GitHubProblem.from(GitHubError.throttled(retryAfter: 120), now: now) == .throttled(until: t(120)))
        #expect(GitHubProblem.from(GitHubError.http(500), now: now) == .unreachable("GitHub answered with HTTP 500."))
        #expect(GitHubProblem.from(GitHubError.forbidden, now: now) == .unreachable("GitHub refused the request."))
        #expect(GitHubProblem.from(URLError(.badURL), now: now) == .unreachable(URLError(.badURL).localizedDescription))
        // No account could be read: why the GitHub CLI's active one couldn't.
        let failure = GitHubAccountsReader.Failure(error: GitHubError.throttled(retryAfter: 120), load: GitHubLoad(login: "robin", items: []))
        #expect(GitHubProblem.from(failure, now: now) == .throttled(until: t(120)))
    }

    @Test func onlyAMissingSignInNeedsOne() {
        #expect(GitHubProblem.cliNotFound.needsSignIn)
        #expect(GitHubProblem.signedOut("").needsSignIn)
        for problem in [GitHubProblem.authFailed("x"), .offline, .throttled(until: referenceDate), .unreachable("x")] {
            #expect(!problem.needsSignIn)
        }
    }

    @Test func messagesSayWhatsWrong() {
        #expect(GitHubProblem.cliNotFound.message.contains("isn't installed"))
        #expect(GitHubProblem.signedOut("x").message == "Sign in to the GitHub CLI to see your pull requests.")
        #expect(GitHubProblem.authFailed("boom").message == "Couldn't get a token from the GitHub CLI: boom")
        #expect(GitHubProblem.unreachable("GitHub refused the request.").message == "GitHub refused the request. The list may be out of date.")
        #expect(GitHubProblem.throttled(until: referenceDate).message.hasPrefix("GitHub asked BriefBar to slow down, until "))
    }
}

/// Every account the GitHub CLI is signed in to, each read from a stub server of its own, by its login.
@Suite struct AccountsReaderTests {
    private let gh = "/opt/homebrew/bin/gh"

    /// Reads the accounts that `runner` lists, or `logins`, the first active, each from its server; with its own tokens
    /// where `tokens` has them.
    private func reader(
        _ logins: [String], servers: [String: StubServer], tokens: [String: any GitHubTokenProviding] = [:], runner: FakeRunner? = nil
    ) -> (reader: GitHubAccountsReader, runner: FakeRunner) {
        let runner = runner ?? FakeRunner(fallback: .output(Fixture.accounts(logins)))
        let accounts = GitHubCLIAccounts(locator: .fixed(gh), runner: runner, now: { referenceDate })
        let reader = GitHubAccountsReader(accounts: accounts) { account in
            (servers[account.login] ?? StubServer()).client(tokens: tokens[account.login])
        }
        return (reader, runner)
    }

    @Test func readsEveryAccountAndListsEachPullRequestOnce() async throws {
        let work = StubServer()
        let own = StubServer()
        // Robin asked their own account to review a pull request they opened as robin: it's theirs, once.
        let shared = Fixture.pullRequest(2, author: "robin", rollup: "FAILURE")
        work.always(.json(Fixture.answer(login: "robin", reviewing: [Fixture.pullRequest(1)], authored: [shared])))
        own.always(.json(Fixture.answer(
            login: "robin-oss", reviewing: [shared],
            authored: [Fixture.pullRequest(3, repository: "robin-oss/tool", author: "robin-oss", reviewDecision: "APPROVED")]
        )))
        let (reader, runner) = reader(["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own])

        let load = try await reader.load()
        #expect(load.login == "robin")
        #expect(load.logins == ["robin", "robin-oss"])
        #expect(load.items.map(\.pullRequest.reference) == ["octo/app#1", "octo/app#2", "robin-oss/tool#3"])
        #expect(load.items.map(\.group) == [.toReview, .failing, .ready])
        #expect(load.items.map(\.role) == [.reviewer, .author, .author])
        #expect(load.notice == nil)
        #expect(!load.moreThanShown)
        #expect(work.received.count == 1)
        #expect(own.received.count == 1)
        #expect(runner.calls.map(\.arguments) == [["auth", "status", "--json", "hosts", "--hostname", "github.com"]])
    }

    /// The list of accounts is kept for half an hour; each read reads every account in it.
    @Test func listsTheAccountsOnlyWhenAskedOrHalfAnHourOn() async throws {
        let work = StubServer()
        work.always(.json(Fixture.answer(login: "robin")))
        let (reader, runner) = reader(["robin"], servers: ["robin": work])

        _ = try await reader.load()
        _ = try await reader.load()
        #expect(runner.calls.count == 1)
        #expect(work.received.count == 2)

        await reader.listAgain()
        _ = try await reader.load()
        #expect(runner.calls.count == 2)
        #expect(await reader.executablePath == gh)
    }

    /// One account's read is as BriefBar's was before it read more: its notices say nothing of whose.
    @Test func oneAccountIsReadAsBefore() async throws {
        let server = StubServer()
        server.always(.json(Fixture.answer(
            reviewing: [Fixture.pullRequest(1)], authoredCount: 51, errors: [["type": "FORBIDDEN", "message": "SAML enforcement"]]
        )))
        let (reader, _) = reader([Fixture.me], servers: [Fixture.me: server])

        let load = try await reader.load()
        let alone = try await GitHubReader.load(client: server.client())
        #expect(load == alone)
        #expect(load.logins == [Fixture.me])
        #expect(load.moreThanShown)
        #expect(load.notice == "Some organizations use single sign-on: authorize the GitHub CLI for them to see their pull requests.")
    }

    /// With a GitHub CLI too old to list its accounts, its active one is read, as before.
    @Test func aCLITooOldToListItsAccountsHasItsActiveOneRead() async throws {
        let server = StubServer()
        server.always(.json(Fixture.answer(login: "robin", authored: [Fixture.pullRequest(1, author: "robin")])))
        let made = Locked<[GitHubAccount]>([])
        let runner = FakeRunner(fallback: .output("", status: 1, stderr: "unknown flag: --json"))
        let reader = GitHubAccountsReader(accounts: GitHubCLIAccounts(locator: .fixed(gh), runner: runner, now: { referenceDate })) { account in
            made.update { $0.append(account) }
            return server.client()
        }

        let load = try await reader.load()
        _ = try await reader.load()
        #expect(made.value == [.active])
        #expect(load.logins == ["robin"])
        #expect(load.items.count == 1)
    }

    @Test func whatEachAccountCouldntReadSaysWhose() async throws {
        let work = StubServer()
        let own = StubServer()
        work.always(.json(Fixture.answer(login: "robin", errors: [["type": "FORBIDDEN", "message": "SAML enforcement"]])))
        own.always(.json(Fixture.answer(login: "robin-oss", authored: [Fixture.pullRequest(1, author: "robin-oss")], authoredCount: 60)))
        let (reader, _) = reader(["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own])

        let load = try await reader.load()
        #expect(load.notice == "robin: Some organizations use single sign-on: authorize the GitHub CLI for them to see their pull requests.")
        #expect(load.moreThanShown)
    }

    /// An account it can't read just now keeps what it read last, and the list says why it may be out of date.
    @Test func anAccountItCantReadKeepsItsLastList() async throws {
        let work = StubServer()
        let own = StubServer()
        work.always(.json(Fixture.answer(login: "robin", reviewing: [Fixture.pullRequest(1)])))
        own.reply(.json(Fixture.answer(login: "robin-oss", authored: [Fixture.pullRequest(3, author: "robin-oss")])), .text("oops", status: 502))
        let (reader, _) = reader(["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own])

        let first = try await reader.load()
        let second = try await reader.load()
        #expect(first.items.count == 2)
        #expect(second.items == first.items)
        #expect(second.logins == ["robin", "robin-oss"])
        #expect(second.notice == "Couldn't read robin-oss's pull requests: GitHub answered with HTTP 502. The list may be out of date.")
    }

    /// An account GitHub doesn't take the GitHub CLI's token for anymore: its pull requests go, and the list says to sign
    /// in again.
    @Test func anAccountThatNeedsSigningInAgainLeavesTheList() async throws {
        let work = StubServer()
        let own = StubServer()
        work.always(.json(Fixture.answer(login: "robin", reviewing: [Fixture.pullRequest(1)])))
        own.reply(
            .json(Fixture.answer(login: "robin-oss", authored: [Fixture.pullRequest(3, author: "robin-oss")])),
            .text("Bad credentials", status: 401), .text("Bad credentials", status: 401)
        )
        let (reader, runner) = reader(["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own])

        _ = try await reader.load()
        let second = try await reader.load()
        #expect(second.items.map(\.pullRequest.number) == [1])
        #expect(second.logins == ["robin", "robin-oss"])
        #expect(second.notice == "Sign in to the GitHub CLI again to see robin-oss's pull requests.")
        // GitHub refused the token: there's no need to list the accounts again for that.
        #expect(runner.calls.count == 1)
    }

    /// The GitHub CLI has no token for an account it still listed, as once you sign it out of one: the accounts are listed
    /// again at the next read.
    @Test func anAccountTheCLIHasNoTokenForHasTheAccountsListedAgain() async throws {
        let work = StubServer()
        work.always(.json(Fixture.answer(login: "robin")))
        let signedOut = GitHubAuthError.signedOut("no oauth token found for github.com account robin-oss")
        let runner = FakeRunner([.output(Fixture.accounts(["robin", "robin-oss"])), .output(Fixture.accounts(["robin"]))])
        let (reader, _) = reader(
            [], servers: ["robin": work], tokens: ["robin-oss": FakeTokens("none", error: signedOut)], runner: runner
        )

        let first = try await reader.load()
        #expect(first.notice == "Sign in to the GitHub CLI again to see robin-oss's pull requests.")
        let second = try await reader.load()
        #expect(runner.calls.count == 2)
        #expect(second.logins == ["robin"])
        #expect(second.notice == nil)
    }

    @Test func anAccountNoLongerListedIsntRead() async throws {
        let work = StubServer()
        let own = StubServer()
        work.always(.json(Fixture.answer(login: "robin")))
        own.always(.json(Fixture.answer(login: "robin-oss", authored: [Fixture.pullRequest(3, author: "robin-oss")])))
        let runner = FakeRunner([.output(Fixture.accounts(["robin", "robin-oss"])), .output(Fixture.accounts(["robin"]))])
        let (reader, _) = reader([], servers: ["robin": work, "robin-oss": own], runner: runner)

        #expect(try await reader.load().items.count == 1)
        await reader.listAgain()
        let load = try await reader.load()
        #expect(load.logins == ["robin"])
        #expect(load.items.isEmpty)
        #expect(own.received.count == 1)
    }

    /// GitHub asking one account's reads to slow down holds that account's alone: until it said, the others are read,
    /// and the list keeps what it last read of that one.
    @Test func anAccountGitHubSlowsDownDoesntHoldTheOthers() async throws {
        let work = StubServer()
        let own = StubServer()
        work.always(.json(Fixture.answer(login: "robin", reviewing: [Fixture.pullRequest(1)])))
        own.reply(
            .json(Fixture.answer(login: "robin-oss", authored: [Fixture.pullRequest(3, author: "robin-oss")])),
            .text("slow down", status: 429, headers: ["Retry-After": "600"])
        )
        let (reader, _) = reader(["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own])

        _ = try await reader.load()
        let slowed = try await reader.load()
        let held = try await reader.load()
        for load in [slowed, held] {
            #expect(load.items.count == 2)
            #expect(load.notice?.hasPrefix("Couldn't read robin-oss's pull requests: GitHub asked BriefBar to slow down, until ") == true)
        }
        #expect(own.received.count == 2)
        #expect(work.received.count == 3)
    }

    @Test func oneAccountThatCantBeReadFailsAsBefore() async throws {
        let server = StubServer()
        server.always(.failure(.notConnectedToInternet))
        let (reader, _) = reader([Fixture.me], servers: [Fixture.me: server])

        await #expect(throws: GitHubError.offline) { try await reader.load() }
    }

    /// No account can be read: it fails as the first one did, the GitHub CLI's active account, with what's left of the
    /// list, as when only some can't be read. What it last read of one offline stays, and one that needs signing in again
    /// goes, as the list says; what's wrong with the first, the list's problem, isn't said again.
    @Test func whenNoAccountCanBeReadItFailsAsTheFirstDidWithWhatsLeft() async throws {
        let work = StubServer()
        let own = StubServer()
        work.reply(.json(Fixture.answer(login: "robin", reviewing: [Fixture.pullRequest(1)])))
        work.always(.failure(.notConnectedToInternet))
        own.reply(
            .json(Fixture.answer(login: "robin-oss", authored: [Fixture.pullRequest(3, author: "robin-oss")])),
            .text("Bad credentials", status: 401), .text("Bad credentials", status: 401)
        )
        let (reader, _) = reader(["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own])

        #expect(try await reader.load().items.count == 2)
        let failure = try await #require(throws: GitHubAccountsReader.Failure.self) { try await reader.load() }
        #expect(failure.error as? GitHubError == .offline)
        #expect(GitHubProblem.from(failure) == .offline)
        #expect(failure.load.items.map(\.pullRequest.number) == [1])
        #expect(failure.load.logins == ["robin", "robin-oss"])
        #expect(failure.load.notice == "Sign in to the GitHub CLI again to see robin-oss's pull requests.")
        #expect(failure.waitsUntil == nil)
    }

    /// The other way round: the first account takes signing in again, so its pull requests go, and the list says so, as
    /// when only some can't be read; what was last read of the other, which GitHub couldn't answer just now, stays, and
    /// that's what's wrong with the list, which a sign-in wouldn't fix.
    @Test func whenTheFirstNeedsSigningInAgainTheOthersKeepTheirLastList() async throws {
        let work = StubServer()
        let own = StubServer()
        work.reply(
            .json(Fixture.answer(login: "robin", reviewing: [Fixture.pullRequest(1)])),
            .text("Bad credentials", status: 401), .text("Bad credentials", status: 401)
        )
        own.reply(.json(Fixture.answer(login: "robin-oss", authored: [Fixture.pullRequest(3, author: "robin-oss")])))
        own.always(.text("oops", status: 502))
        let (reader, _) = reader(["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own])

        _ = try await reader.load()
        let failure = try await #require(throws: GitHubAccountsReader.Failure.self) { try await reader.load() }
        #expect(GitHubProblem.from(failure) == .unreachable("GitHub answered with HTTP 502."))
        #expect(failure.load.items.map(\.pullRequest.number) == [3])
        #expect(failure.load.logins == ["robin", "robin-oss"])
        #expect(failure.load.notice == "Sign in to the GitHub CLI again to see robin's pull requests.")
    }

    /// Every account takes signing in again: it fails as one account does, and the list goes.
    @Test func whenEveryAccountNeedsSigningInAgainItFailsAsOneDoes() async throws {
        let work = StubServer()
        let own = StubServer()
        work.always(.text("Bad credentials", status: 401))
        own.always(.text("Bad credentials", status: 401))
        let (reader, _) = reader(["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own])

        await #expect(throws: GitHubError.unauthorized) { try await reader.load() }
    }

    /// What's wrong as every account alike is said once, as the list's problem.
    @Test func whatsWrongAsEveryAccountIsSaidOnce() async throws {
        let work = StubServer()
        let own = StubServer()
        work.always(.failure(.notConnectedToInternet))
        own.always(.failure(.notConnectedToInternet))
        let (reader, _) = reader(["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own])

        let failure = try await #require(throws: GitHubAccountsReader.Failure.self) { try await reader.load() }
        #expect(GitHubProblem.from(failure) == .offline)
        #expect(failure.load.notice == nil)
        #expect(failure.load.items.isEmpty)
        #expect(failure.load.logins == ["robin", "robin-oss"])
    }

    /// GitHub asking the first account to slow down for an hour doesn't hold another, which GitHub couldn't answer just
    /// now: it may be read again sooner.
    @Test func waitsForGitHubOnlyWhenItAskedThatAsEveryAccount() async throws {
        let work = StubServer()
        let own = StubServer()
        work.always(.text("slow down", status: 429, headers: ["Retry-After": "3600"]))
        own.always(.text("oops", status: 502))
        let (reader, _) = reader(["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own])

        let failure = try await #require(throws: GitHubAccountsReader.Failure.self) { try await reader.load() }
        guard case .throttled = GitHubProblem.from(failure) else {
            Issue.record("The list's problem is the first account's: GitHub asked it to slow down.")
            return
        }
        #expect(failure.waitsUntil == nil)
        #expect(failure.load.notice == "Couldn't read robin-oss's pull requests: GitHub answered with HTTP 502. The list may be out of date.")
    }

    @Test func waitsUntilTheSoonestTimeGitHubGaveAsEachAccount() {
        #expect(GitHubAccountsReader.waitsUntil([.throttled(until: t(600)), .throttled(until: t(300))]) == t(300))
        #expect(GitHubAccountsReader.waitsUntil([.throttled(until: t(600)), .unreachable("x")]) == nil)
        #expect(GitHubAccountsReader.waitsUntil([.offline, .throttled(until: t(300))]) == nil)
    }

    /// Two accounts that turn out to be one, such as the active one's token, which the GitHub CLI can't say whose it is,
    /// and the account it's from: listed once, as the first.
    @Test func accountsThatTurnOutToBeOneAreListedOnce() async throws {
        let unnamed = StubServer()
        let named = StubServer()
        unnamed.always(.json(Fixture.answer(login: "robin", reviewing: [Fixture.pullRequest(1)])))
        named.always(.json(Fixture.answer(login: "robin", reviewing: [Fixture.pullRequest(1), Fixture.pullRequest(5)])))
        let runner = FakeRunner(fallback: .output(Fixture.accounts([("", true, "keyring"), ("robin", false, "keyring")])))
        let (reader, _) = reader([], servers: ["": unnamed, "robin": named], runner: runner)

        let load = try await reader.load()
        #expect(load.logins == ["robin"])
        #expect(load.items.map(\.pullRequest.number) == [1])
    }

    /// Turning GitHub off as a token comes: the read gives up, and nothing it read goes anywhere.
    @Test func aReadThatGivesUpReadsNothing() async throws {
        let work = StubServer()
        let own = StubServer()
        work.always(.json(Fixture.answer(login: "robin")))
        let (reader, _) = reader(
            ["robin", "robin-oss"], servers: ["robin": work, "robin-oss": own], tokens: ["robin-oss": GivingUpTokens(server: own.id)]
        )

        await #expect(throws: CancellationError.self) { try await reader.load() }
        #expect(own.received.isEmpty)
    }

    @Test func anUnnamedAccountIsCalledTheActiveOne() {
        let load = GitHubReader.merge([
            GitHubReader.AccountRead(account: .active, load: nil, problem: .offline),
            GitHubReader.AccountRead(account: GitHubAccount(login: "kai", isActive: false), load: GitHubLoad(login: "kai", items: [])),
        ])
        #expect(load.login == "kai")
        #expect(load.logins == ["kai"])
        #expect(load.notice == "Couldn't read the GitHub CLI's active account's pull requests: You're offline. The list may be out of date.")
    }
}
