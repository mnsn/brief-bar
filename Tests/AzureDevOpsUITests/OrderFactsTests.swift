import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

@MainActor
@Suite(.opensNothing) struct OrderFactsTests {
    private static let me = DemoData.me

    private static func pullRequest(
        _ number: Int, from source: String, into target: String = "main", status: PullRequest.Status = .active, draft: Bool = false,
        author: Person = me
    ) -> PullRequest {
        PullRequest(
            key: PRKey("Contoso", number), title: "Pull request \(number)", status: status, author: author,
            createdAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(number)), projectId: "7A0C4E1D", projectName: "Storefront",
            repositoryId: "Repository-Shop", repositoryName: "shop-web", sourceBranch: source, targetBranch: target, isDraft: draft
        )
    }

    private static func link(_ ref: ItemRef) -> String {
        switch ref.kind {
        case .gitHubPullRequest: return "https://github.com/\(ref.scope)/pull/\(ref.id)"
        default: return "https://dev.azure.com/\(ref.scope)/Storefront/_git/shop-web/pullrequest/\(ref.id)"
        }
    }

    /// Pull Request Order, on, with an order of !4085, then !4093 after it.
    private static func order() throws -> (PullRequestOrder, MemoryDefaults) {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        var orders = DeclaredOrders()
        try orders.apply(OrderRequest(entries: [
            .init(link: link(.pullRequest(organization: "contoso", number: 4085))),
            .init(link: link(.pullRequest(organization: "contoso", number: 4093)), after: ["4085"]),
        ]))
        orders.save(to: defaults)
        return (PullRequestOrder(defaults: defaults, isDemo: false), defaults)
    }

    private static func demoStore() async -> PRStore {
        let store = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await store.loadOnce()
        return store
    }

    @Test func aPullRequestIsWhereItsSourceShowsItWithWhatAnOrderNeeds() throws {
        let seen = try #require(PullRequestOrderFacts.pullRequest(Self.pullRequest(4103, from: "robin/totals"), attention: .needsYou))
        #expect(seen == OrderPullRequest(
            ref: .pullRequest(organization: "contoso", number: 4103), repository: "contoso/7a0c4e1d/repository-shop",
            sourceBranch: "robin/totals", targetBranch: "main", author: Self.me.id, state: .open, attention: .needsYou,
            createdAt: Date(timeIntervalSince1970: 1_791_004_103)
        ))
        // Azure DevOps doesn't say, as BriefBar reads it, whether it's a fork's, or which branch is the default.
        #expect(seen.isFork == nil && seen.defaultBranch == nil && seen.stack == nil)
        let states: [(PullRequest.Status, Bool, PullRequestState?)] = [
            (.active, true, .draft), (.completed, false, .merged), (.abandoned, false, .closed), (.other, false, nil),
        ]
        for (status, draft, state) in states {
            let pullRequest = Self.pullRequest(4103, from: "robin/totals", status: status, draft: draft)
            #expect(PullRequestOrderFacts.pullRequest(pullRequest, attention: nil)?.state == state, "\(status)")
        }
    }

    /// What each means for you is what its group counts in the menu bar: To Review only while it counts there.
    @Test func whatEachMeansForYouIsWhatItsGroupCounts() async throws {
        let store = await Self.demoStore()
        func attention(_ number: Int, showToReview: Bool) -> ItemState?? {
            PullRequestOrderFacts.pullRequests(store.records, items: store.items, showToReview: showToReview)
                .first { $0.ref == .pullRequest(organization: "contoso", number: number) }.map(\.attention)
        }
        #expect(attention(4102, showToReview: false) == .some(.needsYou))
        #expect(attention(4091, showToReview: false) == .some(.done))
        #expect(attention(4071, showToReview: false) == .some(nil))
        #expect(attention(4071, showToReview: true) == .some(.needsYou))
        #expect(attention(4085, showToReview: false) == .some(nil))
        let merged = PullRequestOrderFacts.pullRequests(store.records, items: store.items, showToReview: false)
            .first { $0.ref == .pullRequest(organization: "contoso", number: 4085) }
        #expect(merged?.state == .merged)
    }

    /// While Pull Request Order is on, the list's pull requests go to it, with what BriefBar sees in Done; a pull request an
    /// order waits for is next once it merged, and stays merged after Done drops it.
    @Test func itTellsPullRequestOrderWhatTheListShows() async throws {
        let store = await Self.demoStore()
        let (order, defaults) = try Self.order()
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)

        facts.publish()

        let mission = try #require(order.missions.first)
        #expect(mission.steps.map(\.status) == [.merged, .open])
        #expect(mission.steps.last?.standing == .next)
        #expect(OrderEvidence.load(from: defaults).records[.pullRequest(organization: "contoso", number: 4085)]?.outcome == .merged)
        let accountPage = try #require(order.describe(.pullRequest(organization: "contoso", number: 4093)))
        #expect(accountPage.label == "!4093" && accountPage.title == "Add dark mode to the account page")
        #expect(accountPage.status == PRGroup.ready.title && accountPage.open != nil && accountPage.show != nil)
        // Its details show only on a window's Pull Requests page.
        #expect(accountPage.show?() == false)

        facts.stop()

        #expect(order.describe(.pullRequest(organization: "contoso", number: 4093)) == nil)
        #expect(order.missions.first?.steps.map(\.status) == [.merged, .unknown(.sourceOff)])
    }

    /// Till the list was read the first time, Pull Request Order can't tell what a mission is made of: none of its pull
    /// requests are listed yet.
    @Test func whatAMissionIsMadeOfWaitsTillTheListWasRead() async throws {
        let store = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        let (order, _) = try Self.order()
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)

        facts.publish()
        let waiting = try #require(order.missions.first)
        let unread = try #require(order.splitQuestion(for: waiting))
        #expect(unread.makeup == nil)

        await store.loadOnce()
        facts.publish()
        let listed = try #require(order.missions.first)
        let read = try #require(order.splitQuestion(for: listed))
        #expect(read.makeup != nil)
    }

    /// Off, it tells nothing.
    @Test func whileOffItTellsNothing() async throws {
        let store = await Self.demoStore()
        let defaults = MemoryDefaults()
        let order = PullRequestOrder(defaults: defaults, isDemo: false)
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)

        facts.publish()

        #expect(order.missions.isEmpty && order.describe(.pullRequest(organization: "contoso", number: 4093)) == nil)
        #expect(defaults.object(forKey: OrderEvidence.defaultsKey) == nil)
    }

    /// A pull request that targets another's branch goes after it, only when the same person opened both.
    @Test func aStackIsOnlyOnePersonsBranches() throws {
        let sam = Person(id: "6f1c1a52-0000-4000-8000-00000000b001", name: "Sam Rivera")
        let records = [
            Self.pullRequest(4103, from: "robin/totals"), Self.pullRequest(4104, from: "robin/totals-ui", into: "robin/totals"),
            Self.pullRequest(4105, from: "robin/totals-docs", into: "robin/totals", author: sam),
        ].map { PRRecord(pullRequest: $0, role: .author, me: Self.me.id) }
        let facts = OrderFacts(pullRequests: PullRequestOrderFacts.pullRequests(records, items: [], showToReview: false))

        let missions = OrderBoard.missions(facts: facts, orders: DeclaredOrders(), evidence: OrderEvidence())

        #expect(missions.map(\.key) == [.chain(.pullRequest(organization: "contoso", number: 4103))])
        #expect(missions.first?.steps.map(\.ref.id) == ["4103", "4104"])
    }

    /// Waits for what the main queue delivers, as the facts hear the list change.
    private static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A refresh can change what the list read of a pull request without its row, such as when it's retargeted: the order
    /// hears every refresh.
    @Test func everyRefreshTellsTheOrderAgain() async throws {
        let store = await Self.demoStore()
        let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true)
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)
        facts.start()
        defer { facts.stop() }
        #expect(await Self.eventually { order.describe(DemoPullRequestOrder.retry) != nil })
        order.withdraw(.azureDevOps)
        #expect(order.describe(DemoPullRequestOrder.retry) == nil)

        store.refreshed.send()

        #expect(await Self.eventually { order.describe(DemoPullRequestOrder.retry) != nil })
    }

    /// The demo's story outside the sprint (§7.4): its three pull requests, for its tasks, are its mission, in the tasks'
    /// order, with no order known, and the made-up name Apple Intelligence would give it; with Show Links off, there are no
    /// stories, and they're in no mission.
    @Test func theDemosStoryIsAMissionWithAMadeUpName() async throws {
        let store = await Self.demoStore()
        let settings = AppSettings(defaults: MemoryDefaults())
        let sprint = SprintStore(settings: settings, mode: .demo, client: store.client)
        await sprint.loadOnce()
        let copilot = CopilotTasksStore(settings: settings, mode: .demo, notifier: nil)
        func facts(showLinks: Bool) async -> (PullRequestOrder, PullRequestOrderFacts, WorkLinksStore) {
            let links = Links(defaults: MemoryDefaults(), isDemo: showLinks)
            let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true, now: { store.now })
            let workLinks = WorkLinksStore(
                links: links, stories: ItemStories(links: links), store: store, sprint: sprint, copilot: copilot, settings: settings,
                order: order
            )
            await workLinks.loadOnce()
            let facts = PullRequestOrderFacts(order: order, store: store, settings: settings, details: nil, workLinks: workLinks)
            return (order, facts.loadOnce(), workLinks)
        }

        let (order, held, workLinks) = await facts(showLinks: true)
        let key = MissionKey.story(DemoPullRequestOrder.checkoutRedesign)
        let mission = try #require(order.missions.first { $0.key == key })
        #expect(mission.steps.map(\.ref.id) == ["4113", "4088", "4105"])
        #expect(mission.steps.allSatisfy { $0.standing == .unordered })
        #expect(OrderText.story(of: mission, title: order.title(of: mission)) == "User Story 5180")
        #expect(order.title(of: mission) == "Faster checkout" && order.naming(of: mission) == .appleIntelligence)
        #expect(order.name(of: DemoPullRequestOrder.checkoutRedesign) == "Checkout redesign")
        #expect(order.describe(.workItem(organization: "contoso", id: 5181))?.title == "Speed up the checkout page")
        // Each pull request goes with all its work items, for its mission's name.
        let seen = PullRequestOrderFacts.pullRequests(store.records, items: store.items, showToReview: false, stories: workLinks.storiesRead)
        #expect(seen.first { $0.ref.id == "4091" }?.workItems == [5110, 5112].map { .workItem(organization: "contoso", id: $0) })
        // The orders keep their own: their pull requests aren't a story's mission's.
        #expect(order.missions.first { $0.key == DemoPullRequestOrder.focus }?.steps.count == 5)
        _ = held

        let (withoutLinks, _, _) = await facts(showLinks: false)
        #expect(!withoutLinks.missions.contains { $0.isStory })
        #expect(!withoutLinks.missions.contains { $0.contains(.pullRequest(organization: "contoso", number: 4113)) })
    }

    /// By Mission on a window's Pull Requests page is named only while the window shows that page on screen, as it tells
    /// the source; the Sprint's page, or a popover, says nothing of it.
    @Test func byMissionIsNamedOnlyWhileAWindowShowsItsPageOnScreen() {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = AzureDevOpsSource(services: services, summarizer: .withoutModel)
        let order = services.pullRequestOrder
        let viewer = NSObject()
        let key = MissionKey.story(DemoPullRequestOrder.checkoutRedesign)
        order.showing([key], in: viewer, on: PullRequestOrder.page(.azureDevOpsPullRequests, window: "7"))
        #expect(order.onScreen.isEmpty)
        source.sectionVisibilityChanged(.azureDevOpsPullRequests, isShowing: true, by: SectionViewer(.window, id: "7"))
        #expect(order.onScreen == [key])
        source.sectionVisibilityChanged(.azureDevOpsSprint, isShowing: false, by: SectionViewer(.window, id: "7"))
        source.sectionVisibilityChanged(.azureDevOpsPullRequests, isShowing: false, by: SectionViewer(.popover, id: "7"))
        #expect(order.onScreen == [key])
        source.sectionVisibilityChanged(.azureDevOpsPullRequests, isShowing: false, by: SectionViewer(.window, id: "7"))
        #expect(order.onScreen.isEmpty)
        withExtendedLifetime(viewer) {}
    }

    /// The demo's orders are ones an agent could tell: BriefBar would keep them as they are.
    @Test func theDemosOrdersAreOnesAnAgentCouldTell() throws {
        let demos = DemoPullRequestOrder.orders(now: Date()).plans
        #expect(demos.map(\.declaredBy) == [DemoPullRequestOrder.payments, DemoPullRequestOrder.coordinator])
        for demo in demos {
            var checked = DeclaredOrders()
            let told = try checked.apply(OrderRequest(session: demo.declaredBy?.id, entries: demo.entries.map { entry in
                let review: OrderRequest.Review? = switch entry.review {
                case nil: nil
                case .now?: .now
                case .after(let refs, let reason)?: .after(refs.map(Self.link), reason: reason.rawValue)
                }
                return OrderRequest.Entry(link: Self.link(entry.ref), after: entry.after.map(Self.link), review: review)
            }))
            #expect(told.entries == demo.entries && told.declaredBy == demo.declaredBy)
        }
    }

    /// In the demo, it's on, with the demo's order: the account page's next, and the emails' can't be seen.
    @Test func theDemoHasItsOrder() async throws {
        let store = await Self.demoStore()
        let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true)
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)
        order.tellDemo(DemoPullRequestOrder.orders(now: store.now))

        facts.publish()

        let mission = try #require(order.missions.first { $0.key == .plan(DemoPullRequestOrder.id) })
        let steps = Dictionary(uniqueKeysWithValues: mission.steps.map { ($0.ref, $0) })
        #expect(steps[DemoPullRequestOrder.accountPage]?.standing == .next)
        #expect(steps[DemoPullRequestOrder.emails]?.status == .unknown(.notListed))
        #expect(steps[DemoPullRequestOrder.checkoutPage]?.review == .after([DemoPullRequestOrder.accountPage], .buildsOnChanges))
        #expect(mission.sessions.first == DemoPullRequestOrder.coordinator)
    }

    /// The payments' order, which you focus on: the first merged yesterday, the retry is next, and the coupon rounding,
    /// ready to complete before it, says so in orange.
    @Test func theDemosPaymentsOrderIsFocusedWithOneMerged() async throws {
        let store = await Self.demoStore()
        let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true, now: { store.now })
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)
        order.tellDemo(
            DemoPullRequestOrder.orders(now: store.now), evidence: DemoPullRequestOrder.evidence(now: store.now),
            focus: DemoPullRequestOrder.focus
        )

        facts.publish()

        let mission = try #require(order.missions.first)
        #expect(mission.key == DemoPullRequestOrder.focus && mission.isFocused)
        #expect(OrderText.progress(mission) == "1 of 5 merged")
        let steps = Dictionary(uniqueKeysWithValues: mission.steps.map { ($0.ref, $0) })
        #expect(steps[DemoPullRequestOrder.retryPolicy]?.status == .merged)
        #expect(steps[DemoPullRequestOrder.retry]?.standing == .next)
        let rounding = try #require(steps[DemoPullRequestOrder.couponRounding])
        #expect(rounding.standing == .waiting(open: [DemoPullRequestOrder.retry], unknown: []))
        let ready = try #require(store.items.first { $0.key.linkRef == DemoPullRequestOrder.couponRounding })
        #expect(ready.group == .ready)
        #expect(OrderText.tone(of: rounding, isReady: ready.group == .ready) == .warning)
        #expect(OrderText.capsule(rounding) == "After !4102")
        #expect(steps[DemoPullRequestOrder.legacyCoupons]?.review == .after([DemoPullRequestOrder.couponRounding], .sameCode))
        #expect(OrderBoard.step(for: DemoPullRequestOrder.retry, in: order.missions)?.mission.key == DemoPullRequestOrder.focus)
    }

    // MARK: Stages

    private static let sam = Person(id: "5A1B0000-0000-4000-8000-0000000000AA", name: "Sam Rivera")
    private static let priya = Person(id: "5A1B0000-0000-4000-8000-0000000000BB", name: "Priya Shah")

    /// A pull request's stage's facts, as the lists read it, with its details' checks when given.
    private static func stageFacts(
        _ number: Int, role: PRRole = .author, author: Person = me, reviewers: [Reviewer] = [], checks: [Check]? = nil,
        merge: String? = "succeeded"
    ) -> StageFacts? {
        let pr = PullRequest(
            key: PRKey("Contoso", number), title: "Pull request \(number)", author: author,
            createdAt: Date(timeIntervalSince1970: 1_791_000_000), projectId: "7A0C4E1D", projectName: "Storefront",
            repositoryId: "Repository-Shop", repositoryName: "shop-web", mergeStatus: merge, reviewers: reviewers,
            sourceCommit: "c\(number)"
        )
        let details = checks.map { PRDetails(fetchedAt: Date(timeIntervalSince1970: 1_791_000_100), fingerprint: pr.fingerprint, checks: $0) }
        return PullRequestOrderFacts.stageFacts(PRRecord(pullRequest: pr, role: role, details: details, me: me.id), item: nil, tasks: [])
    }

    /// Asked to review someone else's, you're asked until you vote or decline; wanting changes, you wait for theirs.
    @Test func aReviewerWhoHasntVotedIsAsked() throws {
        func facts(_ vote: Vote, declined: Bool = false) throws -> StageFacts {
            try #require(Self.stageFacts(
                4110, role: .reviewer, author: Self.sam,
                reviewers: [Reviewer(person: Self.me, vote: vote, hasDeclined: declined), Reviewer(person: Self.priya, vote: .approved)]
            ))
        }
        let asked = try facts(.none)
        #expect(asked.asksYou == "Sam asked you")
        // Its votes are your own: Priya's approval isn't among them.
        #expect(asked.role == .reviewer && asked.othersVoted && asked.votes == "0")
        #expect(try facts(.approved).asksYou == nil)
        #expect(try facts(.approved).votes == "10")
        #expect(try facts(.none, declined: true).asksYou == nil)
        #expect(try facts(.none, declined: true).votes == "0d")
        let wanting = try facts(.waitingForAuthor)
        #expect(wanting.asksYou == nil && wanting.youWantChanges == "Waiting for Sam's changes")
        #expect(wanting.votes == "-5")
    }

    /// Yours says what holds it up as What's Left does: what failed, who wants changes, the reviewer it requires before how
    /// many approvals, or that it's ready; with nobody else asked, it waits for nobody.
    @Test func yoursSaysWhatHoldsItUp() throws {
        let build = Check(name: "shop-web CI", kind: .build, state: .passed)
        let approvals = Check(name: "Minimum number of reviewers", kind: .reviewers, state: .pending, minimumApprovers: 2)

        let failing = try #require(Self.stageFacts(4088, reviewers: [Reviewer(person: Self.priya, vote: .approved)],
                                                   checks: [Check(name: "shop-web CI", kind: .build, state: .failed)]))
        #expect(failing.failure == "Build failed" && !failing.isReady)

        let conflicts = try #require(Self.stageFacts(4079, reviewers: [Reviewer(person: Self.sam, vote: .none)], checks: [build], merge: "conflicts"))
        #expect(conflicts.failure == "Merge conflicts")

        let changes = try #require(Self.stageFacts(4060, reviewers: [Reviewer(person: Self.priya, vote: .waitingForAuthor)], checks: [build]))
        #expect(changes.changesWanted == "Priya wants changes" && changes.failure == nil)

        let waiting = try #require(Self.stageFacts(
            4102, reviewers: [Reviewer(person: Self.sam, vote: .none, isRequired: true), Reviewer(person: Self.priya, vote: .approved)],
            checks: [build, approvals]
        ))
        #expect(waiting.waitingFor == "Waiting on Sam" && !waiting.isReady)
        // Only the votes cast: Sam, asked but not voting yet, isn't among them.
        #expect(waiting.votes == "10" && waiting.commit == "c4102")

        let ready = try #require(Self.stageFacts(
            4091, reviewers: [Reviewer(person: Self.priya, vote: .approved), Reviewer(person: Self.sam, vote: .approved)],
            checks: [build, Check(name: "Minimum number of reviewers", kind: .reviewers, state: .passed, minimumApprovers: 2)]
        ))
        #expect(ready.isReady && ready.failure == nil && ready.changesWanted == nil)

        let alone = try #require(Self.stageFacts(4105, checks: [build]))
        #expect(alone.waitingFor == nil && !alone.othersVoted && alone.votes == "")
    }

    /// One you watch keeps what you set on it, as what you've seen of it is kept; one only sent to you doesn't.
    @Test func oneYouWatchIsWatchedRatherThanSentToYou() {
        let watched = PRKey("contoso", 4113)
        let records = [4113, 4114].map { number in
            PRRecord(pullRequest: Self.pullRequest(number, from: "dana/\(number)", author: Self.sam), role: .linked, me: Self.me.id)
        }
        let facts = PullRequestOrderFacts.stages(records, items: [], tasks: [], watched: [watched])
        #expect(facts[watched.linkRef]?.role == .watching)
        #expect(facts[PRKey("contoso", 4114).linkRef]?.role == .sentToYou)
    }

    /// A task BriefBar sent to Copilot is a session on its pull request: at work while it gets ready or works, then done or
    /// stopped, since its status changed, called "Copilot" as its row is.
    @Test func aTaskSentToCopilotIsASessionOnIt() throws {
        let started = Date(timeIntervalSince1970: 1_791_000_000)
        func session(_ phase: RunPhase) throws -> StageSession {
            let entry = CopilotTaskEntry(
                id: "3d2c1b0a-9f8e-4d7c-8b6a-5f4e3d2c1b0a", workItem: nil, onPullRequest: nil, action: .fixBuild,
                options: CopilotModel.standard, startedAt: started, status: RunStatus(phase: phase, since: started.addingTimeInterval(60)),
                pullRequest: nil, run: nil
            )
            return try #require(PullRequestOrderFacts.session(entry))
        }
        #expect(try session(.preparing).activity == .working)
        #expect(try session(.working).activity == .working)
        #expect(try session(.finished).activity == .finished)
        #expect(try session(.failed).activity == .stopped)
        #expect(try session(.stopped).activity == .stopped)
        let working = try session(.working)
        #expect(working.name == "Copilot" && working.since == started.addingTimeInterval(60))
        #expect(working.ref == ItemRef.session("3d2c1b0a-9f8e-4d7c-8b6a-5f4e3d2c1b0a"))
    }

    /// The demo's pull requests each have the stage the mockup shows for its kind: what a session asks, a review asked or
    /// sent in Teams, a teammate's review with the reviewer it requires, what failed, what waits for its order, your
    /// changes, and the one-click checkout's prototype you set for a teammate's review two hours ago, with nobody asked.
    @Test func theDemosPullRequestsEachHaveTheirStage() async throws {
        let store = await Self.demoStore()
        let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true, now: { store.now })
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)
        order.tellDemo(
            DemoPullRequestOrder.orders(now: store.now), evidence: DemoPullRequestOrder.evidence(now: store.now),
            focus: DemoPullRequestOrder.focus, changes: DemoPullRequestOrder.changes(now: store.now)
        )

        facts.publish()

        /// "Your review: Alex asked you".
        func stage(_ number: Int) -> String? {
            order.stage(of: .pullRequest(organization: DemoData.organization, number: number)).map { reading in
                reading.stage.title + ": " + StageText.why(reading, name: { _ in nil })
            }
        }
        #expect(stage(4097) == "Your review: Alex asked you")
        #expect(stage(4110) == "Your review: Jordan asked you")
        #expect(stage(4071) == "Your review: Chen asked you")
        #expect(stage(4113) == "Your review: Dana sent it in Teams")
        #expect(stage(4102) == "Teammate's review: Waiting on Sam")
        #expect(stage(4088) == "In progress: Build failed")
        #expect(stage(4079) == "In progress: Merge conflicts")
        #expect(stage(4060) == "In progress: Waiting for Sam's changes")
        #expect(stage(4091) == "Waits for another PR: After !4102")
        #expect(stage(4085) == "Merged: Merged")
        #expect(stage(4108) == nil)
        let prototype = try #require(order.stage(of: DemoPullRequestOrder.oneClickCheckout))
        #expect(prototype.stage == .teammateReview && prototype.why == .findReviewer)
        #expect(prototype.mark?.at == store.now.addingTimeInterval(-2 * 3_600))
    }

    // MARK: From Copilot's review

    /// Before its details are read, or where they couldn't be, yours fails as the list says its merge does.
    @Test func yoursFailsAsTheListSaysItsMergeDoesBeforeItsDetailsAreRead() throws {
        #expect(try #require(Self.stageFacts(4079, merge: "conflicts")).failure == "Merge conflicts")
        #expect(try #require(Self.stageFacts(4080, merge: "failure")).failure == "Merge failed")
        #expect(try #require(Self.stageFacts(4081, merge: "rejectedByPolicy")).failure == "Merge rejected")
        #expect(try #require(Self.stageFacts(4082)).failure == nil)
    }

    /// With no review that holds it up, what's left of yours is its own work: In progress, with What's Left's first item. A
    /// reviewer policy of another name counts as a review while it's pending.
    @Test func withNoReviewHoldingItUpWhatsLeftIsYoursToDo() throws {
        let running = Check(name: "shop-web CI", kind: .build, state: .running)
        let sam = [Reviewer(person: Self.sam, vote: .none)]

        let notApplying = try #require(Self.stageFacts(
            4099, reviewers: sam, checks: [running, Check(name: "Minimum number of reviewers", kind: .reviewers, state: .notApplicable)]
        ))
        #expect(notApplying.leftAfterReviews == "Build running")

        let passed = try #require(Self.stageFacts(4100, reviewers: sam, checks: [running, Check(name: "Code owners", kind: .reviewers, state: .passed)]))
        #expect(passed.leftAfterReviews == "Build running")

        let pending = try #require(Self.stageFacts(4101, reviewers: sam, checks: [running, Check(name: "Code owners", kind: .reviewers, state: .pending)]))
        #expect(pending.leftAfterReviews == nil)
        #expect(pending.waitingFor == "Code owners")

        // Before its details are read, nothing's said to be left.
        #expect(try #require(Self.stageFacts(4102, reviewers: sam)).leftAfterReviews == nil)
    }

    /// Every task sent to Copilot on it counts, not only the newest: an older one still at work keeps it in progress.
    @Test func everyTaskOnItCountsNotOnlyTheNewest() throws {
        let started = Date(timeIntervalSince1970: 1_791_000_000)
        let record = PRRecord(pullRequest: Self.pullRequest(4088, from: "robin/estimates"), role: .author, me: Self.me.id)
        let tasks = (0..<4).map { index in
            CopilotTaskEntry(
                id: "3d2c1b0a-9f8e-4d7c-8b6a-5f4e3d2c1b0\(index)", workItem: nil,
                onPullRequest: PullRequestReference(
                    organization: "Contoso", project: "Storefront", repository: "shop-web", id: 4088, sourceBranch: "robin/estimates"
                ),
                action: .fixBuild, options: CopilotModel.standard, startedAt: started.addingTimeInterval(Double(-index * 60)),
                status: RunStatus(phase: index == 3 ? .working : .finished, since: started), pullRequest: nil, run: nil
            )
        }
        let facts = try #require(PullRequestOrderFacts.stages([record], items: [], tasks: tasks)[record.id.linkRef])
        #expect(facts.sessions.count == 4)
        #expect(facts.sessions.contains { $0.activity == .working })
        let reading = StageRules.reading(facts: facts, sessions: facts.sessions, marks: [], order: .free)
        #expect(reading?.stage == .inProgress)
    }

    /// Only one a list shows is listed: one the lists still read but don't show, such as one sent to you in a chat once you
    /// answered it, isn't.
    @Test func onlyOneAListShowsIsListed() throws {
        let now = Date(timeIntervalSince1970: 1_791_100_000)
        let shown = PRRecord(pullRequest: Self.pullRequest(4093, from: "robin/dark-mode"), role: .author, me: Self.me.id)
        let read = PRRecord(pullRequest: Self.pullRequest(4113, from: "jordan/checkout", author: Self.sam), role: .linked, me: Self.me.id)
        let row = try #require(PRClassifier.snapshot(for: shown, seenCutoff: .distantPast, dismissedCutoff: .distantPast, now: now))
        #expect(PRClassifier.snapshot(for: read, seenCutoff: .distantPast, dismissedCutoff: .distantPast, now: now) == nil)

        let facts = PullRequestOrderFacts.stages([shown, read], items: [row], tasks: [])
        #expect(facts[shown.id.linkRef]?.isListed == true)
        #expect(facts[read.id.linkRef]?.isListed == false)
    }

    /// Someone else's that Needs You brings back is yours to review again, whatever your vote: new commits since you
    /// voted, or someone sending it to you in a chat.
    @Test func newCommitsOrAChatBringSomeoneElsesBackToYourReview() throws {
        let order = Self.onOrder()
        let ref = PRKey("Contoso", 4088).linkRef
        let voted = Date(timeIntervalSince1970: 1_791_000_200)
        func record(_ yours: Vote, pushed: Bool = false, sent: Bool = false) -> PRRecord {
            var record = Self.record(4088, role: .reviewer, author: Self.priya, reviewers: [Reviewer(person: Self.me, vote: yours)])
            record.details?.activity = [Activity(threadId: 1, kind: .vote, at: voted, actor: Self.me, vote: yours)]
            if pushed {
                record.details?.activity.append(Activity(
                    threadId: 2, kind: .push, at: voted.addingTimeInterval(600), actor: Self.priya, commitCount: 2
                ))
            }
            if sent {
                record.chatLinks = [ChatLink(
                    link: PullRequestLink(organization: "Contoso", project: "Storefront", repository: "shop-web", number: 4088),
                    app: "com.microsoft.teams2", sender: Self.sam.name, sentAt: voted.addingTimeInterval(900), notificationKey: "sam-4088"
                )]
            }
            return record
        }
        // Approved, with nothing since: nothing on it is yours.
        Self.tell(order, [record(.approved)])
        #expect(order.stage(of: ref) == nil)

        // Priya pushes since: it's yours to review again.
        Self.tell(order, [record(.approved, pushed: true)])
        let again = try #require(order.stage(of: ref))
        #expect(again.stage == .yourReview)
        #expect(StageText.why(again, name: { _ in nil }) == "New commits by Priya")

        // Having wanted changes, her new commits are yours to review, rather than still waited for.
        Self.tell(order, [record(.waitingForAuthor, pushed: true)])
        #expect(order.stage(of: ref)?.stage == .yourReview)

        // Sam sends it to you in Teams after you approved it.
        Self.tell(order, [record(.approved, sent: true)])
        let sent = try #require(order.stage(of: ref))
        #expect(sent.stage == .yourReview)
        #expect(StageText.why(sent, name: { _ in nil }) == "Sam sent it in Teams")
    }

    // MARK: From the coordinator's review

    /// A pull request as the lists read it, with its details' checks when given.
    private static func record(
        _ number: Int, role: PRRole = .author, author: Person = me, reviewers: [Reviewer] = [], checks: [Check]? = [Check(
            name: "shop-web CI", kind: .build, state: .passed
        )]
    ) -> PRRecord {
        let pr = PullRequest(
            key: PRKey("Contoso", number), title: "Pull request \(number)", author: author,
            createdAt: Date(timeIntervalSince1970: 1_791_000_000), projectId: "7A0C4E1D", projectName: "Storefront",
            repositoryId: "Repository-Shop", repositoryName: "shop-web", reviewers: reviewers, sourceCommit: "c\(number)"
        )
        let details = checks.map { PRDetails(fetchedAt: Date(timeIntervalSince1970: 1_791_000_100), fingerprint: pr.fingerprint, checks: $0) }
        return PRRecord(pullRequest: pr, role: role, details: details, me: me.id)
    }

    /// Tells Pull Request Order what the lists read of these, each one listed, as the app does.
    private static func tell(_ order: PullRequestOrder, _ records: [PRRecord], tasks: [CopilotTaskEntry] = []) {
        let now = Date(timeIntervalSince1970: 1_791_100_000)
        let rows = records.compactMap { PRClassifier.snapshot(for: $0, seenCutoff: .distantPast, dismissedCutoff: .distantPast, now: now) }
        #expect(rows.count == records.count)
        order.publish(.azureDevOps, stages: PullRequestOrderFacts.stages(records, items: rows, tasks: tasks), account: "robin@contoso.com")
    }

    private static func onOrder() -> PullRequestOrder {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        return PullRequestOrder(defaults: defaults, isDemo: false, now: { Date(timeIntervalSince1970: 1_791_100_000) })
    }

    private static func task(on number: Int, _ action: PullRequestAction, _ phase: RunPhase) -> CopilotTaskEntry {
        let started = Date(timeIntervalSince1970: 1_791_050_000)
        return CopilotTaskEntry(
            id: "4e3d2c1b-0a9f-4e8d-9c7b-6a5f4e3d2c1\(number % 10)", workItem: nil,
            onPullRequest: PullRequestReference(
                organization: "Contoso", project: "Storefront", repository: "shop-web", id: number, sourceBranch: "feature"
            ),
            action: action, options: CopilotModel.standard, startedAt: started, status: RunStatus(phase: phase, since: started),
            pullRequest: nil, run: nil
        )
    }

    /// Asking someone to review yours after Finished My Review keeps it: only a vote they cast ends it.
    @Test func askingSomeoneToReviewYoursKeepsFinishedMyReview() throws {
        let order = Self.onOrder()
        let ref = PRKey("Contoso", 4093).linkRef
        let done = [Self.task(on: 4093, .fixBuild, .finished)]
        Self.tell(order, [Self.record(4093)], tasks: done)
        #expect(order.stage(of: ref).map { StageText.why($0, name: { _ in nil }) } == "Copilot finished")
        #expect(order.finishedReview(ref) == .done)
        #expect(order.stage(of: ref)?.why == .findReviewer)

        // You add Priya, as Add Reviewers in Azure DevOps lets you: she hasn't voted.
        Self.tell(order, [Self.record(4093, reviewers: [Reviewer(person: Self.priya, vote: .none, isRequired: true)])], tasks: done)
        let asked = try #require(order.stage(of: ref))
        #expect(asked.stage == .teammateReview && asked.isSetByYou)
        #expect(StageText.why(asked, name: { _ in nil }) == "Waiting on Priya")

        // Her vote ends it.
        Self.tell(order, [Self.record(4093, reviewers: [Reviewer(person: Self.priya, vote: .approved, isRequired: true)])], tasks: done)
        #expect(order.stage(of: ref)?.isSetByYou == false)
    }

    /// On someone else's, your own vote ends Finished My Review, and co-reviewers' votes don't.
    @Test func yourOwnVoteEndsFinishedMyReviewOnSomeoneElses() throws {
        let order = Self.onOrder()
        let ref = PRKey("Contoso", 4088).linkRef
        func reviewers(_ yours: Vote, sam: Vote) -> [Reviewer] {
            [Reviewer(person: Self.me, vote: yours), Reviewer(person: Self.sam, vote: sam)]
        }
        Self.tell(order, [Self.record(4088, role: .reviewer, author: Self.priya, reviewers: reviewers(.none, sam: .none))])
        #expect(order.stage(of: ref)?.stage == .yourReview)
        #expect(order.finishedReview(ref) == .done)
        #expect(order.stage(of: ref)?.isOnBoard == false)

        // Sam votes: it's still off your board.
        Self.tell(order, [Self.record(4088, role: .reviewer, author: Self.priya, reviewers: reviewers(.none, sam: .approved))])
        #expect(order.stage(of: ref)?.isOnBoard == false)
        #expect(order.stage(of: ref)?.isSetByYou == true)

        // You vote Wait for Author: it waits for Priya's changes.
        Self.tell(order, [Self.record(4088, role: .reviewer, author: Self.priya, reviewers: reviewers(.waitingForAuthor, sam: .approved))])
        let waiting = try #require(order.stage(of: ref))
        #expect(waiting.stage == .inProgress && !waiting.isSetByYou)
        #expect(StageText.why(waiting, name: { _ in nil }) == "Waiting for Priya's changes")

        // Approving instead leaves nothing for you on it.
        let other = PRKey("Contoso", 4089).linkRef
        Self.tell(order, [Self.record(4089, role: .reviewer, author: Self.priya, reviewers: reviewers(.none, sam: .none))])
        order.finishedReview(other)
        Self.tell(order, [Self.record(4089, role: .reviewer, author: Self.priya, reviewers: reviewers(.approved, sam: .none))])
        #expect(order.stage(of: other) == nil)
    }

    /// Pre-review is a review: it writes nothing.
    @Test func aPreReviewTaskIsAReview() throws {
        #expect(try #require(PullRequestOrderFacts.session(Self.task(on: 4088, .review, .working))).isReview)
        #expect(try #require(PullRequestOrderFacts.session(Self.task(on: 4088, .fixBuild, .working))).isReview == false)
        // While it runs, someone else's stays yours to review.
        let order = Self.onOrder()
        let record = Self.record(4088, role: .reviewer, author: Self.priya, reviewers: [Reviewer(person: Self.me, vote: .none)])
        Self.tell(order, [record], tasks: [Self.task(on: 4088, .review, .working)])
        let reading = try #require(order.stage(of: record.id.linkRef))
        #expect(reading.stage == .yourReview)
        #expect(StageText.why(reading, name: { _ in nil }) == "Copilot is pre-reviewing it")
    }

    /// A Board card says what failed once: where its stage's words say it after their reason, "Copilot is writing it ·
    /// build failed", it has no ✕ of its own, and VoiceOver doesn't hear it twice.
    @Test func aBoardCardSaysAFailureOnce() throws {
        let order = Self.onOrder()
        let failing = Self.record(4088, checks: [Check(name: "shop-web CI", kind: .build, state: .failed)])
        let now = Date(timeIntervalSince1970: 1_791_100_000)
        let item = try #require(PRClassifier.snapshot(for: failing, seenCutoff: .distantPast, dismissedCutoff: .distantPast, now: now))
        #expect(item.group == .failing)
        Self.tell(order, [failing], tasks: [Self.task(on: 4088, .fixBuild, .working)])
        let reading = try #require(order.stage(of: failing.id.linkRef))
        #expect(StageText.why(reading, name: { _ in nil }) == "Copilot is writing it · build failed")
        #expect(PullRequestBoardCard.flags(item, reading: reading).isEmpty)
        #expect(PullRequestBoardCard.details(item, reading: reading, order: nil, ordering: order) == ["shop-web"])
    }

    // MARK: The Board

    /// Someone else's says whose it is, by first name, for why it can't go to a teammate's review; yours names nobody.
    @Test func someoneElsesSaysWhoseItIs() throws {
        #expect(try #require(Self.stageFacts(4110, role: .reviewer, author: Self.sam)).author == "Sam")
        #expect(try #require(Self.stageFacts(4088)).author == nil)
        let sent = PRRecord(pullRequest: Self.pullRequest(4113, from: "dana/4113", author: Self.priya), role: .linked, me: Self.me.id)
        #expect(PullRequestOrderFacts.stages([sent], items: [], tasks: [])[sent.id.linkRef]?.author == "Priya")
    }

    /// The Board counts only the cards it draws, those the list shows: one that merged that the lists read but don't show
    /// isn't counted in Merged.
    @Test func theBoardCountsOnlyWhatTheListShows() throws {
        let (order, _) = try Self.order()
        let records = [(4085, PullRequest.Status.completed), (4086, .completed), (4093, .active)].map { number, status in
            PRRecord(pullRequest: Self.pullRequest(number, from: "robin/\(number)", status: status), role: .author, me: Self.me.id)
        }
        let now = Date(timeIntervalSince1970: 1_791_010_000)
        let rows = try records.filter { $0.pullRequest.key.number != 4086 }.map { record in
            try #require(PRClassifier.snapshot(for: record, seenCutoff: .distantPast, dismissedCutoff: .distantPast, now: now))
        }
        order.publish(
            .azureDevOps, pullRequests: records.compactMap { PullRequestOrderFacts.pullRequest($0.pullRequest, attention: nil) },
            stages: PullRequestOrderFacts.stages(records, items: rows, tasks: []), account: "robin@contoso.com"
        )

        let board = order.board(kinds: [.pullRequest])
        let listed = Set(rows.map(\.key.linkRef))
        #expect(board.counts[.merged] == 1)
        #expect(board.refs == listed)
        #expect(board.counts.values.reduce(0, +) == board.refs.count)
        let cards = board.lanes.flatMap { lane in lane.columns.values.flatMap { $0 } }
        #expect(Set(cards.map(\.ref)) == listed)
        #expect(Set(cards.filter { $0.stage == .merged }.map(\.ref)) == [.pullRequest(organization: "contoso", number: 4085)])
    }

    /// In the demo too, every card the Board counts is one its page draws.
    @Test func theDemosBoardCountsWhatItDraws() async throws {
        let store = await Self.demoStore()
        let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true, now: { store.now })
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)
        order.tellDemo(
            DemoPullRequestOrder.orders(now: store.now), evidence: DemoPullRequestOrder.evidence(now: store.now),
            focus: DemoPullRequestOrder.focus
        )
        facts.publish()

        let board = order.board(kinds: [.pullRequest])
        #expect(board.counts[.merged] ?? 0 > 0)
        #expect(board.refs.isSubset(of: Set(store.items.map(\.key.linkRef))))
        #expect(board.counts.values.reduce(0, +) == board.refs.count)
    }

    /// On a Board card in Can merge or Waits, the stage's words say where its order puts it: it has no capsule, and VoiceOver
    /// doesn't hear its order again. One with no order known still shows the quiet ✎ of a change of yours, and VoiceOver
    /// hears what it says.
    @Test func aBoardCardKeepsWhatAChangeOfYoursSaysWhereItHasNoOrder() throws {
        let order = Self.onOrder()
        let now = Date(timeIntervalSince1970: 1_791_100_000)
        let item = try #require(
            PRClassifier.snapshot(for: Self.record(4130), seenCutoff: .distantPast, dismissedCutoff: .distantPast, now: now)
        )
        let ref = item.key.linkRef
        let reading = StageReading(stage: .canMerge, why: .ready(autoComplete: false))
        let moved = OrderRowContext(
            step: OrderStep(ref: ref, status: .open, standing: .unordered, notes: [.moved(from: nil, now)]), isReady: true
        )
        let next = OrderRowContext(step: OrderStep(ref: ref, status: .open, standing: .next), isReady: true)
        let said = try #require(moved.sentence)
        #expect(PullRequestBoardCard.details(item, reading: reading, order: moved, ordering: order) == [said, "shop-web"])
        #expect(PullRequestBoardCard.details(item, reading: reading, order: next, ordering: order) == ["shop-web"])

        let copilot = CopilotTasksStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo, notifier: nil)
        func height(_ context: OrderRowContext?) -> CGFloat {
            let card = PullRequestBoardCard(
                item: item, card: BoardCard(ref: ref, reading: reading), order: context, ordering: order, now: now
            )
            return NSHostingView(rootView: card.frame(width: 220).environmentObject(copilot)).fittingSize.height
        }
        #expect(height(moved) > height(nil) + 8)
        #expect(abs(height(next) - height(nil)) < 0.5)
    }

    /// The page hands the Board its Set as Next to Merge, which a drop from Waits onto Can merge and ⌘← do: it sets it as
    /// next in that mission, as Mission ▸ does, and it can merge. VoiceOver hears its Undo is in its mission's lane, or, with
    /// a lane for every card, which shows no mission's, at the top, as the card's Mission menu says too.
    @Test func theBoardSetsItAsNextInItsMissionAndSaysWhereUndoIs() throws {
        let (order, _) = try Self.order()
        let first = ItemRef.pullRequest(organization: "contoso", number: 4085)
        let later = ItemRef.pullRequest(organization: "contoso", number: 4093)
        order.publish(
            .azureDevOps,
            pullRequests: [first, later].map { ref in
                OrderPullRequest(
                    ref: ref, repository: "contoso/7a0c4e1d/repository-shop", sourceBranch: "robin/\(ref.id)", targetBranch: "main",
                    author: Self.me.id, createdAt: Date(timeIntervalSince1970: 1_791_000_000)
                )
            },
            stages: [first: StageFacts(role: .author), later: StageFacts(role: .author, isReady: true)],
            account: "robin@contoso.com"
        )
        let mission = try #require(order.missions.first { $0.contains(later) }?.key)
        #expect(order.stage(of: later)?.stage == .waits)
        PullRequestsByMission.setAsNext(order)(later, mission, .byMission)
        #expect(order.lastOrderChange?.mission == mission && order.lastOrderChange?.said == "You set !4093 as next to merge")
        #expect(order.stage(of: later)?.stage == .canMerge)

        #expect(MissionMenuContext.UndoPlace.onBoard(.missions) == .byMission)
        #expect(MissionMenuContext.UndoPlace.onBoard(BoardLanes.none) == .top)
        let edit = OrderEdit.setNext(later, in: mission, true)
        #expect(MissionMenuContext(order: order, mission: mission, undo: .byMission).undoPlace(of: edit, in: mission) == "in its mission")
        #expect(MissionMenuContext(order: order, mission: mission, undo: .top).undoPlace(of: edit, in: mission) == "at the top of the list")
    }

    /// A Board card in Can merge says, to VoiceOver too, that you set it as next to merge, and in Waits that an order went
    /// against your change, as its row does: the stage's words say neither. One whose order alone places it says nothing
    /// more there.
    @Test func aBoardCardKeepsWhatAChangeOfYoursSaysOnCanMergeAndWaits() throws {
        let order = Self.onOrder()
        let now = Date(timeIntervalSince1970: 1_791_100_000)
        let item = try #require(
            PRClassifier.snapshot(for: Self.record(4130), seenCutoff: .distantPast, dismissedCutoff: .distantPast, now: now)
        )
        let ref = item.key.linkRef
        let other = ItemRef.pullRequest(organization: "contoso", number: 4131)
        let canMerge = StageReading(stage: .canMerge, why: .ready(autoComplete: false))
        let yours = OrderRowContext(
            step: OrderStep(ref: ref, status: .open, standing: .next, notes: [.yourNext(now)], isYours: true, isChangedByYou: true),
            isReady: true
        )
        let set = try #require(yours.sentence)
        #expect(PullRequestBoardCard.details(item, reading: canMerge, order: yours, ordering: order) == [set, "shop-web"])

        let waits = StageReading(stage: .waits, why: .waitsFor([other], words: "After !4131"))
        let override = OrderOverride(by: nil, at: now, now: .after([other]), yours: .next)
        let overridden = OrderRowContext(
            step: OrderStep(ref: ref, status: .open, standing: .waiting(open: [other], unknown: []), notes: [.orderChangedIt(override)]),
            isReady: true
        )
        let against = try #require(overridden.sentence)
        #expect(against.contains("after you'd set it as next"))
        #expect(PullRequestBoardCard.details(item, reading: waits, order: overridden, ordering: order) == [against, "shop-web"])
        let theirs = OrderRowContext(step: OrderStep(ref: ref, status: .open, standing: .waiting(open: [other], unknown: [])), isReady: true)
        #expect(PullRequestBoardCard.details(item, reading: waits, order: theirs, ordering: order) == ["shop-web"])
    }

    /// Your made-up changes in the demo hold over its orders: the order status rename goes first, the retry waits for it, and
    /// the build agents' upgrade and the slow query log are a mission of your own.
    @Test func theDemosChangesHoldOverItsOrders() async throws {
        let store = await Self.demoStore()
        let order = PullRequestOrder(defaults: MemoryDefaults(), isDemo: true, now: { store.now })
        let facts = PullRequestOrderFacts(order: order, store: store, settings: AppSettings(defaults: MemoryDefaults()), details: nil)
        order.tellDemo(
            DemoPullRequestOrder.orders(now: store.now), evidence: DemoPullRequestOrder.evidence(now: store.now),
            focus: DemoPullRequestOrder.focus, changes: DemoPullRequestOrder.changes(now: store.now)
        )

        facts.publish()

        let payments = try #require(order.missions.first { $0.key == DemoPullRequestOrder.focus })
        let steps = Dictionary(uniqueKeysWithValues: payments.steps.map { ($0.ref, $0) })
        let rename = try #require(steps[DemoPullRequestOrder.statusRename])
        #expect(rename.standing == .next && rename.isYours && rename.isChangedByYou)
        let retry = try #require(steps[DemoPullRequestOrder.retry])
        #expect(retry.standing == .waiting(open: [DemoPullRequestOrder.statusRename], unknown: []) && retry.isYours)
        #expect(OrderText.kind(of: payments) == "changed by you")
        let yours = try #require(order.missions.first { $0.key == .mine(DemoPullRequestOrder.mineID) })
        #expect(yours.steps.map(\.ref) == [DemoPullRequestOrder.buildAgents, DemoPullRequestOrder.slowQueries])
        #expect(yours.steps.map(\.standing) == [.next, .waiting(open: [DemoPullRequestOrder.buildAgents], unknown: [])])
        #expect(OrderText.kind(of: yours) == "Your mission")
    }

    /// The pull requests listed only because someone sent them in a chat, which you don't watch.
    @Test func itSaysWhichArentYoursButSentInAChat() async throws {
        let store = await Self.demoStore()
        let sent = PullRequestOrderFacts.sentInChats(store.records, watched: [])
        let linked = store.records.filter { $0.role == .linked }.map(\.id)
        #expect(!sent.isEmpty && sent == Set(linked.map(\.linkRef)))
        #expect(PullRequestOrderFacts.sentInChats(store.records, watched: Set(linked)).isEmpty)
    }
}
