import BriefBarCore
import Foundation
import SwiftUI
import Testing
@testable import BriefBarUI

/// Summarize with Copilot: off until you turn it on, only with Show Links, only when you ask, kept in memory, and saying
/// when what it summed up changed since.
@MainActor
@Suite struct StorySummariesTests {
    private let workItem = ItemRef.workItem(organization: "contoso", id: 5110)
    private let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4091)

    /// What the writer was asked.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [String] = []
        var prompts: [String] { lock.withLock { _prompts } }
        func add(_ prompt: String) { lock.withLock { _prompts.append(prompt) } }
    }

    private func hub(on: Bool = true, links linksOn: Bool = true, defaults: MemoryDefaults = MemoryDefaults())
        -> (Links, ItemStories, StorySummaries) {
        let links = Links(defaults: MemoryDefaults(), isDemo: false)
        links.setOn(linksOn)
        let stories = ItemStories(links: links)
        let summaries = StorySummaries(defaults: defaults, links: links, stories: stories, isDemo: false)
        summaries.setOn(on)
        return (links, stories, summaries)
    }

    private func publish(_ links: Links, status: String = "Ready to complete") {
        links.publish(.azureDevOps, links: [ItemLink(workItem, pullRequest, origin: .azureDevOps)!], items: [
            LinkedItem(ref: workItem, label: "5110", title: "Coupon totals round down", symbol: "ladybug", color: .red, status: "Active"),
            LinkedItem(ref: pullRequest, label: "!4091", title: "Fix the coupon rounding error", symbol: "arrow.triangle.pull",
                       color: .green, state: .done, status: status),
        ])
    }

    private func writer(_ asked: Asked, answer: String = "HEADLINE: Fixed in !4091.\nNEXT: You: complete !4091.\nSUMMARY: Approved.")
        -> StorySummaries.Writer {
        { prompt, _ in
            asked.add(prompt)
            return .success(answer)
        }
    }

    @Test func itsOffUntilYouTurnItOnAndNeedsShowLinks() async {
        let defaults = MemoryDefaults()
        let links = Links(defaults: MemoryDefaults(), isDemo: false)
        let summaries = StorySummaries(defaults: defaults, links: links, stories: ItemStories(links: links), isDemo: false)
        #expect(!summaries.isOn)
        #expect(!summaries.isAvailable)
        #expect(summaries.model == "claude-haiku-5.5")
        summaries.setOn(true)
        // Without Show Links, there's nothing to summarize.
        #expect(!summaries.isAvailable)
        let asked = Asked()
        summaries.write = writer(asked)
        await summaries.summarizeAndWait(workItem)
        #expect(asked.prompts.isEmpty)
        #expect(summaries.state(for: workItem) == nil)
        // It's kept, with the model you chose.
        summaries.setModel("gpt-6.1-sol")
        let again = StorySummaries(defaults: defaults, links: links, stories: ItemStories(links: links), isDemo: false)
        #expect(again.isOn)
        #expect(again.model == "gpt-6.1-sol")
        // The demo shows made-up ones.
        #expect(StorySummaries(defaults: MemoryDefaults(), links: links, stories: ItemStories(links: links), isDemo: true).isOn)
    }

    @Test func itWritesWhenYouAskFromWhatTheDetailsShow() async throws {
        let (links, stories, summaries) = hub()
        publish(links)
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest]) { ref in
            ref.kind == .workItem
                ? ItemStory(sentence: "Active", notes: [ItemStory.Fact("Description", "Totals round down.")])
                : ItemStory(sentence: "Ready to complete: Approved by Priya Shah", facts: [ItemStory.Fact("Comments", "No open threads")])
        }
        let asked = Asked()
        summaries.write = writer(asked)
        // Who you are, as Azure DevOps knows you.
        summaries.yourName = { "Robin Diaz" }
        // Nothing until you ask.
        #expect(asked.prompts.isEmpty)
        await summaries.summarizeAndWait(workItem)
        let prompt = try #require(asked.prompts.first)
        #expect(prompt.contains("<data>\nREADER: Robin Diaz\n\nWORK ITEM 5110: Coupon totals round down\nStatus: Active\nDescription: Totals round down."))
        #expect(prompt.contains("PULL REQUEST !4091: Fix the coupon rounding error\nLinked: Linked in Azure DevOps"))
        #expect(prompt.contains("- Comments: No open threads"))
        guard case .written(let summary, _, _, let model)? = summaries.state(for: workItem) else {
            Issue.record("Not written")
            return
        }
        #expect(summary == StorySummary(headline: "Fixed in !4091.", nextFor: "you", next: "Complete !4091.", paragraph: "Approved."))
        #expect(model == "claude-haiku-5.5")
        #expect(!summaries.isOutOfDate(workItem))

        // What it summed up changed since.
        publish(links, status: "Completed")
        #expect(summaries.isOutOfDate(workItem))
        // Nothing's summarized for a thing with nothing linked.
        await summaries.summarizeAndWait(.workItem(organization: "contoso", id: 1))
        #expect(asked.prompts.count == 1)
    }

    @Test func itSaysWhyThereIsNone() async {
        let (links, _, summaries) = hub()
        publish(links)
        summaries.write = { _, _ in .failure(StorySummaries.Problem("Copilot took too long to answer.")) }
        await summaries.summarizeAndWait(workItem)
        guard case .failed(let problem, _)? = summaries.state(for: workItem) else {
            Issue.record("Didn't fail")
            return
        }
        #expect(problem.message == "Copilot took too long to answer.")

        summaries.write = { _, _ in .success("   ") }
        await summaries.summarizeAndWait(workItem)
        guard case .failed(let empty, _)? = summaries.state(for: workItem) else {
            Issue.record("Didn't fail")
            return
        }
        #expect(empty.message == "Copilot answered nothing.")

        // Without a way to ask Copilot.
        summaries.write = nil
        await summaries.summarizeAndWait(workItem)
        guard case .failed? = summaries.state(for: workItem) else {
            Issue.record("Didn't fail")
            return
        }
    }

    @Test func whatsCancelledDismissedOrTurnedOffIsForgotten() async throws {
        let (links, _, summaries) = hub()
        publish(links)
        let gate = Gate()
        summaries.write = { _, _ in
            await gate.wait()
            return .success("HEADLINE: Late.")
        }
        summaries.summarize(workItem)
        guard case .writing? = summaries.state(for: workItem) else {
            Issue.record("Not writing")
            return
        }
        for _ in 0..<200 where !gate.isWaiting {
            try await Task.sleep(for: .milliseconds(5))
        }
        summaries.cancel(workItem)
        #expect(summaries.state(for: workItem) == nil)
        gate.open()
        try await Task.sleep(for: .milliseconds(30))
        // What it answered after it was cancelled doesn't show.
        #expect(summaries.state(for: workItem) == nil)

        summaries.write = { _, _ in .success("HEADLINE: Fixed.") }
        await summaries.summarizeAndWait(workItem)
        #expect(summaries.state(for: workItem) != nil)
        summaries.dismiss(workItem)
        #expect(summaries.state(for: workItem) == nil)

        await summaries.summarizeAndWait(workItem)
        links.setOn(false)
        #expect(summaries.state(for: workItem) == nil)
        links.setOn(true)
        await summaries.summarizeAndWait(workItem)
        summaries.setOn(false)
        #expect(summaries.state(for: workItem) == nil)
    }

    @Test func whatOnlyThisMacKnowsIsNeverSent() async throws {
        let (links, stories, summaries) = hub()
        // Someone sent it to you in a chat: that's why it needs you.
        links.publish(.azureDevOps, links: [ItemLink(workItem, pullRequest, origin: .azureDevOps)!], items: [
            LinkedItem(ref: workItem, label: "5110", title: "Coupon totals round down", symbol: "ladybug", color: .red, status: "Active"),
            LinkedItem(ref: pullRequest, label: "!4091", title: "Fix the coupon rounding error", symbol: "arrow.triangle.pull",
                       color: .orange, state: .needsYou, status: "Needs You", sharedStatus: "Active"),
        ])
        let asked = Asked()
        summaries.write = writer(asked)
        // Without its story, its row's status as it may be shared.
        await summaries.summarizeAndWait(workItem)
        let unknown = try #require(asked.prompts.last)
        #expect(unknown.contains("PULL REQUEST !4091: Fix the coupon rounding error\nLinked: Linked in Azure DevOps\nStatus: Active"))
        #expect(!unknown.contains("Needs You"))

        stories.register(.azureDevOps, kinds: [.pullRequest]) { _ in
            ItemStory(sentence: "Dana Whitfield sent this in Teams: By Alex Kim", sharedSentence: "Waiting for reviewers: Sam Rivera")
        }
        await summaries.summarizeAndWait(workItem)
        let told = try #require(asked.prompts.last)
        #expect(told.contains("Status: Waiting for reviewers: Sam Rivera"))
        for said in ["Dana", "Teams", "Needs You"] {
            #expect(!told.contains(said))
        }
        // The details still say it.
        #expect(stories.story(for: pullRequest)?.sentence == "Dana Whitfield sent this in Teams: By Alex Kim")
    }

    @Test func aSourceThatStopsTakesItsSummariesWithIt() async throws {
        let (links, stories, summaries) = hub()
        publish(links)
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest]) { _ in ItemStory(sentence: "Ready to complete") }
        let gate = Gate()
        let stopped = Asked()
        summaries.write = { _, _ in
            await gate.wait()
            if Task.isCancelled { stopped.add("cancelled") }
            return .success("HEADLINE: Fixed in !4091.")
        }
        summaries.summarize(workItem)
        for _ in 0..<200 where !gate.isWaiting {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Azure DevOps stops while Copilot writes.
        links.withdraw(.azureDevOps)
        stories.withdraw(.azureDevOps)
        #expect(summaries.state(for: workItem) == nil)
        gate.open()
        for _ in 0..<200 where stopped.prompts.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(20))
        // Copilot was stopped, and what it answered doesn't show.
        #expect(stopped.prompts == ["cancelled"])
        #expect(summaries.state(for: workItem) == nil)

        // One written already goes too.
        publish(links)
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest]) { _ in ItemStory(sentence: "Ready to complete") }
        await summaries.summarizeAndWait(workItem)
        guard case .written? = summaries.state(for: workItem) else {
            Issue.record("Not written")
            return
        }
        stories.withdraw(.azureDevOps)
        #expect(summaries.state(for: workItem) == nil)
        // And Copilot's own stopping does the same.
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest]) { _ in ItemStory(sentence: "Ready to complete") }
        await summaries.summarizeAndWait(workItem)
        links.publish(.copilot, links: [], items: [])
        links.withdraw(.copilot)
        #expect(summaries.state(for: workItem) == nil)
    }

    @Test func aSummaryWaitsForAStoryBeingToldAlready() async throws {
        let (links, stories, summaries) = hub()
        publish(links)
        let gate = Gate()
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest]) { ref in
            guard ref.kind == .pullRequest else { return ItemStory(sentence: "Active") }
            await gate.wait()
            return ItemStory(sentence: "Ready to complete: Approved by Priya Shah", facts: [ItemStory.Fact("Comments", "No open threads")])
        }
        // The details ask for the pull request's story first.
        stories.request(links.describe(pullRequest))
        for _ in 0..<200 where !gate.isWaiting {
            try await Task.sleep(for: .milliseconds(5))
        }
        let asked = Asked()
        summaries.write = writer(asked)
        summaries.summarize(workItem)
        try await Task.sleep(for: .milliseconds(50))
        // It waits for that story, rather than going without it.
        #expect(asked.prompts.isEmpty)
        #expect(stories.isTelling(pullRequest))
        gate.open()
        for _ in 0..<200 where asked.prompts.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let prompt = try #require(asked.prompts.first)
        #expect(prompt.contains("Status: Ready to complete: Approved by Priya Shah\n- Comments: No open threads"))
        for _ in 0..<200 where isWriting(summaries.state(for: workItem)) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!summaries.isOutOfDate(workItem))
    }

    private func isWriting(_ state: StorySummaries.State?) -> Bool {
        if case .writing? = state { return true }
        return false
    }

    /// What the stories say, which a test changes.
    private final class Said {
        var reviewers = "Waiting on Sam Rivera (required)"
    }

    @Test func outOfDateIsWhatTheRowsSayNotHowLongAgo() async throws {
        let (links, stories, summaries) = hub()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        stories.now = { clock }
        let teammates = ItemRef.pullRequest(organization: "contoso", number: 4120)
        let task = ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b02")!
        func publish(task date: Date, more: [LinkedItem] = []) {
            let items = [
                LinkedItem(ref: workItem, label: "5110", title: "Coupon totals round down", symbol: "ladybug", color: .red, status: "Active"),
                // A teammate's: its row says it's active, whatever the votes.
                LinkedItem(ref: teammates, label: "!4120", title: "Save items for later", symbol: "arrow.triangle.pull", color: .blue,
                           status: "Active", date: Date(timeIntervalSince1970: 900_000)),
                LinkedItem(ref: task, label: "5112: Round half up", title: "Copilot: 5112: Round half up", symbol: "paperplane.fill",
                           color: .blue, state: .running, status: "Working: Run the cart tests", date: date, sent: SentToCopilot(from: workItem)),
            ] + more
            links.publish(.azureDevOps, links: items.dropFirst().compactMap { ItemLink(workItem, $0.ref, origin: .azureDevOps) }, items: items)
        }
        let said = Said()
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest, .session]) { ref in
            switch ref.kind {
            case .pullRequest:
                ItemStory(sentence: "Waiting for reviewers: Sam Rivera", date: clock, facts: [ItemStory.Fact("Reviewers", said.reviewers)])
            case .session:
                ItemStory(sentence: "Working: Run the cart tests", date: clock, facts: [ItemStory.Fact("Model", "Claude Sonnet 5.5 · Medium")])
            default:
                ItemStory(sentence: "Active", facts: [ItemStory.Fact("Tasks", "1 of 3 done")])
            }
        }
        publish(task: clock.addingTimeInterval(-6 * 60))
        summaries.write = writer(Asked())
        await summaries.summarizeAndWait(workItem)
        #expect(!summaries.isOutOfDate(workItem))

        // A minute on, the task has been working for 7 minutes rather than 6, and each is told again.
        clock += 61
        publish(task: clock.addingTimeInterval(-7 * 60))
        await stories.tell([links.describe(workItem)] + links.connections(of: workItem).map(\.item))
        #expect(!summaries.isOutOfDate(workItem))
        #expect(summaries.whatChanged(workItem) == nil)

        // The teammate's pull request is approved: its row stays the same, and its story says so.
        said.reviewers = "Approved by Sam Rivera"
        clock += 61
        await stories.tell(links.connections(of: workItem).map(\.item))
        #expect(summaries.isOutOfDate(workItem))
        #expect(summaries.whatChanged(workItem) == "!4120 changed")

        // What's linked since, or not anymore.
        publish(task: clock, more: [LinkedItem(ref: pullRequest, label: "!4091", title: "Fix the coupon rounding error",
                                               symbol: "arrow.triangle.pull", color: .green, state: .done, status: "Ready to complete")])
        #expect(summaries.whatChanged(workItem) == "!4120 changed; !4091 was linked")
        links.publish(.azureDevOps, links: [ItemLink(workItem, teammates, origin: .azureDevOps)!], items: [
            LinkedItem(ref: workItem, label: "5110", title: "Coupon totals round down", symbol: "ladybug", color: .red, status: "Active"),
            LinkedItem(ref: teammates, label: "!4120", title: "Save items for later", symbol: "arrow.triangle.pull", color: .blue, status: "Active"),
        ])
        #expect(summaries.whatChanged(workItem) == "!4120 changed; “5112: Round half up” was unlinked")
    }

    @Test func aStoryForgottenSinceDoesntMakeItOutOfDate() async throws {
        let (links, stories, summaries) = hub()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        stories.now = { clock }
        publish(links)
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest]) { _ in
            ItemStory(sentence: "Ready to complete: Approved by Priya Shah", facts: [ItemStory.Fact("Comments", "No open threads")])
        }
        summaries.write = writer(Asked())
        await summaries.summarizeAndWait(workItem)
        // A quarter of an hour on, what was told is forgotten, until it's told again.
        clock += 16 * 60
        #expect(stories.story(for: pullRequest) == nil)
        #expect(!summaries.isOutOfDate(workItem))
        // Its row changed, though: that it can tell.
        links.publish(.azureDevOps, links: [ItemLink(workItem, pullRequest, origin: .azureDevOps)!], items: [
            LinkedItem(ref: workItem, label: "5110", title: "Coupon totals round down", symbol: "ladybug", color: .red, status: "Active"),
            LinkedItem(ref: pullRequest, label: "!4091", title: "Fix the coupon rounding error", symbol: "arrow.triangle.pull",
                       color: .red, state: .failing, status: "Failing"),
        ])
        #expect(summaries.whatChanged(workItem) == "!4091 changed")
    }

    /// Holds the writer until it's let go.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        var isWaiting: Bool { lock.withLock { continuation != nil } }

        func wait() async {
            await withCheckedContinuation { continuation in
                let open = lock.withLock {
                    if opened { return true }
                    self.continuation = continuation
                    return false
                }
                if open { continuation.resume() }
            }
        }

        func open() {
            let waiting = lock.withLock {
                opened = true
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume()
        }
    }
}
