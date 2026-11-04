import Foundation
import Testing
@testable import BriefBarCore

@Suite struct OrderPresentationTests {
    static func pr(_ number: Int) -> ItemRef { OrderPlansTests.pr(number) }

    static func gh(_ number: Int) -> ItemRef { .gitHubPullRequest(repository: "contoso/shop-web", number: number) }

    static let session = ItemRef.session("00000000-0000-4000-8000-000000000001")!
    static let planID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static func step(_ ref: ItemRef, _ standing: OrderStanding, status: OrderStatus = .open) -> OrderStep {
        OrderStep(ref: ref, status: status, standing: standing)
    }

    static func mission(
        _ steps: [OrderStep], attached: [OrderStep] = [], key: MissionKey? = nil, kind: OrderMission.Kind = .stack
    ) -> OrderMission {
        OrderMission(
            key: key ?? .chain(steps.first?.ref ?? attached[0].ref), kind: kind, steps: steps, attached: attached, cycles: [],
            isFocused: false, isFinished: false, isStale: false, attention: nil, date: nil, sessions: []
        )
    }

    static func declared(revision: Int, by session: ItemRef?) -> OrderMission.Kind {
        .declared(id: planID, revision: revision, declaredBy: session, updatedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: The view

    @Test func itsListUntilYouChooseMapAndItRemembersWhatYouChose() {
        let defaults = MemorySettings()
        #expect(OrderView.load(from: defaults) == .list)

        OrderView.map.save(to: defaults)
        #expect(OrderView.load(from: defaults) == .map)
        #expect(defaults.string(forKey: "order.view") == "map")

        defaults.set("graph", forKey: OrderView.defaultsKey)
        #expect(OrderView.load(from: defaults) == .list)
        #expect(OrderView.allCases.map(\.title) == ["List", "Map"])
    }

    // MARK: A row's capsule

    @Test func onlyWhatCanMergeNextStandsOutAndOneThatWaitsTurnsOrangeOnceItsReady() {
        let waiting = Self.step(Self.pr(4091), .waiting(open: [Self.pr(4102)], unknown: []))
        let unresolved = Self.step(Self.pr(4091), .unresolved([Self.pr(4118)]))
        let tones: [(OrderStanding, Bool, OrderCapsuleTone)] = [
            (.next, false, .next), (.next, true, .next),
            (.anyTime, true, .quiet), (.merged, false, .quiet), (.closed, false, .quiet), (.notInOrder, true, .quiet),
            (.notVisible(.notListed), false, .waiting), (.notVisible(.sourceOff), false, .waiting),
            (.prerequisiteClosed(Self.pr(4102)), false, .warning), (.retarget(after: Self.pr(4102), to: "main"), false, .warning),
            (.inCycle(with: [Self.pr(4102)]), false, .warning),
        ]
        for (standing, isReady, tone) in tones {
            #expect(OrderText.tone(of: Self.step(Self.pr(4091), standing), isReady: isReady) == tone, "\(standing)")
        }
        #expect(OrderText.tone(of: waiting, isReady: false) == .waiting)
        #expect(OrderText.tone(of: waiting, isReady: true) == .warning)
        #expect(OrderText.tone(of: unresolved, isReady: false) == .waiting)
        #expect(OrderText.tone(of: unresolved, isReady: true) == .warning)
    }

    @Test func theCapsulesSentenceSaysWhyAndWhenItsSessionSuggestsReviewingIt() {
        var step = Self.step(Self.pr(3990), .waiting(open: [Self.pr(4091), Self.pr(4079)], unknown: []))
        #expect(OrderText.sentence(of: step) == "Merge after !4091 and !4079")
        #expect(
            OrderText.sentence(of: step, isReady: true)
                == "Merge after !4091 and !4079 · completing it now would go against its order"
        )

        step.notes = [.alsoIn([Self.planID])]
        step.review = .after([Self.pr(4091)], .sameCode)
        #expect(
            OrderText.sentence(of: step)
                == "Merge after !4091 and !4079. Also in another order. Review after !4091: changes the same code"
        )

        #expect(OrderText.sentence(of: Self.step(Self.pr(4102), .next), isReady: true) == "Next to merge")
        #expect(OrderText.sentence(of: Self.step(Self.pr(4102), .unordered)) == nil)
    }

    @Test func aRowsCapsuleSpeaksForTheFirstOrderThatHasItElseTheOneItsStackedWith() throws {
        let ref = Self.pr(4102)
        let family = Self.mission([Self.step(ref, .unordered)], key: .family(Self.session), kind: .family(session: Self.session))
        let attaching = Self.mission([Self.step(Self.pr(4101), .next)], attached: [Self.step(ref, .notInOrder)])
        let naming = Self.mission(
            [Self.step(Self.pr(4100), .next), Self.step(ref, .waiting(open: [Self.pr(4100)], unknown: []))],
            key: .plan(Self.planID), kind: Self.declared(revision: 1, by: nil)
        )

        let found = try #require(OrderBoard.step(for: ref, in: [family, attaching, naming]))
        #expect(found.mission.key == .plan(Self.planID))
        #expect(found.step.standing == .waiting(open: [Self.pr(4100)], unknown: []))

        let stacked = try #require(OrderBoard.step(for: ref, in: [family, attaching]))
        #expect(stacked.mission.key == attaching.key && stacked.step.standing == .notInOrder)

        #expect(OrderBoard.step(for: ref, in: [family]) == nil)
        #expect(OrderBoard.step(for: Self.pr(9999), in: [family, attaching, naming]) == nil)
    }

    // MARK: A mission on a page

    @Test func aPageListsItsOwnPullRequestsAndCountsTheOthers() {
        let mission = Self.mission([
            Self.step(Self.pr(4093), .next), Self.step(Self.gh(412), .waiting(open: [Self.pr(4093)], unknown: [])),
            Self.step(Self.pr(4118), .notVisible(.notListed), status: .unknown(.notListed)),
        ])
        #expect(mission.steps(of: [.pullRequest]).map(\.ref) == [Self.pr(4093), Self.pr(4118)])
        #expect(mission.steps(of: [.gitHubPullRequest]).map(\.ref) == [Self.gh(412)])
        #expect(mission.count(outside: [.pullRequest]) == 1)
        #expect(mission.count(outside: [.gitHubPullRequest]) == 2)
        #expect(mission.shows([.pullRequest]) && mission.shows([.gitHubPullRequest]))

        let onlyStackedOnGitHub = Self.mission([Self.step(Self.pr(4093), .next)], attached: [Self.step(Self.gh(413), .notInOrder)])
        #expect(onlyStackedOnGitHub.shows([.gitHubPullRequest]))
        #expect(!Self.mission([Self.step(Self.pr(4093), .next)]).shows([.gitHubPullRequest]))
    }

    @Test func mergedAndClosedOnesFoldIntoOneLine() {
        let mission = Self.mission([
            Self.step(Self.pr(4074), .merged, status: .merged), Self.step(Self.pr(4075), .closed, status: .closed),
            Self.step(Self.pr(4076), .merged, status: .merged), Self.step(Self.pr(4102), .next),
        ])
        #expect(mission.folded.map(\.ref) == [Self.pr(4074), Self.pr(4075), Self.pr(4076)])
        #expect(OrderText.folded(mission.folded) == "2 merged · 1 closed")
        #expect(OrderText.folded([Self.step(Self.pr(4074), .merged, status: .merged)]) == "1 merged")
        #expect(OrderText.folded([Self.step(Self.pr(4075), .closed, status: .closed)]) == "1 closed")
        #expect(OrderText.progress(mission) == "2 of 4 merged")
    }

    @Test func aMissionIsCalledAfterItsSessionElseItsFirstPullRequestStillOpen() {
        let names: [ItemRef: String] = [Self.session: "Fix the payments bugs", Self.pr(4102): "Add retry with backoff"]
        let name = { (ref: ItemRef) in names[ref] }
        let steps = [Self.step(Self.pr(4074), .merged, status: .merged), Self.step(Self.pr(4102), .next)]

        #expect(OrderText.title(of: Self.mission(steps, kind: Self.declared(revision: 3, by: Self.session)), name: name)
            == "Fix the payments bugs")
        #expect(OrderText.title(of: Self.mission(steps, kind: Self.declared(revision: 3, by: nil)), name: name)
            == "Add retry with backoff")
        #expect(OrderText.title(of: Self.mission(steps, kind: .family(session: Self.session)), name: name)
            == "Fix the payments bugs")
        #expect(OrderText.title(of: Self.mission(steps), name: name) == "Add retry with backoff")
        #expect(OrderText.title(of: Self.mission(steps), name: { _ in nil }) == "!4102 in contoso")
        let finished = [Self.step(Self.pr(4074), .merged, status: .merged)]
        #expect(OrderText.title(of: Self.mission(finished), name: { _ in nil }) == "!4074 in contoso")
    }

    @Test func itsHeaderSaysWhatKindOfGroupItIsAndWhoToldItsOrder() {
        let steps = [Self.step(Self.pr(4102), .next)]
        let name = { (ref: ItemRef) in ref == Self.session ? "Ship the cart" : nil }

        #expect(OrderText.kind(of: Self.mission(steps, key: .plan(Self.planID))) == nil)
        #expect(OrderText.kind(of: Self.mission(steps, key: .stack(repository: "contoso/shop-api", number: 7))) == "GitHub stack 7")
        #expect(OrderText.kind(of: Self.mission(steps)) == "Stacked branches")
        #expect(OrderText.kind(of: Self.mission(steps, key: .family(Self.session))) == "No order known")

        #expect(OrderText.told(Self.mission(steps, kind: Self.declared(revision: 1, by: Self.session)), name: name)
            == "Told by ‘Ship the cart’")
        #expect(OrderText.told(Self.mission(steps, kind: Self.declared(revision: 3, by: Self.session)), name: name)
            == "Told by ‘Ship the cart’ · revision 3")
        #expect(OrderText.told(Self.mission(steps, kind: Self.declared(revision: 2, by: nil)), name: name)
            == "Told by a session · revision 2")
        #expect(OrderText.told(Self.mission(steps), name: name) == nil)
    }

    @Test func itsWords() {
        #expect(OrderText.sessions(1) == "1 session")
        #expect(OrderText.sessions(3) == "3 sessions")
        #expect(OrderText.elsewhere(1, on: "GitHub") == "+1 on GitHub")
        #expect(OrderText.elsewhere(2, on: "Azure DevOps") == "+2 on Azure DevOps")
        #expect(OrderText.placeholder(Self.step(Self.pr(4074), .merged, status: .merged)) == "!4074 · Merged")
        #expect(OrderText.placeholder(Self.step(Self.pr(4075), .closed, status: .closed)) == "!4075 · Closed without merging")
        #expect(OrderText.placeholder(Self.step(Self.pr(4118), .notVisible(.notListed), status: .unknown(.notListed)))
            == "!4118 · Can't see it")
        #expect(OrderText.placeholder(Self.step(Self.pr(4118), .notVisible(.sourceOff), status: .unknown(.sourceOff)))
            == "!4118 · Azure DevOps is off")
        #expect(OrderText.placeholder(Self.step(Self.gh(412), .notVisible(.sourceOff), status: .unknown(.sourceOff)))
            == "#412 · GitHub is off")
    }

    // MARK: Paths

    @Test func hoveringOneLightsWhatGoesBeforeItAndAfterItThroughOthers() {
        let lines = [(4101, 4102), (4102, 4103), (4102, 4105), (4105, 4106), (4200, 4201)].map { before, after in
            OrderLine(edge: OrderEdge(Self.pr(before), Self.pr(after)), style: .dashed)
        }
        #expect(OrderLine.related(to: Self.pr(4102), by: lines) == Set([4101, 4102, 4103, 4105, 4106].map(Self.pr)))
        #expect(OrderLine.related(to: Self.pr(4105), by: lines) == Set([4101, 4102, 4105, 4106].map(Self.pr)))
        #expect(OrderLine.related(to: Self.pr(4103), by: lines) == Set([4101, 4102, 4103].map(Self.pr)))
        #expect(OrderLine.related(to: Self.pr(4201), by: lines) == Set([4200, 4201].map(Self.pr)))
        #expect(OrderLine.related(to: Self.pr(4104), by: lines) == [Self.pr(4104)])
    }
}
