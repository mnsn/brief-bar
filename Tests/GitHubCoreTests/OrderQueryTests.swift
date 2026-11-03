import BriefBarCore
import Foundation
import Testing
@testable import GitHubCore

@Suite struct OrderQueryTests {
    /// A pull request as the order's query answers it: with the branch it merges into, whether it's a fork's, the
    /// repository's default branch, and its GitHub stack.
    static func orderPullRequest(
        _ number: Int, branch: String, base: String, isCrossRepository: Bool = false,
        stack: [(position: Int, number: Int, state: String)]? = nil, stackNumber: Int = 41
    ) -> [String: Any] {
        var object = Fixture.pullRequest(number, author: Fixture.me)
        object["headRefName"] = branch
        object["baseRefName"] = base
        object["isCrossRepository"] = isCrossRepository
        object["repository"] = ["nameWithOwner": "octo/app", "defaultBranchRef": ["name": "main"]]
        if let stack {
            object["stackEntry"] = [
                "position": stack.first { $0.number == number }?.position ?? 1,
                "stack": [
                    "number": stackNumber,
                    "baseRefName": "main",
                    "entries": ["nodes": stack.map { member in
                        ["position": member.position, "pullRequest": ["number": member.number, "state": member.state,
                                                                       "repository": ["nameWithOwner": "octo/app"]]]
                    }],
                ] as [String: Any],
            ]
        } else {
            object["stackEntry"] = NSNull()
        }
        return object
    }

    /// GitHub's GraphQL API takes reads and writes the same way, so the order's query must only read too, with the same
    /// variables as the usual one.
    @Test func theOrdersQueryIsTheUsualOneWithWhatAnOrderNeedsAndOnlyReads() {
        let text = PullRequestQuery.orderText.lowercased()
        #expect(text.hasPrefix("query "))
        #expect(!text.contains("mutation"))
        #expect(!text.contains("subscription"))
        let orderFields = [
            " baseRefName", "isCrossRepository", "defaultBranchRef { name }", "stackEntry {", "number baseRefName",
            "entries(first: 50) { nodes { position pullRequest { number state repository { nameWithOwner } } } }",
        ]
        for field in orderFields {
            #expect(PullRequestQuery.orderText.contains(field), "\(field)")
            #expect(!PullRequestQuery.text.contains(field), "\(field)")
        }
        for field in ["headRefName", "reviewDecision", "mergeable", "statusCheckRollup", "latestOpinionatedReviews", "rateLimit"] {
            #expect(PullRequestQuery.orderText.contains(field), "\(field)")
        }
        #expect(PullRequestQuery.orderText.contains("$reviewing: String!, $authored: String!, $count: Int!"))
    }

    @Test func withTheOrderOnTheClientSendsTheOrdersQueryAndSaysSo() async throws {
        let server = StubServer()
        server.reply(.json(Fixture.answer(authored: [Self.orderPullRequest(7, branch: "robin/cart", base: "robin/rounding")])))

        let result = try await server.client().pullRequests(order: true)

        #expect(result.hasOrder)
        #expect(server.received.first?.json["query"] as? String == PullRequestQuery.orderText)
        let pullRequest = GitHubPullRequest(try #require(result.data.authored.nodes.first))
        #expect(pullRequest.order == .init(baseBranch: "robin/rounding", isFork: false, defaultBranch: "main"))
    }

    @Test func whenGitHubLacksAFieldTheUsualQueryGoesInsteadFromThenOn() async throws {
        let server = StubServer()
        let missing = ["errors": [["message": "Field 'stackEntry' doesn't exist on type 'PullRequest'"]]]
        let usual = Fixture.answer(authored: [Fixture.pullRequest(2, author: Fixture.me)])
        server.reply(.json(missing), .json(usual), .json(usual))
        let client = server.client()

        let first = try await client.pullRequests(order: true)
        #expect(!first.hasOrder)
        #expect(first.data.authored.nodes.map(\.number) == [2])
        let second = try await client.pullRequests(order: true)
        #expect(!second.hasOrder)
        #expect(server.received.map { $0.json["query"] as? String } == [
            PullRequestQuery.orderText, PullRequestQuery.text, PullRequestQuery.text,
        ])
    }

    @Test func otherwiseTheUsualQueryGoesOnlyThisTime() async throws {
        let server = StubServer()
        let failed = ["errors": [["message": "Something went wrong while executing your query."]]]
        let ordered = Fixture.answer(authored: [Self.orderPullRequest(7, branch: "robin/cart", base: "main")])
        server.reply(.json(failed), .json(Fixture.answer()), .json(ordered))
        let client = server.client()

        let failedOnce = try await client.pullRequests(order: true)
        #expect(!failedOnce.hasOrder)
        let answered = try await client.pullRequests(order: true)
        #expect(answered.hasOrder)
        #expect(server.received.map { $0.json["query"] as? String } == [
            PullRequestQuery.orderText, PullRequestQuery.text, PullRequestQuery.orderText,
        ])
        // A rate limit isn't a reason to send another.
        let limited = StubServer()
        limited.reply(.json(["errors": [["type": "RATE_LIMITED", "message": "API rate limit exceeded"]]]))
        await #expect(throws: GitHubError.self) { try await limited.client().pullRequests(order: true) }
        #expect(limited.received.count == 1)
    }

    @Test func anOrdersFieldGitHubCouldntReadIsOnlyMissingFromTheOrder() async throws {
        let server = StubServer()
        var object = Self.orderPullRequest(7, branch: "robin/cart", base: "robin/rounding")
        object["stackEntry"] = NSNull()
        let stackError: [String: Any] = [
            "type": "FORBIDDEN", "message": "Resource not accessible by integration", "path": ["authored", "nodes", 0, "stackEntry"],
        ]
        let saml: [String: Any] = [
            "type": "FORBIDDEN", "message": "Resource protected by organization SAML enforcement.", "path": ["reviewing", "nodes", 1],
        ]
        server.reply(.json(Fixture.answer(authored: [object], errors: [stackError, saml])))

        let result = try await server.client().pullRequests(order: true)

        #expect(result.errors == [
            GraphQLError(
                type: "FORBIDDEN", message: "Resource protected by organization SAML enforcement.", path: ["reviewing", "nodes", "1"]
            ),
        ])
        let pullRequest = GitHubPullRequest(try #require(result.data.authored.nodes.first))
        #expect(pullRequest.order == .init(baseBranch: "robin/rounding", isFork: false, defaultBranch: "main", stack: nil))
        // On its own, it says nothing's missing.
        server.reply(.json(Fixture.answer(authored: [object], errors: [stackError])))
        let quiet = try await GitHubReader.load(client: server.client(), order: true)
        #expect(quiet.notice == nil)
    }

    @Test func aStackAndItsPullRequestsStatesBecomeWhatAnOrderSees() throws {
        let stack = [
            (position: 1, number: 5, state: "MERGED"), (position: 2, number: 6, state: "OPEN"), (position: 3, number: 7, state: "OPEN"),
        ]
        let object = Self.orderPullRequest(7, branch: "robin/saved-addresses", base: "robin/address-form", stack: stack)
        let pullRequest = try Fixture.decoded(object)
        let order = try #require(pullRequest.order)
        #expect(order.baseBranch == "robin/address-form")
        #expect(order.stack == GitHubStack(repository: "octo/app", number: 41, baseBranch: "main", members: [
            .init(position: 1, ref: .gitHubPullRequest(repository: "octo/app", number: 5), state: .merged),
            .init(position: 2, ref: .gitHubPullRequest(repository: "octo/app", number: 6), state: .open),
            .init(position: 3, ref: .gitHubPullRequest(repository: "octo/app", number: 7), state: .open),
        ]))
        let seen = try #require(pullRequest.orderPullRequest(attention: .needsYou))
        #expect(seen.ref == .gitHubPullRequest(repository: "octo/app", number: 7))
        #expect(seen.repository == "octo/app")
        #expect(seen.sourceBranch == "robin/saved-addresses" && seen.targetBranch == "robin/address-form")
        #expect(seen.isFork == false && seen.defaultBranch == "main" && seen.author == Fixture.me)
        #expect(seen.state == .open && seen.attention == .needsYou)
        #expect(OrderFacts(pullRequests: [seen]).observations.contains(
            OrderObservation(ref: .gitHubPullRequest(repository: "octo/app", number: 5), state: .merged, witness: .gitHubStack)
        ))
        // Round trip, as a snapshot is kept.
        let data = try JSONEncoder().encode(pullRequest)
        #expect(try JSONDecoder().decode(GitHubPullRequest.self, from: data) == pullRequest)
    }

    @Test func withoutTheOrdersQueryAPullRequestTellsAnOrderNothing() throws {
        let pullRequest = try Fixture.decoded(Fixture.pullRequest(12))
        #expect(pullRequest.order == nil)
        #expect(pullRequest.orderPullRequest(attention: nil) == nil)
        var draft = Self.orderPullRequest(13, branch: "robin/fork-fix", base: "main", isCrossRepository: true)
        draft["isDraft"] = true
        let seen = try #require(try Fixture.decoded(draft).orderPullRequest(attention: nil))
        #expect(seen.state == .draft && seen.isFork == true)
        // A stack member in a state BriefBar doesn't know has none.
        #expect(PullRequestState(gitHub: "QUEUED") == nil)
    }
}
