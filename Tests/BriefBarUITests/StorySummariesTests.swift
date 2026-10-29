import BriefBarCore
import Foundation
import SwiftUI
import Testing
@testable import BriefBarUI

/// Summaries: off until you turn it on, only with Show Links, only when you ask, kept in memory, and saying
/// when what it summed up changed since.
@MainActor
@Suite struct StorySummariesTests {
    private let workItem = ItemRef.workItem(organization: "contoso", id: 5110)
    private let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4091)
    private let sentTask = ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b02")!

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
        #expect(summaries.model == StorySummaries.appleIntelligenceModel)
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
        // Existing choices, including the former default, aren't migrated to Apple Intelligence.
        defaults.set("claude-haiku-5.5", forKey: StorySummaries.modelKey)
        let previous = StorySummaries(defaults: defaults, links: links, stories: ItemStories(links: links), isDemo: false)
        #expect(previous.model == "claude-haiku-5.5")
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
        summaries.setYourName(.github) { "robin" }
        summaries.setYourName(.azureDevOps) { "Robin Diaz" }
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
        #expect(model == StorySummaries.appleIntelligenceModel)
        #expect(!summaries.isOutOfDate(workItem))

        // What it summed up changed since.
        publish(links, status: "Completed")
        #expect(summaries.isOutOfDate(workItem))
        // Nothing's summarized for a thing with nothing linked.
        await summaries.summarizeAndWait(.workItem(organization: "contoso", id: 1))
        #expect(asked.prompts.count == 1)
    }

    /// As it's written, the sources read more of each thing for it: what they read goes into the prompt, with each thing.
    @Test func itSumsUpWhatTheSourcesReadForItToo() async throws {
        let (links, stories, summaries) = hub()
        publish(links)
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest]) { ref in
            ref.kind == .workItem
                ? ItemStory(sentence: "Active", notes: [ItemStory.Fact("Description", "Totals round…")])
                : ItemStory(sentence: "Waiting for reviewers")
        }
        var read: [ItemRef] = []
        stories.registerContext(.azureDevOps, kinds: [.workItem, .pullRequest]) { ref in
            read.append(ref)
            return ref.kind == .workItem
                ? [ItemStory.Fact("Description", "Totals round down for coupons in every currency.")]
                : [ItemStory.Fact("Open threads", "Sam Rivera on Coupon.swift:12: Round half up?")]
        }
        let asked = Asked()
        summaries.write = writer(asked)
        // Nothing's read until a summary is written.
        #expect(read.isEmpty)
        await summaries.summarizeAndWait(workItem)
        #expect(read == [workItem, pullRequest])
        let prompt = try #require(asked.prompts.first)
        #expect(prompt.contains("WORK ITEM 5110: Coupon totals round down\nStatus: Active\nDescription:\nTotals round down for coupons in every currency."))
        #expect(!prompt.contains("Totals round…"))
        #expect(prompt.contains("Status: Waiting for reviewers\nOpen threads:\nSam Rivera on Coupon.swift:12: Round half up?"))
        // What was read says nothing about whether it's out of date: its story does.
        #expect(!summaries.isOutOfDate(workItem))
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
        #expect(empty.message == "Apple Intelligence answered nothing.")

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

    /// What's told of each, which a test changes.
    private final class Told {
        var stories: [ItemRef: ItemStory] = [:]
    }

    /// What a summary of the work item says changed since, once what's told of what it summed up goes from `then` to `now`,
    /// as it's told again a minute on; nil when nothing did. A pull request and a task sent to Copilot are linked to it.
    private func whatChanged(then: [ItemRef: ItemStory], now: [ItemRef: ItemStory]) async -> String? {
        let (links, stories, summaries) = hub()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        stories.now = { clock }
        let items = [
            LinkedItem(ref: workItem, label: "5110", title: "Coupon totals round down", symbol: "ladybug", color: .red, status: "Active"),
            LinkedItem(ref: pullRequest, label: "!4091", title: "Fix the coupon rounding error", symbol: "arrow.triangle.pull",
                       color: .red, state: .failing, status: "Build failed"),
            LinkedItem(ref: sentTask, label: "5112: Round half up", title: "Copilot: 5112: Round half up", symbol: "paperplane.fill",
                       color: .blue, state: .running, status: "Working: Run the cart tests", sent: SentToCopilot(from: workItem)),
        ]
        links.publish(.azureDevOps, links: items.dropFirst().compactMap { ItemLink(workItem, $0.ref, origin: .azureDevOps) }, items: items)
        let told = Told()
        told.stories = then
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest, .session]) { ref in told.stories[ref] }
        summaries.write = writer(Asked())
        await summaries.summarizeAndWait(workItem)
        guard case .written? = summaries.state(for: workItem) else {
            Issue.record("Not written")
            return nil
        }
        #expect(summaries.whatChanged(workItem) == nil)

        told.stories = now
        clock += 61
        await stories.tell(items)
        for (ref, story) in now {
            #expect(stories.story(for: ref) == story)
        }
        return summaries.whatChanged(workItem)
    }

    @Test func anEditedDescriptionMakesItOutOfDate() async {
        let then = ItemStory(sentence: "Active", notes: [ItemStory.Fact("Description", "Totals round down.")], notesRead: true)
        var now = then
        now.notes = [ItemStory.Fact("Description", "Totals round down when a coupon takes off a percentage.")]
        #expect(await whatChanged(then: [workItem: then], now: [workItem: now]) == "5110 changed")
    }

    @Test func aNewCommentMakesItOutOfDate() async {
        let then = ItemStory(sentence: "Active", notes: [
            ItemStory.Fact("Description", "Totals round down."),
            ItemStory.Fact("Latest comments", "Priya Shah: Only totals with half a cent are off."),
        ], notesRead: true)
        var now = then
        now.notes[1].value = "Sam Rivera: Finance wants them rounded half up instead.\nPriya Shah: Only totals with half a cent are off."
        #expect(await whatChanged(then: [workItem: then], now: [workItem: now]) == "5110 changed")
    }

    @Test func anotherErrorInAFailedRunMakesItOutOfDate() async {
        func failed(_ error: String) -> ItemStory {
            ItemStory(sentence: "Build failed: payments-api CI", runs: [
                ItemStory.Run(name: "payments-api CI", state: .failing, status: "Failed at Run unit tests", detail: error),
            ])
        }
        let then = failed("2 tests failed in CouponTests.")
        let now = failed("1 test failed in CurrencyTests.")
        #expect(await whatChanged(then: [pullRequest: then], now: [pullRequest: now]) == "!4091 changed")
    }

    /// Copilot's checkpoints, corrected: as many as before, but one of them, or what's been done or what's next, says
    /// something else.
    @Test func whatCopilotRecordedMakesItOutOfDateWithAsManyCheckpoints() async {
        let then = ItemStory(sentence: "Working: Run the cart tests", account: ItemStory.Account(
            source: "Copilot's notes", milestones: ["Rounding reproduced", "Rounding fixed"], overview: "Totals round half up now.",
            done: ["Rounded half up in CouponService.Apply"], next: ["Run the cart tests"], lastMessage: "Running the cart tests."
        ))
        var milestone = then
        milestone.account?.milestones[1] = "Rounding fixed for positive totals"
        var overview = then
        overview.account?.overview = "Totals round half up now, but negative ones still round down."
        var done = then
        done.account?.done = ["Rounded half up in CouponService.Apply", "Added a test for negative totals"]
        var next = then
        next.account?.next = ["Round negative totals too"]
        for now in [milestone, overview, done, next] {
            #expect(now.account?.milestoneCount == then.account?.milestoneCount)
            #expect(await whatChanged(then: [sentTask: then], now: [sentTask: now]) == "“5112: Round half up” changed")
        }
    }

    /// Read both then and now, a work item's first comment, or its last one gone, changes what it says.
    @Test func aFirstCommentOrTheLastOneGoneMakesItOutOfDate() async {
        let none = ItemStory(sentence: "Active", notesRead: true)
        let commented = ItemStory(
            sentence: "Active", notes: [ItemStory.Fact("Latest comments", "Sam Rivera: This blocks the release.")], notesRead: true
        )
        #expect(await whatChanged(then: [workItem: none], now: [workItem: commented]) == "5110 changed")
        #expect(await whatChanged(then: [workItem: commented], now: [workItem: none]) == "5110 changed")
        #expect(await whatChanged(then: [workItem: none], now: [workItem: none]) == nil)
    }

    /// A work item has its notes only while its details were read, which those of another may have taken the place of.
    @Test func notesKnownOnlyThenOrOnlyNowDontMakeItOutOfDate() async {
        let read = ItemStory(sentence: "Active", notes: [ItemStory.Fact("Description", "Totals round down.")], notesRead: true)
        let unread = ItemStory(sentence: "Active")
        #expect(await whatChanged(then: [workItem: read], now: [workItem: unread]) == nil)
        #expect(await whatChanged(then: [workItem: unread], now: [workItem: read]) == nil)
        // Nor when only some were read, such as its description while its comments couldn't be.
        let commented = ItemStory(sentence: "Active", notes: [
            ItemStory.Fact("Description", "Totals round down."), ItemStory.Fact("Latest comments", "Sam Rivera: This blocks the release."),
        ], notesRead: true)
        let withoutComments = ItemStory(sentence: "Active", notes: [ItemStory.Fact("Description", "Totals round down.")])
        #expect(await whatChanged(then: [workItem: commented], now: [workItem: withoutComments]) == nil)
    }

    /// What the Copilot CLI was looked for with.
    private final class Looks: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func add() { lock.withLock { _count += 1 } }
    }

    @Test func itsOfferedOnlyWithSomethingToSumUp() {
        let (links, _, summaries) = hub()
        let session = ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b02")!
        func publish(tasks: Int, linked: [LinkedItem]) {
            let subject = LinkedItem(ref: workItem, label: "5110", title: "Coupon totals round down", symbol: "ladybug", color: .red,
                                     status: "Active", parts: tasks)
            links.publish(.azureDevOps, links: linked.compactMap { ItemLink(workItem, $0.ref, origin: .azureDevOps) }, items: [subject] + linked)
        }
        let fix = LinkedItem(ref: pullRequest, label: "!4091", title: "Fix the coupon rounding error", symbol: "arrow.triangle.pull",
                             color: .green, state: .done, status: "Ready to complete")
        let task = LinkedItem(ref: session, label: "5112: Round half up", title: "Copilot: 5112: Round half up", symbol: "paperplane.fill",
                              color: .blue, state: .running, status: "Working: Run the cart tests")
        // One thing linked is enough: its description, comments or conversation say more than its row.
        publish(tasks: 0, linked: [fix])
        #expect(summaries.hasSomethingToSum(workItem))
        publish(tasks: 3, linked: [fix])
        #expect(summaries.hasSomethingToSum(workItem))
        publish(tasks: 0, linked: [fix, task])
        #expect(summaries.hasSomethingToSum(workItem))
        // Nothing linked, or Show Links off: nothing.
        publish(tasks: 3, linked: [])
        #expect(!summaries.hasSomethingToSum(workItem))
        publish(tasks: 0, linked: [fix, task])
        links.setOn(false)
        #expect(!summaries.hasSomethingToSum(workItem))
    }

    /// The model is told the reader sees who it all waits on only where that shows: in a work item's details, not on a
    /// pull request's or a session's page or row.
    @Test func onlyAWorkItemsPromptSaysWhoItWaitsOnIsShown() async throws {
        let (links, stories, summaries) = hub()
        publish(links)
        stories.register(.azureDevOps, kinds: [.pullRequest]) { _ in
            ItemStory(sentence: "Ready to complete", waits: [.you("you, to complete !4091")])
        }
        let asked = Asked()
        summaries.write = writer(asked)
        await summaries.summarizeAndWait(workItem)
        await summaries.summarizeAndWait(pullRequest)
        #expect(asked.prompts.count == 2)
        #expect(asked.prompts.first?.contains("SHOWN:\nWaiting on: you, to complete !4091\n") == true)
        #expect(asked.prompts.last?.contains("SHOWN:\n") == false)
    }

    @Test func aPullRequestsOrASessionsRowIsSummedUpFromWhatsKnownOfIt() async throws {
        let (links, stories, summaries) = hub()
        let session = ItemRef.session("0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01")!
        // A pull request with nothing linked, and a session.
        links.publish(.azureDevOps, links: [], items: [
            LinkedItem(ref: pullRequest, label: "!4091", title: "Fix the coupon rounding error", symbol: "arrow.triangle.pull",
                       color: .green, state: .done, status: "Ready to complete"),
        ])
        links.publish(.copilot, links: [], items: [
            LinkedItem(ref: session, label: "Add dark mode to settings", title: "Add dark mode to settings", symbol: "questionmark.bubble",
                       color: .orange, state: .needsYou, status: "Waiting for your answer"),
        ])
        stories.register(.azureDevOps, kinds: [.pullRequest]) { _ in
            ItemStory(sentence: "Ready to complete: Approved by Priya Shah", facts: [ItemStory.Fact("Comments", "No open threads")])
        }
        let asked = Asked()
        summaries.write = writer(asked)
        // Rows offer it for what a source says what it is; a work item has Where It Stands for it.
        #expect(summaries.canSummarize(pullRequest))
        #expect(summaries.canSummarize(session))
        #expect(!summaries.canSummarize(workItem))
        #expect(!summaries.canSummarize(.pullRequest(organization: "contoso", number: 1)))

        // With nothing linked, what's known of it is what's summed up.
        await summaries.summarizeAndWait(pullRequest)
        let prompt = try #require(asked.prompts.first)
        #expect(prompt.contains("PULL REQUEST !4091: Fix the coupon rounding error\nStatus: Ready to complete: Approved by Priya Shah"))
        #expect(prompt.contains("- Comments: No open threads"))
        guard case .written? = summaries.state(for: pullRequest) else {
            Issue.record("Not written")
            return
        }
        // Nothing's known of the session, and nothing's linked to it: nothing to sum up, and nothing asked.
        await summaries.summarizeAndWait(session)
        #expect(asked.prompts.count == 1)
        #expect(summaries.state(for: session) == nil)

        // Without Show Links, or with it off, no row offers it.
        links.setOn(false)
        #expect(!summaries.canSummarize(pullRequest))
        links.setOn(true)
        summaries.setOn(false)
        #expect(!summaries.canSummarize(pullRequest))
    }

    @Test func closingOneKeepsItToShowAgainForNothing() async throws {
        let (links, stories, summaries) = hub()
        publish(links)
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest]) { _ in ItemStory(sentence: "Active") }
        let asked = Asked()
        summaries.write = writer(asked)
        await summaries.summarizeAndWait(workItem)
        guard case .written? = summaries.state(for: workItem) else {
            Issue.record("Not written")
            return
        }
        // ✕ hides it; it's kept, and shows again without asking Copilot.
        summaries.hide(workItem)
        #expect(summaries.isHidden(workItem))
        #expect(summaries.shownState(for: workItem) == nil)
        summaries.show(workItem)
        #expect(summaries.shownState(for: workItem) == summaries.state(for: workItem))
        #expect(asked.prompts.count == 1)
        // Writing it again shows it.
        summaries.hide(workItem)
        await summaries.summarizeAndWait(workItem)
        #expect(!summaries.isHidden(workItem))
        #expect(asked.prompts.count == 2)
        // Turned off, what was hidden goes with the rest.
        summaries.hide(workItem)
        summaries.setOn(false)
        summaries.setOn(true)
        #expect(!summaries.isHidden(workItem))
        #expect(summaries.state(for: workItem) == nil)
    }

    @Test func itCallsYouByWhatAzureDevOpsOrGitHubKnowsYouAs() {
        let (_, _, summaries) = hub()
        #expect(summaries.yourName == nil)
        summaries.setYourName(.github) { "robin" }
        #expect(summaries.yourName == "robin")
        summaries.setYourName(.azureDevOps) { "Robin Diaz" }
        #expect(summaries.yourName == "Robin Diaz")
        // Before Azure DevOps read your pull requests, GitHub's.
        summaries.setYourName(.azureDevOps) { nil }
        #expect(summaries.yourName == "robin")
        summaries.setYourName(.github, nil)
        summaries.setYourName(.azureDevOps, nil)
        #expect(summaries.yourName == nil)
    }

    @Test func itSaysWhatItWasWrittenFrom() {
        func input(_ ref: ItemRef, _ label: String) -> StorySummaries.Input {
            StorySummaries.Input(ref: ref, label: label, row: "", story: nil)
        }
        let first = ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01")!
        let second = ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b02")!
        #expect(StorySummaries.source(of: [input(workItem, "5110"), input(pullRequest, "!4091"), input(first, "Round half up")])
            == "5110, !4091 and 1 Copilot session")
        #expect(StorySummaries.source(of: [input(workItem, "5110"), input(first, "One"), input(second, "Two")])
            == "5110 and 2 Copilot sessions")
        #expect(SummarizeButton.help(for: workItem, model: "Claude Haiku 5.5")
            == "Sends this work item and what's linked to it to GitHub Copilot (Claude Haiku 5.5): 1 request on your Copilot plan.")
    }

    @Test func settingsSaysWhenTheCLIIsntThere() async {
        let (_, _, summaries) = hub(on: false)
        let looks = Looks()
        summaries.findCLI = {
            looks.add()
            return false
        }
        // Not while it's off.
        await summaries.lookForCLI()
        #expect(looks.count == 0)
        #expect(summaries.hasCLI == nil)
        summaries.setOn(true)
        // Apple Intelligence needs neither a CLI lookup nor a Copilot sign-in.
        await summaries.lookForCLI()
        #expect(looks.count == 0)
        #expect(summaries.hasCLI == nil)
        summaries.setModel("claude-haiku-5.5")
        await summaries.lookForCLI()
        #expect(looks.count == 1)
        #expect(summaries.hasCLI == false)
        // When it can't tell, what it knew stays.
        summaries.findCLI = { nil }
        await summaries.lookForCLI()
        #expect(summaries.hasCLI == false)
    }

    // MARK: Writing one as it opens

    /// A work item with something to sum up: a pull request, and tasks of its own.
    private func publishWithTasks(_ links: Links, status: String = "Ready to complete") {
        links.publish(.azureDevOps, links: [ItemLink(workItem, pullRequest, origin: .azureDevOps)!], items: [
            LinkedItem(ref: workItem, label: "5110", title: "Coupon totals round down", symbol: "ladybug", color: .red, status: "Active",
                       parts: 2),
            LinkedItem(ref: pullRequest, label: "!4091", title: "Fix the coupon rounding error", symbol: "arrow.triangle.pull",
                       color: .green, state: .done, status: status),
        ])
    }

    /// Opening a work item's details writes its summary, then shows that one again for nothing while it's current; once
    /// what it summed up changes, opening it writes another, once that one's a while old. Not when you closed it, or chose
    /// to write them only when you ask.
    @Test func openingOneWritesItsSummaryUnlessOneIsCurrent() async throws {
        let defaults = MemoryDefaults()
        let (links, stories, summaries) = hub(defaults: defaults)
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        summaries.now = { clock }
        publishWithTasks(links)
        let asked = Asked()
        summaries.write = writer(asked)
        #expect(summaries.writesWhenOpened)
        await summaries.opened(workItem)
        await waitForWriting(summaries, workItem)
        #expect(asked.prompts.count == 1)
        // Current: shown again for nothing.
        await summaries.opened(workItem)
        #expect(asked.prompts.count == 1)
        // What it summed up changed: it's out of date, but opening it writes another only once it's a while old.
        publishWithTasks(links, status: "Completed")
        #expect(summaries.isOutOfDate(workItem))
        await summaries.opened(workItem)
        #expect(asked.prompts.count == 1)
        clock += StorySummaries.rewriteAfter
        await summaries.opened(workItem)
        await waitForWriting(summaries, workItem)
        #expect(asked.prompts.count == 2)

        // Closed, it stays closed.
        publishWithTasks(links, status: "Abandoned")
        summaries.hide(workItem)
        await summaries.opened(workItem)
        #expect(asked.prompts.count == 2)
        // Written only when you ask.
        summaries.show(workItem)
        summaries.setWritesWhenOpened(false)
        await summaries.opened(workItem)
        #expect(asked.prompts.count == 2)
        #expect(defaults.object(forKey: StorySummaries.whenOpenedKey) as? Bool == false)
        #expect(!StorySummaries(defaults: defaults, links: links, stories: ItemStories(links: links), isDemo: false).writesWhenOpened)
        // Nothing to sum up: a work item with nothing linked has no summary, as it has no ✨.
        summaries.setWritesWhenOpened(true)
        links.publish(.azureDevOps, links: [], items: [
            LinkedItem(ref: workItem, label: "5110", title: "Coupon totals round down", symbol: "ladybug", color: .red, status: "Active"),
            LinkedItem(ref: pullRequest, label: "!4091", title: "Fix the coupon rounding error", symbol: "arrow.triangle.pull",
                       color: .green, state: .done, status: "Ready to complete"),
        ])
        summaries.dismiss(workItem)
        await summaries.opened(workItem)
        #expect(asked.prompts.count == 2)
        // A pull request's page sums up what's known of it, with nothing else linked.
        stories.register(.azureDevOps, kinds: [.pullRequest]) { _ in ItemStory(sentence: "Ready to complete") }
        await summaries.opened(pullRequest)
        await waitForWriting(summaries, pullRequest)
        #expect(asked.prompts.count == 3)
    }

    /// One that couldn't be written isn't tried again by opening it until a while later: Try Again does it at once.
    @Test func openingOneThatFailedTriesAgainOnlyAfterAWhile() async {
        let (links, _, summaries) = hub()
        publishWithTasks(links)
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        summaries.now = { clock }
        let tries = Asked()
        summaries.write = { prompt, _ in
            tries.add(prompt)
            return .failure(StorySummaries.Problem("Copilot took too long to answer."))
        }
        await summaries.opened(workItem)
        await waitForWriting(summaries, workItem)
        #expect(tries.prompts.count == 1)
        await summaries.opened(workItem)
        #expect(tries.prompts.count == 1)
        clock += StorySummaries.retryAfter
        await summaries.opened(workItem)
        await waitForWriting(summaries, workItem)
        #expect(tries.prompts.count == 2)

        // Closing what said it couldn't be written doesn't make opening it try again any sooner.
        summaries.hide(workItem)
        #expect(summaries.state(for: workItem) == nil)
        await summaries.opened(workItem)
        #expect(tries.prompts.count == 2)
        // Try Again does, at once; once one is written, opening it writes as before.
        summaries.write = writer(tries)
        summaries.summarize(workItem)
        await waitForWriting(summaries, workItem)
        #expect(tries.prompts.count == 3)
        publishWithTasks(links, status: "Completed")
        clock += StorySummaries.rewriteAfter
        await summaries.opened(workItem)
        await waitForWriting(summaries, workItem)
        #expect(tries.prompts.count == 4)
    }

    /// Before When came, summaries were written only when you asked: whoever had them on then keeps that; whoever turns
    /// them on later has them written as they open things. Saved once, so it doesn't change later.
    @Test func whoHadSummariesOnKeepsThemWrittenOnlyWhenTheyAsk() {
        let links = Links(defaults: MemoryDefaults(), isDemo: false)
        let before = MemoryDefaults()
        before.set(true, forKey: StorySummaries.enabledKey)
        let theirs = StorySummaries(defaults: before, links: links, stories: ItemStories(links: links), isDemo: false)
        #expect(theirs.isOn && !theirs.writesWhenOpened)
        #expect(before.object(forKey: StorySummaries.whenOpenedKey) as? Bool == false)
        let fresh = MemoryDefaults()
        let yours = StorySummaries(defaults: fresh, links: links, stories: ItemStories(links: links), isDemo: false)
        #expect(yours.writesWhenOpened)
        yours.setOn(true)
        #expect(StorySummaries(defaults: fresh, links: links, stories: ItemStories(links: links), isDemo: false).writesWhenOpened)
    }

    /// As the details open a thing whose summary they'll write in a moment, its card shows already, as it will be; Not Now
    /// keeps it from being written, this time; and once they stop waiting, it's gone, unless another wait took its place.
    @Test func whatsAboutToBeWrittenShowsAndNotNowKeepsIt() async {
        let (links, _, summaries) = hub()
        publishWithTasks(links)
        let asked = Asked()
        summaries.write = writer(asked)
        let acted = summaries.timesActed(on: workItem)
        let wait = summaries.expect(workItem, unlessActedSince: acted)
        #expect(wait != nil && summaries.isPending(workItem))
        // Opened again meanwhile: the first wait ending says nothing.
        let again = summaries.expect(workItem, unlessActedSince: acted)
        summaries.stopExpecting(workItem, wait)
        #expect(summaries.isPending(workItem))
        summaries.stopExpecting(workItem, again)
        #expect(!summaries.isPending(workItem))
        // Not Now: nothing's written as it opened, and nothing's about to be.
        _ = summaries.expect(workItem, unlessActedSince: acted)
        summaries.notNow(workItem)
        #expect(!summaries.isPending(workItem))
        await summaries.opened(workItem, unlessActedSince: acted)
        #expect(asked.prompts.isEmpty)
        // Nothing waits where a summary is there already, or where there's nothing to sum up.
        summaries.summarize(workItem)
        await waitForWriting(summaries, workItem)
        #expect(summaries.expect(workItem, unlessActedSince: nil) == nil)
        #expect(summaries.expect(.workItem(organization: "contoso", id: 1), unlessActedSince: nil) == nil)
    }

    /// One there that's out of date and old enough, or that couldn't be written a while ago, says it's about to be
    /// written again as it opens, with Not Now; one that's current, or new, doesn't.
    @Test func aRewriteAsItOpensIsAnnouncedToo() async {
        let (links, _, summaries) = hub()
        publishWithTasks(links)
        let asked = Asked()
        summaries.write = writer(asked)
        await summaries.summarizeAndWait(workItem)
        let later = { Date().addingTimeInterval(StorySummaries.rewriteAfter + 60) }
        // Current, however old: nothing to write.
        summaries.now = later
        #expect(summaries.expect(workItem, unlessActedSince: nil) == nil)
        // Out of date, but new: not yet.
        publishWithTasks(links, status: "Completed")
        summaries.now = Date.init
        #expect(summaries.isOutOfDate(workItem))
        #expect(summaries.expect(workItem, unlessActedSince: nil) == nil)
        // Out of date and old enough: about to be written again, and Not Now keeps it as it is.
        summaries.now = later
        let acted = summaries.timesActed(on: workItem)
        let wait = summaries.expect(workItem, unlessActedSince: acted)
        #expect(wait != nil && summaries.isPending(workItem))
        summaries.notNow(workItem)
        #expect(!summaries.isPending(workItem))
        await summaries.opened(workItem, unlessActedSince: acted)
        #expect(asked.prompts.count == 1)
        // One that couldn't be written: not right away, and once it's a while ago, it's about to be tried again.
        summaries.now = Date.init
        summaries.write = { _, _ in .failure(StorySummaries.Problem("Copilot took too long to answer.")) }
        await summaries.summarizeAndWait(workItem)
        #expect(summaries.expect(workItem, unlessActedSince: nil) == nil)
        summaries.now = { Date().addingTimeInterval(StorySummaries.retryAfter + 60) }
        #expect(summaries.expect(workItem, unlessActedSince: nil) != nil)
    }

    /// While its setting shows from Turn On…, nothing's written as it opens: once it's gone, it is.
    @Test func nothingsWrittenAsItOpensWhileItsSettingIsChosen() async {
        let (links, _, summaries) = hub()
        publishWithTasks(links)
        let asked = Asked()
        summaries.write = writer(asked)
        summaries.setChoosing(true)
        #expect(summaries.expect(workItem, unlessActedSince: nil) == nil)
        await summaries.opened(workItem)
        #expect(asked.prompts.isEmpty)
        summaries.setChoosing(false)
        await summaries.opened(workItem)
        await waitForWriting(summaries, workItem)
        #expect(asked.prompts.count == 1)
    }

    /// A next step that only says again what Waiting On says above it doesn't show; one that says more, is for someone
    /// else, or names something else, does.
    @Test func aNextStepWaitingOnSaysAlreadyDoesntShowTwice() {
        let waits: [ItemStory.Wait] = [
            .you("you, to complete !4091"), .people("Sam Rivera, to answer on !4102"), .copilot("Copilot, on task 5103"),
        ]
        #expect(SummaryCard.repeats("Complete !4091.", for: "you", among: waits))
        #expect(SummaryCard.repeats("Answer on !4102.", for: "Sam Rivera", among: waits))
        #expect(SummaryCard.repeats("Finish task 5103.", for: "Copilot", among: waits))
        #expect(!SummaryCard.repeats("Complete !4091 once the build on main passes again.", for: "you", among: waits))
        #expect(!SummaryCard.repeats("Complete !4091.", for: "Sam Rivera", among: waits))
        #expect(!SummaryCard.repeats("Complete !4120.", for: "you", among: waits))
        #expect(!SummaryCard.repeats("Ask Priya Shah to review it.", for: "you", among: waits))
        #expect(!SummaryCard.repeats("Complete !4091.", for: nil, among: waits))
        #expect(!SummaryCard.repeats("Complete !4091.", for: "you", among: []))
    }

    /// A summary's points show a bullet each, with their bold and code; a link only as its words, since what a model
    /// writes may come from anyone's comment.
    @Test func aSummarysPointsShowWithTheirBoldAndCodeButNoLinks() {
        let text = "- **Done:** Added `SavedItemsList`.\n* **Left:** [the docs](https://example.com/x)\nThen more\nand more."
        #expect(SummaryMarkdown.blocks(text) == [
            .point("**Done:** Added `SavedItemsList`."), .point("**Left:** [the docs](https://example.com/x)"),
            .text("Then more and more."),
        ])
        let left = SummaryMarkdown.inline("**Left:** [the docs](https://example.com/x)")
        #expect(String(left.characters) == "Left: the docs")
        #expect(left.runs.allSatisfy { $0.link == nil })
        let done = SummaryMarkdown.inline("**Done:** Added `SavedItemsList`.")
        #expect(String(done.characters) == "Done: Added SavedItemsList.")
        #expect(done.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(done.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(String(SummaryMarkdown.joined("- One\n- Two\nThree").characters) == "•  One\n•  Two\nThree")
        // Without points, it's text, as it was.
        #expect(SummaryMarkdown.blocks("Approved by Priya Shah.") == [.text("Approved by Priya Shah.")])
    }

    /// The picker says what each model costs: Apple Intelligence nothing, Haiku the least and Opus the most.
    @Test func thePickerSaysWhatEachModelCosts() {
        #expect(StorySummariesSetting.choiceTitle(StorySummaries.appleIntelligence) == "Apple Intelligence (on this Mac, free)")
        #expect(StorySummariesSetting.choiceTitle(.init(id: "claude-haiku-5.5", name: "Claude Haiku 5.5")) == "Claude Haiku 5.5 (cheapest)")
        #expect(StorySummariesSetting.choiceTitle(.init(id: "claude-opus-5.5", name: "Claude Opus 5.5"))
                == "Claude Opus 5.5 (most capable, costs the most)")
        #expect(StorySummariesSetting.choiceTitle(.init(id: "gpt-6.1-sol", name: "GPT-6.1 Sol")) == "GPT-6.1 Sol")
    }

    /// Closing one that couldn't be written again closes the one before it, kept to show again; and it's not tried again
    /// by opening it any sooner.
    @Test func closingOneThatCouldntBeWrittenAgainKeepsTheOneBefore() async {
        let (links, _, summaries) = hub()
        publishWithTasks(links)
        summaries.write = { _, _ in .success("HEADLINE: Fixed in !4091.") }
        await summaries.summarizeAndWait(workItem)
        let first = summaries.state(for: workItem)
        summaries.write = { _, _ in .failure(StorySummaries.Problem("Copilot took too long to answer.")) }
        await summaries.summarizeAndWait(workItem)
        guard case .failed? = summaries.state(for: workItem) else {
            Issue.record("Didn't fail")
            return
        }
        summaries.hide(workItem)
        #expect(summaries.isHidden(workItem))
        #expect(summaries.shownState(for: workItem) == nil)
        summaries.show(workItem)
        #expect(summaries.state(for: workItem) == first)
        #expect(summaries.previous(for: workItem) == nil)
    }

    /// Closing one while it's written again stops that, and closes the one before it, kept to show again.
    @Test func closingOneBeingWrittenAgainStopsItAndKeepsTheOneBefore() async throws {
        let (links, _, summaries) = hub()
        publishWithTasks(links)
        summaries.write = { _, _ in .success("HEADLINE: Fixed in !4091.") }
        await summaries.summarizeAndWait(workItem)
        let first = summaries.state(for: workItem)
        let gate = Gate()
        summaries.write = { _, _ in
            await gate.wait()
            return .success("HEADLINE: Completed.")
        }
        summaries.summarize(workItem)
        for _ in 0..<200 where !gate.isWaiting {
            try await Task.sleep(for: .milliseconds(5))
        }
        summaries.hide(workItem)
        #expect(summaries.isHidden(workItem))
        #expect(summaries.state(for: workItem) == first)
        #expect(summaries.previous(for: workItem) == nil)
        // The one stopped never takes its place.
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(summaries.state(for: workItem) == first)
        summaries.show(workItem)
        #expect(summaries.shownState(for: workItem) == first)
    }

    /// What you did since it opened stands: a summary you stopped, wrote, closed or showed again isn't written by
    /// itself as the details open; the next time it opens, it is.
    @Test func openingOneNeverUndoesWhatYouDidSinceItOpened() async throws {
        let (links, _, summaries) = hub()
        publishWithTasks(links)
        let asked = Asked()
        let gate = Gate()
        summaries.write = { prompt, _ in
            asked.add(prompt)
            await gate.wait()
            return .success("HEADLINE: Fixed in !4091.")
        }
        // It opens; before its moment is up, you ask for one, then stop it.
        let acted = summaries.timesActed(on: workItem)
        summaries.summarize(workItem)
        for _ in 0..<200 where !gate.isWaiting {
            try await Task.sleep(for: .milliseconds(5))
        }
        summaries.cancel(workItem)
        gate.open()
        await summaries.opened(workItem, unlessActedSince: acted)
        #expect(asked.prompts.count == 1)
        #expect(summaries.state(for: workItem) == nil)
        // Opened again, it's written.
        await summaries.opened(workItem, unlessActedSince: summaries.timesActed(on: workItem))
        await waitForWriting(summaries, workItem)
        #expect(asked.prompts.count == 2)
        // Each of these is something you did.
        let before = summaries.timesActed(on: workItem)
        summaries.hide(workItem)
        summaries.show(workItem)
        summaries.dismiss(workItem)
        #expect(summaries.timesActed(on: workItem) == before + 3)
    }

    /// Written again, the one before shows meanwhile; stopped, it's back; and once the new one's written, it's gone.
    @Test func theOneBeforeShowsWhileAnotherIsWritten() async throws {
        let (links, _, summaries) = hub()
        publish(links)
        summaries.write = { _, _ in .success("HEADLINE: Approved.") }
        await summaries.summarizeAndWait(workItem)
        let first = summaries.state(for: workItem)
        guard case .written? = first else {
            Issue.record("Not written")
            return
        }
        let gate = Gate()
        summaries.write = { _, _ in
            await gate.wait()
            return .success("HEADLINE: Completed.")
        }
        summaries.summarize(workItem)
        #expect(summaries.previous(for: workItem) == first)
        for _ in 0..<200 where !gate.isWaiting {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Stopped: the one before is back.
        summaries.cancel(workItem)
        #expect(summaries.state(for: workItem) == first)
        #expect(summaries.previous(for: workItem) == nil)
        gate.open()

        // Written: the new one replaces it.
        summaries.write = { _, _ in .success("HEADLINE: Completed.") }
        await summaries.summarizeAndWait(workItem)
        guard case .written(let summary, _, _, _)? = summaries.state(for: workItem) else {
            Issue.record("Not written again")
            return
        }
        #expect(summary.headline == "Completed.")
        #expect(summaries.previous(for: workItem) == nil)
        // One that couldn't be written keeps the one before, to show under why.
        summaries.write = { _, _ in .failure(StorySummaries.Problem("Copilot took too long to answer.")) }
        let second = summaries.state(for: workItem)
        await summaries.summarizeAndWait(workItem)
        #expect(summaries.previous(for: workItem) == second)
        summaries.dismiss(workItem)
        #expect(summaries.previous(for: workItem) == nil)
    }

    /// Lets a summary started by opening one be written.
    private func waitForWriting(_ summaries: StorySummaries, _ subject: ItemRef) async {
        for _ in 0..<400 {
            if case .writing? = summaries.state(for: subject) {
                try? await Task.sleep(for: .milliseconds(5))
            } else {
                return
            }
        }
    }

    @Test func selectedProviderIsTheOnlyOneAskedAndLocalFailuresNeverFallBack() async {
        let local = Asked()
        let cloud = Asked()
        let failure = StorySummaries.onDeviceProblem(.unavailable("Turn on Apple Intelligence."))
        let write = StorySummaries.writer(copilot: { prompt, options in
            cloud.add("\(options.model): \(prompt)")
            return .success("HEADLINE: Copilot summary.")
        }, onDevice: { prompt, _ in
            local.add(prompt)
            return .failure(failure)
        })
        let localResult = await write("Local input", .init(model: StorySummaries.appleIntelligenceModel))
        #expect(localResult == .failure(failure))
        #expect(local.prompts == ["Local input"])
        #expect(cloud.prompts.isEmpty)
        let cloudResult = await write("Cloud input", .init(model: "claude-haiku-5.5"))
        #expect(cloudResult == .success("HEADLINE: Copilot summary."))
        #expect(cloud.prompts == ["claude-haiku-5.5: Cloud input"])
        #expect(local.prompts.count == 1)
    }

    @Test func localSummaryUsesItsOwnPromptBudgetAndNoReasoningEffort() async throws {
        let (links, stories, summaries) = hub()
        publish(links)
        stories.register(.azureDevOps, kinds: [.workItem, .pullRequest]) { _ in
            ItemStory(sentence: "Active", notes: (0..<20).map {
                ItemStory.Fact("Comment \($0)", String(repeating: "A detail. ", count: 100))
            })
        }
        let local = Asked()
        let cloud = Asked()
        summaries.write = StorySummaries.writer(copilot: { prompt, options in
            #expect(options.model == "claude-haiku-5.5")
            #expect(options.effort == "low")
            cloud.add(prompt)
            return .success("HEADLINE: Cloud summary.")
        }, onDevice: { prompt, options in
            #expect(options.model == StorySummaries.appleIntelligenceModel)
            #expect(options.effort == nil)
            local.add(prompt)
            return .success("HEADLINE: Local summary.")
        })
        await summaries.summarizeAndWait(workItem)
        let localPrompt = try #require(local.prompts.first)
        #expect(localPrompt.hasPrefix("<data>\n"))
        #expect(localPrompt.hasSuffix("\n</data>"))
        #expect(localPrompt.count <= 6_000 + "<data>\n\n</data>".count)
        #expect(localPrompt.contains("Details left out for length."))
        #expect(localPrompt.contains("PULL REQUEST !4091"))
        #expect(cloud.prompts.isEmpty)
        summaries.setModel("claude-haiku-5.5")
        await summaries.summarizeAndWait(workItem)
        let cloudPrompt = try #require(cloud.prompts.first)
        #expect(cloudPrompt.hasPrefix(StorySummaryPrompt.instructions))
        #expect(cloudPrompt.count > localPrompt.count)
        #expect(local.prompts.count == 1)
        guard case .written(let summary, _, _, let model)? = summaries.state(for: workItem) else {
            Issue.record("Not written")
            return
        }
        #expect(summary.headline == "Cloud summary.")
        #expect(model == "claude-haiku-5.5")
    }

    @Test func switchingModelsStopsTheOldRequestButKeepsWrittenAttribution() async throws {
        let (links, _, summaries) = hub()
        publish(links)
        summaries.write = writer(Asked())
        await summaries.summarizeAndWait(workItem)
        summaries.setModel("claude-haiku-5.5")
        let first = summaries.state(for: workItem)
        guard case .written(_, _, _, let model)? = first else {
            Issue.record("Written summary was lost")
            return
        }
        #expect(model == StorySummaries.appleIntelligenceModel)
        #expect(summaries.attribution(for: model) == "Apple Intelligence on this Mac")

        let gate = Gate()
        let finished = Asked()
        summaries.write = { _, _ in
            await gate.wait()
            finished.add(Task.isCancelled ? "cancelled" : "not cancelled")
            return .success("HEADLINE: Late cloud response.")
        }
        summaries.summarize(workItem)
        for _ in 0..<200 where !gate.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.isWaiting)
        // Stopped, the one before is back, as it was written; the late answer never replaces it.
        summaries.setModel(StorySummaries.appleIntelligenceModel)
        #expect(summaries.state(for: workItem) == first)
        gate.open()
        for _ in 0..<200 where finished.prompts.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(finished.prompts == ["cancelled"])
        #expect(summaries.state(for: workItem) == first)
    }

    @Test func providerLabelsPrivacyAndCostsMatchTheSelectedModel() {
        let (_, _, summaries) = hub()
        #expect(summaries.actionTitle == "Summarize with Apple Intelligence")
        #expect(SummaryCard.writing(summaries) == "Summarizing with Apple Intelligence · on this Mac")
        #expect(SummaryCard.title(for: summaries.model) == "Summary by Apple Intelligence")
        let localHelp = SummarizeButton.help(for: workItem, model: "Apple Intelligence", onDevice: true)
        #expect(localHelp.contains("on this Mac"))
        #expect(localHelp.contains("no Copilot requests"))
        #expect(!localHelp.contains("1 request"))
        let localLines = StorySummariesSetting.lines(onDevice: true, writesWhenOpened: true)
        #expect(localLines.first { $0.label == "Costs" }?.text == "no Copilot requests or subscription needed.")
        #expect(localLines.first { $0.label == "Where" }?.text.contains("never Private Cloud Compute or Copilot") == true)

        summaries.models.append(.init(id: "claude-haiku-5.5", name: "Claude Haiku 5.5"))
        summaries.setModel("claude-haiku-5.5")
        #expect(summaries.actionTitle == "Summarize with Copilot")
        #expect(SummaryCard.writing(summaries) == "Summarizing with Claude Haiku 5.5 · 1 request")
        #expect(summaries.attribution(for: summaries.model) == "Claude Haiku 5.5 through GitHub Copilot")
        #expect(StorySummariesSetting.lines(onDevice: false, writesWhenOpened: true).first { $0.label == "Where" }?.text.contains("session history") == true)
    }

    @Test(arguments: [
        OnDeviceModel.Failure.unavailable("Apple Intelligence is off."),
        .unsupportedLanguage, .refused, .tooLong, .notReady, .busy, .empty, .failed,
    ])
    func everyLocalFailureHasAnActionableMessage(_ failure: OnDeviceModel.Failure) {
        let problem = StorySummaries.onDeviceProblem(failure)
        #expect(!problem.message.isEmpty)
        #expect(problem.message.contains("Apple Intelligence"))
        #expect(problem.fix == (failure == .busy || failure == .empty ? nil : .chooseModel))
        if case .unavailable(let reason) = failure { #expect(problem.message == reason) }
    }

    /// Where Apple Intelligence isn't there, as on macOS before 26, on a Mac that can't run it, or with it off, asking
    /// it is a failure that says why, never a crash. Where it is there, the test is skipped: asking would run the model.
    @Test(.enabled(if: OnDeviceModel.unavailableReason != nil, "Apple Intelligence is available here, and asking would run it."))
    func askingAppleIntelligenceWhereItIsNotAvailableSaysWhy() async {
        let answer = await StorySummaries.writeOnDevice(
            "<data>\nWORK ITEM 5110: Coupon totals round down\n</data>", .init(model: StorySummaries.appleIntelligenceModel)
        )
        // It can become available while the test runs, and then asking is allowed to work.
        guard OnDeviceModel.unavailableReason != nil else { return }
        guard case .failure(let problem) = answer else {
            Issue.record("Asking succeeded where Apple Intelligence isn't available.")
            return
        }
        #expect(!problem.message.isEmpty)
        #expect(problem.fix == .chooseModel)
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
