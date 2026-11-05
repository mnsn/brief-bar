import BriefBarCore
import BriefBarUI
import Foundation
import SwiftUI
import Testing

/// The time, as a test moves it on.
@MainActor
fileprivate final class Clock {
    var now = Date(timeIntervalSince1970: 1_792_000_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Apple Intelligence, as a test answers for it: what it was asked, and the answer it gives, at once or once released.
@MainActor
fileprivate final class Model {
    var prompts: [String] = []
    var answer: Result<String, OnDeviceModel.Failure> = .success("Faster checkout")
    var isAvailable = true
    /// Whether it holds its answers until `release()`.
    var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func release() {
        let waiting = held
        held = []
        for answer in waiting { answer.resume() }
    }

    func namer(clock: Clock) -> MissionNamer {
        MissionNamer(
            isAvailable: { [unowned self] in isAvailable },
            respond: { [unowned self] prompt, _ in
                prompts.append(prompt)
                if holds {
                    await withCheckedContinuation { held.append($0) }
                }
                return answer
            },
            now: { clock.now }
        )
    }
}

/// A page that shows By Mission, as the service knows it.
fileprivate final class Viewer {}

/// A mission's name (§7.4.7), as the service gives it: yours, then Apple Intelligence's, then BriefBar's own; when Apple
/// Intelligence is asked; and how your names are kept and follow their missions, as Focus does.
@MainActor
@Suite struct MissionNamingTests {
    static let story = ItemRef.workItem(organization: "contoso", id: 5180)
    static let session = ItemRef.session("00000000-0000-4000-8000-000000000003")!

    static func pr(_ number: Int) -> ItemRef { .pullRequest(organization: "contoso", number: number) }

    static func task(_ id: Int, rank: Double) -> OrderStory {
        OrderStory(ref: story, type: "User Story", task: .workItem(organization: "contoso", id: id), rank: rank)
    }

    static func ado(_ number: Int, _ stories: [OrderStory]?) -> OrderPullRequest {
        OrderPullRequest(
            ref: pr(number), repository: "contoso/p/shop-web", sourceBranch: "robin/part-\(number)", targetBranch: "main",
            author: "robin", createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number)), stories: stories
        )
    }

    static func item(_ ref: ItemRef, _ title: String) -> LinkedItem {
        LinkedItem(ref: ref, label: ref.shortOrderLabel, title: title, symbol: "circle", color: .blue)
    }

    /// Azure DevOps' two pull requests for User Story 5180, with Show Links reading their stories; without them while it's
    /// off, as Azure DevOps tells them then.
    static func tell(_ order: PullRequestOrder, firstTitle: String = "Speed up the checkout page", readsStories: Bool = true) {
        order.publish(
            .azureDevOps,
            pullRequests: [ado(4113, readsStories ? [task(5181, rank: 1)] : nil), ado(4105, readsStories ? [task(5183, rank: 3)] : nil)],
            items: [
                item(pr(4113), firstTitle), item(pr(4105), "Prototype one-click checkout"), item(story, "Checkout redesign"),
                item(.workItem(organization: "contoso", id: 5181), "Speed up the checkout page"),
                item(.workItem(organization: "contoso", id: 5183), "Prototype one-click checkout"),
            ],
            readsStories: readsStories
        )
    }

    fileprivate static func service(_ defaults: MemoryDefaults = MemoryDefaults(), clock: Clock, isDemo: Bool = false) -> PullRequestOrder {
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        return PullRequestOrder(defaults: defaults, isDemo: isDemo, now: { clock.now })
    }

    /// Waits for what the model's answer sets, on the main actor.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aMissionIsCalledByYourNameThenAppleIntelligencesThenBriefBarsOwn() async throws {
        let clock = Clock()
        let model = Model()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        #expect(mission.key == .story(Self.story))
        #expect(order.title(of: mission) == "Checkout redesign" && order.naming(of: mission) == .briefBar)

        let viewer = Viewer()
        order.showing([mission.key], in: viewer)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { order.modelNames[mission.key] != nil })
        #expect(order.title(of: mission) == "Faster checkout" && order.naming(of: mission) == .appleIntelligence)
        #expect(order.briefBarsName(of: mission) == "Faster checkout")
        // It's asked from the titles, with BriefBar's own name to keep unless it no longer fits.
        let prompt = try #require(model.prompts.first)
        #expect(prompt.hasPrefix("Current name: Checkout redesign\nStory: Checkout redesign\n"))
        #expect(prompt.contains("- Speed up the checkout page") && prompt.contains("- Prototype one-click checkout"))
        // Nothing of it is kept.
        #expect(defaults.object(forKey: MissionNames.defaultsKey) == nil)

        #expect(order.rename(mission, to: "Coupons and speed") == .named)
        #expect(order.title(of: mission) == "Coupons and speed" && order.naming(of: mission) == .you)
        let saved = try #require(defaults.data(forKey: MissionNames.defaultsKey).flatMap { String(data: $0, encoding: .utf8) })
        #expect(saved == #"[{"key":"story/workItem/contoso/5180","name":"Coupons and speed","unseen":0}]"#)
        // A mission you named isn't asked about, and your name is never in a question.
        Self.tell(order, firstTitle: "Make checkout faster")
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.prompts.count == 1)
        #expect(!model.prompts.contains { $0.contains("Coupons and speed") })

        order.useBriefBarsName(mission.key)
        #expect(order.title(of: mission) == "Faster checkout")
        #expect(defaults.object(forKey: MissionNames.defaultsKey) == nil)
        order.stopShowing(in: viewer)
    }

    @Test func itsAskedOnlyWhileOnScreenOnceSettledAndAgainOnlyOnChange() async throws {
        let clock = Clock()
        let model = Model()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = Viewer()

        // Off screen: never.
        clock.advance(60)
        order.namer?.next()
        #expect(model.prompts.isEmpty)
        // On screen: once it's stayed the same for five seconds.
        order.showing([key], in: viewer)
        clock.advance(MissionNamer.settleFor - 1)
        order.namer?.next()
        #expect(model.prompts.isEmpty)
        clock.advance(1)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 1 })
        // Shown again as it was: not again.
        order.stopShowing(in: viewer)
        order.showing([key], in: viewer)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.prompts.count == 1)
        // What it's named from changed: again, once settled.
        Self.tell(order, firstTitle: "Make checkout faster")
        order.namer?.next()
        #expect(model.prompts.count == 1)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 2 })
        #expect(model.prompts[1].contains("- Make checkout faster"))
        // Without Apple Intelligence: not at all.
        model.isAvailable = false
        Self.tell(order, firstTitle: "Checkout, faster")
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.prompts.count == 2)
        order.stopShowing(in: viewer)
    }

    @Test func aSourceTurnedOffAndOnAgainHasItsMissionsNamedAgain() async throws {
        let clock = Clock()
        let model = Model()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = Viewer()
        order.showing([key], in: viewer)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { order.modelNames[key] != nil })

        order.forget(.azureDevOps)
        #expect(order.modelNames[key] == nil)
        Self.tell(order)
        order.showing([key], in: viewer)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 2 && order.modelNames[key] != nil })
        order.stopShowing(in: viewer)
    }

    @Test func untilShowLinksReadItsWorkItemsItWaits() async throws {
        let clock = Clock()
        let model = Model()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        let viewer = Viewer()
        // A session's pull requests, one whose work items Show Links hasn't read yet.
        order.publish(.copilot, sessions: [OrderSession(ref: Self.session, pullRequests: [Self.pr(4113), Self.pr(4105)])],
                      items: [Self.item(Self.session, "Checkout speed")])
        order.publish(.azureDevOps, pullRequests: [Self.ado(4113, []), Self.ado(4105, nil)],
                      items: [Self.item(Self.pr(4113), "Speed up the checkout page")], readsStories: true)
        let key = try #require(order.missions.first?.key)
        #expect(key == .family(Self.session))
        order.showing([key], in: viewer)
        clock.advance(10 * MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.prompts.isEmpty)
        // Read, and for no story: it's asked, from the pull requests' and the session's titles.
        order.publish(.azureDevOps, pullRequests: [Self.ado(4113, []), Self.ado(4105, [])],
                      items: [Self.item(Self.pr(4113), "Speed up the checkout page")], readsStories: true)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 1 })
        #expect(model.prompts[0].hasPrefix("Current name: Checkout speed\n"))
        #expect(model.prompts[0].contains("Copilot sessions:\n- Checkout speed"))
        order.stopShowing(in: viewer)
    }

    @Test func aRefusalKeepsTheNameItHadAndIsntAskedAgain() async throws {
        let clock = Clock()
        let model = Model()
        model.answer = .failure(.refused)
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        let viewer = Viewer()
        order.showing([mission.key], in: viewer)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(order.title(of: mission) == "Checkout redesign")
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.prompts.count == 1)
        // An answer that's no name keeps it too.
        model.answer = .success("\"\"")
        Self.tell(order, firstTitle: "Make checkout faster")
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(order.title(of: mission) == "Checkout redesign")
        order.stopShowing(in: viewer)
    }

    @Test func anAnswerForWhatChangedOrWentMeanwhileDoesntCountAndItsAskedAgain() async throws {
        let clock = Clock()
        let model = Model()
        model.holds = true
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = Viewer()
        order.showing([key], in: viewer)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 1 })

        // What it's named from changed while Apple Intelligence answered: asked again, once settled, from what it is now.
        Self.tell(order, firstTitle: "Make checkout faster")
        model.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(order.modelNames[key] == nil)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 2 })
        #expect(model.prompts[1].contains("- Make checkout faster"))

        // Pull Request Order went off meanwhile: on again, it's asked again.
        order.setOn(false)
        model.release()
        try await Task.sleep(for: .milliseconds(50))
        order.setOn(true)
        Self.tell(order, firstTitle: "Make checkout faster")
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 3 })

        // Azure DevOps was turned off meanwhile: its name isn't kept, and on again, it's asked again.
        order.forget(.azureDevOps)
        model.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(order.modelNames.isEmpty)
        Self.tell(order, firstTitle: "Make checkout faster")
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 4 })
        model.holds = false
        model.release()
        #expect(await Self.eventually { order.modelNames[key] == "Faster checkout" })
        order.stopShowing(in: viewer)
    }

    @Test func whileAppleIntelligenceIsOffItLooksAgainEveryHalfMinute() async throws {
        let clock = Clock()
        let model = Model()
        model.isAvailable = false
        let order = Self.service(clock: clock)
        let namer = model.namer(clock: clock)
        order.namer = namer
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = Viewer()
        order.showing([key], in: viewer)
        clock.advance(MissionNamer.settleFor)
        namer.next()
        #expect(model.prompts.isEmpty)
        #expect(namer.wakesAt == clock.now.addingTimeInterval(MissionNamer.retryAfter))
        // Turned on meanwhile: it's asked as it looks again.
        model.isAvailable = true
        clock.advance(MissionNamer.retryAfter)
        namer.next()
        #expect(await Self.eventually { model.prompts.count == 1 })
        order.stopShowing(in: viewer)
    }

    @Test func aRenameLeftAsItWasKeepsNothingThoughAppleIntelligenceNamedItMeanwhile() async throws {
        let clock = Clock()
        let model = Model()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        // Rename… shows its name now…
        let shown = order.title(of: mission)
        #expect(shown == "Checkout redesign")
        // …and Apple Intelligence names it before you're done.
        let viewer = Viewer()
        order.showing([mission.key], in: viewer)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { order.modelNames[mission.key] != nil })
        #expect(order.rename(mission, to: shown, from: shown) == .unchanged)
        #expect(order.names.entries.isEmpty && defaults.object(forKey: MissionNames.defaultsKey) == nil)
        #expect(order.title(of: mission) == "Faster checkout")
        // What you typed is kept.
        #expect(order.rename(mission, to: "Coupons and speed", from: shown) == .named)
        #expect(order.title(of: mission) == "Coupons and speed")
        order.stopShowing(in: viewer)
    }

    @Test func renameKeepsOnlyWhatYouTypedAndRefusesAtTheCap() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        var full = MissionNames()
        for number in 1...MissionNames.mostNames {
            _ = full.rename(.chain(Self.pr(number)), to: "Mission \(number)", briefBarsName: "x")
        }
        full.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        #expect(!order.canRename(mission.key))
        #expect(order.rename(mission, to: "Coupons") == .full)
        #expect(order.names.name(for: mission.key) == nil)
        #expect(MissionNames.load(from: defaults).entries.count == MissionNames.mostNames)
        // One whose mission isn't seen goes, two weeks after: room again.
        for _ in 0..<(14 * 12 + 1) {
            clock.advance(2 * 3_600)
            order.timePassed()
        }
        #expect(order.canRename(mission.key))
        // BriefBar's own name, as it shows now: nothing kept.
        #expect(order.rename(mission, to: "Checkout redesign") == .unchanged)
        #expect(order.names.entries.isEmpty)
    }

    @Test func yourNameWaitsWhileWhatMakesItsMissionIsOffAndGoesTwoWeeksAfterItWasLastSeen() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        order.rename(mission, to: "Coupons and speed")
        // Show Links off: no story's mission, and its name waits, however long.
        Self.tell(order, readsStories: false)
        #expect(order.missions.isEmpty)
        for _ in 0..<(30 * 12) {
            clock.advance(2 * 3_600)
            order.timePassed()
        }
        #expect(order.names.name(for: mission.key) == "Coupons and speed")
        // Pull Request Order off: it waits too, and turned on again, it's there.
        order.setOn(false)
        clock.advance(30 * 86_400)
        order.setOn(true)
        #expect(order.names.name(for: mission.key) == "Coupons and speed")
        // Show Links on, but its pull requests went: two weeks later, it goes.
        order.publish(.azureDevOps, pullRequests: [], readsStories: true)
        for _ in 0..<(13 * 12) {
            clock.advance(2 * 3_600)
            order.timePassed()
        }
        #expect(order.names.name(for: mission.key) == "Coupons and speed")
        for _ in 0..<(12 + 1) {
            clock.advance(2 * 3_600)
            order.timePassed()
        }
        #expect(order.names.name(for: mission.key) == nil)
        #expect(defaults.object(forKey: MissionNames.defaultsKey) == nil)
    }

    @Test func focusAndYourNameFollowASessionsPullRequestsToTheirStory() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        order.publish(.copilot, sessions: [OrderSession(ref: Self.session, pullRequests: [Self.pr(4113), Self.pr(4105)])])
        order.publish(.azureDevOps, pullRequests: [Self.ado(4113, nil), Self.ado(4105, nil)], readsStories: true)
        let family = try #require(order.missions.first)
        #expect(family.key == .family(Self.session))
        order.setFocus(family.key)
        order.rename(family, to: "Checkout work")
        // Show Links read them: both are for User Story 5180.
        Self.tell(order)
        let story = try #require(order.missions.first)
        #expect(story.key == .story(Self.story) && story.isFocused)
        #expect(order.focus == .story(Self.story) && OrderFocus.load(from: defaults) == .story(Self.story))
        #expect(order.title(of: story) == "Checkout work")
        #expect(MissionNames.load(from: defaults).name(for: .story(Self.story)) == "Checkout work")
    }

    @Test func forgetAllAndTurningAzureDevOpsOffForgetTheNames() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        order.rename(mission, to: "Coupons and speed")
        #expect(order.keepsAnything)
        order.forget(.azureDevOps)
        #expect(order.names.entries.isEmpty && defaults.object(forKey: MissionNames.defaultsKey) == nil)

        Self.tell(order)
        order.rename(try #require(order.missions.first), to: "Coupons and speed")
        order.forgetAll()
        #expect(order.names.entries.isEmpty && defaults.object(forKey: MissionNames.defaultsKey) == nil)
    }

    @Test func theDemosNamesAreMadeUpAndItNeverAsksTheModel() throws {
        let clock = Clock()
        let order = Self.service(clock: clock, isDemo: true)
        #expect(order.namer == nil)
        order.tellDemo(DeclaredOrders(), names: [.story(Self.story): "Faster checkout"])
        Self.tell(order)
        let mission = try #require(order.missions.first)
        #expect(order.title(of: mission) == "Faster checkout" && order.naming(of: mission) == .appleIntelligence)
    }
}
