import AppKit
import BriefBarCore
@testable import BriefBarUI
import Foundation
import SwiftUI
import Testing

/// The time, as a test moves it on.
@MainActor
fileprivate final class SplitClock {
    var now = Date(timeIntervalSince1970: 1_792_000_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Apple Intelligence, as a test answers for it: it tells coupons from build agents, by the titles it's asked about.
@MainActor
fileprivate final class SplitModel {
    var namePrompts: [String] = []
    var splitPrompts: [String] = []
    /// Why it can't answer now, or nil when it can.
    var unavailability: OnDeviceModel.Unavailability?
    /// Its answer to a split's question, where a test gives one; else it tells coupons from build agents.
    var splitAnswer: ((String) -> String)?
    /// Whether it holds its answers to splits' questions, or to names, until `release()`.
    var holdsSplits = false
    var holdsNames = false
    /// How it fails the split question it's asked the nth time, where a test says.
    var splitFailures: [Int: OnDeviceModel.Failure] = [:]
    private var held: [CheckedContinuation<Void, Never>] = []

    func release() {
        let waiting = held
        held = []
        for answer in waiting { answer.resume() }
    }

    /// Held strongly, as nothing it holds holds the namer: a question the namer asked can be answered after its test
    /// ends, on a busy machine, and finds it there.
    func namer(clock: SplitClock) -> MissionNamer {
        MissionNamer(
            unavailability: { [self] in unavailability },
            respond: { [self] prompt, _ in
                namePrompts.append(prompt)
                if holdsNames {
                    await withCheckedContinuation { held.append($0) }
                }
                return .success(Self.name(prompt))
            },
            respondSplit: { [self] prompt, _, _ in
                splitPrompts.append(prompt)
                let asked = splitPrompts.count
                if holdsSplits {
                    await withCheckedContinuation { held.append($0) }
                }
                if let failure = splitFailures[asked] { return .failure(failure) }
                return .success(splitAnswer?(prompt) ?? Self.split(prompt))
            },
            now: { clock.now }
        )
    }

    static func name(_ prompt: String) -> String {
        let titles = prompt.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.joined(separator: "\n").lowercased()
        switch (titles.contains("coupon"), titles.contains("build agents")) {
        case (true, true): return "Checkout and build agents"
        case (false, true): return "Build agents"
        default: return "Checkout coupons"
        }
    }

    /// The parts whose titles are about coupons, then the others; all one piece of work when either is none.
    static func split(_ prompt: String) -> String {
        var coupons: [Int] = []
        var others: [Int] = []
        for chunk in prompt.components(separatedBy: "Part ").dropFirst() {
            guard let number = Int(chunk.prefix { $0.isNumber }) else { continue }
            if chunk.lowercased().contains("coupon") { coupons.append(number) } else { others.append(number) }
        }
        guard !coupons.isEmpty, !others.isEmpty else {
            return #"{"oneWork":true,"groups":[{"parts":[\#((coupons + others).sorted().map(String.init).joined(separator: ","))]}]}"#
        }
        func group(_ parts: [Int]) -> String { #"{"parts":[\#(parts.map(String.init).joined(separator: ","))]}"# }
        return #"{"oneWork":false,"groups":[\#(group(coupons)),\#(group(others))]}"#
    }
}

/// A page that shows By Mission, as the service knows it.
fileprivate final class SplitViewer {}

/// Suggested splits (§7.4.8), as the service and the namer give them: asked after names, twice, of what's on screen
/// once settled, and again only when what the mission is made of changes; Split as one change of yours, with one Undo
/// that counts as Keep Together; Keep Together kept by what the mission is made of, and forgotten with its source. One
/// at a time, as the naming tests are.
@MainActor
@Suite(.serialized) struct SuggestedSplitsTests {
    static let story = ItemRef.workItem(organization: "contoso", id: 5100)
    static let planID = UUID(uuidString: "41111111-2222-4333-8444-555555555555")!

    static func pr(_ number: Int) -> ItemRef { MissionNamingTests.pr(number) }

    static let titles: [Int: String] = [
        4101: "Add the coupon field", 4102: "Round coupon totals", 4103: "Show coupon errors",
        4120: "Upgrade the build agents", 4121: "Cache the build agents' packages", 4122: "Pin the build agents' images",
    ]

    /// Azure DevOps' pull requests for User Story 5100, each for a task of its own, in their numbers' order, with Show Links
    /// reading their stories, but those `pending`'s; or, Show Links off, none. Open, but those `states` says otherwise.
    static func tell(
        _ order: PullRequestOrder, _ numbers: [Int] = [4101, 4102, 4120, 4121], retitled: [Int: String] = [:],
        readsStories: Bool = true, pending: Set<Int> = [], states: [Int: PullRequestState] = [:]
    ) {
        let pullRequests = numbers.enumerated().map { index, number in
            var pullRequest = MissionNamingTests.ado(number, readsStories && !pending.contains(number) ? [
                OrderStory(ref: story, type: "User Story", task: .workItem(organization: "contoso", id: number + 1_000), rank: Double(index + 1)),
            ] : nil)
            if let state = states[number] { pullRequest.state = state }
            return pullRequest
        }
        var items = [MissionNamingTests.item(story, "Checkout redesign")]
        for number in numbers {
            let title = retitled[number] ?? titles[number] ?? "Pull request \(number)"
            items.append(MissionNamingTests.item(pr(number), title))
            items.append(MissionNamingTests.item(.workItem(organization: "contoso", id: number + 1_000), title))
        }
        order.publish(.azureDevOps, pullRequests: pullRequests, items: items, readsStories: readsStories)
    }

    static let session = ItemRef.session("00000000-0000-4000-8000-000000000401")!

    /// Copilot's session that opened them.
    static func tellCopilot(_ order: PullRequestOrder, opened numbers: [Int] = [4101, 4102, 4120, 4121]) {
        order.publish(
            .copilot, sessions: [OrderSession(ref: session, pullRequests: numbers.map(pr))],
            items: [MissionNamingTests.item(session, "Checkout coupons and agents")]
        )
    }

    fileprivate static func service(_ defaults: MemoryDefaults = MemoryDefaults(), clock: SplitClock, isDemo: Bool = false) -> PullRequestOrder {
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        return PullRequestOrder(defaults: defaults, isDemo: isDemo, now: { clock.now })
    }

    fileprivate static func show(_ keys: [MissionKey], in viewer: SplitViewer, by order: PullRequestOrder) {
        order.setVisible(true, for: MissionNamingTests.page)
        order.showing(keys, in: viewer, on: MissionNamingTests.page)
    }

    static func mission(_ key: MissionKey, in order: PullRequestOrder) -> OrderMission? {
        order.missions.first { $0.key == key }
    }

    static func refs(of mission: OrderMission?) -> Set<ItemRef> {
        Set(((mission?.steps ?? []) + (mission?.attached ?? [])).map(\.ref))
    }

    /// You kept the mission together as its question says it's made now.
    static func keptAsMade(_ question: MissionSplitQuestion, by order: PullRequestOrder) -> Bool {
        guard let contents = question.contents else { return order.keptTogether.keeps(question.key) }
        return order.keptTogether.entries[question.key]?.contents[contents.tells] == contents.digests
    }

    /// Three hours go by, as `KeptTogether.settleFor` counts them, the service looking again each hour, as its clock does.
    fileprivate static func hoursPass(_ order: PullRequestOrder, clock: SplitClock) {
        for _ in 0..<Int(KeptTogether.settleFor / KeptTogether.mostAtOnce) {
            clock.advance(KeptTogether.mostAtOnce)
            order.timePassed()
        }
    }

    /// What you kept together is kept: its suggestion doesn't show, nor is Apple Intelligence asked it again once settled.
    fileprivate static func stillKept(
        _ key: MissionKey, in order: PullRequestOrder, model: SplitModel, clock: SplitClock, viewer: SplitViewer,
        _ when: Comment
    ) async throws {
        let asked = model.splitPrompts.count
        let mission = try #require(Self.mission(key, in: order), when)
        #expect(order.keptTogether.entries[key] != nil, when)
        #expect(order.suggestedSplit(for: mission) == nil, when)
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.splitPrompts.count == asked, when)
    }

    /// The story's mission on screen, settled, with the split Apple Intelligence suggests for it.
    fileprivate static func suggested(
        _ order: PullRequestOrder, model: SplitModel, clock: SplitClock, viewer: SplitViewer
    ) async throws -> OrderMission {
        let mission = try #require(order.missions.first)
        #expect(mission.key == .story(Self.story))
        Self.show([mission.key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: mission) != nil })
        return try #require(Self.mission(mission.key, in: order))
    }

    @Test func aSplitIsSuggestedAfterTheNameFromTwoQuestionsAndConfirmedAsOneChangeWithOneUndo() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let viewer = SplitViewer()
        var mission = try await Self.suggested(order, model: model, clock: clock, viewer: viewer)
        let key = mission.key

        // The mission's name first; then the question twice, its parts in order with its story, then reversed without; then
        // the names of the groups that need one.
        #expect(model.namePrompts.count == 3)
        #expect(model.splitPrompts.count == 2)
        #expect(model.splitPrompts[0].hasPrefix("Story: “Checkout redesign”\nPart 1:\n- “Add the coupon field”\n"))
        #expect(model.splitPrompts[1].hasPrefix("Part 1:\n- “Cache the build agents' packages”\n"))
        #expect(model.namePrompts[1].hasPrefix("Current name: “Checkout and build agents”\n"))
        #expect(!model.namePrompts[2].contains("Current name"))
        let box = try #require(order.splitBox(for: mission))
        #expect(box.button == "Split in Two")
        #expect(box.lines.map(\.title) == ["Checkout coupons", "Build agents"])
        #expect(box.lines.map(\.goes) == [.keeps, .newMission])
        #expect(box.lines.map(\.refs) == [[Self.pr(4101), Self.pr(4102)], [Self.pr(4120), Self.pr(4121)]])
        // Nothing moved yet.
        #expect(order.title(of: mission) == "Checkout and build agents")
        #expect(Self.refs(of: mission).count == 4)

        // Split: one change, with Focus staying on the mission, which takes the name its group was given.
        order.setFocus(key)
        let said = try #require(order.split(mission))
        #expect(said == "‘Build agents’ is a new mission with 4120 and 4121. Undo is on the card of ‘Checkout coupons’.")
        mission = try #require(Self.mission(key, in: order))
        #expect(Self.refs(of: mission) == [Self.pr(4101), Self.pr(4102)])
        #expect(order.title(of: mission) == "Checkout coupons" && order.naming(of: mission) == .appleIntelligence)
        let new = try #require(order.missions.first { if case .mine = $0.key { true } else { false } })
        #expect(Self.refs(of: new) == [Self.pr(4120), Self.pr(4121)])
        #expect(order.title(of: new) == "Build agents" && order.naming(of: new) == .appleIntelligence)
        #expect(order.focus == key)
        guard case .order(let last)? = order.lastChange else {
            Issue.record("A split is your last change to a mission")
            return
        }
        #expect(Set(last.touched.keys) == [Self.pr(4120), Self.pr(4121)])
        #expect(last.said == "Split ‘Checkout coupons’: !4120 and !4121 are in ‘Build agents’ now")
        // Apple Intelligence's names, in memory: none of them yours.
        #expect(defaults.object(forKey: MissionNames.defaultsKey) == nil)
        #expect(order.suggestedSplit(for: mission) == nil)
        // The one that kept its key isn't asked its name again, though nothing else shows meanwhile.
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.namePrompts.count == 3)
        // Shown, neither is asked its name again, being named from what it was asked with.
        Self.show([key, new.key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.namePrompts.count == 3 && model.splitPrompts.count == 2)

        // Undo puts all of it back at once, the names Apple Intelligence had given too, and counts as Keep Together.
        #expect(order.undo())
        mission = try #require(Self.mission(key, in: order))
        #expect(Self.refs(of: mission).count == 4)
        #expect(!order.missions.contains { $0.key == new.key })
        #expect(order.title(of: mission) == "Checkout and build agents" && order.naming(of: mission) == .appleIntelligence)
        #expect(order.modelNames[new.key] == nil)
        // On screen, it isn't asked its name again, being named from what it was asked with before the split.
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.namePrompts.count == 3)
        #expect(order.title(of: mission) == "Checkout and build agents")
        let question = try #require(order.splitQuestion(for: mission))
        #expect(Self.keptAsMade(question, by: order))
        #expect(defaults.data(forKey: KeptTogether.defaultsKey) != nil)
        #expect(order.suggestedSplit(for: mission) == nil)
        // Suggested Split… shows it again, as it still holds, without asking again.
        #expect(order.offersSuggestedSplit(mission))
        order.showSuggestedSplit(mission)
        #expect(order.suggestedSplit(for: mission) != nil)
        #expect(!order.offersSuggestedSplit(mission))
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.splitPrompts.count == 2)
        order.stopShowing(in: viewer)
    }

    /// The names Undo of a split puts back go with it as BriefBar sees its pull requests change, and as the chains and
    /// missions it names are renamed.
    @Test func theNamesUndoOfASplitPutsBackGoWithIt() {
        let key = MissionKey.story(Self.story)
        let asked = MissionNameInputs(pullRequests: ["Add the coupon field"])
        let names = [
            key: OrderLastChange.ReplacedName(name: "Checkout and build agents", asked: asked),
            MissionKey.mine(Self.planID): OrderLastChange.ReplacedName(name: nil, asked: nil),
        ]
        var last = OrderLastChange(
            said: "Split", refs: [Self.pr(4120)], mission: .chain(Self.pr(4101)), touched: [Self.pr(4120): nil], evidence: OrderEvidence()
        )
        last.names = names
        #expect(last.seeing(OrderEvidence()).names == names)
        #expect(last.renamingChains([Self.pr(4101): Self.pr(4102)]).names == names)
        #expect(last.renamingMissions { _ in key }.names == names)
    }

    /// A name Apple Intelligence was asked for a mission a split named, answered off screen once Undo put back the name it
    /// had, doesn't count: it was asked of what Undo took back.
    @Test func aNameAnsweredAfterUndoOfTheSplitThatNamedItsMissionDoesntCount() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let viewer = SplitViewer()
        let mission = try await Self.suggested(order, model: model, clock: clock, viewer: viewer)
        let key = mission.key
        try #require(order.split(mission) != nil)
        #expect(model.namePrompts.count == 3)
        // Retitled on screen, the mission that kept its key is asked its name again, and the answer waits.
        model.holdsNames = true
        Self.tell(order, retitled: [4101: "Add the coupon field and its hint"])
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try #require(await MissionNamingTests.eventually { model.namePrompts.count == 4 })
        order.stopShowing(in: viewer)
        #expect(order.undo())
        #expect(order.title(of: try #require(Self.mission(key, in: order))) == "Checkout and build agents")
        model.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(order.title(of: try #require(Self.mission(key, in: order))) == "Checkout and build agents")
    }

    @Test func itsAskedOnlyWithAppleIntelligenceOnScreenOnceSettledAndAgainOnlyWhenWhatTheMissionIsMadeOfChanges() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = SplitViewer()

        // Off screen: never.
        clock.advance(60)
        order.namer?.next()
        #expect(model.splitPrompts.isEmpty)
        // On screen: once it's stayed the same for five seconds, after its name.
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor - 1)
        order.namer?.next()
        #expect(model.namePrompts.isEmpty && model.splitPrompts.isEmpty)
        clock.advance(1)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { model.splitPrompts.count == 2 && model.namePrompts.count == 3 })
        // A title edit alone: its name may be asked again, but not the split.
        Self.tell(order, retitled: [4102: "Round coupon totals half up"])
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.splitPrompts.count == 2)
        // What it's made of changed: asked again, once settled.
        Self.tell(order, [4101, 4102, 4103, 4120, 4121])
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.splitPrompts.count == 2)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { model.splitPrompts.count == 4 })
        // Without Apple Intelligence: not at all.
        model.unavailability = .notEnabled
        Self.tell(order, [4101, 4102, 4103, 4120, 4121, 4122])
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.splitPrompts.count == 4)
        order.stopShowing(in: viewer)
    }

    /// Pull Request Order going off while Apple Intelligence answers a split's first question stops it there: the second
    /// isn't asked, nor are the groups named, and on again, what's on screen is asked at once, not after the rest of it.
    @Test func aSplitUnderWayAsksNothingMoreOnceItsAnswerCantCount() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        model.holdsSplits = true
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try #require(await MissionNamingTests.eventually { model.splitPrompts.count == 1 })
        #expect(model.namePrompts.count == 1)

        order.setOn(false)
        order.setOn(true)
        Self.tell(order)
        clock.advance(MissionNamer.settleFor)
        model.release()
        // Its name first, as Pull Request Order forgot what it asked, then the first question again: not the second.
        try #require(await MissionNamingTests.eventually { model.splitPrompts.count == 2 })
        #expect(model.splitPrompts[1].hasPrefix("Story: “Checkout redesign”\nPart 1:\n- “Add the coupon field”\n"))
        #expect(model.namePrompts.count == 2)
        #expect(model.namePrompts[1] == model.namePrompts[0])

        model.holdsSplits = false
        model.release()
        let mission = try #require(Self.mission(key, in: order))
        #expect(await MissionNamingTests.eventually { order.suggestedSplit(for: mission) != nil })
        #expect(model.splitPrompts.count == 3)
        order.stopShowing(in: viewer)
    }

    /// A split under way whose mission leaves the screen asks Apple Intelligence nothing more of it, and keeps what it
    /// found: back on screen and settled, it's asked only the rest.
    @Test func aSplitUnderWayWhoseMissionLeavesTheScreenIsAskedTheRestOnceItsBack() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        model.holdsSplits = true
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try #require(await MissionNamingTests.eventually { model.splitPrompts.count == 1 && model.namePrompts.count == 1 })
        // Both questions, then the first group's name, which it's answering as the mission leaves the screen.
        model.holdsSplits = false
        model.holdsNames = true
        model.release()
        try #require(await MissionNamingTests.eventually { model.namePrompts.count == 2 })
        #expect(model.splitPrompts.count == 2)
        order.stopShowing(in: viewer)
        model.holdsNames = false
        model.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.namePrompts.count == 2)
        let mission = try #require(Self.mission(key, in: order))
        #expect(order.suggestedSplit(for: mission) == nil)

        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { order.suggestedSplit(for: mission) != nil })
        #expect(model.splitPrompts.count == 2)
        #expect(model.namePrompts.count == 3)
        order.stopShowing(in: viewer)
    }

    /// The first question's answer is kept as the mission leaves the screen before the second is asked, for that question
    /// alone: once what the mission is made of changed, its parts come in another order, which that doesn't tell, or
    /// Pull Request Order or Azure DevOps went off and on, it's asked the first again; back on screen as it was, only the
    /// second.
    @Test func aSplitsFirstAnswerIsKeptForTheSameQuestionAsItsMissionLeavesTheScreen() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        model.holdsSplits = true
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = SplitViewer()
        // Shows the mission till it's asked one more question, which it's answering as the mission leaves the screen.
        func askedOneAsItLeaves() async throws -> String {
            let asked = model.splitPrompts.count
            Self.show([key], in: viewer, by: order)
            clock.advance(MissionNamer.settleFor)
            order.namer?.next()
            try #require(await MissionNamingTests.eventually { model.splitPrompts.count == asked + 1 })
            order.stopShowing(in: viewer)
            model.release()
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.splitPrompts.count == asked + 1)
            return model.splitPrompts[asked]
        }

        #expect(try await askedOneAsItLeaves().hasPrefix("Story: “Checkout redesign”\nPart 1:\n- “Add the coupon field”\n"))
        Self.tellCopilot(order)
        #expect(try await askedOneAsItLeaves().hasPrefix("Story: “Checkout redesign”\n"))
        Self.tell(order, [4101, 4120, 4102, 4121])
        let reordered = try await askedOneAsItLeaves()
        #expect(reordered.hasPrefix("Story: “Checkout redesign”\n"))
        #expect(reordered.contains("Part 2:\n- “Upgrade the build agents”\n"))
        order.setOn(false)
        order.setOn(true)
        Self.tell(order, [4101, 4120, 4102, 4121])
        Self.tellCopilot(order)
        #expect(try await askedOneAsItLeaves() == reordered)
        order.forget(.azureDevOps)
        Self.tell(order, [4101, 4120, 4102, 4121])
        #expect(try await askedOneAsItLeaves() == reordered)

        model.holdsSplits = false
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        let mission = try #require(Self.mission(key, in: order))
        #expect(await MissionNamingTests.eventually { order.suggestedSplit(for: mission) != nil })
        #expect(model.splitPrompts.count == 6)
        #expect(model.splitPrompts.last?.hasPrefix("Part 1:\n- “Cache the build agents' packages”\n") == true)
        order.stopShowing(in: viewer)
    }

    /// The first question's answer is kept while Apple Intelligence is too busy for the second: only the second is asked
    /// again.
    @Test func aSplitsFirstAnswerIsKeptWhileAppleIntelligenceIsTooBusyForTheSecond() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        model.splitFailures = [2: .busy]
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try #require(await MissionNamingTests.eventually {
            order.namer?.wakesAt == clock.now.addingTimeInterval(MissionNamer.retryAfter)
        })
        #expect(model.splitPrompts.count == 2)
        clock.advance(MissionNamer.retryAfter)
        order.namer?.next()
        let mission = try #require(Self.mission(key, in: order))
        #expect(await MissionNamingTests.eventually { order.suggestedSplit(for: mission) != nil })
        #expect(model.splitPrompts.count == 3)
        #expect(model.splitPrompts[2] == model.splitPrompts[1])
        order.stopShowing(in: viewer)
    }

    /// Undo Your Changes to This Mission… on the mission a split made takes the split back too, and counts as Keep Together.
    @Test func undoYourChangesToTheMissionASplitMadeKeepsTheOneItCameFromTogether() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let viewer = SplitViewer()
        let mission = try await Self.suggested(order, model: model, clock: clock, viewer: viewer)
        try #require(order.split(mission) != nil)
        let new = try #require(order.missions.first { if case .mine = $0.key { true } else { false } })
        order.dismissLastChange()
        #expect(order.change(.undoMission(new.key), in: new.key) != nil)
        let back = try #require(Self.mission(mission.key, in: order))
        #expect(Self.refs(of: back).count == 4)
        let question = try #require(order.splitQuestion(for: back))
        #expect(Self.keptAsMade(question, by: order))
        #expect(order.suggestedSplit(for: back) == nil)
        order.stopShowing(in: viewer)
    }

    /// The name you give the mission is the kept group's, and never goes in a question: renaming it asks nothing again.
    @Test func yourNameIsTheKeptGroupsAndNeverInAQuestion() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let viewer = SplitViewer()
        var mission = try await Self.suggested(order, model: model, clock: clock, viewer: viewer)
        #expect(order.rename(mission, to: "Coupons and agents") == .named)
        mission = try #require(Self.mission(mission.key, in: order))
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { order.suggestedSplit(for: mission) != nil })
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.splitPrompts.count == 2 && model.namePrompts.count == 3)
        let box = try #require(order.splitBox(for: mission))
        #expect(box.lines.map(\.title) == ["Coupons and agents", "Build agents"])
        #expect(!(model.splitPrompts + model.namePrompts).contains { $0.contains("Coupons and agents") })
        // Split keeps your name on the mission, and names only the new one.
        _ = order.split(mission)
        mission = try #require(Self.mission(mission.key, in: order))
        #expect(order.title(of: mission) == "Coupons and agents" && order.naming(of: mission) == .you)
        order.stopShowing(in: viewer)
    }

    /// The first answer that sees one piece of work settles it: no second question, no names, no suggestion, and not
    /// asked again until what the mission is made of changes. Nor does a second answer that groups the parts otherwise
    /// than the first, so that what both separate leaves one group.
    @Test func whatEitherAnswerKeepsTogetherStaysTogether() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        model.splitAnswer = { _ in #"{"oneWork":true,"groups":[{"parts":[1,2,3,4]}]}"# }
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        let viewer = SplitViewer()
        Self.show([mission.key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { model.splitPrompts.count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.splitPrompts.count == 1 && model.namePrompts.count == 1)
        #expect(order.suggestedSplit(for: mission) == nil && order.splits.isEmpty)
        Self.tell(order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.splitPrompts.count == 1)

        // The first splits off the first two, the second (reversed) the last one and the rest: together, all one.
        model.splitAnswer = { prompt in
            prompt.hasPrefix("Story:")
                ? #"{"oneWork":false,"groups":[{"parts":[1,2]},{"parts":[3,4,5]}]}"#
                : #"{"oneWork":false,"groups":[{"parts":[1]},{"parts":[2,3,4,5]}]}"#
        }
        Self.tell(order, [4101, 4102, 4103, 4120, 4121])
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { model.splitPrompts.count == 3 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(order.splits.isEmpty)
        order.stopShowing(in: viewer)
    }

    /// An order of four, opened under Copilot's session, on screen and settled, with its suggestion kept together.
    fileprivate static func keptOrder(
        _ defaults: MemoryDefaults, model: SplitModel, clock: SplitClock, viewer: SplitViewer
    ) async throws -> PullRequestOrder {
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        orders.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tellCopilot(order)
        Self.tell(order)
        let key = MissionKey.plan(Self.planID)
        #expect(order.missions.map(\.key) == [key])
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        let suggested = try #require(Self.mission(key, in: order))
        try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: suggested) != nil })
        _ = order.keepTogether(suggested)
        return order
    }

    /// Turning Show Links or Copilot off, which only leaves BriefBar telling less of what a mission is made of, doesn't bring
    /// back a suggestion you kept together, then or as they're on again: what it's made of each way is kept with it once
    /// told so for three hours, and compared only with what it was made of the same way. Nor does keeping one together while
    /// Show Links is off.
    @Test func turningShowLinksOrCopilotOffKeepsWhatYouKeptTogether() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let viewer = SplitViewer()
        let order = try await Self.keptOrder(defaults, model: model, clock: clock, viewer: viewer)
        let key = MissionKey.plan(Self.planID)
        func stillKept(_ when: Comment) async throws {
            try await Self.stillKept(key, in: order, model: model, clock: clock, viewer: viewer, when)
        }
        Self.tell(order, readsStories: false)
        try await stillKept("Show Links off")
        Self.hoursPass(order, clock: clock)
        try await stillKept("Show Links off for three hours")
        order.withdraw(.copilot)
        try await stillKept("Copilot off too")
        Self.hoursPass(order, clock: clock)
        try await stillKept("Copilot off too for three hours")
        Self.tellCopilot(order)
        Self.tell(order)
        try await stillKept("Both on again")
        #expect(KeptTogether.load(from: defaults).entries[key]?.contents.count == 3)
        #expect(model.splitPrompts.count == 2)

        // Kept together while Show Links was off: what it reads later is kept with it, and it isn't asked again.
        order.forgetAll()
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        _ = try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        orders.save(to: defaults)
        order.reloadOrders()
        Self.tell(order, readsStories: false)
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        let unread = try #require(Self.mission(key, in: order))
        try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: unread) != nil })
        let asked = model.splitPrompts.count
        _ = order.keepTogether(unread)
        #expect(KeptTogether.load(from: defaults).entries[key]?.contents.keys.map(\.stories) == [false])
        Self.tell(order)
        Self.hoursPass(order, clock: clock)
        #expect(KeptTogether.load(from: defaults).entries[key]?.contents.count == 2)
        try await stillKept("Show Links on, once kept while off")
        #expect(model.splitPrompts.count == asked)
        order.stopShowing(in: viewer)
    }

    /// Right after BriefBar starts, the sources tell Pull Request Order what they show before they've listed it, as
    /// nothing, and Copilot its sessions before it read which pull requests they opened: what you kept together isn't
    /// counted till they have, however long that takes, as while offline, so it holds, and nothing's saved.
    @Test func keepTogetherHoldsAsBriefBarStartsWhileTheSourcesListWhatTheyShow() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let viewer = SplitViewer()
        try await Self.keptOrder(defaults, model: model, clock: clock, viewer: viewer).stopShowing(in: viewer)
        let key = MissionKey.plan(Self.planID)
        let saved = try #require(defaults.data(forKey: KeptTogether.defaultsKey))

        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        // Before any source tells anything, for three hours: nothing told of it, nothing kept.
        Self.hoursPass(order, clock: clock)
        #expect(order.keptTogether.entries[key]?.contents.count == 1)
        order.publish(.azureDevOps, readsStories: true, listed: false)
        order.publish(.copilot, listed: false)
        #expect(order.missions.map(\.key) == [key])
        Self.hoursPass(order, clock: clock)
        #expect(order.keptTogether.entries[key] != nil)
        Self.tell(order)
        order.publish(.copilot, items: [MissionNamingTests.item(Self.session, "Checkout coupons and agents")], listed: false)
        #expect(order.keptTogether.entries[key] != nil)
        #expect(defaults.data(forKey: KeptTogether.defaultsKey) == saved)
        Self.tellCopilot(order)
        try await Self.stillKept(key, in: order, model: model, clock: clock, viewer: viewer, "Both listed")
        #expect(defaults.data(forKey: KeptTogether.defaultsKey) == saved)
        #expect(model.splitPrompts.count == 2)
        order.stopShowing(in: viewer)
    }

    /// Show Links decides which pull requests opened under a session are its mission: with it off, those for a story join
    /// the others. What you kept together holds as it goes off and on again, and a change while it's off still counts, once
    /// it has lasted three hours.
    @Test func keepTogetherHoldsForASessionsPullRequestsAsShowLinksChangesWhichTheyAre() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        let forStory: Set<Int> = [4103, 4122]
        // Two for the story's tasks, the others for nothing; or, Show Links off, none read.
        func tell(readsStories: Bool, _ numbers: [Int]) {
            let pullRequests = numbers.enumerated().map { index, number in
                MissionNamingTests.ado(number, !readsStories ? nil : forStory.contains(number) ? [
                    OrderStory(ref: Self.story, type: "User Story", task: .workItem(organization: "contoso", id: number + 1_000), rank: Double(index + 1)),
                ] : [])
            }
            let items = [MissionNamingTests.item(Self.story, "Checkout redesign")] + numbers.map { number in
                MissionNamingTests.item(Self.pr(number), Self.titles[number] ?? "Pull request \(number)")
            }
            order.publish(.azureDevOps, pullRequests: pullRequests, items: items, readsStories: readsStories)
            Self.tellCopilot(order, opened: numbers)
        }
        let all = [4101, 4102, 4120, 4121, 4103, 4122]
        tell(readsStories: true, all)
        let key = MissionKey.family(Self.session)
        #expect(Self.refs(of: Self.mission(key, in: order)) == Set([4101, 4102, 4120, 4121].map(Self.pr)))
        #expect(Self.refs(of: Self.mission(.story(Self.story), in: order)) == Set(forStory.map(Self.pr)))
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        let suggested = try #require(Self.mission(key, in: order))
        try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: suggested) != nil })
        _ = order.keepTogether(suggested)
        func stillKept(_ when: Comment) async throws {
            try await Self.stillKept(key, in: order, model: model, clock: clock, viewer: viewer, when)
        }

        tell(readsStories: false, all)
        #expect(Self.refs(of: Self.mission(key, in: order)) == Set(all.map(Self.pr)))
        try await stillKept("Show Links off, with the story's two among them")
        tell(readsStories: true, all)
        try await stillKept("Show Links on again")
        tell(readsStories: false, all)
        try await stillKept("Off again")
        Self.hoursPass(order, clock: clock)
        try await stillKept("Off for three hours")
        // Off, and the session opened another: made of something else, so it's asked again once that's lasted three hours.
        let asked = model.splitPrompts.count
        tell(readsStories: false, all + [4104])
        try await stillKept("Another, just now")
        Self.hoursPass(order, clock: clock)
        #expect(order.keptTogether.entries[key] == nil)
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { model.splitPrompts.count > asked })
        order.stopShowing(in: viewer)
    }

    /// The name a split gives the mission that keeps its key isn't asked again, though nothing else shows after it, as when
    /// it takes one pull request out of missions.
    @Test func takeOutKeepsTheNameItGaveWithoutAskingAgain() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order, [4101, 4102, 4120])
        let viewer = SplitViewer()
        let mission = try await Self.suggested(order, model: model, clock: clock, viewer: viewer)
        #expect(order.splitBox(for: mission)?.button == "Take Out !4120")
        let asked = model.namePrompts.count
        try #require(order.split(mission) != nil)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.namePrompts.count == asked)
        let kept = try #require(Self.mission(mission.key, in: order))
        #expect(Self.refs(of: kept) == [Self.pr(4101), Self.pr(4102)])
        #expect(order.title(of: kept) == "Checkout coupons" && order.naming(of: kept) == .appleIntelligence)
        order.stopShowing(in: viewer)
    }

    /// A split that would leave a story's mission one open pull request, which is no mission, isn't suggested, though both
    /// answers separate all three; nor with one that merged too, as Done lists that only for a while.
    @Test(arguments: [false, true])
    func aSplitThatWouldLeaveAStorysMissionOneOpenPullRequestIsntSuggested(withOneThatMerged: Bool) async throws {
        let clock = SplitClock()
        let model = SplitModel()
        model.splitAnswer = { _ in #"{"oneWork":false,"groups":[{"parts":[1]},{"parts":[2]},{"parts":[3]}]}"# }
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        if withOneThatMerged {
            Self.tell(order, [4099, 4101, 4120, 4121], states: [4099: .merged])
            #expect(Self.refs(of: order.missions.first).contains(Self.pr(4099)))
        } else {
            Self.tell(order, [4101, 4120, 4121])
        }
        let key = try #require(order.missions.first?.key)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { model.splitPrompts.count == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(order.splits.isEmpty)
        #expect(model.namePrompts.count == 1)
        order.stopShowing(in: viewer)
    }

    /// A mission with fewer than three open pull requests, or only one part, isn't asked about, nor is one you made.
    @Test func aMissionTooSmallToSplitIsntAsked() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order, [4101, 4120])
        let key = try #require(order.missions.first?.key)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { model.namePrompts.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.splitPrompts.isEmpty)
        order.stopShowing(in: viewer)
    }

    @Test func keepTogetherIsKeptByWhatTheMissionIsMadeOfAndGoesWithItsSource() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        var order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let viewer = SplitViewer()
        var mission = try await Self.suggested(order, model: model, clock: clock, viewer: viewer)
        let key = mission.key

        #expect(order.keepTogether(mission) == OrderText.keptTogether)
        #expect(order.suggestedSplit(for: mission) == nil)
        let saved = try #require(defaults.data(forKey: KeptTogether.defaultsKey).flatMap { String(data: $0, encoding: .utf8) })
        // A digest of references, never a title.
        #expect(saved.contains("story/workItem/contoso/5100") && !saved.contains("coupon") && !saved.contains("Checkout"))
        // A title edit alone doesn't bring it back.
        Self.tell(order, retitled: [4102: "Round coupon totals half up"])
        mission = try #require(Self.mission(key, in: order))
        #expect(order.suggestedSplit(for: mission) == nil)

        // After a restart, it's still kept, though Show Links reads two of its pull requests' stories only later, which
        // leaves it without them meanwhile; Suggested Split… asks again.
        order.stopShowing(in: viewer)
        order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order, pending: [4120, 4121])
        #expect(Self.refs(of: Self.mission(key, in: order)) == [Self.pr(4101), Self.pr(4102)])
        #expect(order.keptTogether.entries[key] != nil)
        Self.tell(order)
        mission = try #require(Self.mission(key, in: order))
        let question = try #require(order.splitQuestion(for: mission))
        #expect(Self.keptAsMade(question, by: order))
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { model.namePrompts.count == 4 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.splitPrompts.count == 2)
        #expect(order.offersSuggestedSplit(mission))
        order.showSuggestedSplit(mission)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { order.suggestedSplit(for: mission) != nil })
        #expect(model.splitPrompts.count == 4)
        _ = order.keepTogether(mission)
        #expect(order.suggestedSplit(for: mission) == nil)

        // Pull Request Order off keeps it; Copilot off doesn't touch a story's; Azure DevOps off forgets it.
        order.setOn(false)
        #expect(defaults.data(forKey: KeptTogether.defaultsKey) != nil)
        #expect(order.splits.isEmpty)
        order.setOn(true)
        order.forget(.copilot)
        #expect(KeptTogether.load(from: defaults).entries[key] != nil)
        order.forget(.azureDevOps)
        #expect(KeptTogether.load(from: defaults).entries[key] == nil)
        #expect(order.splits.isEmpty)
        order.stopShowing(in: viewer)
    }

    /// What you kept together stays kept as its pull requests merge or close, and once Done no longer lists them, and while
    /// one waits for a next you set, then not, which change how its parts join but nothing the mission is made of: Apple
    /// Intelligence isn't asked again. A pull request it wasn't made of brings the suggestion back three hours later.
    @Test func keepTogetherHoldsAsItsPullRequestsMergeCloseOrWaitForANext() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        let all = [4101, 4102, 4103, 4120, 4121]
        Self.tell(order, all)
        let viewer = SplitViewer()
        let shown = try await Self.suggested(order, model: model, clock: clock, viewer: viewer)
        let key = shown.key
        _ = order.keepTogether(shown)
        func hoursLater(_ when: Comment) async throws {
            Self.hoursPass(order, clock: clock)
            try await Self.stillKept(key, in: order, model: model, clock: clock, viewer: viewer, when)
        }

        Self.tell(order, all, states: [4102: .merged])
        #expect(Self.mission(key, in: order)?.steps.contains { $0.ref == Self.pr(4102) && $0.status == .merged } == true)
        try await hoursLater("Merged")
        Self.tell(order, all, states: [4102: .merged, 4103: .closed])
        try await hoursLater("Closed")
        Self.tell(order, [4101, 4120, 4121])
        try await hoursLater("No longer in Done")
        try #require(order.change(.setNext(Self.pr(4101), in: key, true), in: key)?.canUndo == true)
        try await hoursLater("Waiting for a next")
        try #require(order.change(.setNext(Self.pr(4101), in: key, false), in: key)?.canUndo == true)
        try await hoursLater("No next")

        Self.tell(order, [4101, 4120, 4121, 4122])
        Self.hoursPass(order, clock: clock)
        #expect(order.keptTogether.entries[key] == nil)
        let mission = try #require(Self.mission(key, in: order))
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await MissionNamingTests.eventually { order.suggestedSplit(for: mission) != nil })
        order.stopShowing(in: viewer)
    }

    /// While Show Links still reads what a story's open pull requests are for, its mission can seem finished, with only its
    /// merged ones read: what you kept together isn't counted till it has read them all.
    @Test func keepTogetherWaitsWhileAStorysMissionOnlySeemsFinished() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let open = [4101, 4102, 4120, 4121]
        let merged = [4097, 4098]
        func tell(_ order: PullRequestOrder, pending: Bool) {
            let pullRequests = (open + merged).enumerated().map { index, number in
                var pullRequest = MissionNamingTests.ado(number, pending && open.contains(number) ? nil : [
                    OrderStory(ref: Self.story, type: "User Story", task: .workItem(organization: "contoso", id: number + 1_000), rank: Double(index + 1)),
                ])
                if merged.contains(number) { pullRequest.state = .merged }
                return pullRequest
            }
            let items = [MissionNamingTests.item(Self.story, "Checkout redesign")] + (open + merged).map { number in
                MissionNamingTests.item(Self.pr(number), Self.titles[number] ?? "Pull request \(number)")
            }
            order.publish(.azureDevOps, pullRequests: pullRequests, items: items, readsStories: true)
        }
        var order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        tell(order, pending: false)
        let viewer = SplitViewer()
        let mission = try await Self.suggested(order, model: model, clock: clock, viewer: viewer)
        let key = mission.key
        _ = order.keepTogether(mission)
        order.stopShowing(in: viewer)

        order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        tell(order, pending: true)
        #expect(Self.mission(key, in: order)?.isFinished == true)
        Self.hoursPass(order, clock: clock)
        #expect(order.keptTogether.entries[key] != nil)
        tell(order, pending: false)
        try await Self.stillKept(key, in: order, model: model, clock: clock, viewer: viewer, "All read")
        order.stopShowing(in: viewer)
    }

    @Test func forgetAllOrdersForgetsWhatYouKeptTogether() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let viewer = SplitViewer()
        let mission = try await Self.suggested(order, model: model, clock: clock, viewer: viewer)
        _ = order.keepTogether(mission)
        #expect(defaults.data(forKey: KeptTogether.defaultsKey) != nil)
        order.forgetAll()
        #expect(defaults.data(forKey: KeptTogether.defaultsKey) == nil)
        #expect(order.keptTogether.entries.isEmpty)
        order.stopShowing(in: viewer)
    }

    /// A session's order that names pull requests a split moved takes them, as it does those you moved (decision 2): the
    /// mission they're in then keeps together as it's made now, so that the session and the suggestion don't undo each
    /// other over and over.
    @Test func anOrderTakingWhatASplitMovedKeepsItsMissionTogether() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let viewer = SplitViewer()
        let mission = try await Self.suggested(order, model: model, clock: clock, viewer: viewer)
        try #require(order.split(mission) != nil)
        #expect(order.missions.contains { if case .mine = $0.key { true } else { false } })

        // A session tells an order of all four, after the split.
        clock.advance(60)
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        orders.save(to: defaults)
        order.reloadOrders()
        let key = MissionKey.plan(Self.planID)
        let taken = try #require(Self.mission(key, in: order))
        #expect(Self.refs(of: taken) == [Self.pr(4101), Self.pr(4102), Self.pr(4120), Self.pr(4121)])
        #expect(!order.missions.contains { if case .mine = $0.key { true } else { false } })
        let question = try #require(order.splitQuestion(for: taken))
        #expect(question.isWorthAsking)
        #expect(Self.keptAsMade(question, by: order))
        // Shown, it isn't asked about.
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.splitPrompts.count == 2)
        order.stopShowing(in: viewer)
    }

    /// So does one a session told while BriefBar was closed: as BriefBar starts, it notes that the order took them, and the
    /// mission they're in keeps together then, though BriefBar quits before the sources have read what they show; what it's
    /// made of is told once BriefBar can tell. One it noted before, as it last ran, isn't kept together again, however what
    /// you kept together went since.
    @Test func anOrderTakingWhatASplitMovedWhileBriefBarWasClosedKeepsItsMissionTogether() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let viewer = SplitViewer()
        let split = Self.service(defaults, clock: clock)
        split.namer = model.namer(clock: clock)
        Self.tell(split)
        try #require(split.split(try await Self.suggested(split, model: model, clock: clock, viewer: viewer)) != nil)
        split.stopShowing(in: viewer)

        // BriefBar closed, a session tells an order of all four.
        clock.advance(60)
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        orders.save(to: defaults)
        let key = MissionKey.plan(Self.planID)
        // BriefBar starts, offline, and quits before Azure DevOps has listed anything.
        let offline = Self.service(defaults, clock: clock)
        offline.publish(.azureDevOps, readsStories: true, listed: false)
        #expect(offline.keptTogether.entries[key]?.contents.isEmpty == true)

        // It starts again, online.
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let taken = try #require(Self.mission(key, in: order))
        #expect(Self.refs(of: taken) == [Self.pr(4101), Self.pr(4102), Self.pr(4120), Self.pr(4121)])
        #expect(order.splitQuestion(for: taken)?.isWorthAsking == true)
        try await Self.stillKept(key, in: order, model: model, clock: clock, viewer: viewer, "Taken back while closed")
        // What it's made of, the same for three hours, is told.
        Self.hoursPass(order, clock: clock)
        let told = try #require(Self.mission(key, in: order))
        let question = try #require(order.splitQuestion(for: told))
        #expect(Self.keptAsMade(question, by: order))
        try #require(order.change(.setNext(Self.pr(4101), in: key, true))?.canUndo == true)
        order.stopShowing(in: viewer)

        // What it kept together goes, as once the mission has been made of something else for three hours. BriefBar closed
        // again, the session puts the coupon field after their rounding, against your next; as BriefBar starts, it notes
        // that, and the order it noted taking them before is no news.
        defaults.removeObject(forKey: KeptTogether.defaultsKey)
        clock.advance(60)
        var revised = DeclaredOrders.load(from: defaults)
        try revised.apply(
            OrderRequest(plan: Self.planID.uuidString, revision: 1, entries: [
                .init(link: link(4102)), .init(link: link(4101), after: [link(4102)]), .init(link: link(4120)),
                .init(link: link(4121)),
            ]),
            now: clock.now, newID: UUID()
        )
        revised.save(to: defaults)
        let again = Self.service(defaults, clock: clock)
        Self.tell(again)
        #expect(again.changes[Self.pr(4101)]?.overridden != nil)
        #expect(again.missions.contains { $0.key == key })
        #expect(again.keptTogether.entries[key] == nil)
    }

    /// Undo that gives an order back what it took from a split, as Undo of Put Yours Back does, keeps the mission it's back
    /// in together too, though what you kept together as the order took it went since. Put Yours Back alone, which leaves
    /// the order's mission made of less, isn't a change.
    @Test func undoThatGivesAnOrderBackWhatItTookFromASplitKeepsItsMissionTogether() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let viewer = SplitViewer()
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        Self.tellCopilot(order, opened: [])
        try #require(order.split(try await Self.suggested(order, model: model, clock: clock, viewer: viewer)) != nil)
        order.stopShowing(in: viewer)
        clock.advance(60)
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        orders.save(to: defaults)
        order.reloadOrders()
        let key = MissionKey.plan(Self.planID)
        #expect(order.keptTogether.entries[key] != nil)

        // You put yours back for the build agents' upgrade: the order's mission, without it for three hours, is kept.
        try #require(order.change(.putBack(Self.pr(4120)))?.canUndo == true)
        #expect(!Self.refs(of: Self.mission(key, in: order)).contains(Self.pr(4120)))
        Self.hoursPass(order, clock: clock)
        #expect(order.keptTogether.entries[key] != nil)
        // A session turns out to have opened the coupon field, which the order's mission wasn't made of: three hours later,
        // what you kept together goes.
        Self.tellCopilot(order, opened: [4101])
        Self.hoursPass(order, clock: clock)
        #expect(order.keptTogether.entries[key] == nil)
        #expect(order.undo())
        let back = try #require(Self.mission(key, in: order))
        #expect(Self.refs(of: back).contains(Self.pr(4120)))
        let question = try #require(order.splitQuestion(for: back))
        #expect(Self.keptAsMade(question, by: order))
    }

    /// A split goes by the orders as agents last told them: once a revision BriefBar hadn't heard of yet relates what the
    /// suggestion separates, it doesn't hold, and nothing moves.
    @Test func aRevisionThatRelatesWhatItSeparatesCallsTheSplitOff() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        orders.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tellCopilot(order)
        Self.tell(order)
        let key = MissionKey.plan(Self.planID)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        let shown = try #require(Self.mission(key, in: order))
        try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: shown) != nil })
        // The session puts the build agents' upgrade after the coupon field, which BriefBar hasn't heard yet.
        var revised = DeclaredOrders.load(from: defaults)
        try revised.apply(
            OrderRequest(plan: Self.planID.uuidString, revision: 1, entries: [
                .init(link: link(4101)), .init(link: link(4102)), .init(link: link(4120), after: [link(4101)]),
                .init(link: link(4121)),
            ]),
            now: clock.now, newID: UUID()
        )
        revised.save(to: defaults)
        #expect(order.split(shown) == nil)
        #expect(order.changes.isEmpty)
        #expect(Self.refs(of: Self.mission(key, in: order)) == [Self.pr(4101), Self.pr(4102), Self.pr(4120), Self.pr(4121)])
        order.stopShowing(in: viewer)
    }

    /// A revision told after a split that puts a line across it takes what the split moved back into the order's mission,
    /// which keeps together; Put Yours Back puts all of it back as one change, and the order told again with that line takes
    /// nothing back.
    @Test func aRevisionThatPutsALineAcrossASplitTakesItBackAndPutYoursBackPutsAllOfItBack() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        orders.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tellCopilot(order)
        Self.tell(order)
        let key = MissionKey.plan(Self.planID)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        let shown = try #require(Self.mission(key, in: order))
        try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: shown) != nil })
        try #require(order.split(shown) != nil)
        try #require(Set(order.changes.all.map(\.ref)) == [Self.pr(4120), Self.pr(4121)])
        let mine = try #require(order.changes[Self.pr(4120)]?.placement)
        order.stopShowing(in: viewer)

        // The session puts the build agents' upgrade after the coupon totals since.
        clock.advance(60)
        func tell(_ revision: Int, _ entries: [OrderRequest.Entry]) throws {
            var revised = DeclaredOrders.load(from: defaults)
            try revised.apply(OrderRequest(plan: Self.planID.uuidString, revision: revision, entries: entries), now: clock.now, newID: UUID())
            revised.save(to: defaults)
            order.reloadOrders()
        }
        let crossing: [OrderRequest.Entry] = [
            .init(link: link(4101)), .init(link: link(4102)), .init(link: link(4120), after: [link(4102)]), .init(link: link(4121)),
        ]
        try tell(1, crossing)
        #expect(Self.refs(of: Self.mission(key, in: order)) == [Self.pr(4101), Self.pr(4102), Self.pr(4120), Self.pr(4121)])
        #expect(order.changes[Self.pr(4120)]?.overridden?.by == Self.planID)
        #expect(order.changes[Self.pr(4121)]?.overridden?.with == Self.pr(4120))
        #expect(order.keptTogether.entries[key] != nil)
        #expect(!order.missions.contains { .into($0.key) == mine })

        // Put Yours Back on the one that went back with it: both go back, with one Undo.
        let putBack = try #require(order.change(.putBack(Self.pr(4121))))
        #expect(putBack.said == "You put your changes to !4120 and !4121 back")
        #expect(putBack.refs == [Self.pr(4120), Self.pr(4121)])
        #expect(Self.refs(of: Self.mission(key, in: order)) == [Self.pr(4101), Self.pr(4102)])
        #expect(Self.refs(of: order.missions.first { .into($0.key) == mine }) == [Self.pr(4120), Self.pr(4121)])
        // Told again with that line, and more: nothing goes back.
        clock.advance(60)
        try tell(2, [.init(link: link(4101)), .init(link: link(4102), after: [link(4101)])] + crossing.dropFirst(2))
        #expect(order.changes.all.allSatisfy { $0.overridden == nil })
        #expect(Self.refs(of: Self.mission(key, in: order)) == [Self.pr(4101), Self.pr(4102)])
        // Undo gives the order back what it took.
        #expect(order.undo())
        #expect(Self.refs(of: Self.mission(key, in: order)) == [Self.pr(4101), Self.pr(4102), Self.pr(4120), Self.pr(4121)])
        #expect(order.keptTogether.entries[key] != nil)
    }

    /// A line across a split, told while another session's order had what the split moved, takes it back once BriefBar
    /// forgets that order, and keeps the order's mission together: also what the split moved alone, which goes from that
    /// order's override straight to its own order's.
    @Test func aLineToldWhileAnotherOrderHadWhatASplitMovedTakesItBackAsBriefBarForgetsThatOrder() async throws {
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        let otherID = UUID(uuidString: "71111111-2222-4333-8444-555555555555")!
        for numbers in [[4101, 4102, 4103, 4120], [4101, 4102, 4120, 4121]] {
            let clock = SplitClock()
            let model = SplitModel()
            let defaults = MemoryDefaults()
            var orders = DeclaredOrders.load(from: defaults)
            try orders.apply(OrderRequest(entries: numbers.map { .init(link: link($0)) }), now: clock.now, newID: Self.planID)
            orders.save(to: defaults)
            let order = Self.service(defaults, clock: clock)
            order.namer = model.namer(clock: clock)
            Self.tellCopilot(order, opened: [])
            Self.tell(order, numbers)
            let key = MissionKey.plan(Self.planID)
            let viewer = SplitViewer()
            Self.show([key], in: viewer, by: order)
            clock.advance(MissionNamer.settleFor)
            order.namer?.next()
            let shown = try #require(Self.mission(key, in: order))
            try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: shown) != nil })
            try #require(order.split(shown) != nil)
            try #require(Set(order.changes.all.map(\.ref)) == Set(numbers.filter { $0 >= 4120 }.map(Self.pr)))
            order.stopShowing(in: viewer)
            func save(_ change: (inout DeclaredOrders) throws -> Void) throws {
                var revised = DeclaredOrders.load(from: defaults)
                try change(&revised)
                revised.save(to: defaults)
                order.reloadOrders()
            }

            // Another session's order takes the build agents' upgrade, which keeps the order's mission together, as the order
            // names it too; a session turns out to have opened only the coupon field, and three hours later that goes. The
            // split's order puts the upgrade after the coupon totals meanwhile.
            clock.advance(60)
            try save { try $0.apply(OrderRequest(entries: [.init(link: link(4120))]), now: clock.now, newID: otherID) }
            #expect(order.changes[Self.pr(4120)]?.overridden?.by == otherID)
            #expect(order.keptTogether.entries[key] != nil)
            Self.tellCopilot(order, opened: [4101])
            Self.hoursPass(order, clock: clock)
            #expect(order.keptTogether.entries[key] == nil)
            clock.advance(60)
            try save {
                try $0.apply(
                    OrderRequest(plan: Self.planID.uuidString, revision: 1, entries: numbers.map { number in
                        number == 4120 ? .init(link: link(4120), after: [link(4102)]) : .init(link: link(number))
                    }),
                    now: clock.now
                )
            }
            #expect(order.keptTogether.entries[key] == nil)
            // BriefBar forgets the other order: the split's order takes what the split moved back, and its mission keeps
            // together.
            clock.advance(60)
            try save { _ = try $0.forget(plan: otherID.uuidString) }
            #expect(order.changes.all.allSatisfy { $0.overridden?.by == Self.planID })
            #expect(Self.refs(of: Self.mission(key, in: order)) == Set(numbers.map(Self.pr)))
            #expect(order.keptTogether.entries[key] != nil)
        }
    }

    /// A line among what a split moved, told since, is one BriefBar knows from then on, kept with your changes: once one of
    /// them goes back to the order's mission, by Undo Your Changes to It, the order told again takes nothing back.
    @Test func aLineAmongWhatASplitMovedToldSinceTakesNothingBackOnceOneOfThemGoesBack() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        orders.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tellCopilot(order)
        Self.tell(order)
        let key = MissionKey.plan(Self.planID)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        let shown = try #require(Self.mission(key, in: order))
        try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: shown) != nil })
        try #require(order.split(shown) != nil)
        try #require(Set(order.changes.all.map(\.ref)) == [Self.pr(4120), Self.pr(4121)])
        let mine = try #require(order.changes[Self.pr(4120)]?.placement)
        order.stopShowing(in: viewer)

        // The session puts the build agents' upgrade after the coupon field's tests since, both in your mission now.
        func tell(_ revision: Int, _ entries: [OrderRequest.Entry]) throws {
            var revised = DeclaredOrders.load(from: defaults)
            try revised.apply(OrderRequest(plan: Self.planID.uuidString, revision: revision, entries: entries), now: clock.now, newID: UUID())
            revised.save(to: defaults)
            order.reloadOrders()
        }
        let among: [OrderRequest.Entry] = [
            .init(link: link(4101)), .init(link: link(4102)), .init(link: link(4120)), .init(link: link(4121), after: [link(4120)]),
        ]
        clock.advance(60)
        try tell(1, among)
        #expect(order.changes.all.allSatisfy { $0.overridden == nil })
        #expect(OrderChanges.load(from: defaults)[Self.pr(4121)]?.linedWith == [Self.pr(4120)])
        #expect(Self.refs(of: order.missions.first { .into($0.key) == mine }) == [Self.pr(4120), Self.pr(4121)])

        // Undo Your Changes to It on the coupon field's tests: back in the order's mission, and the order told again takes
        // nothing back.
        try #require(order.change(.undo(Self.pr(4120))) != nil)
        #expect(Set(Self.refs(of: Self.mission(key, in: order))) == [Self.pr(4101), Self.pr(4102), Self.pr(4120)])
        clock.advance(60)
        try tell(2, among)
        #expect(order.changes.all.allSatisfy { $0.overridden == nil })
        #expect(Self.refs(of: order.missions.first { .into($0.key) == mine }) == [Self.pr(4121)])

        // The coupon field's tests after the coupon field, told while they're in the order's mission: Undo brings them back
        // where the split put them, knowing that, so it takes nothing back.
        clock.advance(60)
        try tell(3, [
            .init(link: link(4101)), .init(link: link(4102)), .init(link: link(4120), after: [link(4101)]),
            .init(link: link(4121), after: [link(4120)]),
        ])
        #expect(order.undo())
        #expect(order.changes.all.allSatisfy { $0.overridden == nil })
        #expect(Self.refs(of: order.missions.first { .into($0.key) == mine }) == [Self.pr(4120), Self.pr(4121)])
        #expect(OrderChanges.load(from: defaults)[Self.pr(4120)]?.linedWith == [Self.pr(4101), Self.pr(4121)])
    }

    /// A line to one that closed holds nothing up, so it takes nothing back until that one's open again. Undo of Put Yours
    /// Back keeps the order's mission together again, though what you kept together as the order took them went since.
    @Test func aLineToAClosedOneTakesNothingBackAndUndoOfPutYoursBackKeepsTheOrdersMissionTogether() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        orders.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tellCopilot(order, opened: [])
        Self.tell(order)
        let key = MissionKey.plan(Self.planID)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        let shown = try #require(Self.mission(key, in: order))
        try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: shown) != nil })
        try #require(order.split(shown) != nil)
        try #require(Set(order.changes.all.map(\.ref)) == [Self.pr(4120), Self.pr(4121)])
        order.stopShowing(in: viewer)

        // The session puts the coupon totals, closed for now, after both.
        Self.tell(order, states: [4102: .closed])
        clock.advance(60)
        var revised = DeclaredOrders.load(from: defaults)
        try revised.apply(
            OrderRequest(plan: Self.planID.uuidString, revision: 1, entries: [
                .init(link: link(4101)), .init(link: link(4102), after: [link(4120), link(4121)]), .init(link: link(4120)),
                .init(link: link(4121)),
            ]),
            now: clock.now, newID: UUID()
        )
        revised.save(to: defaults)
        order.reloadOrders()
        #expect(order.changes.all.allSatisfy { $0.overridden == nil })
        Self.tell(order)
        #expect(order.changes[Self.pr(4120)]?.overridden?.before == [Self.pr(4102)])
        #expect(order.changes[Self.pr(4121)]?.overridden?.before == [Self.pr(4102)])
        #expect(Self.refs(of: Self.mission(key, in: order)) == [Self.pr(4101), Self.pr(4102), Self.pr(4120), Self.pr(4121)])

        // Put Yours Back: both are back where the split put them.
        try #require(order.change(.putBack(Self.pr(4120)))?.canUndo == true)
        #expect(order.changes.all.allSatisfy { $0.bySplit && $0.overridden == nil })
        #expect(Self.refs(of: Self.mission(key, in: order)) == [Self.pr(4101), Self.pr(4102)])
        // A session turns out to have opened the coupon field: three hours later, what you kept together goes.
        Self.tellCopilot(order, opened: [4101])
        Self.hoursPass(order, clock: clock)
        #expect(order.keptTogether.entries[key] == nil)
        #expect(order.undo())
        let back = try #require(Self.mission(key, in: order))
        #expect(Self.refs(of: back) == [Self.pr(4101), Self.pr(4102), Self.pr(4120), Self.pr(4121)])
        #expect(order.keptTogether.entries[key] != nil)
    }

    /// One you set as next to merge in another mission it's in too stays where it is as a split goes, with what it's
    /// grouped with: the split would take your next away.
    @Test func oneYouSetAsNextInAnotherMissionStaysAsItsMissionSplits() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        let otherID = UUID(uuidString: "51111111-2222-4333-8444-555555555555")!
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        // Another session's order names the build agents' upgrade too.
        try orders.apply(OrderRequest(entries: [4120, 4130].map { .init(link: link($0)) }), now: clock.now, newID: otherID)
        orders.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tellCopilot(order)
        Self.tell(order, [4101, 4102, 4120, 4121, 4130])
        let key = MissionKey.plan(Self.planID)
        let other = MissionKey.plan(otherID)
        try #require(order.change(.setNext(Self.pr(4120), in: other, true))?.canUndo == true)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        let shown = try #require(Self.mission(key, in: order))
        try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: shown) != nil })
        try #require(order.split(shown) != nil)
        #expect(order.changes[Self.pr(4120)]?.first == other)
        #expect(Self.refs(of: Self.mission(key, in: order)) == [Self.pr(4120), Self.pr(4121)])
        #expect(Self.refs(of: Self.mission(other, in: order)).contains(Self.pr(4120)))
        order.stopShowing(in: viewer)
    }

    /// So does one whose change of yours a session's order went against since, with what it's grouped with, though no other
    /// mission has it: the split would take away yours, which you can still put back.
    @Test func oneWhoseChangeAnOrderWentAgainstStaysAsItsMissionSplits() async throws {
        let clock = SplitClock()
        let model = SplitModel()
        let defaults = MemoryDefaults()
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [4101, 4102, 4120, 4121].map { .init(link: link($0)) }), now: clock.now, newID: Self.planID
        )
        orders.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tellCopilot(order)
        Self.tell(order)
        let key = MissionKey.plan(Self.planID)
        try #require(order.change(.setNext(Self.pr(4120), in: key, true))?.canUndo == true)
        // The session puts the build agents' upgrade after their packages' cache since.
        clock.advance(60)
        var revised = DeclaredOrders.load(from: defaults)
        try revised.apply(
            OrderRequest(plan: Self.planID.uuidString, revision: 1, entries: [
                .init(link: link(4101)), .init(link: link(4102)), .init(link: link(4120), after: [link(4121)]),
                .init(link: link(4121)),
            ]),
            now: clock.now, newID: UUID()
        )
        revised.save(to: defaults)
        order.reloadOrders()
        #expect(order.changes[Self.pr(4120)]?.holds(in: revised) == false)
        let viewer = SplitViewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        let shown = try #require(Self.mission(key, in: order))
        try #require(await MissionNamingTests.eventually { order.suggestedSplit(for: shown) != nil })
        try #require(order.split(shown) != nil)
        #expect(order.changes[Self.pr(4120)]?.first == key)
        #expect(Self.refs(of: Self.mission(key, in: order)) == [Self.pr(4120), Self.pr(4121)])
        order.stopShowing(in: viewer)
    }

    @Test func theAnswerIsItsGroupsAloneByGuidedGeneration() throws {
        let shape = try OnDeviceModel.Shape.split(parts: 4)
        let json = try shape.text(ofJSON: #"{"oneWork": false, "groups": [{"parts": [1, 2]}, {"parts": [3, 4]}]}"#)
        #expect(MissionSplitting.grouping(fromJSON: json, parts: 4) == [[0, 1], [2, 3]])
        let one = try shape.text(ofJSON: #"{"oneWork": true, "groups": [{"parts": [1, 2, 3, 4]}]}"#)
        #expect(MissionSplitting.grouping(fromJSON: one, parts: 4) == nil)
    }

    /// The box shows only while its mission has a suggestion; narrow, or with bigger text, its lines and buttons wrap.
    @Test func theBoxShowsOnlyWithASuggestionAndWrapsWhenNarrow() throws {
        let clock = SplitClock()
        let order = Self.service(clock: clock, isDemo: true)
        order.tellDemo(
            DeclaredOrders(),
            split: (.story(Self.story), [[Self.pr(4101), Self.pr(4102)], [Self.pr(4120), Self.pr(4121)]], ["Checkout coupons", "Build agents"])
        )
        Self.tell(order)
        let mission = try #require(order.missions.first)
        func height(_ width: CGFloat, scale: CGFloat = 1, of mission: OrderMission) -> CGFloat {
            let box = SplitSuggestionView(mission: mission, order: order, select: { _ in })
                .environment(\.textScale, scale)
                .frame(width: width)
            return NSHostingView(rootView: box).fittingSize.height
        }
        let wide = height(900, of: mission)
        #expect(wide > 60)
        #expect(height(300, of: mission) > wide)
        #expect(height(900, scale: 1.5, of: mission) > wide)
        // Kept together: gone.
        _ = order.keepTogether(mission)
        #expect(height(900, of: mission) == 0)
    }

    /// Split and Keep Together are as big as the text, bezel and all, where AppKit would keep a button's own title at its
    /// control's size.
    @Test func theBoxsButtonsAreAsBigAsTheText() {
        func size(_ scale: CGFloat) -> CGSize {
            let buttons = HStack(spacing: 8) { SplitButtons(title: "Take Out !4120", split: {}, keepTogether: {}) }
                .controlSize(.small)
                .environment(\.textScale, scale)
                .fixedSize()
            return NSHostingView(rootView: buttons).fittingSize
        }
        let usual = size(1)
        let bigger = size(1.5)
        #expect(bigger.width > usual.width * 1.2 && bigger.height > usual.height)
    }

    @Test func theDemosSplitIsMadeUpAndItNeverAsksTheModel() throws {
        let clock = SplitClock()
        let order = Self.service(clock: clock, isDemo: true)
        #expect(order.namer == nil)
        order.tellDemo(
            DeclaredOrders(), names: [.story(Self.story): "Faster checkout"],
            split: (.story(Self.story), [[Self.pr(4101), Self.pr(4102)], [Self.pr(4120), Self.pr(4121)]], ["Faster checkout", "Build agents"])
        )
        Self.tell(order)
        let mission = try #require(order.missions.first)
        let box = try #require(order.splitBox(for: mission))
        #expect(box.lines.map(\.title) == ["Faster checkout", "Build agents"])
        #expect(box.button == "Split in Two")
    }
}
