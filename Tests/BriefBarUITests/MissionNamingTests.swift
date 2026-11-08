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

    func namer(clock: Clock) -> MissionNamer {
        MissionNamer(
            unavailability: { [unowned self] in unavailability },
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
        order.showing([mission.key], in: viewer)
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
        order.showing([key], in: viewer)
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
        order.showing([key], in: viewer)
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
        #expect(order.names.name(for: mission.key) == nil)
        let kept = MissionNames.load(from: defaults)
        #expect(kept.name(for: mission.key) == nil && kept.name(for: gitHub) == "Storefront polish")
        #expect((kept.entries[gitHub]?.unseen ?? 0) > 3_600)
        // After a restart too.
        #expect(Self.service(defaults, clock: clock).names.name(for: mission.key) == nil)
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
        order.showing([key], in: viewer)
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
        order.showing([other], in: viewer)
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
        order.showing([key], in: viewer)
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
    @Test func onlyTheMissionsInSightAreOnScreen() async throws {
        _ = NSApplication.shared
        let order = Self.service(clock: Clock())
        // Three stacks of two pull requests, each a mission.
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
        let missions = order.missions
        #expect(missions.count == 3)
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        // By Mission in a scroll view this high, each of its pull requests' rows a third of it at least.
        func page(height: CGFloat) -> AnyView {
            AnyView(
                ScrollView {
                    MissionsBody(
                        view: .list, ordering: order, kinds: [.pullRequest], elsewhere: "GitHub", openElsewhere: nil,
                        listed: pullRequests.map(\.ref), row: { step, _ in AnyView(Text(step.ref.id).frame(height: 240)) },
                        place: { _ in nil }, isSelected: { _ in false }, select: { _ in false }, rest: { _ in AnyView(EmptyView()) }
                    )
                }
                .environmentObject(services)
                .frame(width: 600, height: height)
            )
        }
        let host = NSHostingView(rootView: page(height: 300))
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 600, height: 300), styleMask: .borderless, backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        try await until("the first mission is on screen") { order.onScreen == [missions[0].key] }

        // A scroll view tall enough for them all.
        host.rootView = page(height: 2_400)
        try await until("every mission is on screen") { Set(order.onScreen) == Set(missions.map(\.key)) }
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
