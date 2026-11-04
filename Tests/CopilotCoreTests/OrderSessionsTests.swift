import BriefBarCore
import Foundation
import Testing
@testable import CopilotCore

@Suite struct OrderSessionsTests {
    private static let coordinator = "3c1d7e52-9a40-4b6f-8e21-5f0b2c7d9a10"
    private static let cart = "a7e4c901-2b5d-4f38-9c16-0d8e3f7b2a11"
    private static let rounding = "b2f9d613-4c7a-4e05-8b3d-1a6c9e0f4b12"
    private static let reviewer = "c8a3e275-6d1f-4b90-a7c4-2e5b8d1f0c13"
    private static let helper = "d4b6f087-8e2a-4c13-9f5d-3b7a0c2e1d14"

    private static func session(
        _ id: String, parent: String? = nil, coordinator: String? = nil, sessionType: String = "project",
        _ pullRequests: [RecordedPullRequest] = []
    ) -> SessionMeta {
        SessionMeta(
            id: id, name: id.prefix(4).description, sessionType: sessionType, coordinatorSessionId: coordinator,
            parentSessionId: parent, links: pullRequests.isEmpty ? nil : SessionLinks(pullRequests: pullRequests)
        )
    }

    private static func ado(_ number: Int, _ role: RecordedPullRequest.Role? = nil) -> RecordedPullRequest {
        RecordedPullRequest(
            repository: nil, number: nil, url: "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/\(number)", role: role
        )
    }

    private static func gitHub(_ number: Int, _ role: RecordedPullRequest.Role?) -> RecordedPullRequest {
        RecordedPullRequest(repository: "octo/storefront", number: number, url: nil, role: role)
    }

    private static func ref(_ id: String) -> ItemRef {
        ItemRef.session(id)!
    }

    /// A pull request a session told BriefBar it opened goes with it, as one the app records it opened does: even without
    /// what the app read of its work, ahead of a session the app links to it without saying how, and never with another
    /// session that only started from it.
    @Test func thePullRequestsASessionToldBriefBarItOpenedGoWithIt() {
        let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4102)
        let sessions = OrderSessions.sessions(
            [
                Self.session(Self.coordinator, sessionType: "chat"),
                Self.session(Self.cart, parent: Self.coordinator, coordinator: Self.coordinator),
                Self.session(Self.helper, [Self.ado(4102)]),
                Self.session(Self.reviewer, [Self.ado(4102, .startedFrom)]),
            ],
            told: [
                Self.ref(Self.cart): [pullRequest, .workItem(organization: "contoso", id: 5124)],
                Self.ref(Self.rounding): [.pullRequest(organization: "contoso", number: 4118)],
            ]
        )
        #expect(sessions == [
            OrderSession(
                ref: Self.ref(Self.cart), parent: Self.ref(Self.coordinator), coordinator: Self.ref(Self.coordinator),
                pullRequests: [pullRequest]
            ),
        ])
    }

    /// The usual shape: a coordinator starts a session for each pull request, which opens it.
    @Test func eachSessionGoesWithThePullRequestsItOpenedUnderItsCoordinator() {
        let sessions = OrderSessions.sessions([
            Self.session(Self.coordinator, sessionType: "chat"),
            Self.session(Self.cart, parent: Self.coordinator, coordinator: Self.coordinator, [Self.gitHub(7, .opened)]),
            Self.session(Self.rounding, parent: Self.coordinator, coordinator: Self.coordinator, [Self.ado(4102)]),
        ])

        #expect(sessions == [
            OrderSession(
                ref: Self.ref(Self.cart), parent: Self.ref(Self.coordinator), coordinator: Self.ref(Self.coordinator),
                pullRequests: [.gitHubPullRequest(repository: "octo/storefront", number: 7)]
            ),
            OrderSession(
                ref: Self.ref(Self.rounding), parent: Self.ref(Self.coordinator), coordinator: Self.ref(Self.coordinator),
                pullRequests: [.pullRequest(organization: "contoso", number: 4102)]
            ),
        ])
    }

    @Test func aPullRequestASessionOnlyStartedFromIsntItsWork() {
        let sessions = OrderSessions.sessions([
            Self.session(Self.cart, [Self.ado(4101, .opened), Self.ado(4102), Self.gitHub(7, .opened)]),
            // Started from !4101 to fix its comments; a provider links it to !4102 and !4103 without saying how.
            Self.session(Self.reviewer, [Self.ado(4101, .startedFrom), Self.ado(4102), Self.ado(4103), Self.ado(4103)]),
            Self.session(Self.helper, [Self.gitHub(7, nil), Self.gitHub(7, .startedFrom)]),
        ])

        #expect(sessions.map(\.pullRequests) == [
            [.pullRequest(organization: "contoso", number: 4101), .pullRequest(organization: "contoso", number: 4102),
             .gitHubPullRequest(repository: "octo/storefront", number: 7)],
            [.pullRequest(organization: "contoso", number: 4102), .pullRequest(organization: "contoso", number: 4103)],
        ])
        // The helper only has #7, which another session opened.
        #expect(!sessions.map(\.ref).contains(Self.ref(Self.helper)))
    }

    /// A provider can also link a session to the pull request it started from, without saying how: that's still not its
    /// work, whichever the app lists first, even when no session opened it.
    @Test func aLinkToThePullRequestASessionStartedFromIsntItsWork() {
        let sessions = OrderSessions.sessions([
            Self.session(Self.reviewer, [Self.ado(4105), Self.ado(4105, .startedFrom), Self.ado(4106)]),
            Self.session(Self.helper, [Self.gitHub(9, .startedFrom), Self.gitHub(9, nil)]),
        ])

        #expect(sessions.map(\.ref) == [Self.ref(Self.reviewer)])
        #expect(sessions.map(\.pullRequests) == [[.pullRequest(organization: "contoso", number: 4106)]])
    }

    @Test func whatBriefBarCantNameIsLeftOut() {
        let sessions = OrderSessions.sessions([
            Self.session("not-a-session", [Self.ado(4101, .opened)]),
            Self.session(Self.cart, parent: Self.cart, coordinator: "someone", [Self.ado(4102, .opened)]),
            Self.session(Self.cart, [Self.ado(4103, .opened)]),
            Self.session(Self.rounding, [
                RecordedPullRequest(repository: nil, number: nil, url: "https://example.com/pull/3", role: .opened),
            ]),
            Self.session(Self.helper),
        ])

        #expect(sessions == [
            OrderSession(ref: Self.ref(Self.cart), pullRequests: [.pullRequest(organization: "contoso", number: 4102)]),
        ])
    }

    /// Pull requests no order names group under the session that coordinates the ones that opened them.
    @Test func theirPullRequestsGroupUnderTheirCoordinator() throws {
        let facts = OrderFacts(
            pullRequests: [4101, 4102, 4103].map { number in
                OrderPullRequest(
                    ref: .pullRequest(organization: "contoso", number: number), repository: "contoso/7d3f9a12/shop-web",
                    sourceBranch: "refs/heads/robin/\(number)", targetBranch: "refs/heads/main", author: "robin", state: .open,
                    createdAt: t(Double(number))
                )
            },
            sessions: OrderSessions.sessions([
                Self.session(Self.cart, coordinator: Self.coordinator, [Self.ado(4101, .opened)]),
                Self.session(Self.rounding, parent: Self.coordinator, [Self.ado(4102, .opened)]),
                Self.session(Self.reviewer, [Self.ado(4101, .startedFrom), Self.ado(4103, .opened)]),
            ])
        )

        let missions = OrderBoard.missions(facts: facts, orders: DeclaredOrders(), evidence: OrderEvidence(), now: t(5000))

        let mission = try #require(missions.first)
        #expect(missions.count == 1)
        #expect(mission.key == .family(Self.ref(Self.coordinator)))
        #expect(mission.steps.map(\.ref) == [4101, 4102].map { .pullRequest(organization: "contoso", number: $0) })
        #expect(mission.steps.map(\.session) == [Self.ref(Self.cart), Self.ref(Self.rounding)])
    }
}
