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
