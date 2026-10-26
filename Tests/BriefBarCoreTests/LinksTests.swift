import Foundation
import Testing
@testable import BriefBarCore

@Suite struct LinksTests {
    private let workItem = ItemRef.workItem(organization: "Contoso", id: 5101)
    private let otherWorkItem = ItemRef.workItem(organization: "contoso", id: 5120)
    private let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4071)
    private let gitHubPullRequest = ItemRef.gitHubPullRequest(repository: "Octo/Shop-Web", number: 12)
    private let session = ItemRef.session("6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let otherSession = ItemRef.session("0b5c1a52-49e6-4f43-9a3c-6d0f37f1b2a1")!

    // MARK: References

    @Test func referencesCompareWhateverCaseTheyreWrittenIn() {
        #expect(workItem == .workItem(organization: "contoso", id: 5101))
        #expect(gitHubPullRequest == .gitHubPullRequest(repository: "octo/shop-web", number: 12))
        #expect(session.id == "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        #expect(ItemRef.session("not a session") == nil)
        #expect(workItem != pullRequest)
    }

    @Test func referencesRoundTripThroughTheirDescription() throws {
        for ref in [workItem, pullRequest, gitHubPullRequest, session] {
            #expect(ItemRef(ref.description) == ref)
            let data = try JSONEncoder().encode(ref)
            #expect(try JSONDecoder().decode(ItemRef.self, from: data) == ref)
        }
        #expect(gitHubPullRequest.description == "gitHubPullRequest/octo/shop-web/12")
    }

    @Test func aDescriptionThatIsntBriefBarsIsntAReference() {
        for text in [
            "", "workItem", "workItem/contoso/", "workItem/contoso/-3", "workItem/contoso/12a", "workItem/con toso/12",
            "pullRequest//4", "gitHubPullRequest/octo/12", "gitHubPullRequest/../../12", "session/x/6f9619ff-8b86-d011-b42d-00c04fc964ff",
            "session//../../etc", "chat/contoso/1",
        ] {
            #expect(ItemRef(text) == nil, "\(text)")
        }
    }

    @Test func onlyThingsOfDifferentKindsLinkAndNeverTwoPullRequests() {
        #expect(ItemRef.canLink(workItem, pullRequest))
        #expect(ItemRef.canLink(workItem, gitHubPullRequest))
        #expect(ItemRef.canLink(session, pullRequest))
        #expect(ItemRef.canLink(session, workItem))
        #expect(!ItemRef.canLink(workItem, otherWorkItem))
        #expect(!ItemRef.canLink(session, otherSession))
        #expect(!ItemRef.canLink(pullRequest, gitHubPullRequest))
        #expect(!ItemRef.canLink(pullRequest, pullRequest))
        #expect(LinkPair(pullRequest, workItem) == LinkPair(workItem, pullRequest))
        #expect(LinkPair(pullRequest, workItem)?.first == workItem)
    }

    // MARK: The graph

    @Test func thingsAreLinkedBothWaysWithEverythingThatLinksThem() {
        let graph = LinkGraph(links: [
            ItemLink(pullRequest, workItem, origin: .azureDevOps)!,
            ItemLink(workItem, pullRequest, origin: .copilot)!,
        ])
        #expect(graph.connections(of: workItem) == [.init(item: pullRequest, origins: [.azureDevOps, .copilot])])
        #expect(graph.connections(of: pullRequest) == [.init(item: workItem, origins: [.azureDevOps, .copilot])])
        #expect(graph.isLinked(workItem, pullRequest))
        #expect(graph.connections(of: session).isEmpty)
    }

    @Test func aWorkItemReachesItsPullRequestsSessionsAndASessionItsWorkItems() {
        let graph = LinkGraph(links: [
            ItemLink(pullRequest, workItem, origin: .azureDevOps)!,
            ItemLink(session, pullRequest, origin: .branch)!,
        ])
        #expect(graph.connections(of: workItem) == [
            .init(item: pullRequest, origins: [.azureDevOps]),
            .init(item: session, origins: [], via: pullRequest),
        ])
        #expect(graph.connections(of: session) == [
            .init(item: workItem, origins: [], via: pullRequest),
            .init(item: pullRequest, origins: [.branch]),
        ])
        // A pull request doesn't reach its work items' other sessions: they may be on other pull requests.
        let other = LinkGraph(links: [
            ItemLink(pullRequest, workItem, origin: .azureDevOps)!,
            ItemLink(session, workItem, origin: .you)!,
        ])
        #expect(other.connections(of: pullRequest) == [.init(item: workItem, origins: [.azureDevOps])])
    }

    @Test func aDirectLinkWinsOverOneThroughAPullRequest() {
        let graph = LinkGraph(links: [
            ItemLink(pullRequest, workItem, origin: .azureDevOps)!,
            ItemLink(session, pullRequest, origin: .branch)!,
            ItemLink(session, workItem, origin: .copilot)!,
        ])
        #expect(graph.connections(of: workItem).map(\.item) == [pullRequest, session])
        #expect(graph.connections(of: workItem).last == .init(item: session, origins: [.copilot]))
    }

    @Test func yourLinksJoinTheSourcesAndHidingOneHidesWhatsLinkedThroughIt() {
        var edits = LinkEdits()
        edits.link(session, workItem, at: t(0))
        let graph = LinkGraph(links: [ItemLink(pullRequest, workItem, origin: .azureDevOps)!], edits: edits)
        #expect(graph.connections(of: workItem) == [
            .init(item: pullRequest, origins: [.azureDevOps]),
            .init(item: session, origins: [.you]),
        ])

        // Hidden: the pull request's link, and the session reached through it goes, rather than showing as hidden.
        var hidden = LinkEdits()
        hidden.unlink(workItem, pullRequest, hides: true, at: t(1))
        let facts = [ItemLink(pullRequest, workItem, origin: .azureDevOps)!, ItemLink(session, pullRequest, origin: .branch)!]
        let hiding = LinkGraph(links: facts, edits: hidden)
        #expect(hiding.connections(of: workItem) == [.init(item: pullRequest, origins: [.azureDevOps], isHidden: true)])
        #expect(hiding.visibleConnections(of: workItem).isEmpty)
        #expect(!hiding.isLinked(workItem, pullRequest))
        // The session still has its pull request, but not the work item through it.
        #expect(hiding.visibleConnections(of: session) == [.init(item: pullRequest, origins: [.branch])])

        // Hiding a session reached through a pull request hides just that.
        var oneSession = LinkEdits()
        oneSession.unlink(workItem, session, hides: true, at: t(2))
        let graph2 = LinkGraph(links: facts, edits: oneSession)
        #expect(graph2.connections(of: workItem) == [
            .init(item: pullRequest, origins: [.azureDevOps]),
            .init(item: session, origins: [], via: pullRequest, isHidden: true),
        ])
        #expect(graph2.visibleConnections(of: pullRequest).map(\.item) == [workItem, session])
    }

    @Test func unlinkingYourOwnLinkForgetsItAndHidingSomethingElsesKeepsItHidden() {
        var edits = LinkEdits()
        edits.link(session, workItem, at: t(0))
        edits.unlink(session, workItem, hides: false, at: t(1))
        #expect(edits.isEmpty)

        edits.unlink(workItem, pullRequest, hides: true, at: t(2))
        #expect(edits.hidden.count == 1)
        // Linking it again shows it again, as yours too.
        edits.link(pullRequest, workItem, at: t(3))
        #expect(edits.hidden.isEmpty)
        #expect(edits.added[LinkPair(workItem, pullRequest)!] == t(3))
        edits.unlink(workItem, pullRequest, hides: true, at: t(4))
        edits.showAgain(pullRequest, workItem)
        #expect(edits.isEmpty)
        // Nothing to say about two that can't be linked.
        edits.link(workItem, otherWorkItem)
        #expect(edits.isEmpty)
    }

    @Test func turningASourceOffForgetsTheEditsAboutItsThings() {
        var edits = LinkEdits()
        edits.link(session, workItem, at: t(0))
        edits.link(session, gitHubPullRequest, at: t(0))
        edits.unlink(workItem, pullRequest, hides: true, at: t(0))
        var withoutCopilot = edits
        withoutCopilot.forget([.session])
        #expect(withoutCopilot.added.isEmpty)
        #expect(withoutCopilot.hidden.count == 1)
        var withoutAzureDevOps = edits
        withoutAzureDevOps.forget([.workItem, .pullRequest])
        #expect(Array(withoutAzureDevOps.added.keys) == [LinkPair(session, gitHubPullRequest)!])
        #expect(withoutAzureDevOps.hidden.isEmpty)
    }

    @Test func editsAreKeptWithReferencesOnlyAndOldOnesGo() throws {
        let defaults = MemorySettings()
        var edits = LinkEdits()
        edits.link(session, workItem, at: t(0))
        edits.unlink(workItem, pullRequest, hides: true, at: t(10))
        edits.save(to: defaults)
        #expect(LinkEdits.load(from: defaults) == edits)

        let text = String(decoding: try #require(defaults.data(forKey: LinkEdits.defaultsKey)), as: UTF8.self)
        #expect(text.contains("workItem/contoso/5101"))
        #expect(text.contains("session//6f9619ff-8b86-d011-b42d-00c04fc964ff"))

        edits.forget(before: t(5))
        #expect(edits.added.isEmpty)
        #expect(edits.hidden.count == 1)
        edits.forget(before: t(20))
        edits.save(to: defaults)
        #expect(defaults.object(forKey: LinkEdits.defaultsKey) == nil)
    }

    @Test func whatAnotherProgramWroteThatIsntAReferenceIsLeftOut() {
        let defaults = MemorySettings()
        let json = """
            [{"first":"session//../../../etc/passwd","second":"workItem/contoso/1","hidden":false,"date":0},
             {"first":"workItem/contoso/5101","second":"workItem/contoso/5120","hidden":false,"date":0},
             {"first":"workItem/contoso/5101","second":"session//6f9619ff-8b86-d011-b42d-00c04fc964ff","hidden":false,"date":0},
             {"oops":true}]
            """
        defaults.set(Data(json.utf8), forKey: LinkEdits.defaultsKey)
        let edits = LinkEdits.load(from: defaults)
        #expect(Array(edits.added.keys) == [LinkPair(workItem, session)!])
        defaults.set(Data("nonsense".utf8), forKey: LinkEdits.defaultsKey)
        #expect(LinkEdits.load(from: defaults).isEmpty)
    }

    // MARK: Branches

    @Test func aSessionOnAPullRequestsBranchInItsRepositoryIsLinked() {
        let pr = BranchHint(branch: "refs/heads/users/robin/coupon-rounding", target: "refs/heads/main", repositories: ["shop-web"])
        let mine = BranchHint(branch: "users/robin/coupon-rounding", repositories: BranchHint.repositories(["Shop-Web", "shop-web"]))
        #expect(BranchLinks.matches(session: mine, pullRequest: pr))
        #expect(BranchLinks.links(sessions: [session: mine], pullRequests: [pullRequest: pr])
            == [ItemLink(session, pullRequest, origin: .branch)!])

        // Another repository, another branch, or a branch everybody works on, links nothing.
        let elsewhere = BranchHint(branch: "users/robin/coupon-rounding", repositories: ["payments-api"])
        #expect(!BranchLinks.matches(session: elsewhere, pullRequest: pr))
        let other = BranchHint(branch: "users/robin/other", repositories: ["shop-web"])
        #expect(!BranchLinks.matches(session: other, pullRequest: pr))
        let main = BranchHint(branch: "main", repositories: ["shop-web"])
        #expect(!BranchLinks.matches(session: main, pullRequest: BranchHint(branch: "main", target: "release/1", repositories: ["shop-web"])))
        let target = BranchHint(branch: "release/2.4", repositories: ["shop-web"])
        #expect(!BranchLinks.matches(session: target, pullRequest: BranchHint(branch: "release/2.4", target: "release/2.4", repositories: ["shop-web"])))
        #expect(!BranchLinks.matches(session: BranchHint(branch: "", repositories: ["shop-web"]), pullRequest: BranchHint(branch: "", repositories: ["shop-web"])))
    }

    @Test func aGitHubRepositoryMatchesByItsFullNameOrItsName() {
        let repositories = BranchHint.repositories(["storefront"], gitHub: "contoso/shop-web")
        #expect(repositories == ["storefront", "contoso/shop-web", "shop-web"])
        let pr = BranchHint(branch: "robin/links", target: "main", repositories: BranchHint.repositories([], gitHub: "Contoso/Shop-Web"))
        #expect(BranchLinks.matches(session: BranchHint(branch: "robin/links", repositories: repositories), pullRequest: pr))
        #expect(BranchHint.repositories([nil, " "], gitHub: "not a repository").isEmpty)
    }

    // MARK: Pasted links

    @Test func aPastedLinkNamesWhatItPointsTo() {
        let cases: [(String, ItemRef?)] = [
            ("https://dev.azure.com/Contoso/Storefront/_git/shop-web/pullrequest/4071", pullRequest),
            ("https://dev.azure.com/contoso/Store%20front/_git/shop-web/pullrequest/4071?_a=files", pullRequest),
            ("https://contoso.visualstudio.com/DefaultCollection/Storefront/_git/shop-web/pullrequest/4071", pullRequest),
            ("  https://dev.azure.com/contoso/Storefront/_workitems/edit/5101 ", workItem),
            ("https://dev.azure.com/contoso/_workitems/edit/5101/", workItem),
            ("https://github.com/octo/shop-web/pull/12/files", gitHubPullRequest),
            ("ghapp://sessions/6f9619ff-8b86-d011-b42d-00c04fc964ff", session),
            ("6F9619FF-8B86-D011-B42D-00C04FC964FF", session),
            ("https://dev.azure.com/contoso/Storefront/_build/results?buildId=4", nil),
            ("https://dev.azure.com/contoso/Storefront/pullrequest/4071", nil),
            ("https://evil.example/contoso/_git/x/pullrequest/4071", nil),
            ("https://github.com/octo/shop-web/issues/12", nil),
            ("ghapp://sessions/../../etc", nil),
            ("file:///etc/passwd", nil),
            ("5101", nil),
        ]
        for (text, expected) in cases {
            #expect(ItemRef.from(link: text) == expected, "\(text)")
        }
    }

    // MARK: Suggestions

    @Test func suggestionsPutWhatsOnTheBranchOrNamesTheNumberFirst() {
        let subject = LinkCandidate(
            ref: session, title: "Round coupon totals half up",
            hint: BranchHint(branch: "users/robin/coupon-rounding", repositories: ["shop-web"])
        )
        let onBranch = LinkCandidate(
            ref: pullRequest, title: "Fix the coupon rounding error",
            hint: BranchHint(branch: "users/robin/coupon-rounding", target: "main", repositories: ["shop-web"]), date: t(0)
        )
        let sameRepository = LinkCandidate(
            ref: .pullRequest(organization: "contoso", number: 4080), title: "Speed up the checkout page",
            hint: BranchHint(branch: "checkout-speed", target: "main", repositories: ["shop-web"]), date: t(50)
        )
        let named = LinkCandidate(ref: .workItem(organization: "contoso", id: 5110), title: "Coupon totals round down instead of to the nearest cent")
        let unrelated = LinkCandidate(ref: otherWorkItem, title: "Pay with a gift card at checkout")
        let ranked = LinkSuggestions.rank([unrelated, sameRepository, named, onBranch], for: subject)
        #expect(ranked == [pullRequest, named.ref])

        // The work item's number, in a session's name or branch.
        let wi = LinkCandidate(ref: workItem, title: "Save items for later from the cart")
        let byName = LinkCandidate(ref: otherSession, title: "Work on 5101")
        let byBranch = LinkCandidate(ref: session, title: "Cart", hint: BranchHint(branch: "wi-5101", repositories: ["shop-web"]))
        let notQuite = LinkCandidate(ref: .session(UUID().uuidString)!, title: "Port 51010")
        #expect(Set(LinkSuggestions.rank([byName, byBranch, notQuite], for: wi)) == [otherSession, session])
        // Nothing it can't link to.
        #expect(LinkSuggestions.rank([LinkCandidate(ref: otherWorkItem, title: "Save items for later")], for: wi).isEmpty)
    }
}
