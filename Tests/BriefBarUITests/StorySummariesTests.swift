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
        // Nothing until you ask.
        #expect(asked.prompts.isEmpty)
        await summaries.summarizeAndWait(workItem)
        let prompt = try #require(asked.prompts.first)
        #expect(prompt.contains("WORK ITEM 5110: Coupon totals round down\nStatus: Active\nDescription: Totals round down."))
        #expect(prompt.contains("PULL REQUEST !4091: Fix the coupon rounding error\nLinked: Linked in Azure DevOps"))
        #expect(prompt.contains("- Comments: No open threads"))
        guard case .written(let summary, _, _, let model)? = summaries.state(for: workItem) else {
            Issue.record("Not written")
            return
        }
        #expect(summary == StorySummary(headline: "Fixed in !4091.", next: "You: complete !4091.", paragraph: "Approved."))
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
