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
                            account: ItemStory.Account(source: "Copilot's summary", overview: "Coupons round half up."))
                : nil
        }
        await stories.tell([item(session), item(pullRequest)])
        let told = stories.story(for: session)
        #expect(told?.sentence == "Opened a pull request")
        #expect(told?.facts == [ItemStory.Fact("Sent", "12m ago")])
        // Copilot's checkpoints say more than the summary a task ended with.
        #expect(told?.account == checkpoints)
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

    @Test func theTallyCountsEachStateForTwoThingsOrMore() {
        let asks = connection(session, state: .needsYou, minutesAgo: 1)
        let done = connection(.pullRequest(organization: "contoso", number: 4091), state: .done, minutesAgo: 2)
        let alsoDone = connection(.pullRequest(organization: "contoso", number: 4093), state: .done, minutesAgo: 3)
        let waiting = connection(.pullRequest(organization: "contoso", number: 4120), state: nil, minutesAgo: 4)
        #expect(WhereItStandsSection.tally([asks])?.map(\.text) == nil)
        #expect(WhereItStandsSection.tally([asks, done, alsoDone, waiting])?.map(\.text) == ["1 needs you", "2 done or ready"])
        #expect(WhereItStandsSection.tally([waiting, waiting]) == nil)
    }
}
