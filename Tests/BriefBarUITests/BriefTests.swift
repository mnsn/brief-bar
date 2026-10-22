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

    @Test func saysTheBriefsFirstLineThenTheNewestOfWhatNeedsYouInTheWidget() {
        let lines = [
            line(.copilot, "release", .needsYou, 1),
            line(.copilot, "plan", .needsYou, 2),
            line(.teams, "launch-crew", .needsYou, 5),
            line(.azureDevOps, "checkout", .needsYou, 8),
            line(.copilot, "node", .failing, 10),
        ]
        let widget = Briefing.widgetLines(lines, rows: 2)
        #expect(widget.first?.id == "release")
        #expect(widget.needsYou.map(\.id) == ["plan", "launch-crew"])
        #expect(widget.more == 1)

        let wrongOnly = Briefing.widgetLines([line(.copilot, "node", .failing, 10)], rows: 4)
        #expect(wrongOnly.first?.id == "node")
        #expect(wrongOnly.needsYou.isEmpty && wrongOnly.more == 0)
        #expect(Briefing.widgetLines([], rows: 4).first == nil)
    }

    @Test func keepsItsOwnWordsUntilTheModelHasWritten() {
        let writer = BriefWriter(isEnabled: false)
        var asking = line(.teams, "chat", .needsYou, 1)
        asking.request = BriefRequest(prompt: "Chat: …", instructions: "…", lead: "Avery Quinn: ")
        writer.write([asking], for: List())
        #expect(writer.text(for: asking).text == "chat.")
        #expect(!writer.text(for: asking).isWritten)
        // A line that asks for nothing is done at once.
        #expect(writer.isDone(with: [line(.copilot, "plain", .done, 1)]))

        // What the model already wrote for it, such as a chat's summary, is said as it is, and not asked for again.
        var summarized = line(.teams, "summarized", .needsYou, 1)
        summarized.written = "Avery Quinn: The deck is in the shared folder."
        #expect(writer.text(for: summarized) == ("Avery Quinn: The deck is in the shared folder.", true))
        #expect(writer.isDone(with: [summarized]))
    }

    /// A list or page that shows a brief.
    private final class List {}

    /// Stands in for the on-device model: notes what it's asked, and answers at once, or once let go.
    @MainActor
    private final class Model {
        private(set) var asked: [String] = []
        var holds = false
        private var held: [CheckedContinuation<Void, Never>] = []

        func respond(_ request: BriefRequest) async -> Result<String, OnDeviceModel.Failure> {
            asked.append(request.prompt)
            if holds {
                await withCheckedContinuation { held.append($0) }
            }
            return .success("Written for \(request.prompt).")
        }

        func letGo() {
            holds = false
            let waiting = held
            held = []
            waiting.forEach { $0.resume() }
        }
    }

    private func asking(_ prompt: String) -> BriefLine {
        var asking = line(.teams, prompt, .needsYou, 1)
        asking.request = BriefRequest(prompt: prompt, instructions: "…", lead: "Avery Quinn: ")
        return asking
    }

    /// Lets the writer's work on the main actor go on until `done`, or a second goes by.
    private func settle(until done: () -> Bool) async {
        for _ in 0..<100 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Lets it go on for a moment, for what shouldn't happen to have the chance.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    @Test func asksTheModelOnlyForWhatsOnScreen() async {
        let model = Model()
        model.holds = true
        let writer = BriefWriter(isAvailable: { true }, respond: { await model.respond($0) })
        let list = List()
        let lines = ["first", "second", "third"].map(asking)
        writer.write(lines, for: list)
        await settle { !model.asked.isEmpty }
        // One at a time.
        #expect(model.asked == ["first"])

        // The list hides: what's still waiting isn't asked for. What was being written is kept, for when it shows again.
        writer.stop(list)
        model.letGo()
        await settle { writer.text(for: lines[0]).isWritten }
        #expect(writer.text(for: lines[0]).text == "Avery Quinn: Written for first.")
        await settle()
        #expect(model.asked == ["first"])

        // A refresh that takes a line away: it isn't asked for either.
        model.holds = true
        writer.write(Array(lines[1...]), for: list)
        await settle { model.asked.count == 2 }
        writer.write([lines[1]], for: list)
        model.letGo()
        await settle()
        #expect(model.asked == ["first", "second"])
        #expect(writer.text(for: lines[1]).isWritten && !writer.text(for: lines[2]).isWritten)

        // Nor once a list goes away without saying so.
        model.holds = true
        var other: List? = List()
        writer.write([lines[2], asking("fourth")], for: other!)
        await settle { model.asked.count == 3 }
        other = nil
        model.letGo()
        await settle()
        #expect(model.asked == ["first", "second", "third"])
        #expect(other == nil)
    }

    @Test func asksNothingWhileOffOrWithoutTheModel() async {
        let model = Model()
        let off = BriefWriter(isEnabled: false, isAvailable: { true }, respond: { await model.respond($0) })
        let unavailable = BriefWriter(isAvailable: { false }, respond: { await model.respond($0) })
        let list = List()
        off.write([asking("chat")], for: list)
        unavailable.write([asking("chat")], for: list)
        await settle()
        #expect(model.asked.isEmpty)
    }

    @Test func forgetsWhatItWroteTenMinutesAfterItsLineLeftTheScreen() async {
        let model = Model()
        let writer = BriefWriter(isAvailable: { true }, respond: { await model.respond($0) })
        let list = List()
        let other = List()
        let chat = asking("chat")
        let start = Date()
        writer.write([chat], for: list, now: start)
        await settle { writer.text(for: chat).isWritten }

        // On screen for an hour: kept.
        writer.write([], for: other, now: start.addingTimeInterval(3_600))
        #expect(writer.text(for: chat).isWritten)
        // Then off screen: kept ten minutes, for when a list shows it again, then forgotten.
        writer.stop(list, now: start.addingTimeInterval(3_600))
        writer.write([], for: other, now: start.addingTimeInterval(3_600 + BriefWriter.keepFor - 1))
        #expect(writer.text(for: chat).isWritten)
        writer.write([], for: other, now: start.addingTimeInterval(3_600 + BriefWriter.keepFor + 1))
        #expect(!writer.text(for: chat).isWritten)
        #expect(model.asked == ["chat"])
    }

    @Test func cleansWhatTheModelWrites() {
        #expect(BriefWriter.clean("Summary: “Staging is green.”\nMore text") == "Staging is green.")
        #expect(BriefWriter.clean("**Shipping** at `5`") == "Shipping at 5")
        #expect(BriefWriter.clean("  ") == nil)
        #expect(BriefWriter.clean(String(repeating: "a", count: 300))?.count == 220)
    }
}
