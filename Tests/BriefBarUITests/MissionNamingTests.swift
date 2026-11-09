import AppKit
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
    /// Why it can't answer now, or nil when it can.
    var unavailability: OnDeviceModel.Unavailability?
    /// Whether it holds its answers until `release()`.
    var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func release() {
        let waiting = held
        held = []
        for answer in waiting { answer.resume() }
    }

    /// Held strongly, as nothing it holds holds the namer: a question the namer asked can be answered after its test
    /// ends, on a busy machine, and finds it there.
    func namer(clock: Clock) -> MissionNamer {
        MissionNamer(
            unavailability: { [self] in unavailability },
            respond: { [self] prompt, _ in
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
/// Intelligence is asked; and how your names are kept and follow their missions, as Focus does. One at a time: started all
/// at once, their work on the main thread holds it long enough that the Board's keyboard tests press a key before the card
/// they moved has the keyboard's focus back.
@MainActor
@Suite(.serialized) struct MissionNamingTests {
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

    /// An Azure DevOps pull request from `source` into `target`, as a chain's.
    static func stacked(_ number: Int, from source: String, into target: String, _ stories: [OrderStory]?) -> OrderPullRequest {
        OrderPullRequest(
            ref: pr(number), repository: "contoso/p/shop-web", sourceBranch: source, targetBranch: target, author: "robin",
            createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number)), stories: stories
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

    /// The window's page the tests show By Mission on.
    static let page = PullRequestOrder.page(.azureDevOpsPullRequests, window: "1")

    /// By Mission shows these missions in `viewer`, on a window's page that's on screen, as its source says.
    fileprivate static func show(_ keys: [MissionKey], in viewer: Viewer, by order: PullRequestOrder) {
        order.setVisible(true, for: page)
        order.showing(keys, in: viewer, on: page)
    }

    /// Waits for what the model's answer sets, on the main actor, for as long as a busy machine could need
    /// (`waitLimit`).
    static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !condition(), ContinuousClock.now < deadline {
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
        Self.show([mission.key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { order.modelNames[mission.key] != nil })
        #expect(order.title(of: mission) == "Faster checkout" && order.naming(of: mission) == .appleIntelligence)
        #expect(order.briefBarsName(of: mission) == "Faster checkout")
        // It's asked from the titles, with BriefBar's own name to keep unless it no longer fits.
        let prompt = try #require(model.prompts.first)
        #expect(prompt.hasPrefix("Current name: “Checkout redesign”\nStory: “Checkout redesign”\n"))
        #expect(prompt.contains("- “Speed up the checkout page”") && prompt.contains("- “Prototype one-click checkout”"))
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

    /// Apple Intelligence may keep BriefBar's own name, as it's asked to while that fits: it named it all the same.
    @Test func aNameAppleIntelligenceKeptIsStillItsOwn() async throws {
        let clock = Clock()
        let model = Model()
        model.answer = .success("Checkout redesign")
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        #expect(order.title(of: mission) == "Checkout redesign" && order.naming(of: mission) == .briefBar)
        let viewer = Viewer()
        Self.show([mission.key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { order.modelNames[mission.key] != nil })
        #expect(order.title(of: mission) == "Checkout redesign" && order.naming(of: mission) == .appleIntelligence)
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
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor - 1)
        order.namer?.next()
        #expect(model.prompts.isEmpty)
        clock.advance(1)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 1 })
        // Shown again as it was: not again.
        order.stopShowing(in: viewer)
        Self.show([key], in: viewer, by: order)
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
        try #require(await Self.eventually { model.prompts.count == 2 })
        #expect(model.prompts[1].contains("- “Make checkout faster”"))
        // With the name it shows now, Apple Intelligence's, to keep while it fits.
        #expect(model.prompts[1].hasPrefix("Current name: “Faster checkout”\n"))
        // Without Apple Intelligence: not at all.
        model.unavailability = .notEnabled
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
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { order.modelNames[key] != nil })

        order.forget(.azureDevOps)
        #expect(order.modelNames[key] == nil)
        Self.tell(order)
        Self.show([key], in: viewer, by: order)
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
        Self.show([key], in: viewer, by: order)
        clock.advance(10 * MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.prompts.isEmpty)
        // Read, and for no story: it's asked, from the pull requests' and the session's titles.
        order.publish(.azureDevOps, pullRequests: [Self.ado(4113, []), Self.ado(4105, [])],
                      items: [Self.item(Self.pr(4113), "Speed up the checkout page")], readsStories: true)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try #require(await Self.eventually { model.prompts.count == 1 })
        #expect(model.prompts[0].hasPrefix("Current name: “Checkout speed”\n"))
        #expect(model.prompts[0].contains("Copilot sessions:\n- “Checkout speed”"))
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
        Self.show([mission.key], in: viewer, by: order)
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

    /// The answer is made a name with what the mission was named from: a question one of its titles asks can be its name.
    @Test func aQuestionOneOfItsTitlesAsksCanBeItsName() async throws {
        let clock = Clock()
        let model = Model()
        model.answer = .success("Why is checkout slow?")
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order, firstTitle: "Why is checkout slow?")
        let mission = try #require(order.missions.first)
        let viewer = Viewer()
        Self.show([mission.key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { order.modelNames[mission.key] != nil })
        #expect(order.title(of: mission) == "Why is checkout slow?" && order.naming(of: mission) == .appleIntelligence)
        order.stopShowing(in: viewer)
    }

    /// Turning Azure DevOps off forgets every name Apple Intelligence gave missions from its titles, and the answer under
    /// way: a Copilot session's mission's too, though its key names no Azure DevOps pull request.
    @Test func turningAzureDevOpsOffForgetsAppleIntelligencesNamesOfASessionsMission() async throws {
        for late in [false, true] {
            let clock = Clock()
            let model = Model()
            let order = Self.service(clock: clock)
            order.namer = model.namer(clock: clock)
            order.publish(.copilot, sessions: [OrderSession(ref: Self.session, pullRequests: [Self.pr(4113), Self.pr(4105)])],
                          items: [Self.item(Self.session, "Checkout work session")])
            order.publish(.azureDevOps, pullRequests: [Self.ado(4113, nil), Self.ado(4105, nil)], items: [
                Self.item(Self.pr(4113), "Speed up the checkout page"), Self.item(Self.pr(4105), "Prototype one-click checkout"),
            ])
            let family = MissionKey.family(Self.session)
            #expect(order.missions.map(\.key) == [family])
            model.holds = late
            let viewer = Viewer()
            Self.show([family], in: viewer, by: order)
            clock.advance(MissionNamer.settleFor)
            order.namer?.next()
            if late {
                try #require(await Self.eventually { model.prompts.count == 1 })
                order.forget(.azureDevOps)
                model.release()
                try await Task.sleep(for: .milliseconds(100))
            } else {
                try #require(await Self.eventually { order.modelNames[family] == "Faster checkout" })
                order.forget(.azureDevOps)
            }
            #expect(order.modelNames.isEmpty, "late: \(late)")
            order.stopShowing(in: viewer)
        }
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
        Self.show([key], in: viewer, by: order)
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
        try #require(await Self.eventually { model.prompts.count == 2 })
        #expect(model.prompts[1].contains("- “Make checkout faster”"))

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
        model.unavailability = .notEnabled
        let order = Self.service(clock: clock)
        let namer = model.namer(clock: clock)
        order.namer = namer
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = Viewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        namer.next()
        #expect(model.prompts.isEmpty)
        #expect(namer.wakesAt == clock.now.addingTimeInterval(MissionNamer.retryAfter))
        // Turned on meanwhile: it's asked as it looks again.
        model.unavailability = nil
        clock.advance(MissionNamer.retryAfter)
        namer.next()
        #expect(await Self.eventually { model.prompts.count == 1 })
        order.stopShowing(in: viewer)
    }

    /// On a Mac that can't run Apple Intelligence, it never looks again.
    @Test func onAMacThatCantRunAppleIntelligenceItNeverLooksAgain() throws {
        let clock = Clock()
        let model = Model()
        model.unavailability = .notEligible
        let order = Self.service(clock: clock)
        let namer = model.namer(clock: clock)
        order.namer = namer
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = Viewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        namer.next()
        #expect(model.prompts.isEmpty && namer.wakesAt == nil)
        order.stopShowing(in: viewer)
    }

    /// BriefBar keeps a window it closes, to open it again, with its page's views, so By Mission doesn't hear it went.
    /// What the window's page tells its source as the window closes does: nothing it shows is named anymore, and it stops
    /// looking for Apple Intelligence.
    @Test func aClosedWindowsMissionsArentNamed() async throws {
        _ = NSApplication.shared
        let clock = Clock()
        let model = Model()
        model.unavailability = .notReady
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let page = PullRequestOrder.page(.azureDevOpsPullRequests, window: "1")
        let body = ScrollView {
            MissionsBody(
                view: .list, ordering: order, kinds: [.pullRequest], elsewhere: "GitHub", openElsewhere: nil,
                listed: [Self.pr(4113), Self.pr(4105)], row: { step, _ in AnyView(Text(step.ref.id)) },
                place: { _ in nil }, isSelected: { _ in false }, select: { _ in false }, rest: { _ in AnyView(EmptyView()) }
            )
        }
        .environment(\.shownSection, .azureDevOpsPullRequests)
        .environment(\.shownWindow, "1")
        .environmentObject(AppServices(defaults: MemoryDefaults(), isDemo: true))
        .frame(width: 600, height: 400)
        // As BriefBar's windows are.
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 600, height: 400), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AnyView(body))
        defer { window.contentView = nil }
        order.setVisible(true, for: page)
        try await until("its mission is on screen") { order.onScreen == [key] }
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        // Apple Intelligence is getting ready: it looks again in half a minute.
        #expect(order.namer?.wakesAt != nil)

        // ⌘W, and the page off screen, as its source hears.
        window.close()
        order.setVisible(false, for: page)
        #expect(order.onScreen.isEmpty)
        #expect(order.namer?.wakesAt == nil)
        model.unavailability = nil
        Self.tell(order, firstTitle: "Make checkout faster")
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.prompts.isEmpty)
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
        Self.show([mission.key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { order.modelNames[mission.key] != nil })
        #expect(order.rename(mission, to: shown, from: shown) == .unchanged)
        #expect(order.yourNames.entries.isEmpty && defaults.object(forKey: MissionNames.defaultsKey) == nil)
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
        #expect(order.yourNames.name(for: mission.key) == nil)
        #expect(MissionNames.load(from: defaults).entries.count == MissionNames.mostNames)
        // One whose mission isn't seen goes, two weeks after: room again.
        for _ in 0..<(14 * 12 + 1) {
            clock.advance(2 * 3_600)
            order.timePassed()
        }
        #expect(order.canRename(mission.key))
        // BriefBar's own name, as it shows now: nothing kept.
        #expect(order.rename(mission, to: "Checkout redesign") == .unchanged)
        #expect(order.yourNames.entries.isEmpty)
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
        #expect(order.yourNames.name(for: mission.key) == "Coupons and speed")
        // Show Links on, but its pull requests' work items not read yet, as right after BriefBar starts: it waits too.
        order.publish(.azureDevOps, pullRequests: [Self.ado(4113, nil), Self.ado(4105, nil)], readsStories: true)
        for _ in 0..<(30 * 12) {
            clock.advance(2 * 3_600)
            order.timePassed()
        }
        #expect(order.yourNames.name(for: mission.key) == "Coupons and speed")
        // Pull Request Order off: it waits too, and turned on again, it's there.
        order.setOn(false)
        clock.advance(30 * 86_400)
        order.setOn(true)
        #expect(order.yourNames.name(for: mission.key) == "Coupons and speed")
        // Show Links on, but its pull requests went: two weeks later, it goes.
        order.publish(.azureDevOps, pullRequests: [], readsStories: true)
        for _ in 0..<(13 * 12) {
            clock.advance(2 * 3_600)
            order.timePassed()
        }
        #expect(order.yourNames.name(for: mission.key) == "Coupons and speed")
        for _ in 0..<(12 + 1) {
            clock.advance(2 * 3_600)
            order.timePassed()
        }
        #expect(order.yourNames.name(for: mission.key) == nil)
        #expect(defaults.object(forKey: MissionNames.defaultsKey) == nil)
    }

    /// Up Next calls a card's mission as By Mission's header does: the name you gave it, else BriefBar's own.
    @Test func upNextCallsAMissionByTheNameItsHeaderShows() throws {
        let clock = Clock()
        let order = Self.service(clock: clock)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        #expect(UpNextView.missionTitle(mission.key, order: order) == "Checkout redesign")
        order.rename(mission, to: "Coupons and speed")
        #expect(UpNextView.missionTitle(mission.key, order: order) == "Coupons and speed")
        #expect(UpNextView.missionTitle(nil, order: order) == "Not in a mission")
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

    /// What's kept by a session's pull requests' mission follows them to their story's, by one rule: your changes, what Undo
    /// would put back, Focus and your name. The one you put with them goes along, rather than stay in a mission that's gone.
    @Test func yourChangesUndoFocusAndNameFollowASessionsPullRequestsToTheirStory() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        let (family, story) = (MissionKey.family(Self.session), MissionKey.story(Self.story))
        func undone(_ number: Int) -> OrderChange? { order.lastOrderChange?.touched[Self.pr(number)].flatMap { $0 } }
        order.publish(.copilot, sessions: [OrderSession(ref: Self.session, pullRequests: [Self.pr(4113), Self.pr(4105), Self.pr(4106)])])
        order.publish(.azureDevOps, pullRequests: [4113, 4105, 4106, 4120].map { Self.ado($0, nil) }, readsStories: true)
        #expect(order.missions.map(\.key) == [family])
        order.setFocus(family)
        order.rename(try #require(order.missions.first), to: "Checkout work")
        order.change(.move([Self.pr(4120)], to: .into(family), from: nil))
        order.change(.setNext(Self.pr(4105), in: family, true))
        // Then !4106 instead: Undo would set !4105 as next there again.
        order.change(.setNext(Self.pr(4106), in: family, true))
        #expect(order.lastOrderChange?.mission == family && undone(4105)?.first == family)

        // Show Links read them: the session's three are for User Story 5180, !4120 for none.
        order.publish(.azureDevOps, pullRequests: [
            Self.ado(4113, [Self.task(5181, rank: 1)]), Self.ado(4106, [Self.task(5182, rank: 2)]),
            Self.ado(4105, [Self.task(5183, rank: 3)]), Self.ado(4120, []),
        ], readsStories: true)
        #expect(order.missions.map(\.key) == [story])
        let mission = try #require(order.missions.first)
        #expect(Set(mission.steps.map(\.ref)) == Set([4113, 4106, 4105, 4120].map(Self.pr)))
        #expect(mission.steps.first { $0.ref == Self.pr(4106) }?.standing == .next)
        #expect(order.changes[Self.pr(4120)]?.placement == .into(story) && order.changes[Self.pr(4106)]?.first == story)
        #expect(OrderChanges.load(from: defaults)[Self.pr(4120)]?.placement == .into(story))
        #expect(order.focus == story && OrderFocus.load(from: defaults) == story)
        #expect(order.title(of: mission) == "Checkout work")
        #expect(order.lastOrderChange?.mission == story && undone(4105)?.first == story)
        // Undo sets !4105 as next again, in the story's mission.
        #expect(order.undo())
        #expect(order.changes[Self.pr(4105)]?.first == story)
        #expect(order.missions.first?.steps.first { $0.ref == Self.pr(4105) }?.standing == .next)
    }

    /// A chain whose earliest pull request you moved out, still open, goes on by the next: Focus and your name follow it
    /// there, by the same rule, not the one you moved.
    @Test func focusAndYourNameFollowAChainWhoseEarliestYouMovedOut() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        func stacked(_ number: Int, from source: String, into target: String) -> OrderPullRequest {
            OrderPullRequest(
                ref: Self.pr(number), repository: "contoso/p/shop-web", sourceBranch: source, targetBranch: target, author: "robin",
                createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number)), stories: []
            )
        }
        order.publish(.azureDevOps, pullRequests: [
            stacked(4110, from: "robin/a", into: "main"), stacked(4111, from: "robin/b", into: "robin/a"),
            stacked(4112, from: "robin/c", into: "robin/b"),
        ], readsStories: true)
        let chain = try #require(order.missions.first)
        #expect(chain.key == .chain(Self.pr(4110)))
        order.setFocus(chain.key)
        order.rename(chain, to: "Totals")
        let mine = MissionKey.mine(UUID(uuidString: "44444444-5555-4666-8777-888888888888")!)
        order.change(.move([Self.pr(4110)], to: .into(mine), from: chain.key))

        let next = MissionKey.chain(Self.pr(4111))
        #expect(Set(order.missions.map(\.key)) == [next, mine])
        #expect(order.focus == next && OrderFocus.load(from: defaults) == next)
        #expect(order.yourNames.name(for: next) == "Totals" && order.yourNames.name(for: chain.key) == nil)
        #expect(order.title(of: try #require(order.missions.first { $0.key == next })) == "Totals")
    }

    /// What's kept by a chain follows its pull requests into their story's mission as Show Links reads them, and back out
    /// as it's turned off: Focus, your name, and the one you put in it, which never shows apart from them. So it does when a
    /// teammate's pull request is for the story too, on its own: out, it goes with the chain, the one mission they went to.
    @Test func focusYourNameAndWhatYouPutInAChainFollowItIntoItsStoryAndBackOut() throws {
        for teammate in [false, true] {
            let clock = Clock()
            let defaults = MemoryDefaults()
            let order = Self.service(defaults, clock: clock)
            let (chain, story) = (MissionKey.chain(Self.pr(4110)), MissionKey.story(Self.story))
            func publish(reading: Bool, stories: Bool) {
                let theirs = teammate ? [Self.ado(4120, reading ? (stories ? [Self.task(5184, rank: 4)] : []) : nil)] : []
                order.publish(.azureDevOps, pullRequests: [
                    Self.stacked(4110, from: "robin/a", into: "main", reading ? (stories ? [Self.task(5181, rank: 1)] : []) : nil),
                    Self.stacked(4111, from: "robin/b", into: "robin/a", reading ? (stories ? [Self.task(5182, rank: 2)] : []) : nil),
                    Self.ado(4130, reading ? [] : nil),
                ] + theirs, readsStories: reading)
            }
            func expectKept(by key: MissionKey) throws {
                #expect(order.missions.map(\.key) == [key], "teammate: \(teammate)")
                let mission = try #require(order.missions.first)
                let theirs = teammate && key == story ? [4120] : []
                #expect(Set(mission.steps.map(\.ref)) == Set(([4110, 4111, 4130] + theirs).map(Self.pr)), "teammate: \(teammate)")
                #expect(mission.steps.allSatisfy { step in
                    step.notes.allSatisfy { note in
                        switch note {
                        case .placementGone, .placementUnseen: return false
                        default: return true
                        }
                    }
                })
                #expect(mission.isFocused && order.focus == key && OrderFocus.load(from: defaults) == key)
                #expect(order.title(of: mission) == "Totals" && MissionNames.load(from: defaults).entries.keys.map { $0 } == [key])
                #expect(order.changes[Self.pr(4130)]?.placement == .into(key))
                #expect(OrderChanges.load(from: defaults)[Self.pr(4130)]?.placement == .into(key))
            }
            publish(reading: true, stories: false)
            #expect(order.missions.map(\.key) == [chain])
            order.setFocus(chain)
            order.rename(try #require(order.missions.first), to: "Totals")
            order.change(.move([Self.pr(4130)], to: .into(chain), from: nil))
            order.dismissLastChange()
            try expectKept(by: chain)
            // Show Links read that the chain's are for User Story 5180: they go to its mission, with the one you put there.
            publish(reading: true, stories: true)
            try expectKept(by: story)
            // Turned off: they come back to the chain, as you left it.
            publish(reading: false, stories: false)
            try expectKept(by: chain)
            // And on again.
            publish(reading: true, stories: true)
            try expectKept(by: story)
        }
    }

    /// A story's pull requests that go back to more than one mission as Show Links is turned off, as a teammate's chain's
    /// or a session's do: what was kept by the story's mission waits on it, as which of them it came from isn't known. No
    /// mission has its Focus or your name, and the one you put in it shows on its own card, saying it shows once Show
    /// Links reads the story. On again, the story's mission has them all back.
    @Test func whatsKeptWaitsOnAStorysMissionThatSplitsInSeveral() throws {
        let (chain, theirs, family, story) = (
            MissionKey.chain(Self.pr(4110)), MissionKey.chain(Self.pr(4120)), MissionKey.family(Self.session), MissionKey.story(Self.story)
        )
        // Two chains; your chain and a session's three; your chain, a teammate's and a session's two, where you kept them
        // by the session's.
        let shapes: [(name: String, prs: [Int], sessionPRs: [Int], kept: MissionKey, parts: Set<MissionKey>)] = [
            ("two chains", [4110, 4111, 4120, 4121], [], chain, [chain, theirs]),
            ("a chain and a session's", [4110, 4111, 4113, 4105, 4106], [4113, 4105, 4106], chain, [chain, family]),
            ("three ways", [4110, 4111, 4120, 4121, 4113, 4105], [4113, 4105], family, [chain, theirs, family]),
        ]
        for shape in shapes {
            let clock = Clock()
            let defaults = MemoryDefaults()
            let order = Self.service(defaults, clock: clock)
            if !shape.sessionPRs.isEmpty {
                order.publish(.copilot, sessions: [OrderSession(ref: Self.session, pullRequests: shape.sessionPRs.map(Self.pr))])
            }
            func publish(reading: Bool, stories: Bool) {
                let read = { (task: Int) -> [OrderStory]? in reading ? (stories ? [Self.task(task, rank: Double(task - 5180))] : []) : nil }
                let prs = shape.prs.map { number -> OrderPullRequest in
                    switch number {
                    case 4110: Self.stacked(4110, from: "robin/a", into: "main", read(5181))
                    case 4111: Self.stacked(4111, from: "robin/b", into: "robin/a", read(5182))
                    case 4120: Self.stacked(4120, from: "sam/a", into: "main", read(5184))
                    case 4121: Self.stacked(4121, from: "sam/b", into: "sam/a", read(5185))
                    default: Self.ado(number, read(number + 1_090))
                    }
                }
                order.publish(.azureDevOps, pullRequests: prs + [Self.ado(4130, reading ? [] : nil)], readsStories: reading)
            }
            func expectKept(by key: MissionKey) throws {
                let mission = try #require(order.missions.first { $0.key == key }, "\(shape.name)")
                #expect(mission.steps.map(\.ref).contains(Self.pr(4130)), "\(shape.name)")
                #expect(mission.isFocused && order.focus == key && OrderFocus.load(from: defaults) == key, "\(shape.name)")
                #expect(order.title(of: mission) == "Totals" && Array(MissionNames.load(from: defaults).entries.keys) == [key], "\(shape.name)")
                #expect(OrderChanges.load(from: defaults)[Self.pr(4130)]?.placement == .into(key), "\(shape.name)")
            }
            publish(reading: true, stories: false)
            order.setFocus(shape.kept)
            order.rename(try #require(order.missions.first { $0.key == shape.kept }), to: "Totals")
            order.change(.move([Self.pr(4130)], to: .into(shape.kept), from: nil))
            if shape.kept == family { order.change(.setNext(Self.pr(4113), in: family, true)) }
            order.dismissLastChange()
            try expectKept(by: shape.kept)
            // Where you set one as next among the session's, and the mission it was in then, stay with the session's.
            func expectNextKept() {
                guard shape.kept == family else { return }
                #expect(order.changes[Self.pr(4113)]?.first == family && order.changes[Self.pr(4113)]?.from == family)
            }
            // Show Links read them all for User Story 5180: one mission, which has them.
            publish(reading: true, stories: true)
            #expect(order.missions.map(\.key) == [story], "\(shape.name)")
            try expectKept(by: story)
            expectNextKept()
            for _ in 1...2 {
                // Off: they wait on the story's mission. The one you put in it is on its own card, unseen.
                publish(reading: false, stories: false)
                let parts = order.missions.filter { $0.key != story }
                #expect(Set(parts.map(\.key)) == shape.parts, "\(shape.name)")
                #expect(parts.allSatisfy { !$0.isFocused && order.title(of: $0) != "Totals" }, "\(shape.name)")
                #expect(order.focus == story && OrderFocus.load(from: defaults) == story, "\(shape.name)")
                #expect(Array(MissionNames.load(from: defaults).entries.keys) == [story], "\(shape.name)")
                #expect(OrderChanges.load(from: defaults)[Self.pr(4130)]?.placement == .into(story), "\(shape.name)")
                let card = try #require(order.missions.first { $0.key == story }, "\(shape.name)")
                #expect(card.isMine && card.steps.map(\.ref) == [Self.pr(4130)], "\(shape.name)")
                #expect(card.steps.first?.notes.contains(.placementUnseen(story)) == true, "\(shape.name)")
                expectNextKept()
                if shape.kept == family {
                    #expect(order.missions.first { $0.key == family }?.steps.first { $0.ref == Self.pr(4113) }?.standing == .next)
                }
                // On: all back.
                publish(reading: true, stories: true)
                #expect(order.missions.map(\.key) == [story], "\(shape.name)")
                try expectKept(by: story)
                expectNextKept()
            }
        }
    }

    /// The mission one you didn't move was in, as you set it as next or put it after another there, goes on only to a
    /// mission that has it: a teammate's in a story's mission that goes back to your chain's as Show Links is turned off
    /// keeps the story's, and Undo Your Changes to This Mission in your chain doesn't take it back.
    @Test func theMissionYouChangedOneInGoesOnOnlyWhereItIs() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        let (chain, story) = (MissionKey.chain(Self.pr(4110)), MissionKey.story(Self.story))
        func publish(reading: Bool) {
            let read = { (task: Int) -> [OrderStory]? in reading ? [Self.task(task, rank: Double(task - 5180))] : nil }
            order.publish(.azureDevOps, pullRequests: [
                Self.stacked(4110, from: "robin/a", into: "main", read(5181)), Self.stacked(4111, from: "robin/b", into: "robin/a", read(5182)),
                Self.ado(4120, read(5184)), Self.ado(4121, read(5185)), Self.ado(4122, read(5186)),
            ], readsStories: reading)
        }
        publish(reading: true)
        #expect(order.missions.map(\.key) == [story])
        order.change(.setNext(Self.pr(4121), in: story, true))
        order.change(.mergeAfter(Self.pr(4122), Self.pr(4120), in: story, true))
        order.dismissLastChange()
        #expect(order.changes[Self.pr(4121)]?.from == story && order.changes[Self.pr(4122)]?.from == story)
        // Off: your chain is the one mission the story's went to, but neither of these is in it.
        publish(reading: false)
        #expect(order.missions.map(\.key) == [chain])
        #expect(order.changes[Self.pr(4121)]?.from == story && order.changes[Self.pr(4121)]?.first == story)
        #expect(order.changes[Self.pr(4122)]?.from == story && OrderChanges.load(from: defaults)[Self.pr(4122)]?.from == story)
        #expect(order.changes.undone(in: chain, missions: order.missions).isEmpty)
        // On again: the story's, as you left them.
        publish(reading: true)
        let mission = try #require(order.missions.first)
        #expect(mission.key == story && mission.steps.first { $0.ref == Self.pr(4121) }?.standing == .next)
    }

    /// A chain you split in two, moving one from its middle into a mission of your own, goes on as the part with the most
    /// of it: Focus and your name follow there, and back with Undo.
    @Test func focusAndYourNameFollowAChainYouSplitToItsLongerPart() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        order.publish(.azureDevOps, pullRequests: [
            Self.stacked(4110, from: "robin/a", into: "main", []), Self.stacked(4111, from: "robin/b", into: "robin/a", []),
            Self.stacked(4112, from: "robin/c", into: "robin/b", []), Self.stacked(4113, from: "robin/d", into: "robin/c", []),
        ], readsStories: true)
        let chain = try #require(order.missions.first)
        #expect(chain.key == .chain(Self.pr(4110)) && chain.steps.count == 4)
        order.setFocus(chain.key)
        order.rename(chain, to: "Totals")
        order.change(.setNext(Self.pr(4110), in: chain.key, true))
        let mine = MissionKey.mine(UUID(uuidString: "44444444-5555-4666-8777-888888888888")!)
        order.change(.move([Self.pr(4111)], to: .into(mine), from: chain.key))

        let rest = MissionKey.chain(Self.pr(4112))
        #expect(Set(order.missions.map(\.key)) == [rest, mine])
        #expect(order.focus == rest && OrderFocus.load(from: defaults) == rest)
        #expect(order.yourNames.name(for: rest) == "Totals" && order.yourNames.name(for: chain.key) == nil)
        // Where you set !4110 as next stays on the chain, whole, which !4110 isn't in a part of.
        #expect(order.changes[Self.pr(4110)]?.first == chain.key)
        // Undo: the chain is whole again, and they come back to it, with !4110 next.
        #expect(order.undo())
        #expect(order.missions.map(\.key) == [chain.key])
        let whole = try #require(order.missions.first)
        #expect(order.focus == chain.key && order.title(of: whole) == "Totals")
        #expect(whole.steps.first { $0.ref == Self.pr(4110) }?.standing == .next)
    }

    /// One you set as next in a story's mission, which a teammate's pull request is for too, waits on it as Show Links is
    /// turned off, saying so, rather than go to the part it's in, and is next there again once it's on.
    @Test func aNextYouSetInAStorysMissionWaitsWhileShowLinksIsOffAndHoldsAgain() throws {
        let clock = Clock()
        let order = Self.service(clock: clock)
        let (chain, story) = (MissionKey.chain(Self.pr(4110)), MissionKey.story(Self.story))
        func publish(reading: Bool) {
            order.publish(.azureDevOps, pullRequests: [
                Self.stacked(4110, from: "robin/a", into: "main", reading ? [Self.task(5181, rank: 1)] : nil),
                Self.stacked(4111, from: "robin/b", into: "robin/a", reading ? [Self.task(5182, rank: 2)] : nil),
                Self.ado(4120, reading ? [Self.task(5184, rank: 4)] : nil),
            ], readsStories: reading)
        }
        func next(in key: MissionKey) -> OrderStep? {
            order.missions.first { $0.key == key }?.steps.first { $0.ref == Self.pr(4110) }
        }
        publish(reading: true)
        #expect(order.missions.map(\.key) == [story])
        order.change(.setNext(Self.pr(4110), in: story, true))
        #expect(next(in: story)?.standing == .next)
        // Off: the chain shows apart from the teammate's, and !4110's next waits on the story's mission, saying so.
        publish(reading: false)
        #expect(order.missions.map(\.key) == [chain] && order.changes[Self.pr(4110)]?.first == story)
        #expect(next(in: chain)?.notes.contains(.nextUnseen(story)) == true)
        // On again: next in it again.
        publish(reading: true)
        #expect(order.missions.map(\.key) == [story] && next(in: story)?.standing == .next)
    }

    /// Where you set one as next in a chain stays on the chain as Show Links reads its pull requests as a story's, with a
    /// teammate's: in the story's mission it's next among the chain's and the one you put in the chain, and the teammate's
    /// don't wait for it. Off again, it's next in the chain.
    @Test func aNextYouSetInAChainIsNextAmongItsOwnInItsStorysMission() throws {
        let clock = Clock()
        let order = Self.service(clock: clock)
        let (chain, story) = (MissionKey.chain(Self.pr(4110)), MissionKey.story(Self.story))
        func publish(reading: Bool, stories: Bool) {
            let read = { (task: Int) -> [OrderStory]? in reading ? (stories ? [Self.task(task, rank: Double(task - 5180))] : []) : nil }
            order.publish(.azureDevOps, pullRequests: [
                Self.stacked(4110, from: "robin/a", into: "main", read(5181)), Self.stacked(4111, from: "robin/b", into: "robin/a", read(5182)),
                Self.ado(4130, reading ? [] : nil), Self.ado(4120, read(5184)), Self.ado(4121, read(5185)),
            ], readsStories: reading)
        }
        func step(_ number: Int, in key: MissionKey) -> OrderStep? {
            order.missions.first { $0.key == key }?.steps.first { $0.ref == Self.pr(number) }
        }
        publish(reading: true, stories: false)
        order.change(.move([Self.pr(4130)], to: .into(chain), from: nil))
        order.change(.setNext(Self.pr(4110), in: chain, true))
        order.dismissLastChange()
        #expect(step(4110, in: chain)?.standing == .next && step(4130, in: chain)?.notes.contains(.afterYourNext(Self.pr(4110))) == true)
        // Read as User Story 5180's, with a teammate's two: next among the chain's, which the teammate's don't wait for.
        publish(reading: true, stories: true)
        #expect(order.missions.map(\.key) == [story] && order.changes[Self.pr(4110)]?.first == chain)
        #expect(step(4110, in: story)?.standing == .next && step(4110, in: story)?.notes.contains(.nextElsewhere(chain)) == false)
        #expect(step(4130, in: story)?.notes.contains(.afterYourNext(Self.pr(4110))) == true)
        for theirs in [4120, 4121] {
            let row = step(theirs, in: story)
            #expect(row?.standing == .unordered && row?.prerequisites.isEmpty == true, "!\(theirs)")
        }
        // Off: next in the chain again.
        publish(reading: false, stories: false)
        #expect(order.missions.map(\.key) == [chain] && step(4110, in: chain)?.standing == .next)
    }

    /// Where you set one as next among a session's pull requests stays there as they go to their story's, once a teammate's
    /// of the same story is there too: theirs don't wait for it, and yours says so. Undo would set it there too.
    @Test func aNextYouSetAmongASessionsPullRequestsDoesntSpreadToTheirStorys() throws {
        let clock = Clock()
        let order = Self.service(clock: clock)
        let (family, story) = (MissionKey.family(Self.session), MissionKey.story(Self.story))
        order.publish(.copilot, sessions: [OrderSession(ref: Self.session, pullRequests: [Self.pr(4113), Self.pr(4105)])])
        order.publish(.azureDevOps, pullRequests: [4113, 4105, 4120, 4121].map { Self.ado($0, []) }, readsStories: true)
        #expect(order.missions.map(\.key) == [family])
        order.change(.setNext(Self.pr(4105), in: family, true))
        order.change(.setNext(Self.pr(4113), in: family, true))
        #expect(order.lastOrderChange?.touched[Self.pr(4105)].flatMap { $0 }?.first == family)

        // Show Links read them: the session's are for User Story 5180, and so are a teammate's !4120 and !4121.
        order.publish(.azureDevOps, pullRequests: [
            Self.ado(4113, [Self.task(5181, rank: 1)]), Self.ado(4105, [Self.task(5183, rank: 3)]),
            Self.ado(4120, [Self.task(5184, rank: 4)]), Self.ado(4121, [Self.task(5185, rank: 5)]),
        ], readsStories: true)
        let mission = try #require(order.missions.first)
        #expect(order.missions.map(\.key) == [story] && mission.steps.count == 4)
        #expect(order.changes[Self.pr(4113)]?.first == family)
        #expect(!mission.steps.contains { step in
            if case .waiting = step.standing { return true }
            return step.standing == .next
        })
        #expect(mission.steps.first { $0.ref == Self.pr(4113) }?.notes.contains(.nextElsewhere(family)) == true)
        #expect(order.lastOrderChange?.touched[Self.pr(4105)].flatMap { $0 }?.first == family)
    }

    /// One you set as next in a story's mission stays that mission's, never following out: while Show Links is off it waits,
    /// saying so, and a teammate's pull request for the story opened meanwhile waits for it once the story's mission shows
    /// again. So does one set among a session's pull requests that went whole to their story's mission: from then on it's
    /// that mission's, and a teammate's that joins it later waits for it too.
    @Test func aNextInAStorysMissionStaysItsThoughItsPullRequestsChange() throws {
        let (family, story) = (MissionKey.family(Self.session), MissionKey.story(Self.story))
        func make() -> PullRequestOrder {
            let order = Self.service(clock: Clock())
            order.publish(.copilot, sessions: [OrderSession(ref: Self.session, pullRequests: [Self.pr(4113), Self.pr(4105)])])
            return order
        }
        func publish(_ order: PullRequestOrder, reading: Bool, stories: Bool, teammate: Bool) {
            let read = { (task: Int) -> [OrderStory]? in reading ? (stories ? [Self.task(task, rank: Double(task - 5180))] : []) : nil }
            let theirs = teammate ? [Self.ado(4120, read(5184))] : []
            order.publish(.azureDevOps, pullRequests: [Self.ado(4113, read(5181)), Self.ado(4105, read(5183))] + theirs, readsStories: reading)
        }
        func step(_ order: PullRequestOrder, _ number: Int, in key: MissionKey) -> OrderStep? {
            order.missions.first { $0.key == key }?.steps.first { $0.ref == Self.pr(number) }
        }
        func expectTheStorys(_ order: PullRequestOrder) {
            #expect(order.missions.map(\.key) == [story] && step(order, 4105, in: story)?.standing == .next)
            for other in [4113, 4120] {
                #expect(step(order, other, in: story)?.notes.contains(.afterYourNext(Self.pr(4105))) == true, "!\(other)")
            }
        }

        // Set in the story's mission, which is the session's two.
        let set = make()
        publish(set, reading: true, stories: true, teammate: false)
        set.change(.setNext(Self.pr(4105), in: story, true))
        set.dismissLastChange()
        // Off: it waits on the story's mission, saying so, rather than go to the session's.
        publish(set, reading: false, stories: false, teammate: false)
        #expect(set.missions.map(\.key) == [family] && set.changes[Self.pr(4105)]?.first == story)
        #expect(step(set, 4105, in: family)?.notes.contains(.nextUnseen(story)) == true)
        // A teammate's for the story, opened while it's off; on again: the story's next, which theirs waits for.
        publish(set, reading: false, stories: false, teammate: true)
        publish(set, reading: true, stories: true, teammate: true)
        expectTheStorys(set)

        // Set among the session's, which go whole to their story's mission: it goes with them, then a teammate's joins.
        let went = make()
        publish(went, reading: true, stories: false, teammate: false)
        went.change(.setNext(Self.pr(4105), in: family, true))
        went.dismissLastChange()
        publish(went, reading: true, stories: true, teammate: false)
        #expect(went.changes[Self.pr(4105)]?.first == story)
        publish(went, reading: true, stories: true, teammate: true)
        expectTheStorys(went)
    }

    /// One you set as next in a story's mission follows its pull requests to another story's, as all their tasks move to
    /// it, and back as they return; but not into one where a teammate's is open, which would wait for it: there it waits,
    /// as the mission it was set in is gone, and holds again as that comes back.
    @Test func aNextInAStorysMissionFollowsItsTasksToAnotherStorysAndBack() {
        let other = ItemRef.workItem(organization: "contoso", id: 5190)
        let (story, others) = (MissionKey.story(Self.story), MissionKey.story(other))
        func task(_ id: Int, of story: ItemRef) -> [OrderStory] {
            [OrderStory(ref: story, type: "User Story", task: .workItem(organization: "contoso", id: id), rank: Double(id % 10))]
        }
        func publish(_ order: PullRequestOrder, to story: ItemRef, teammate: Bool = false) {
            let theirs = teammate ? [Self.ado(4120, task(5194, of: other))] : []
            order.publish(
                .azureDevOps, pullRequests: [Self.ado(4113, task(5181, of: story)), Self.ado(4105, task(5183, of: story))] + theirs,
                readsStories: true
            )
        }
        func step(_ order: PullRequestOrder, _ number: Int) -> OrderStep? {
            order.missions.lazy.compactMap { $0.steps.first { $0.ref == Self.pr(number) } }.first
        }
        func expectNext(_ order: PullRequestOrder, in key: MissionKey, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(order.missions.map(\.key) == [key], sourceLocation: sourceLocation)
            #expect(order.changes[Self.pr(4105)]?.first == key, sourceLocation: sourceLocation)
            #expect(step(order, 4105)?.standing == .next, sourceLocation: sourceLocation)
            #expect(step(order, 4113)?.notes.contains(.afterYourNext(Self.pr(4105))) == true, sourceLocation: sourceLocation)
        }

        let order = Self.service(clock: Clock())
        publish(order, to: Self.story)
        order.change(.setNext(Self.pr(4105), in: story, true))
        order.dismissLastChange()
        publish(order, to: other)
        expectNext(order, in: others)
        publish(order, to: Self.story)
        expectNext(order, in: story)

        publish(order, to: other, teammate: true)
        #expect(order.changes[Self.pr(4105)]?.first == story)
        #expect(step(order, 4105)?.notes.contains(.nextElsewhere(story)) == true)
        #expect(step(order, 4120)?.notes.contains(.afterYourNext(Self.pr(4105))) == false)
        publish(order, to: Self.story, teammate: true)
        #expect(order.missions.first { $0.key == story }?.steps.first { $0.ref == Self.pr(4105) }?.standing == .next)
    }

    /// Apple Intelligence's name of a mission of your own waits with it while Undo would bring it back, then goes with it.
    @Test func appleIntelligencesNameOfAMissionOfYourOwnGoesWithIt() async throws {
        let clock = Clock()
        let model = Model()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order, readsStories: false)
        let mine = MissionKey.mine(UUID(uuidString: "44444444-5555-4666-8777-888888888888")!)
        order.change(.move([Self.pr(4113), Self.pr(4105)], to: .into(mine), from: nil))
        let viewer = Viewer()
        Self.show([mine], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try #require(await Self.eventually { order.modelNames[mine] == "Faster checkout" })
        order.stopShowing(in: viewer)
        // Undone: it's gone, but Undo would bring it back, with that name.
        order.change(.undoMission(mine))
        #expect(!order.missions.contains { $0.key == mine } && order.modelNames[mine] == "Faster checkout")
        // No Undo left to bring it back: its name goes.
        order.dismissLastChange()
        order.timePassed()
        #expect(order.modelNames[mine] == nil)
    }

    /// A mission of your own keeps the name you give it, and Focus, while a change of yours puts a pull request in it, or
    /// Undo would: Undo brings it back as it was. Then they go.
    @Test func aMissionOfYourOwnKeepsItsNameAndFocusWhileUndoWouldBringItBack() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order, readsStories: false)
        let mine = MissionKey.mine(UUID(uuidString: "44444444-5555-4666-8777-888888888888")!)
        let both = [Self.pr(4113), Self.pr(4105)]
        order.change(.move(both, to: .into(mine), from: nil))
        order.rename(try #require(order.missions.first { $0.key == mine }), to: "Checkout bits")
        order.setFocus(mine)
        #expect(order.naming(of: try #require(order.missions.first { $0.key == mine })) == .you)

        // Its pull requests moved out: it's gone, but Undo brings it back, with its name and Focus.
        order.change(.move(both, to: .outside, from: mine))
        #expect(!order.missions.contains { $0.key == mine })
        #expect(order.yourNames.name(for: mine) == "Checkout bits" && order.focus == mine)
        #expect(order.undo())
        let back = try #require(order.missions.first { $0.key == mine })
        #expect(order.title(of: back) == "Checkout bits" && back.isFocused)
        #expect(MissionNames.load(from: defaults).name(for: mine) == "Checkout bits")

        // Undone with no Undo left to bring it back: its name and Focus go.
        order.change(.undoMission(mine))
        #expect(order.yourNames.name(for: mine) == "Checkout bits")
        order.dismissLastChange()
        order.timePassed()
        #expect(order.yourNames.name(for: mine) == nil && defaults.object(forKey: MissionNames.defaultsKey) == nil)
        #expect(order.focus == nil && OrderFocus.load(from: defaults) == nil)
    }

    /// Turning a source off forgets all that was kept of its missions before its pull requests leave them, so that nothing
    /// forgotten is saved back: your changes, Focus, the name you gave it, and Undo.
    @Test func turningASourceOffForgetsItsChangesFocusAndNamesBeforeItsMissionsGo() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        let order = Self.service(defaults, clock: clock)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        order.setFocus(mission.key)
        order.rename(mission, to: "Coupons and speed")
        order.change(.setNext(Self.pr(4105), in: mission.key, true))
        #expect(order.lastChange != nil && !order.changes.isEmpty)

        order.forget(.azureDevOps)
        #expect(order.changes.isEmpty && order.focus == nil && order.yourNames.entries.isEmpty && order.lastChange == nil)
        #expect(defaults.object(forKey: OrderChanges.defaultsKey) == nil && defaults.object(forKey: MissionNames.defaultsKey) == nil)
        #expect(OrderFocus.load(from: defaults) == nil)
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
        #expect(order.yourNames.entries.isEmpty && defaults.object(forKey: MissionNames.defaultsKey) == nil)

        Self.tell(order)
        order.rename(try #require(order.missions.first), to: "Coupons and speed")
        order.forgetAll()
        #expect(order.yourNames.entries.isEmpty && defaults.object(forKey: MissionNames.defaultsKey) == nil)
    }

    /// Turning a source off forgets its missions' names for good, though another's last hour unseen ends as it goes, which
    /// saves the names again.
    @Test func aSourceTurnedOffForgetsItsNamesForGoodThoughAnothersHourEndsMeanwhile() throws {
        let clock = Clock()
        let defaults = MemoryDefaults()
        let gitHub = MissionKey.chain(.gitHubPullRequest(repository: "octo/storefront", number: 212))
        var saved = MissionNames()
        _ = saved.rename(gitHub, to: "Storefront polish", briefBarsName: "x")
        saved.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        // GitHub is on, without that mission now: the time it isn't seen counts against its name.
        order.publish(.github)
        Self.tell(order)
        let mission = try #require(order.missions.first)
        order.rename(mission, to: "Coupons and speed")
        clock.advance(3_600 + 1)
        order.forget(.azureDevOps)
        #expect(order.yourNames.name(for: mission.key) == nil)
        let kept = MissionNames.load(from: defaults)
        #expect(kept.name(for: mission.key) == nil && kept.name(for: gitHub) == "Storefront polish")
        #expect((kept.entries[gitHub]?.unseen ?? 0) > 3_600)
        // After a restart too.
        #expect(Self.service(defaults, clock: clock).yourNames.name(for: mission.key) == nil)
    }

    static let planID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let otherPlanID = UUID(uuidString: "11111111-2222-4333-8444-666666666666")!

    /// The preferences, with an order a session told of Azure DevOps' !4113, then !4105.
    static func ordered(_ defaults: MemoryDefaults = MemoryDefaults(), id: UUID = planID) throws -> MemoryDefaults {
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [.init(link: link(4113)), .init(link: link(4105), after: ["4113"])]),
            now: Date(timeIntervalSince1970: 1_791_900_000), newID: id
        )
        orders.save(to: defaults)
        return defaults
    }

    /// Where two orders go round, the stage names the other by Apple Intelligence's name as soon as it comes, as its
    /// mission's header does; and why a card didn't move stays, as its stage didn't change.
    @Test func theStageNamesAnOrderThatGoesRoundByAppleIntelligencesNameAsSoonAsItComes() async throws {
        let clock = Clock()
        let model = Model()
        let defaults = try Self.ordered()
        // Another order puts them the other way round: !4113 after !4105.
        let link = { (number: Int) in "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)" }
        var orders = DeclaredOrders.load(from: defaults)
        try orders.apply(
            OrderRequest(entries: [.init(link: link(4105)), .init(link: link(4113), after: ["4105"])]),
            now: Date(timeIntervalSince1970: 1_791_900_001), newID: Self.otherPlanID
        )
        orders.save(to: defaults)
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        order.publish(
            .azureDevOps, pullRequests: [Self.ado(4113, nil), Self.ado(4105, nil)],
            items: [Self.item(Self.pr(4113), "Speed up the checkout page"), Self.item(Self.pr(4105), "Prototype one-click checkout")],
            stages: [Self.pr(4113): StageFacts(role: .author, isReady: true), Self.pr(4105): StageFacts(role: .author, isReady: true)],
            account: "robin@contoso.com"
        )
        let key = MissionKey.plan(Self.planID)
        let briefBars = try #require(order.names.title(key))
        let says = { (name: String) -> StageWhy in .orderHolds("‘\(name)’ puts !4105 after it: check the order") }
        #expect(order.stage(of: Self.pr(4113))?.why == says(briefBars))
        // ⌘← in the lane of the order its stage names, which doesn't hold it, says where it waits, as the Board keeps it
        // while the details cover it (`OrderBoardView.say`).
        #expect(StageOrder.holders(of: Self.pr(4113), in: order.missions) == [.plan(Self.otherPlanID)])
        let moves = BoardMoves(board: order.board(kinds: [.pullRequest], lanes: .missions), missions: order.missions, order: order, missionChanges: true)
        guard case .refused(let why)? = moves.key(Self.pr(4113), in: .mission(key), forward: false)?.move else {
            Issue.record("⌘← in the other order's lane set it as next")
            return
        }
        #expect(why.hasPrefix("It waits in ‘"))
        order.stageRefusal = StageRefusal(ref: Self.pr(4113), why: why, reading: try #require(order.stage(of: Self.pr(4113))))

        let viewer = Viewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { order.modelNames[key] == "Faster checkout" })
        #expect(order.stage(of: Self.pr(4113))?.why == says("Faster checkout"))
        #expect(order.stageRefusal(of: Self.pr(4113)) == why)
    }

    /// Apple Intelligence's name for an order's mission goes with the order, however it goes: forgotten, or left with no
    /// pull request as Azure DevOps is turned off; and an answer under way for it then doesn't bring it back.
    @Test func anOrdersNameFromAppleIntelligenceGoesWithTheOrder() async throws {
        let clock = Clock()
        let model = Model()
        let defaults = try Self.ordered()
        let order = Self.service(defaults, clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = MissionKey.plan(Self.planID)
        #expect(order.missions.map(\.key) == [key])
        let viewer = Viewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { order.modelNames[key] == "Faster checkout" })

        // Forget This Order.
        order.forget(order: Self.planID)
        #expect(order.modelNames[key] == nil)

        // Another order of them, named as Azure DevOps is turned off.
        _ = try Self.ordered(defaults, id: Self.otherPlanID)
        order.reloadOrders()
        let other = MissionKey.plan(Self.otherPlanID)
        #expect(order.missions.map(\.key) == [other])
        model.holds = true
        Self.show([other], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 2 })
        order.forget(.azureDevOps)
        #expect(DeclaredOrders.load(from: defaults).plan(Self.otherPlanID) == nil)
        model.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(order.modelNames[other] == nil)
        order.stopShowing(in: viewer)
    }

    /// A view that isn't on a window's page names nothing, though a window shows its own page on screen: nothing says that
    /// view is on screen. On a page that's on screen, the same missions are named.
    @Test func aViewOffAWindowsPageNamesNothing() async throws {
        let clock = Clock()
        let model = Model()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = Viewer()
        order.setVisible(true, for: Self.page)
        order.showing([key], in: viewer)
        #expect(order.onScreen.isEmpty)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.prompts.isEmpty)

        order.showing([key], in: viewer, on: Self.page)
        #expect(order.onScreen == [key])
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 1 })
        order.stopShowing(in: viewer)
    }

    /// A window's page that's minimized, hidden or covered names nothing, though what it shows changes, until its source
    /// says it's on screen again.
    @Test func aCoveredOrMinimizedPageNamesNothingUntilItShowsAgain() async throws {
        let clock = Clock()
        let model = Model()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let viewer = Viewer()
        let page = PullRequestOrder.page(.azureDevOpsPullRequests, window: "1")
        order.showing([key], in: viewer, on: page)
        #expect(order.onScreen.isEmpty)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.prompts.isEmpty)

        order.setVisible(true, for: page)
        #expect(order.onScreen == [key])
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        #expect(await Self.eventually { model.prompts.count == 1 })

        order.setVisible(false, for: page)
        #expect(order.onScreen.isEmpty)
        Self.tell(order, firstTitle: "Make checkout faster")
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.prompts.count == 1)
        order.stopShowing(in: viewer)
    }

    /// A session that tells BriefBar it's working on one of a mission's pull requests helps name it, with its title; once
    /// it stops, the mission is asked about again, without it.
    @Test func aSessionWorkingOnItsPullRequestHelpsNameIt() async throws {
        let clock = Clock()
        let model = Model()
        let order = Self.service(clock: clock)
        order.namer = model.namer(clock: clock)
        Self.tell(order)
        let key = try #require(order.missions.first?.key)
        let working = ItemRef.session("00000000-0000-4000-8000-000000000005")!
        let titled = [Self.item(working, "Make checkout faster")]
        order.publish(.copilot, items: titled, working: [working: [Self.pr(4113)]])
        let viewer = Viewer()
        Self.show([key], in: viewer, by: order)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try #require(await Self.eventually { model.prompts.count == 1 })
        #expect(model.prompts[0].contains("Copilot sessions:\n- “Make checkout faster”"))

        order.publish(.copilot, items: titled)
        clock.advance(MissionNamer.settleFor)
        order.namer?.next()
        try #require(await Self.eventually { model.prompts.count == 2 })
        #expect(!model.prompts[1].contains("Make checkout faster"))
        order.stopShowing(in: viewer)
    }

    /// By Mission says only the missions in its scroll view's sight are on screen: one out of sight isn't named until it
    /// comes into it.
    /// Three stacks of two pull requests, each a mission, as Azure DevOps tells them.
    static func threeStacks(_ order: PullRequestOrder) -> [OrderPullRequest] {
        var pullRequests: [OrderPullRequest] = []
        for stack in 0..<3 {
            for (index, number) in [4100 + 10 * stack, 4101 + 10 * stack].enumerated() {
                pullRequests.append(OrderPullRequest(
                    ref: Self.pr(number), repository: "contoso/p/shop-web", sourceBranch: "robin/\(stack)-\(index)",
                    targetBranch: index == 0 ? "main" : "robin/\(stack)-0", author: "robin",
                    createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number))
                ))
            }
        }
        order.publish(.azureDevOps, pullRequests: pullRequests)
        return pullRequests
    }

    /// By Mission on the tests' window's page, in a scroll view this high: in List, each of its pull requests' rows a third
    /// of it at least; on the Board, with these lanes, and no cards, as no pull request has a stage.
    static func byMission(
        _ order: PullRequestOrder, listing pullRequests: [OrderPullRequest], view: OrderView = .list, lanes: BoardLanes? = nil,
        height: CGFloat, services: AppServices
    ) -> AnyView {
        let card: ((BoardCard) -> BoardCardContent?)? = view == .board ? { _ in nil } : nil
        let board = view == .board ? order.board(kinds: [.pullRequest], lanes: lanes) : nil
        return AnyView(
            ScrollView {
                MissionsBody(
                    view: view, ordering: order, kinds: [.pullRequest], elsewhere: "GitHub", openElsewhere: nil,
                    listed: pullRequests.map(\.ref), row: { step, _ in AnyView(Text(step.ref.id).frame(height: 240)) },
                    place: { _ in nil }, isSelected: { _ in false }, select: { _ in false }, rest: { _ in AnyView(EmptyView()) },
                    board: board, card: card
                )
            }
            .environment(\.shownSection, .azureDevOpsPullRequests)
            .environment(\.shownWindow, "1")
            .environmentObject(services)
            .frame(width: 600, height: height)
        )
    }

    /// A window off screen's, as the tests' page has it: drawn, but never in front of anything.
    static func window(showing host: NSView, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 600, height: height), styleMask: .borderless, backing: .buffered,
            defer: false
        )
        window.contentView = host
        return window
    }

    @Test func onlyTheMissionsInSightAreOnScreen() async throws {
        _ = NSApplication.shared
        let order = Self.service(clock: Clock())
        let pullRequests = Self.threeStacks(order)
        let missions = order.missions
        #expect(missions.count == 3)
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        order.setVisible(true, for: Self.page)
        let host = NSHostingView(rootView: Self.byMission(order, listing: pullRequests, height: 300, services: services))
        let window = Self.window(showing: host, height: 300)
        defer { window.contentView = nil }
        try await until("the first mission is on screen") { order.onScreen == [missions[0].key] }

        // A scroll view tall enough for them all.
        host.rootView = Self.byMission(order, listing: pullRequests, height: 2_400, services: services)
        try await until("every mission is on screen") { Set(order.onScreen) == Set(missions.map(\.key)) }
    }

    /// On the Board, a mission's lane is in sight as the page scrolls up and down, though the Board scrolls sideways.
    @Test func onTheBoardOnlyTheLanesInThePagesSightAreOnScreen() async throws {
        _ = NSApplication.shared
        let order = Self.service(clock: Clock())
        let pullRequests = Self.threeStacks(order)
        let missions = order.missions
        #expect(missions.count == 3)
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        order.setVisible(true, for: Self.page)
        let board = { (height: CGFloat) in
            Self.byMission(order, listing: pullRequests, view: .board, lanes: .missions, height: height, services: services)
        }
        let host = NSHostingView(rootView: board(150))
        let window = Self.window(showing: host, height: 150)
        defer { window.contentView = nil }
        try await until("the first mission's lane is on screen") { order.onScreen.first == missions[0].key }
        try await Task.sleep(for: .milliseconds(100))
        #expect(order.onScreen.first == missions[0].key)
        #expect(!order.onScreen.contains(missions[2].key))

        host.rootView = board(2_400)
        try await until("every mission's lane is on screen") { Set(order.onScreen) == Set(missions.map(\.key)) }
    }

    /// The missions one view had in sight aren't another's: on the Board with a lane for every card, none is on screen.
    @Test func whatOneViewHadInSightAnotherDoesntShow() async throws {
        _ = NSApplication.shared
        let order = Self.service(clock: Clock())
        let pullRequests = Self.threeStacks(order)
        let missions = order.missions
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        order.setVisible(true, for: Self.page)
        let host = NSHostingView(rootView: Self.byMission(order, listing: pullRequests, height: 2_400, services: services))
        let window = Self.window(showing: host, height: 2_400)
        defer { window.contentView = nil }
        try await until("every mission is on screen") { Set(order.onScreen) == Set(missions.map(\.key)) }

        host.rootView = Self.byMission(order, listing: pullRequests, view: .board, lanes: BoardLanes.none, height: 2_400, services: services)
        try await until("no mission is on screen") { order.onScreen.isEmpty }

        host.rootView = Self.byMission(order, listing: pullRequests, height: 2_400, services: services)
        try await until("every mission is on screen again") { Set(order.onScreen) == Set(missions.map(\.key)) }
    }

    /// Apple Intelligence's answer is the mission's name alone, by guided generation: its schema is made as BriefBar runs,
    /// without `@Generable`'s macro, and the name is read from what the model generates.
    @Test func theAnswerIsTheNameAloneByGuidedGeneration() throws {
        let shape = try #require(MissionNamer.answerShape)
        #expect(try shape.text(ofJSON: #"{"name": "Checkout coupons"}"#) == "Checkout coupons")
        #expect(throws: (any Error).self) { try shape.text(ofJSON: #"{"title": "Checkout coupons"}"#) }
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
