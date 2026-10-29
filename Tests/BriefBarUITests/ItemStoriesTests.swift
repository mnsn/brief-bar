import BriefBarCore
import Foundation
import SwiftUI
import Testing
@testable import BriefBarUI

/// What the sources tell about their things beyond their rows, for the details: only when asked, only while Show Links is
/// on, put together across sources, and kept in memory only while it's current.
@MainActor
@Suite struct ItemStoriesTests {
    private let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4091)
    private let session = ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01")!

    /// Counts what a teller was asked.
    private final class Asked {
        var refs: [ItemRef] = []
    }

    private func item(_ ref: ItemRef, state: ItemState? = nil, status: String? = nil, date: Date? = nil) -> LinkedItem {
        LinkedItem(ref: ref, label: ref.id, title: "Round coupons", symbol: "circle", color: .secondary, state: state, status: status, date: date)
    }

    private func hub(on: Bool = true) -> (Links, ItemStories) {
        let links = Links(defaults: MemoryDefaults(), isDemo: false)
        links.setOn(on)
        return (links, ItemStories(links: links))
    }

    @Test func itTellsNothingWhileShowLinksIsOff() async {
        let (links, stories) = hub(on: false)
        let asked = Asked()
        stories.register(.azureDevOps, kinds: [.pullRequest]) { ref in
            asked.refs.append(ref)
            return ItemStory(sentence: "Waiting for reviewers")
        }
        await stories.tell([item(pullRequest)])
        #expect(asked.refs.isEmpty)
        #expect(stories.story(for: pullRequest) == nil)
        links.setOn(true)
        await stories.tell([item(pullRequest)])
        #expect(asked.refs == [pullRequest])
        #expect(stories.story(for: pullRequest)?.sentence == "Waiting for reviewers")
        // Turning it off forgets what was told.
        links.setOn(false)
        #expect(stories.story(for: pullRequest) == nil)
        links.setOn(true)
        #expect(!stories.hasTold(pullRequest))
    }

    @Test func eachSourceTellsWhatItKnowsInTheSourcesOrder() async {
        let (_, stories) = hub()
        let checkpoints = ItemStory.Account(source: "Copilot's checkpoints", milestones: ["Planning", "Rounding half up"])
        // Registered in the other order: Azure DevOps still tells first.
        stories.register(.copilot, kinds: [.session]) { _ in ItemStory(sentence: "", account: checkpoints) }
        stories.register(.azureDevOps, kinds: [.pullRequest, .session]) { ref in
            ref.kind == .session
                ? ItemStory(sentence: "Opened a pull request", facts: [ItemStory.Fact("Sent", "12m ago")],
                            account: ItemStory.Account(source: "Copilot's report", overview: "Coupons round half up."))
                : nil
        }
        await stories.tell([item(session), item(pullRequest)])
        let told = stories.story(for: session)
        #expect(told?.sentence == "Opened a pull request")
        #expect(told?.facts == [ItemStory.Fact("Sent", "12m ago")])
        // Copilot's checkpoints say more than the report a task ended with, which is what it said last.
        #expect(told?.account?.milestones == checkpoints.milestones)
        #expect(told?.account?.lastMessage == "Coupons round half up.")
        // Nobody knows the pull request: there's nothing to tell, and that's told.
        #expect(stories.story(for: pullRequest) == nil)
        #expect(stories.hasTold(pullRequest))
    }

    @Test func itTellsAgainOnlyWhenTheRowChangesOrAMinutePassed() async {
        let (_, stories) = hub()
        var now = Date(timeIntervalSince1970: 1_000_000)
        stories.now = { now }
        let asked = Asked()
        stories.register(.azureDevOps, kinds: [.pullRequest]) { ref in
            asked.refs.append(ref)
            return ItemStory(sentence: "Told \(asked.refs.count)")
        }
        let waiting = item(pullRequest, status: "Waiting", date: now)
        await stories.tell([waiting])
        await stories.tell([waiting])
        #expect(asked.refs.count == 1)
        // The row changed.
        await stories.tell([item(pullRequest, state: .done, status: "Ready", date: now)])
        #expect(stories.story(for: pullRequest)?.sentence == "Told 2")
        // A session's checkpoints come without its row changing: after a minute, it's told again.
        now += 61
        await stories.tell([item(pullRequest, state: .done, status: "Ready", date: Date(timeIntervalSince1970: 1_000_000))])
        #expect(asked.refs.count == 3)
        // A quarter of an hour later, what was told is gone.
        now += 15 * 60
        #expect(stories.story(for: pullRequest) == nil)
    }

    @Test func askingTwiceAsksTheSourceOnce() async throws {
        let (_, stories) = hub()
        let asked = Asked()
        stories.register(.azureDevOps, kinds: [.pullRequest]) { ref in
            asked.refs.append(ref)
            try? await Task.sleep(for: .milliseconds(20))
            return ItemStory(sentence: "Waiting for reviewers")
        }
        stories.request(item(pullRequest))
        stories.request(item(pullRequest))
        #expect(stories.isTelling(pullRequest))
        for _ in 0..<200 where !stories.hasTold(pullRequest) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stories.story(for: pullRequest)?.sentence == "Waiting for reviewers")
        #expect(!stories.isTelling(pullRequest))
        #expect(asked.refs == [pullRequest])
    }

    @Test func aSourceThatStopsTakesWhatItToldWithIt() async {
        let (_, stories) = hub()
        stories.register(.copilot, kinds: [.session]) { _ in ItemStory(sentence: "Asks: Use a new table?") }
        await stories.tell([item(session)])
        #expect(stories.story(for: session) != nil)
        stories.withdraw(.copilot)
        #expect(stories.story(for: session) == nil)
        // Nothing tells about sessions now: asking reads nothing.
        await stories.tell([item(session)])
        #expect(!stories.hasTold(session))
    }

    @Test func turningShowLinksOffBeforeAStoryIsToldReadsNothing() async throws {
        let (links, stories) = hub()
        let asked = Asked()
        stories.register(.copilot, kinds: [.session]) { ref in
            asked.refs.append(ref)
            return ItemStory(sentence: "Finished")
        }
        stories.request(item(session))
        links.setOn(false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(asked.refs.isEmpty)
        #expect(!stories.isTelling(session))
        #expect(!stories.hasTold(session))
    }

    /// Holds a teller until it's let go.
    @MainActor
    private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// More of a thing was read, such as a work item's details: it's told again the next time it's asked for, even for
    /// the same row within the minute, and what was told shows until then.
    @Test func aStoryMadeOutOfDateIsToldAgainWhenAskedAndShowsUntilThen() async {
        let (_, stories) = hub()
        let asked = Asked()
        stories.register(.azureDevOps, kinds: [.pullRequest]) { ref in
            asked.refs.append(ref)
            return ItemStory(sentence: asked.refs.count == 1 ? "Read before its details" : "Read with its details")
        }
        let row = item(pullRequest, status: "Waiting")
        await stories.tell([row])
        stories.invalidate(pullRequest)
        #expect(stories.story(for: pullRequest)?.sentence == "Read before its details")
        await stories.tell([row])
        #expect(asked.refs.count == 2)
        #expect(stories.story(for: pullRequest)?.sentence == "Read with its details")
        // One never told stays untold.
        stories.invalidate(session)
        #expect(!stories.hasTold(session))
    }

    /// One being told when it's made out of date is told again: what was being told doesn't take its place.
    @Test func aStoryBeingToldWhenItsMadeOutOfDateIsToldAgain() async throws {
        let (_, stories) = hub()
        let gate = Gate()
        let asked = Asked()
        stories.register(.azureDevOps, kinds: [.pullRequest]) { ref in
            asked.refs.append(ref)
            guard asked.refs.count == 1 else { return ItemStory(sentence: "Read with its details") }
            await gate.wait()
            return ItemStory(sentence: "Read before its details")
        }
        stories.request(item(pullRequest))
        for _ in 0..<200 where gate.continuation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        stories.invalidate(pullRequest)
        gate.open()
        for _ in 0..<200 where stories.isTelling(pullRequest) || !stories.hasTold(pullRequest) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(stories.story(for: pullRequest)?.sentence == "Read with its details")
        #expect(asked.refs.count == 2)
    }

    @Test func aStoryTakenBackNeverReplacesTheOneToldInItsPlace() async throws {
        let (_, stories) = hub()
        let gate = Gate()
        stories.register(.copilot, kinds: [.session]) { _ in
            await gate.wait()
            return ItemStory(sentence: "Told before Copilot stopped")
        }
        stories.request(item(session))
        for _ in 0..<200 where gate.continuation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Copilot stops and starts again, and the same row asks again, while the first story is still being told.
        stories.withdraw(.copilot)
        stories.register(.copilot, kinds: [.session]) { _ in ItemStory(sentence: "Told since") }
        stories.request(item(session))
        gate.open()
        for _ in 0..<200 where !stories.hasTold(session) || stories.isTelling(session) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(stories.story(for: session)?.sentence == "Told since")
        #expect(!stories.isTelling(session))
    }

    @Test func aSummaryCancelledWhileAStoryIsToldLeavesNothingBeingTold() async throws {
        let (_, stories) = hub()
        let gate = Gate()
        let asked = Asked()
        stories.register(.copilot, kinds: [.session]) { ref in
            asked.refs.append(ref)
            if asked.refs.count == 1 { await gate.wait() }
            return ItemStory(sentence: "Finished")
        }
        stories.register(.azureDevOps, kinds: [.pullRequest]) { ref in
            asked.refs.append(ref)
            return ItemStory(sentence: "Waiting for reviewers")
        }
        let summary = Task { await stories.tell([item(session), item(pullRequest)]) }
        for _ in 0..<200 where gate.continuation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(stories.isTelling(session))
        summary.cancel()
        gate.open()
        await summary.value
        // What it asked is taken back, and it asks nothing more.
        #expect(!stories.isTelling(session))
        #expect(!stories.hasTold(session))
        #expect(asked.refs == [session])
        // Asked again for the same row, it's told.
        await stories.tell([item(session)])
        #expect(asked.refs == [session, session])
        #expect(stories.story(for: session)?.sentence == "Finished")
    }

    @Test func tellingWaitsForAStoryBeingToldForTheSameRow() async throws {
        let (_, stories) = hub()
        let gate = Gate()
        let asked = Asked()
        stories.register(.copilot, kinds: [.session]) { ref in
            asked.refs.append(ref)
            let count = asked.refs.count
            await gate.wait()
            return ItemStory(sentence: "Told \(count)")
        }
        // The details ask first.
        stories.request(item(session))
        for _ in 0..<200 where gate.continuation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let summary = Task { await stories.tell([item(session)]) }
        try await Task.sleep(for: .milliseconds(30))
        gate.open()
        await summary.value
        // Told once, and there for what waited.
        #expect(asked.refs == [session])
        #expect(stories.story(for: session)?.sentence == "Told 1")

        // What waits for another's request doesn't take it back: that one goes on, for the details.
        let next = item(session, status: "Working")
        stories.request(next)
        for _ in 0..<200 where gate.continuation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancelled = Task { await stories.tell([next]) }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        gate.open()
        await cancelled.value
        for _ in 0..<200 where stories.isTelling(session) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(asked.refs == [session, session])
        #expect(stories.story(for: session)?.sentence == "Told 2")
    }

    // MARK: Where it stands

    private func connection(_ ref: ItemRef, state: ItemState?, minutesAgo: Double) -> LinkConnection {
        LinkConnection(
            item: item(ref, state: state, date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60)), origins: [.azureDevOps],
            via: nil, isHidden: false, isKnownElsewhere: true
        )
    }

    @Test func whatNeedsYouShowsFirstThenWhatsWrongAtWorkAndDone() {
        let waiting = connection(.pullRequest(organization: "contoso", number: 4120), state: nil, minutesAgo: 1)
        let done = connection(.pullRequest(organization: "contoso", number: 4091), state: .done, minutesAgo: 2)
        let failing = connection(.pullRequest(organization: "contoso", number: 4088), state: .failing, minutesAgo: 30)
        let asks = connection(session, state: .needsYou, minutesAgo: 90)
        let working = connection(ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b02")!, state: .running, minutesAgo: 5)
        let newerDone = connection(.pullRequest(organization: "contoso", number: 4093), state: .done, minutesAgo: 1)
        let ordered = WhereItStandsSection.ordered([waiting, done, failing, asks, working, newerDone])
        #expect(ordered.map(\.item.ref) == [asks, failing, working, newerDone, done, waiting].map(\.item.ref))
    }

    @Test func theTallyCountsEachStateForFiveThingsOrMore() {
        let asks = connection(session, state: .needsYou, minutesAgo: 1)
        let done = connection(.pullRequest(organization: "contoso", number: 4091), state: .done, minutesAgo: 2)
        let alsoDone = connection(.pullRequest(organization: "contoso", number: 4093), state: .done, minutesAgo: 3)
        let waiting = connection(.pullRequest(organization: "contoso", number: 4120), state: nil, minutesAgo: 4)
        let other = connection(.pullRequest(organization: "contoso", number: 4118), state: nil, minutesAgo: 5)
        // Fewer: their icons say it.
        #expect(WhereItStandsSection.tally([asks, done, alsoDone, waiting]) == nil)
        #expect(WhereItStandsSection.tally([asks, done, alsoDone, waiting, other])?.map(\.text) == ["1 needs you", "2 done or ready"])
        #expect(WhereItStandsSection.tally([waiting, other, waiting, other, waiting]) == nil)
    }

    @Test func sessionsShowUnderThePullRequestTheyreLinkedThrough() {
        let pullRequest = item(.pullRequest(organization: "contoso", number: 4091), state: .done, date: Date(timeIntervalSince1970: 1_000_000))
        let teammates = connection(.pullRequest(organization: "contoso", number: 4120), state: nil, minutesAgo: 1)
        let ready = LinkConnection(item: pullRequest, origins: [.azureDevOps], via: nil, isHidden: false, isKnownElsewhere: true)
        let opened = LinkConnection(
            item: item(session, state: .needsYou, date: Date(timeIntervalSince1970: 1_000_000 - 60)), origins: [], via: pullRequest,
            isHidden: false, isKnownElsewhere: true
        )
        let groups = WhereItStandsSection.groups(WhereItStandsSection.ordered([teammates, ready, opened]))
        // The pull request leads its session, and the session's needing you puts the group first.
        #expect(groups.map(\.lead.item.ref) == [ready.item.ref, teammates.item.ref])
        #expect(groups.first?.children.map(\.item.ref) == [session])
    }

    @Test func aTaskYouSentSaysWhatFor() {
        let workItem = ItemRef.workItem(organization: "contoso", id: 5112)
        let fix = ItemRef.pullRequest(organization: "contoso", number: 4088)
        func task(_ sent: SentToCopilot) -> LinkedItem {
            LinkedItem(ref: session, label: "5112: Round half up", title: "Copilot: 5112: Round half up", symbol: "paperplane.fill",
                       color: .blue, sent: sent)
        }
        #expect(WhereItStandsSection.name(of: task(SentToCopilot(from: workItem)), subject: workItem) == "Sent to Copilot")
        // From something else, which its marker numbers: that thing's title, as Azure DevOps has it.
        let bug = ItemRef.workItem(organization: "contoso", id: 5110)
        let elsewhere = SentToCopilot(from: workItem, label: "5112", title: "Round half up in the coupon service")
        #expect(WhereItStandsSection.name(of: task(elsewhere), subject: bug) == "Round half up in the coupon service")
        #expect(WhereItStandsSection.name(of: task(SentToCopilot(from: workItem, label: "5112")), subject: bug) == "Sent to Copilot")
        let fixElsewhere = SentToCopilot(action: "Fix the Build", from: fix, label: "!4088", title: "Show delivery estimates")
        #expect(WhereItStandsSection.name(of: task(fixElsewhere), subject: bug) == "Fix the Build: Show delivery estimates")
        #expect(WhereItStandsSection.name(of: task(SentToCopilot(action: "Fix the Build", from: fix)), subject: workItem, parent: fix)
            == "Fix the Build with Copilot")
        // A session of the app's is called by its name, a pull request by its title.
        #expect(WhereItStandsSection.name(of: item(session), subject: workItem) == session.id)
        #expect(WhereItStandsSection.name(of: item(fix), subject: workItem) == "Round coupons")
        #expect(WhereItStandsSection.phrase("Ready to complete: Approved by you") == ("Ready to complete:", "Approved by you"))
        #expect(WhereItStandsSection.phrase("Finished") == ("Finished", ""))
    }
}
