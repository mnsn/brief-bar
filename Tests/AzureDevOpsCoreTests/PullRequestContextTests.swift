import BriefBarCore
import Foundation
import Testing
@testable import AzureDevOpsCore

/// What a pull request adds to a summary of it, read only as one is written: its description, in plain text, and how its
/// comment threads go, from Azure DevOps with GETs, or as your pull requests' were read.
@Suite struct PullRequestContextTests {
    private let me = People.me.id

    // MARK: Its comment threads

    @Test func theThreadsSayWhatsUnresolvedTheOpenOnesFirstThenHowManyAreResolved() {
        let threads = [
            ReviewThread(id: 1, status: "fixed", filePath: "/src/Coupon.swift", line: 12, comments: [
                comment(1, People.alex, "Round half up?", at: t(-3 * hour)), comment(2, People.me, "Done.", at: t(-2 * hour)),
            ]),
            ReviewThread(id: 2, filePath: "/src/Cart.swift", line: 42, comments: [
                comment(1, People.sam, "Could we cap the backoff at 30 seconds?", at: t(-2 * hour)),
                comment(2, People.priya, "Agreed, 30 seconds is plenty.", at: t(-hour)),
                comment(3, People.me, "Capped it.", at: t(-30 * minute)),
            ]),
            ReviewThread(id: 3, status: nil, comments: [comment(1, People.bot, "Code coverage is 82%.", at: t(-10 * minute))]),
            ReviewThread(id: 4, status: "pending", comments: [
                comment(1, People.priya, "Do any partners still call the v1 endpoint?", at: t(-4 * hour)),
            ]),
            ReviewThread(id: 5, status: "wontFix", comments: [comment(1, People.sam, "Rename the enum?", at: t(-day))]),
            ReviewThread(id: 6, status: "closed", filePath: "/README.md", comments: [comment(1, People.alex, "A typo.", at: t(-2 * day))]),
        ]
        // The open ones first, then the one without a status, each the newest first; then the latest resolved, in brief.
        #expect(PullRequestContext.digest(threads, me: me) == """
            Unresolved (3):
            Sam Rivera on src/Cart.swift:42: Could we cap the backoff at 30 seconds? — You: Capped it.
            Priya Shah: Do any partners still call the v1 endpoint?
            Shop Build Service: Code coverage is 82%.
            Resolved (3), the latest: Alex Kim on src/Coupon.swift:12: Round half up? (fixed); Sam Rivera: Rename the enum? (won't fix)
            """)
        // Without knowing who you are, you're named as anyone is.
        #expect(PullRequestContext.digest(threads).contains("— Robin Diaz: Capped it."))
        #expect(PullRequestContext.digest([]) == "No comments.")
        #expect(PullRequestContext.digest([threads[0]], me: me) == """
            Unresolved: none
            Resolved (1): Alex Kim on src/Coupon.swift:12: Round half up? (fixed)
            """)
        #expect(PullRequestContext.digest([threads[3]], me: me) == """
            Unresolved (1):
            Priya Shah: Do any partners still call the v1 endpoint?
            Resolved: none
            """)
    }

    @Test func aThreadSaysWhichFileItsOnFromTheRepositorysRoot() {
        func place(_ path: String?, line: Int? = nil) -> String? {
            PullRequestContext.place(ReviewThread(id: 1, filePath: path, line: line, comments: []))
        }
        #expect(place("/src/Cart.swift", line: 42) == "src/Cart.swift:42")
        #expect(place("/src/Cart.swift") == "src/Cart.swift")
        #expect(place(nil) == nil)
        #expect(place("/") == nil)
        // A long path, by its file's name.
        #expect(place("/" + String(repeating: "deep/", count: 25) + "Cart.swift", line: 3) == "Cart.swift:3")
    }

    /// When they don't all fit, each says less, and then the last ones are left out, saying how many.
    @Test func theThreadsAreCutToFit() throws {
        let long = String(repeating: "Totals round down for coupons in every currency. ", count: 20)
        let open = (1...12).map { index in
            ReviewThread(id: index, filePath: "/src/File\(index).swift", line: index, comments: [
                comment(1, People.sam, long, at: t(Double(-index) * hour)),
                comment(2, People.priya, long, at: t(Double(-index) * hour + 60)),
            ])
        }
        let resolved = ReviewThread(id: 99, status: "fixed", comments: [comment(1, People.alex, "Typo.", at: t(-day))])
        let digest = PullRequestContext.digest(open + [resolved], me: me)
        #expect(digest.count <= PullRequestContext.threadsLimit)
        let lines = digest.components(separatedBy: "\n")
        #expect(lines.first == "Unresolved (12):")
        #expect(lines[1].hasPrefix("Sam Rivera on src/File1.swift:1: Totals round down"))
        #expect(lines[1].contains(" — Priya Shah: Totals round down"))
        #expect(lines[1].count < 400)
        let more = try #require(lines.first { $0.hasSuffix(" more)") })
        #expect(more == "(\(13 - lines.firstIndex(of: more)!) more)")
        #expect(lines.last == "Resolved (1): Alex Kim: Typo. (fixed)")

        // In full when they fit: what was said first, then the latest reply, each cut to its length.
        let few = PullRequestContext.digest(Array(open.prefix(2)), me: me).components(separatedBy: "\n")
        #expect(few.count == 4)
        #expect(few[1].count > 600)
        #expect(few[1].count < 800)
    }

    // MARK: Its description

    @Test func aDescriptionIsPlainTextWithoutWhatItsTemplateAsks() throws {
        let markdown = """
            <!-- Say what changed, and why. -->
            Round coupon totals **half up**, as [finance](https://example.invalid/finance) asked. Thanks @<\(People.sam.id.uppercased())>!

            ## Testing
            - Rounding tests for every currency
            - [x] Checked by hand, with `SAVE15`

            <!-- Link the work item
            """
        #expect(PullRequestContext.description(markdown, names: [People.sam.id: People.sam.name]) == """
            Round coupon totals half up, as finance asked. Thanks @Sam Rivera!
            Testing
            • Rounding tests for every currency
            [x] Checked by hand, with SAVE15
            """)
        #expect(PullRequestContext.description(" \n<!-- Say what changed. -->\n") == nil)
        let repeated = String(repeating: "Saved items move back to the cart in one click. ", count: 100)
        let long = try #require(PullRequestContext.description(repeated))
        #expect(long.count <= PullRequestContext.descriptionLimit)
        #expect(long.count > PullRequestContext.descriptionLimit - 100)
        #expect(long.hasSuffix("…"))
    }

    @Test func readsAPullRequestsDescriptionWhenItHasOne() throws {
        let described = try Fixture.decode(ADOPullRequest.self, Fixture.pullRequest(7, description: "Fix the total."))
        #expect(described.description == "Fix the total.")
        #expect(try Fixture.decode(ADOPullRequest.self, Fixture.pullRequest(7)).description == nil)
    }

    // MARK: Reading Azure DevOps

    /// Someone else's pull request: its description, then its threads where it says it is now, but for the system threads
    /// that record votes and pushes, and those deleted.
    @Test func readsSomeoneElsesPullRequestsDescriptionAndThreads() async throws {
        let server = StubServer()
        let description = "Saves items for later. @<\(People.priya.id.uppercased())> has the design.\n\n"
            + String(repeating: "An account keeps up to 50 saved items. ", count: 120)
        server.on("/_apis/git/pullrequests/4120", json: Fixture.pullRequest(
            4120, title: "Save items for later", author: People.sam, reviewers: [Fixture.reviewer(People.priya)], project: "p9",
            repository: "r9", description: description
        ))
        var deleted = Fixture.thread(3, comments: [Fixture.comment(1, People.alex, "Never mind.", at: t(-hour))], published: t(-hour))
        deleted["isDeleted"] = true
        server.on("/p9/_apis/git/repositories/r9/pullRequests/4120/threads", json: Fixture.list([
            Fixture.thread(1, comments: [
                Fixture.comment(1, People.priya, "Should saved items expire?", at: t(-hour)),
                Fixture.comment(2, People.sam, "After 90 days.", at: t(-30 * minute)),
            ], published: t(-hour), filePath: "/src/SavedItems.cs"),
            Fixture.activity(2, "VoteUpdate", at: t(-20 * minute), by: People.priya, properties: ["CodeReviewVoteResult": "10"]),
            deleted,
        ]))
        // As it was last read, somewhere else.
        let known = makePR(4120, title: "Save items for later", author: People.sam)
        let parts = await PullRequestContext.read(known, me: me, client: server.client())
        #expect(parts.map(\.label) == ["Description", "Comment threads"])
        let read = parts[0].value
        #expect(read.hasPrefix("Saves items for later. @Priya Shah has the design.\nAn account keeps up to 50 saved items."))
        #expect(read.count <= PullRequestContext.descriptionLimit)
        #expect(read.hasSuffix("…"))
        #expect(parts[1].value == """
            Unresolved (1):
            Priya Shah on src/SavedItems.cs:12: Should saved items expire? — Sam Rivera: After 90 days.
            Resolved: none
            """)
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func yourPullRequestsThreadsAreTheOnesItsGiven() async {
        let server = StubServer()
        server.on("/_apis/git/pullrequests/7", json: Fixture.pullRequest(7, description: "Fix the total."))
        server.on("/threads", json: Fixture.list([]))
        let threads = [ReviewThread(id: 1, comments: [comment(1, People.sam, "Could we cap it?", at: t(-hour))])]
        let parts = await PullRequestContext.read(makePR(7), threads: threads, me: me, client: server.client())
        #expect(parts == [
            ItemStory.Fact("Description", "Fix the total."),
            ItemStory.Fact("Comment threads", "Unresolved (1):\nSam Rivera: Could we cap it?\nResolved: none"),
        ])
        #expect(server.requests.map { $0.url?.path } == ["/contoso/_apis/git/pullrequests/7"])
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func aReadThatFailsLeavesItsPartOut() async {
        // The pull request can't be read: its threads are, where it was last read.
        let unread = StubServer()
        unread.on("/_apis/git/pullrequests/7") { _ in .status(500) }
        unread.on("/p1/_apis/git/repositories/r1/pullRequests/7/threads", json: Fixture.list([
            Fixture.thread(1, comments: [Fixture.comment(1, People.sam, "Could we cap it?", at: t(-hour))], published: t(-hour)),
        ]))
        #expect(await PullRequestContext.read(makePR(7), client: unread.client()) == [
            ItemStory.Fact("Comment threads", "Unresolved (1):\nSam Rivera: Could we cap it?\nResolved: none"),
        ])
        // Its threads can't be read.
        let forbidden = StubServer()
        forbidden.on("/_apis/git/pullrequests/7", json: Fixture.pullRequest(7, description: "Fix the total."))
        forbidden.on("/threads") { _ in .status(403) }
        #expect(await PullRequestContext.read(makePR(7), client: forbidden.client()) == [ItemStory.Fact("Description", "Fix the total.")])
        // Without a description, there's nothing to say of it; without comments, it says so.
        let quiet = StubServer()
        quiet.on("/_apis/git/pullrequests/7", json: Fixture.pullRequest(7))
        quiet.on("/threads", json: Fixture.list([]))
        #expect(await PullRequestContext.read(makePR(7), client: quiet.client()) == [ItemStory.Fact("Comment threads", "No comments.")])
        for server in [unread, forbidden, quiet] {
            #expect(server.requests.count == 2)
            #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    @Test func readsNothingMoreOnceAzureDevOpsAsksToSlowDown() async {
        let server = StubServer()
        server.on("/_apis/git/pullrequests/7") { _ in .status(429, headers: ["Retry-After": "30"]) }
        server.on("/threads", json: Fixture.list([]))
        let client = server.client()
        #expect(await PullRequestContext.read(makePR(7), client: client).isEmpty)
        #expect(server.requests.count == 1)
        // Asked to wait, it reads nothing, but what it's given still counts: your pull request's threads.
        let threads = [ReviewThread(id: 1, comments: [comment(1, People.sam, "Could we cap it?", at: t(-hour))])]
        #expect(await PullRequestContext.read(makePR(7), threads: threads, client: client).map(\.label) == ["Comment threads"])
        #expect(server.requests.count == 1)
    }

    @Test func readsNothingOnceItsTaskIsCancelled() async {
        let server = StubServer()
        server.on("/_apis/git/pullrequests/7", json: Fixture.pullRequest(7, description: "Fix the total."))
        server.on("/threads", json: Fixture.list([]))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await PullRequestContext.read(makePR(7), client: server.client())
        }
        #expect(await task.value.isEmpty)
        #expect(server.requests.isEmpty)
    }
}
