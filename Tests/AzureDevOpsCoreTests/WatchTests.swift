import Foundation
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
}
