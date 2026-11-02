import Foundation
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// Where in a pull request the links BriefBar makes lead, for its details in BriefBar's window to show it there: a comment
/// thread, or a run. With made-up pull requests.
@Suite struct PullRequestPlaceTests {
    @Test func readsTheThreadOrTheRunALinkLeadsTo() {
        let thread = ADOEndpoint.pullRequestPage(organization: "contoso", project: "Shop Web", repository: "shop web", id: 4102, threadId: 11)
        #expect(PullRequestPlace(link: thread) == .thread(11))
        let run = ADOEndpoint.buildPage(organization: "contoso", project: "Shop Web", buildId: 82_109)
        #expect(PullRequestPlace(link: run) == .run(82_109))
        // As Azure DevOps' older addresses have them, too.
        let older = URL(string: "https://contoso.visualstudio.com/Shop/_git/web/pullrequest/4102?_a=overview&discussionId=7")!
        #expect(PullRequestPlace(link: older) == .thread(7))
    }

    @Test func leadsNowhereElse() {
        let links = [
            ADOEndpoint.pullRequestPage(organization: "contoso", project: "Shop", repository: "web", id: 4102),
            ADOEndpoint.workItemPage(organization: "contoso", project: "Shop", id: 5160),
            ADOEndpoint.myPullRequestsPage(organization: "contoso"),
            URL(string: "https://dev.azure.com/contoso/Shop/_git/web/pullrequest/4102?discussionId=0")!,
            URL(string: "https://dev.azure.com/contoso/Shop/_git/web/pullrequest/4102?discussionId=first")!,
            URL(string: "https://dev.azure.com/contoso/Shop/_build?definitionId=12")!,
            URL(string: "https://example.com/contoso/Shop/_git/web/pullrequest/4102?discussionId=7")!,
            URL(string: "https://example.com/?discussionId=7")!,
        ]
        for link in links {
            #expect(PullRequestPlace(link: link) == nil, "\(link)")
        }
    }

    /// Where each made-up pull request's row opens it: the comment that needs you, or the run after its merge that waits for
    /// an approval; the pull request itself for one whose build failed, which isn't a link to its run, or that's ready.
    @Test func aRowLeadsWhereItsLinkDoes() throws {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let rows = DemoData.records(now: now).compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), dismissedCutoff: seen.dismissedCutoff(for: $0.id), now: now)
        }
        func place(_ number: Int) throws -> PullRequestPlace? {
            try #require(rows.first { $0.key.number == number }).place
        }
        #expect(try place(4102) == .thread(11))
        #expect(try place(4097) == .thread(21))
        #expect(try place(4085) == .run(82_109))
        #expect(try place(4088) == nil)
        #expect(try place(4091) == nil)
        #expect(try place(4113) == nil)
    }

    /// A notification about one of a thread's comments leads to that thread, rather than to the one its row opens at.
    @Test func aNotificationLeadsToItsOwnThread() throws {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let record = try #require(DemoData.records(now: now).first { $0.id.number == 4102 })
        let row = try #require(PRClassifier.snapshot(
            for: record, seenCutoff: seen.cutoff(for: record.id), dismissedCutoff: seen.dismissedCutoff(for: record.id), now: now
        ))
        let event = PREvent(id: "c12", kind: .comment, at: now, actor: "Priya Shah", text: "One more thing.", threadId: 12)
        let note = NotificationPlanner.note(for: event, in: row)
        #expect(note.url.flatMap(PullRequestPlace.init(link:)) == .thread(12))
        // And to its pull request, by the key it keeps.
        let key = try #require(note.key)
        #expect(PRKey(description: key.description) == key)
    }

    @Test func readsAKeyAsItsWritten() {
        #expect(PRKey(description: "contoso/4102") == PRKey("contoso", 4102))
        #expect(PRKey(description: PRKey("Contoso-Labs", 7).description)?.organization == "Contoso-Labs")
        for text in ["contoso", "contoso/", "/4102", "contoso/four", "contoso/0", "contoso/-3", ""] {
            #expect(PRKey(description: text) == nil, "\(text)")
        }
    }
}
