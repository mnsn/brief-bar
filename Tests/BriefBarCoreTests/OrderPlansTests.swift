import Foundation
import Testing
@testable import BriefBarCore

@Suite struct OrderPlansTests {
    private let session = ItemRef.session("6f9619ff-8b86-d011-b42d-00c04fc964ff")!
    private let planID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static func pr(_ number: Int, in organization: String = "contoso") -> ItemRef {
        .pullRequest(organization: organization, number: number)
    }

    static func link(_ number: Int, in organization: String = "contoso") -> String {
        "https://dev.azure.com/\(organization)/shop/_git/shop-web/pullrequest/\(number)"
    }

    /// As the user put it: x1 before x2, x2 before x3, x4 any time, x5 after x2 and before x6.
    static let userExample = OrderRequest(entries: [
        .init(link: link(4101)),
        .init(link: link(4102), after: ["4101"]),
        .init(link: link(4103), after: [link(4102)]),
        .init(link: link(4104)),
        .init(link: link(4105), after: ["!4102"]),
        .init(link: link(4106), after: ["4105"]),
    ])

    // MARK: Telling

    @Test func anOrderIsKeptWithAnIDAndItsFirstRevisionWhetherItNamesPullRequestsByLinkOrNumber() throws {
        var orders = DeclaredOrders()
        let plan = try orders.apply(Self.userExample, now: t(0), newID: planID)
        #expect(plan.id == planID)
        #expect(plan.revision == 1)
        #expect(plan.createdAt == t(0) && plan.updatedAt == t(0))
        #expect(plan.declaredBy == nil)
        #expect(plan.refs == [4101, 4102, 4103, 4104, 4105, 4106].map { Self.pr($0) })
        #expect(plan.entry(for: Self.pr(4103))?.after == [Self.pr(4102)])
        #expect(plan.entry(for: Self.pr(4105))?.after == [Self.pr(4102)])
        #expect(plan.entry(for: Self.pr(4104))?.after == [])
        #expect(plan.puts(Self.pr(4101), before: Self.pr(4106)))
        #expect(!plan.puts(Self.pr(4103), before: Self.pr(4106)))
        #expect(!plan.puts(Self.pr(4104), before: Self.pr(4102)))
        #expect(orders.plans == [plan])
    }

    @Test func theSessionThatToldItIsKeptOnlyToSayWhereItCameFrom() throws {
        var orders = DeclaredOrders()
        var request = Self.userExample
        request.session = "ghapp://sessions/6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let plan = try orders.apply(request, now: t(0))
        #expect(plan.declaredBy == session)
        #expect(orders.plans(declaredBy: session).map(\.id) == [plan.id])
        // Replaced without saying, it still came from there.
        let replaced = try orders.apply(
            OrderRequest(plan: plan.id.uuidString, revision: 1, entries: [.init(link: Self.link(4101))]), now: t(1)
        )
        #expect(replaced.declaredBy == session)
        request.session = "not a session"
        #expect(throws: OrderPlanError.notASession("not a session")) { try orders.apply(request, now: t(2)) }
        #expect(orders.plans.count == 1)
    }

    @Test func aSessionCanTellSeveralOrdersAndBriefBarNeverMergesThem() throws {
        var orders = DeclaredOrders()
        let first = try orders.apply(OrderRequest(session: session.id, entries: [
            .init(link: Self.link(4101)), .init(link: Self.link(4102), after: ["4101"]),
        ]), now: t(0))
        let second = try orders.apply(OrderRequest(session: session.id, entries: [
            .init(link: Self.link(4102)), .init(link: Self.link(4110), after: ["4102"]),
        ]), now: t(1))
        #expect(first.id != second.id)
        #expect(orders.plans.count == 2)
        #expect(orders.plans(with: Self.pr(4102)).map(\.id) == [first.id, second.id])
        #expect(orders.refs == [Self.pr(4101), Self.pr(4102), Self.pr(4110)])
    }

    @Test func whatIsntClearIsRefusedAndChangesNothing() {
        var orders = DeclaredOrders()
        let workItem = "https://dev.azure.com/contoso/shop/_workitems/edit/5101"
        let cases: [(OrderRequest, OrderPlanError)] = [
            (OrderRequest(entries: []), .empty),
            (OrderRequest(entries: (1...51).map { .init(link: Self.link($0)) }), .tooMany),
            (OrderRequest(entries: [.init(link: workItem)]), .notAPullRequest(workItem)),
            (OrderRequest(entries: [.init(link: "4101")]), .notAPullRequest("4101")),
            (OrderRequest(entries: [.init(link: Self.link(4101)), .init(link: Self.link(4101))]), .twice(Self.pr(4101))),
            (OrderRequest(entries: [.init(link: Self.link(4101), after: ["4107"])]), .notInList("4107", by: Self.pr(4101))),
            (OrderRequest(entries: [.init(link: Self.link(4101), after: [workItem])]), .notInList(workItem, by: Self.pr(4101))),
            (OrderRequest(entries: [.init(link: Self.link(4101), after: ["4101"])]), .itself(Self.pr(4101))),
            (OrderRequest(entries: [
                .init(link: Self.link(4101), after: ["4102"]), .init(link: Self.link(4102), after: ["4103"]),
                .init(link: Self.link(4103), after: ["4101"]),
            ]), .cycle([Self.pr(4101), Self.pr(4102), Self.pr(4103)])),
            (OrderRequest(entries: [
                .init(link: Self.link(4101), review: .after(["4102"], reason: "because")), .init(link: Self.link(4102)),
            ]), .notAReason("because")),
            (OrderRequest(entries: [.init(link: Self.link(4101), review: .after([], reason: "same_code"))]),
             .reviewAfterNothing(Self.pr(4101))),
            (OrderRequest(entries: [
                .init(link: Self.link(4101), review: .after(["4102"], reason: "same_code")),
                .init(link: Self.link(4102), review: .after(["4101"], reason: "same_code")),
            ]), .reviewCycle([Self.pr(4101), Self.pr(4102)])),
            (OrderRequest(revision: 1, entries: [.init(link: Self.link(4101))]), .planMissing),
            (OrderRequest(plan: "not an ID", revision: 1, entries: [.init(link: Self.link(4101))]), .notAPlan("not an ID")),
        ]
        for (request, error) in cases {
            #expect(throws: error) { try orders.apply(request, now: t(0)) }
        }
        #expect(orders.plans.isEmpty)
    }

    @Test func aNumberThatTwoPullRequestsInTheListHaveNeedsItsLink() throws {
        var orders = DeclaredOrders()
        let gitHub = "https://github.com/octo/storefront/pull/4101"
        let gitHubRef = ItemRef.gitHubPullRequest(repository: "octo/storefront", number: 4101)
        var request = OrderRequest(entries: [
            .init(link: Self.link(4101)), .init(link: gitHub), .init(link: Self.link(4102), after: ["4101"]),
        ])
        #expect(throws: OrderPlanError.ambiguous(4101, [Self.pr(4101), gitHubRef])) { try orders.apply(request, now: t(0)) }
        request.entries = [
            .init(link: Self.link(4101)), .init(link: Self.link(4101, in: "fabrikam")), .init(link: Self.link(4102), after: ["!4101"]),
        ]
        #expect(throws: OrderPlanError.ambiguous(4101, [Self.pr(4101), Self.pr(4101, in: "fabrikam")])) {
            try orders.apply(request, now: t(0))
        }
        request.entries = [.init(link: Self.link(4101)), .init(link: gitHub), .init(link: Self.link(4102), after: [gitHub])]
        let plan = try orders.apply(request, now: t(0))
        #expect(plan.entry(for: Self.pr(4102))?.after == [gitHubRef])
    }

    @Test func anOrderIsReplacedOnlyAtTheRevisionTheAgentLastRead() throws {
        var orders = DeclaredOrders()
        let plan = try orders.apply(Self.userExample, now: t(0), newID: planID)
        var replacement = OrderRequest(plan: planID.uuidString.lowercased(), revision: 1, entries: [
            .init(link: Self.link(4101)), .init(link: Self.link(4102), after: ["4101"]),
        ])
        let replaced = try orders.apply(replacement, now: t(60))
        #expect(replaced.id == planID && replaced.revision == 2)
        #expect(replaced.createdAt == t(0) && replaced.updatedAt == t(60))
        #expect(replaced.refs == [Self.pr(4101), Self.pr(4102)])
        #expect(plan.revision == 1)
        // An agent that read revision 1 can't replace revision 2 without reading it.
        #expect(throws: OrderPlanError.changed(since: 1, now: 2)) { try orders.apply(replacement, now: t(120)) }
        replacement.revision = nil
        #expect(throws: OrderPlanError.revisionMissing) { try orders.apply(replacement, now: t(120)) }
        let forgotten = UUID()
        #expect(throws: OrderPlanError.noSuchPlan(forgotten)) {
            try orders.apply(OrderRequest(plan: forgotten.uuidString, revision: 1, entries: replacement.entries), now: t(120))
        }
        #expect(orders.plans == [replaced])
    }

    @Test func theFiftyFirstOrderIsRefusedAndNoneIsForgottenToMakeRoom() throws {
        var orders = DeclaredOrders()
        for number in 1...DeclaredOrders.mostPlans {
            try orders.apply(OrderRequest(entries: [.init(link: Self.link(number))]), now: t(Double(number)))
        }
        let kept = orders.plans.map(\.id)
        #expect(throws: OrderPlanError.full) {
            try orders.apply(OrderRequest(entries: [.init(link: Self.link(999))]), now: t(100))
        }
        #expect(orders.plans.map(\.id) == kept)
        let replaced = try orders.apply(
            OrderRequest(plan: kept[0].uuidString, revision: 1, entries: [.init(link: Self.link(998))]), now: t(101)
        )
        #expect(replaced.revision == 2)
    }

    // MARK: Forgetting

    @Test func anOrderIsForgottenByItsIDAtTheRevisionGiven() throws {
        var orders = DeclaredOrders()
        let plan = try orders.apply(Self.userExample, now: t(0), newID: planID)
        #expect(throws: OrderPlanError.changed(since: 3, now: 1)) { try orders.forget(plan: planID.uuidString, revision: 3) }
        let forgotten = try orders.forget(plan: planID.uuidString.lowercased(), revision: 1)
        #expect(forgotten == plan)
        #expect(orders.plans.isEmpty)
        #expect(throws: OrderPlanError.noSuchPlan(planID)) { try orders.forget(plan: planID.uuidString) }
        try orders.apply(Self.userExample, now: t(1), newID: planID)
        orders.forget(planID)
        #expect(orders.plans.isEmpty)
    }

    @Test func turningASourceOffForgetsItsPullRequestsInEveryOrder() throws {
        var orders = DeclaredOrders()
        let gitHub = "https://github.com/octo/storefront/pull/212"
        let mixed = try orders.apply(OrderRequest(entries: [
            .init(link: gitHub),
            .init(link: Self.link(4101), after: [gitHub]),
            .init(link: Self.link(4102), after: ["4101", gitHub], review: .after([gitHub], reason: "same_code")),
        ]), now: t(0))
        try orders.apply(OrderRequest(entries: [.init(link: gitHub)]), now: t(1))
        orders.forget([.gitHubPullRequest])
        #expect(orders.plans.map(\.id) == [mixed.id])
        let left = try #require(orders.plan(mixed.id))
        #expect(left.revision == 2)
        #expect(left.refs == [Self.pr(4101), Self.pr(4102)])
        #expect(left.entry(for: Self.pr(4101))?.after == [])
        #expect(left.entry(for: Self.pr(4102))?.after == [Self.pr(4101)])
        #expect(left.entry(for: Self.pr(4102))?.review == nil)
    }

    @Test func anOrderGoesTwoWeeksAfterBriefBarSawItsLastPullRequestMergeOrCloseAndNeverBefore() throws {
        var orders = DeclaredOrders()
        let plan = try orders.apply(OrderRequest(entries: [
            .init(link: Self.link(4101)), .init(link: Self.link(4102), after: ["4101"]),
        ]), now: t(0))
        var evidence = OrderEvidence()
        evidence.observe(OrderObservation(ref: Self.pr(4101), state: .merged, witness: .list), at: t(100))
        // One BriefBar can't see may have merged, or not: the order stays, however old.
        #expect(DeclaredOrders.finishedAt(plan, evidence: evidence) == nil)
        var removed = orders.removeFinished(evidence: evidence, now: t(400 * 86_400))
        #expect(removed.isEmpty)
        evidence.observe(OrderObservation(ref: Self.pr(4102), state: .closed, witness: .list), at: t(200))
        #expect(DeclaredOrders.finishedAt(plan, evidence: evidence) == t(200))
        removed = orders.removeFinished(evidence: evidence, now: t(200 + DeclaredOrders.finishedFor))
        #expect(removed.isEmpty)
        removed = orders.removeFinished(evidence: evidence, now: t(201 + DeclaredOrders.finishedFor))
        #expect(removed == [plan.id])
        #expect(orders.plans.isEmpty)
    }

    // MARK: Saving

    @Test func ordersAreSavedAsReferencesCodesAndDatesAndReadBack() throws {
        let defaults = MemorySettings()
        var orders = DeclaredOrders()
        var request = Self.userExample
        request.session = session.id
        request.entries[2].review = .after(["4102"], reason: "builds_on_changes")
        request.entries[3].review = .now
        try orders.apply(request, now: t(0), newID: planID)
        orders.save(to: defaults)
        #expect(DeclaredOrders.load(from: defaults) == orders)
        let saved = String(decoding: try #require(defaults.data(forKey: DeclaredOrders.defaultsKey)), as: UTF8.self)
        #expect(saved.contains("pullRequest/contoso/4101"))
        #expect(saved.contains("builds_on_changes"))
        #expect(!saved.contains("dev.azure.com"))
        DeclaredOrders().save(to: defaults)
        #expect(defaults.data(forKey: DeclaredOrders.defaultsKey) == nil)
    }

    @Test func whatCantBeReadIsLeftOutAndTheRestIsKept() throws {
        let defaults = MemorySettings()
        let readable = UUID()
        let circular = UUID()
        let json = """
            [
              {"id": "\(readable)", "revision": 2, "createdAt": 0, "updatedAt": 10, "declaredBy": "pullRequest/contoso/1",
               "entries": [
                 {"pullRequest": "pullRequest/contoso/4101"},
                 {"pullRequest": "pullRequest/contoso/4102",
                  "after": ["pullRequest/contoso/4101", "pullRequest/contoso/4999", "nonsense", "pullRequest/contoso/4102"],
                  "review": {"when": "after", "pullRequests": ["pullRequest/contoso/4999"], "reason": "same_code"}},
                 {"pullRequest": "pullRequest/contoso/4101"},
                 {"pullRequest": "workItem/contoso/5101"},
                 {"pullRequest": "not a reference"},
                 {"pullRequest": "pullRequest/contoso/4103", "review": {"when": "later"}}
               ]},
              {"id": "\(circular)", "revision": 1, "createdAt": 0, "updatedAt": 0, "entries": [
                 {"pullRequest": "pullRequest/contoso/1", "after": ["pullRequest/contoso/2"]},
                 {"pullRequest": "pullRequest/contoso/2", "after": ["pullRequest/contoso/1"]}
              ]},
              {"id": "not a UUID", "revision": 1},
              {"id": "\(UUID())", "revision": 0, "createdAt": 0, "updatedAt": 0, "entries": [{"pullRequest": "pullRequest/contoso/7"}]},
              "nonsense"
            ]
            """
        defaults.set(Data(json.utf8), forKey: DeclaredOrders.defaultsKey)
        let orders = DeclaredOrders.load(from: defaults)
        #expect(orders.plans.map(\.id) == [readable])
        let plan = try #require(orders.plans.first)
        #expect(plan.revision == 2)
        #expect(plan.declaredBy == nil)
        #expect(plan.refs == [Self.pr(4101), Self.pr(4102), Self.pr(4103)])
        #expect(plan.entry(for: Self.pr(4102))?.after == [Self.pr(4101)])
        #expect(plan.entry(for: Self.pr(4102))?.review == nil)
        #expect(plan.entry(for: Self.pr(4103))?.review == nil)
        defaults.set(Data("not JSON".utf8), forKey: DeclaredOrders.defaultsKey)
        #expect(DeclaredOrders.load(from: defaults).plans.isEmpty)
    }

    // MARK: What BriefBar saw

    @Test func evidenceKeepsOnlyWhatASourceShowedAndAMergeIsFinal() {
        var evidence = OrderEvidence()
        let ref = Self.pr(4101)
        /// Whether what a source shows of it now changes what's kept.
        func changes(_ state: PullRequestState, _ witness: OrderEvidence.Witness = .list, at seconds: TimeInterval, of item: ItemRef? = nil)
            -> Bool {
            evidence.observe(OrderObservation(ref: item ?? ref, state: state, witness: witness), at: t(seconds))
        }
        #expect(!changes(.open, at: 0))
        #expect(evidence.records.isEmpty)
        #expect(changes(.closed, at: 10))
        #expect(evidence.records[ref] == OrderEvidence.Record(outcome: .closed, observedAt: t(10), witness: .list))
        // Seen closed again, it's still from when BriefBar first saw it.
        #expect(!changes(.closed, at: 20))
        // Reactivated, it's no longer closed.
        #expect(changes(.draft, at: 30))
        #expect(evidence.records[ref] == nil)
        #expect(changes(.merged, .gitHubStack, at: 40))
        #expect(!changes(.open, at: 50))
        #expect(!changes(.closed, at: 60))
        #expect(evidence.records[ref] == OrderEvidence.Record(outcome: .merged, observedAt: t(40), witness: .gitHubStack))
        #expect(!changes(.merged, at: 70, of: ItemRef.workItem(organization: "contoso", id: 5101)))
    }

    @Test func evidenceIsSavedKeptForWhatOrdersNameAndForgottenWithItsSource() {
        let defaults = MemorySettings()
        let gitHub = ItemRef.gitHubPullRequest(repository: "octo/storefront", number: 210)
        var evidence = OrderEvidence()
        evidence.observe(OrderObservation(ref: Self.pr(4101), state: .merged, witness: .list), at: t(1))
        evidence.observe(OrderObservation(ref: Self.pr(4102), state: .closed, witness: .list), at: t(2))
        evidence.observe(OrderObservation(ref: gitHub, state: .merged, witness: .gitHubStack), at: t(3))
        evidence.save(to: defaults)
        #expect(OrderEvidence.load(from: defaults) == evidence)
        var forgot = evidence.keep(only: [Self.pr(4101), gitHub])
        #expect(forgot)
        #expect(evidence.records.keys.sorted() == [Self.pr(4101), gitHub])
        forgot = evidence.keep(only: [Self.pr(4101), gitHub])
        #expect(!forgot)
        forgot = evidence.forget([.gitHubPullRequest])
        #expect(forgot)
        #expect(evidence.records.keys.sorted() == [Self.pr(4101)])
        OrderEvidence().save(to: defaults)
        #expect(defaults.data(forKey: OrderEvidence.defaultsKey) == nil)
    }

    // MARK: Focus

    @Test func focusIsKeptByItsMissionsKeyAndForgottenWithEveryOrder() throws {
        let defaults = MemorySettings()
        let keys: [MissionKey] = [.plan(planID), .stack(repository: "octo/storefront", number: 41), .chain(Self.pr(4101)), .family(session)]
        for key in keys {
            #expect(MissionKey(key.description) == key)
            OrderFocus.save(key, to: defaults)
            #expect(OrderFocus.load(from: defaults) == key)
        }
        #expect(MissionKey.stack(repository: "octo/storefront", number: 41).description == "stack/octo/storefront/41")
        for text in [
            "", "plan", "plan/nope", "stack/octo/41", "stack/Octo/storefront/41", "stack/octo/storefront/x",
            "chain/session//6f9619ff-8b86-d011-b42d-00c04fc964ff", "family/pullRequest/contoso/1", "other/x",
        ] {
            #expect(MissionKey(text) == nil, "\(text)")
        }
        #expect(OrderFocus.ref(of: .chain(Self.pr(4101))) == Self.pr(4101))
        #expect(OrderFocus.ref(of: .plan(planID)) == nil)

        var orders = DeclaredOrders()
        try orders.apply(Self.userExample, now: t(0))
        orders.save(to: defaults)
        var evidence = OrderEvidence()
        evidence.observe(OrderObservation(ref: Self.pr(4101), state: .merged, witness: .list), at: t(1))
        evidence.save(to: defaults)
        DeclaredOrders.forgetAll(in: defaults)
        #expect(DeclaredOrders.load(from: defaults).plans.isEmpty)
        #expect(OrderEvidence.load(from: defaults).records.isEmpty)
        #expect(OrderFocus.load(from: defaults) == nil)
    }

    // MARK: Words

    @Test func refusalsSayWhatToDoNamingPullRequestsByNumber() {
        let gitHub = ItemRef.gitHubPullRequest(repository: "octo/storefront", number: 4101)
        #expect(OrderPlanError.ambiguous(4101, [Self.pr(4101), gitHub]).description
            == "4101 could be !4101 in contoso or octo/storefront#4101: name it by its link.")
        #expect(OrderPlanError.cycle([Self.pr(4101), Self.pr(4102)]).description
            == "!4101 in contoso and !4102 in contoso merge after each other, so none of them can merge first.")
        #expect(OrderPlanError.changed(since: 1, now: 2).description
            == "The order changed since revision 1, and is at revision 2 now: read it again, then send it again.")
        let long = OrderPlanError.notAPullRequest(String(repeating: "x", count: 300) + "\nmore").description
        #expect(long.count < 200)
        #expect(!long.contains("\n"))
    }
}
