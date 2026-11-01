import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// Pull requests you watch by their links, though you're not on them.
@Suite struct WatchTests {
    @Test func oneYouWatchIsListedAsIfYouReviewedIt() throws {
        let pr = makePR(author: People.alex)
        let record = PRRecord(pullRequest: pr, role: .linked, details: makeDetails(for: pr, lastActivity: t(-hour)), me: People.me.id)
        // Not watched, and not sent in a chat: not listed.
        #expect(PRClassifier.snapshot(for: record, seenCutoff: t(-day), dismissedCutoff: t(-day), now: t(0)) == nil)

        let watched = record.watched()
        #expect(watched.role == .reviewer)
        #expect(watched.isWatched)
        let snapshot = try #require(PRClassifier.snapshot(for: watched, seenCutoff: t(-day), dismissedCutoff: t(-day), now: t(0)))
        #expect(snapshot.group == .toReview)
        #expect(snapshot.headline == "Watching")
        #expect(snapshot.detail == "By Alex Kim")
        #expect(snapshot.isWatched)

        // A mention there needs you, as on any review.
        let mention = ReviewThread(id: 3, comments: [comment(1, People.alex, "@Robin could you look?", at: t(-minute), mentions: [People.me])])
        let mentioned = PRRecord(pullRequest: pr, role: .linked, details: makeDetails(for: pr, threads: [mention]), me: People.me.id).watched()
        #expect(PRClassifier.snapshot(for: mentioned, seenCutoff: t(-day), dismissedCutoff: t(-day), now: t(0))?.reason == .mentioned)

        // Once you're a reviewer, or it's yours, it's that.
        let named = makePR(author: People.alex, reviewers: [Reviewer(person: People.me, vote: .none, isRequired: true)])
        let review = PRRecord(pullRequest: named, role: .reviewer, details: makeDetails(for: named, lastActivity: t(-hour)), me: People.me.id)
        #expect(PRClassifier.snapshot(for: review.watched(), seenCutoff: t(-day), dismissedCutoff: t(-day), now: t(0))?.headline == "Required review")
        #expect(PRRecord(pullRequest: makePR(), role: .author, me: People.me.id).watched().role == .author)
    }

    @Test func linksToPullRequestsThatClosedOrAreGoneAreReported() async throws {
        let server = StubServer()
        server.serveOrganization()
        server.on("/contoso/_apis/git/pullrequests/8", json: Fixture.pullRequest(8, author: People.alex))
        server.on("/contoso/_apis/git/pullrequests/9", json: Fixture.pullRequest(9, author: People.alex, status: "completed", closed: t(0)))
        server.on("/contoso/_apis/git/pullrequests/10") { _ in .status(404) }
        server.on("/contoso/_apis/git/pullrequests/11") { _ in .status(500) }
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) { _ in }
        let keys = Set([8, 9, 10, 11].map { PRKey(Fixture.org, $0) })
        await engine.setLinkedPullRequests(keys)
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id.number) == [8])
        // A failure that may pass isn't a reason to stop watching.
        #expect(snapshot.closedLinks == [PRKey(Fixture.org, 9), PRKey(Fixture.org, 10)])

        // Not asked for anymore: not reported.
        await engine.setLinkedPullRequests([PRKey(Fixture.org, 8), PRKey(Fixture.org, 10)])
        #expect(await engine.currentSnapshot().closedLinks == [PRKey(Fixture.org, 10)])
    }

    /// Asked to slow down, BriefBar reads the rest of the pull requests you watch at a refresh once it may ask again,
    /// rather than an hour later: being asked to slow down isn't a failure of theirs.
    @Test func askedToSlowDownItReadsThemAgainAtTheNextRefresh() async throws {
        let clock = Mutex(t(0))
        let server = StubServer()
        server.serveOrganization()
        server.on("/contoso/_apis/git/pullrequests/8") { _ in .status(429, headers: ["Retry-After": "0.05"]) }
        server.on("/contoso/_apis/git/pullrequests/9", json: Fixture.pullRequest(9, author: People.alex))
        let engine = PulseEngine(
            client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org]), now: { clock.withLock { $0 } }
        ) { _ in }
        await engine.setLinkedPullRequests([PRKey(Fixture.org, 8), PRKey(Fixture.org, 9)])
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().records.isEmpty)
        // Nothing more was asked for once Azure DevOps said to slow down.
        #expect(!server.requests.contains { $0.url?.path.hasSuffix("/pullrequests/9") == true })

        // A minute later, once it may ask again, both are read.
        server.on("/contoso/_apis/git/pullrequests/8", json: Fixture.pullRequest(8, author: People.alex))
        try await Task.sleep(for: .milliseconds(300))
        clock.withLock { $0 = t(minute) }
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id.number) == [8, 9])
        #expect(snapshot.closedLinks.isEmpty)
    }

    /// Azure DevOps ignores the letter case of an organization's name: a link that spells it differently is to the pull
    /// request found in your lists, which is listed once, as it was found, and isn't read again by its link.
    @Test func aLinkThatSpellsTheOrganizationDifferentlyIsThePullRequestFound() async throws {
        let server = StubServer()
        let pullRequest = Fixture.pullRequest(42, author: People.alex, reviewers: [Fixture.reviewer(People.me)])
        server.serveOrganization(reviewing: [pullRequest])
        server.on("/Contoso/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/Contoso/_apis/git/pullrequests/42", json: pullRequest)
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) { _ in }
        await engine.setLinkedPullRequests([PRKey("Contoso", 42)])
        await engine.refreshNow()

        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.count == 1)
        let record = try #require(snapshot.records.first)
        #expect(record.id.organization == Fixture.org)
        #expect(record.id == PRKey("Contoso", 42))
        #expect(record.role == .reviewer)
        #expect(snapshot.closedLinks.isEmpty)
        #expect(!server.requests.contains { $0.url?.path.contains("/Contoso/") == true })
    }

    @Test func keysTellOrganizationsApartIgnoringTheirCase() {
        #expect(PRKey("Contoso", 42) == PRKey("contoso", 42))
        #expect(Set([PRKey("Contoso", 42), PRKey("CONTOSO", 42), PRKey("contoso", 43)]).count == 2)
        #expect(PRKey("Contoso", 42) != PRKey("Fabrikam", 42))
        #expect(!(PRKey("Contoso", 42) < PRKey("contoso", 42)) && !(PRKey("contoso", 42) < PRKey("Contoso", 42)))
        #expect(PRKey("contoso", 42) < PRKey("Fabrikam", 7))
        // Each keeps its own spelling.
        #expect(PRKey("Contoso", 42).description == "Contoso/42")
    }
}
