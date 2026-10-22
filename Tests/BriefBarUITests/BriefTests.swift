import BriefBarCore
import Foundation
import Testing
@testable import BriefBarUI

@MainActor
@Suite struct BriefTests {
    private func line(_ source: SourceID, _ id: String, _ state: ItemState, _ minutesAgo: Double?) -> BriefLine {
        BriefLine(
            id: id, source: source, state: state, date: minutesAgo.map { Date(timeIntervalSince1970: 100_000 - $0 * 60) },
            sentence: "\(id).", open: {}
        )
    }

    @Test func coversEverySourceWithSomethingToSayThenWhatsMostPressing() {
        // Copilot has the newest of everything, but each source gets its most pressing line first.
        let picked = Briefing.pick([
            line(.copilot, "release", .needsYou, 1),
            line(.copilot, "plan", .needsYou, 2),
            line(.copilot, "question", .needsYou, 4),
            line(.teams, "launch-crew", .needsYou, 5),
            line(.azureDevOps, "checkout", .needsYou, 8),
            line(.copilot, "node", .failing, 10),
            line(.azureDevOps, "coupon", .done, 30),
            line(.copilot, "readme", .done, 20),
            line(.copilot, "tests", .running, 0),
        ])
        // One of each source, then the newest wrong and done, in the order they show: by state, the newest first.
        #expect(picked.map(\.id) == ["release", "launch-crew", "checkout", "node", "readme"])
    }

    @Test func fillsWithWhatsMostPressingAndLeavesOutWhatsRunning() {
        let picked = Briefing.pick([
            line(.azureDevOps, "a", .needsYou, 3),
            line(.azureDevOps, "b", .needsYou, 1),
            line(.azureDevOps, "c", .needsYou, nil),
            line(.azureDevOps, "d", .needsYou, 2),
            line(.azureDevOps, "ready", .done, 0),
            line(.copilot, "running", .running, 0),
        ], limit: 4)
        #expect(picked.map(\.id) == ["b", "d", "a", "ready"])
        #expect(Briefing.pick([line(.copilot, "running", .running, 0)]).isEmpty)
        #expect(Briefing.pick([]).isEmpty)
    }

    @Test func keepsItsOwnWordsUntilTheModelHasWritten() {
        let writer = BriefWriter(isEnabled: false)
        var asking = line(.teams, "chat", .needsYou, 1)
        asking.request = BriefRequest(prompt: "Chat: …", instructions: "…", lead: "Avery Quinn: ")
        writer.write([asking])
        #expect(writer.text(for: asking).text == "chat.")
        #expect(!writer.text(for: asking).isWritten)
        // A line that asks for nothing is done at once.
        #expect(writer.isDone(with: [line(.copilot, "plain", .done, 1)]))
    }

    @Test func cleansWhatTheModelWrites() {
        #expect(BriefWriter.clean("Summary: “Staging is green.”\nMore text") == "Staging is green.")
        #expect(BriefWriter.clean("**Shipping** at `5`") == "Shipping at 5")
        #expect(BriefWriter.clean("  ") == nil)
        #expect(BriefWriter.clean(String(repeating: "a", count: 300))?.count == 220)
    }
}
