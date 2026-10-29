import BriefBarCore
import Foundation
import Testing
@testable import CopilotCore

private typealias Ask = SessionConversation.Ask
private typealias Turn = SessionConversation.Turn
private typealias Conversation = SessionConversation.Conversation

@Suite struct SessionConversationTests {
    private static let id = "6f0d3a85-4e2c-4b9a-8d17-9c5e2a1b3f06"

    /// What you or another session asked, and what Copilot answered, in order: not what it said as it called tools, what
    /// it and its subagents said to each other, nor the app's notices. The summary a task was called done with is an
    /// answer too, said once when its last message says the same.
    @Test func readsWhatWasAskedAndAnsweredInOrder() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            try writeLog([
                Line.sessionStart(at: t(0)),
                Line.userMessage("Add a **Save for later** button\nto each cart item.", at: t(1)),
                Line.turnStart(at: t(2)),
                Line.event("assistant.message", data: [
                    "content": "Looking at the cart first.", "toolRequests": [["toolCallId": "c1", "name": "view"]],
                ], at: t(3)),
                Line.toolStart("view", id: "c1", at: t(4)),
                Line.toolComplete(id: "c1", at: t(5)),
                Line.event(
                    "user.message", data: ["content": "Find where the cart is drawn.", "source": "agent-explore-1"], at: t(6),
                    agentId: "explore-1"
                ),
                Line.message("It's in CartPage.tsx.", at: t(7), subagent: true),
                Line.message("CartItemRow draws each item.", at: t(8), agentId: "explore-1"),
                Line.message("""
                    Added the button:

                    - Saves through `POST /api/cart/save`
                    - Hidden from guests

                    See [the pull request](https://example.com/pr/1).
                    """, at: t(9)),
                Line.turnEnd(at: t(10)),
                Line.userMessage("<system_notification>Session \"Add dark mode\" is idle.</system_notification>", at: t(11)),
                Line.event("user.message", data: ["content": "Test it with an empty cart too.", "source": "agent-1"], at: t(12)),
                Line.assistantMessage(toolCalls: ["c2"], at: t(13)),
                Line.message("Tested it with an empty cart.", at: t(14)),
                Line.taskComplete("Tested it with an empty cart.", at: t(15)),
                Line.userMessage("Push it.", at: t(16)),
                Line.message("", at: t(17)),
                Line.taskComplete("Pushed the saved-items branch.", at: t(18)),
                Line.userMessage("  ", at: t(19)),
                Line.shutdown(at: t(20)),
            ], to: paths.eventsFile(Self.id))

            let conversation = SessionConversation.read(paths: paths, id: Self.id)
            #expect(conversation == Conversation(turns: [
                Turn(
                    ask: Ask("Add a Save for later button to each cart item."),
                    answers: ["Added the button: - Saves through POST /api/cart/save - Hidden from guests. See the pull request."]
                ),
                Turn(ask: Ask("Test it with an empty cart too.", isFromAnotherSession: true), answers: [
                    "Tested it with an empty cart.",
                ]),
                Turn(ask: Ask("Push it."), answers: ["Pushed the saved-items branch."]),
            ]))
            #expect(SessionConversation.digest(conversation) == """
                You: Add a Save for later button to each cart item.
                Copilot: Added the button: - Saves through POST /api/cart/save - Hidden from guests. See the pull request.
                Another session: Test it with an empty cart too.
                Copilot: Tested it with an empty cart.
                You: Push it.
                Copilot: Pushed the saved-items branch.
                """)
            #expect(SessionConversation.digest(paths: paths, id: Self.id) == SessionConversation.digest(conversation))
        }
    }

    /// Nothing asked or answered, nothing to say: a session that only called tools, or that has no log.
    @Test func saysNothingOfASessionWhereNothingWasSaid() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            #expect(SessionConversation.digest(paths: paths, id: Self.id) == "")
            try writeLog([
                Line.sessionStart(at: t(0)),
                Line.assistantMessage(toolCalls: ["c1"], at: t(1)),
                Line.toolStart("bash", id: "c1", at: t(2)),
                Line.userMessage("Run the tests.", at: t(3), agentId: "task-1"),
                Line.message("All pass.", at: t(4), subagent: true),
            ], to: paths.eventsFile(Self.id))
            #expect(SessionConversation.read(paths: paths, id: Self.id) == Conversation())
            #expect(SessionConversation.digest(paths: paths, id: Self.id) == "")
            #expect(SessionConversation.digest(Conversation()) == "")
        }
    }

    /// A log can be huge: only its start, for what was asked first, and its end, for the latest turns, are read, and the
    /// digest says a part was left out. One no longer than both is read whole.
    @Test func readsAHugeLogByItsStartAndItsEnd() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            let filler = { (from: Double) in (0..<10).map { Line.filler(bytes: 1_000, at: t(from + Double($0))) } }
            try writeLog(
                [
                    Line.sessionStart(at: t(0)),
                    Line.userMessage("Save items for later from the cart.", at: t(1)),
                    Line.message("Here's the plan: a saved items table, and a button.", at: t(2)),
                ] + filler(10) + [
                    Line.userMessage("Add the table first.", at: t(30)),
                    Line.message("Added the table.", at: t(31)),
                ] + filler(40) + [
                    Line.userMessage("Now push it.", at: t(60)),
                    Line.taskComplete("Pushed the saved-items branch.", at: t(61)),
                ],
                to: paths.eventsFile(Self.id)
            )

            let conversation = SessionConversation.read(paths: paths, id: Self.id, headBytes: 4_000, tailBytes: 6_000)
            #expect(conversation == Conversation(
                turns: [
                    Turn(ask: Ask("Save items for later from the cart.")),
                    Turn(ask: Ask("Now push it."), answers: ["Pushed the saved-items branch."]),
                ],
                unreadBefore: 1
            ))
            #expect(SessionConversation.digest(conversation) == """
                You: Save items for later from the cart.
                (part of the conversation left out)
                You: Now push it.
                Copilot: Pushed the saved-items branch.
                """)

            #expect(SessionConversation.read(paths: paths, id: Self.id, headBytes: 10_000, tailBytes: 20_000).unreadBefore == nil)
            #expect(SessionConversation.digest(paths: paths, id: Self.id) == """
                You: Save items for later from the cart.
                Copilot: Here's the plan: a saved items table, and a button.
                You: Add the table first.
                Copilot: Added the table.
                You: Now push it.
                Copilot: Pushed the saved-items branch.
                """)
        }
    }

    /// A read starts and ends where it may: a line cut there decodes to nothing, and an answer whose turn started before
    /// the end is read from is a turn of its own. So is a line Copilot is still writing.
    @Test func aLineCutWhereAReadStartsOrEndsSaysNothing() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            let latest = [
                Line.userMessage("Add the table, with a migration, and an API to save and list items.", at: t(30)),
                Line.message("Added the table and the API.", at: t(31)),
                Line.userMessage("Push it.", at: t(40)),
                Line.message("Pushed it.", at: t(41)),
            ]
            try writeLog(
                [Line.userMessage("Save items for later.", at: t(1)), Line.message("Planned it.", at: t(2))]
                    + (0..<8).map { Line.filler(bytes: 1_000, at: t(Double(10 + $0))) } + latest,
                to: paths.eventsFile(Self.id)
            )
            try appendRaw(#"{"type":"assistant.message","data":{"content":"Still writ"#, to: paths.eventsFile(Self.id))
            let attributes = try FileManager.default.attributesOfItem(atPath: paths.eventsFile(Self.id).path)
            let size = try #require(attributes[.size] as? Int)
            let unwritten = #"{"type":"assistant.message","data":{"content":"Still writ"#.utf8.count
            let latestStart = size - unwritten - latest.reduce(0) { $0 + $1.utf8.count + 1 }

            // Its start ends in the first ask's line, and its end starts in another's.
            let conversation = SessionConversation.read(
                paths: paths, id: Self.id, headBytes: 20, tailBytes: size - latestStart - 10
            )
            #expect(conversation == Conversation(
                turns: [Turn(answers: ["Added the table and the API."]), Turn(ask: Ask("Push it."), answers: ["Pushed it."])],
                unreadBefore: 0
            ))
            #expect(SessionConversation.digest(conversation) == """
                (part of the conversation left out)
                Copilot: Added the table and the API.
                You: Push it.
                Copilot: Pushed it.
                """)

            // Its start ends in the line after the first ask.
            let first = Line.userMessage("Save items for later.", at: t(1)).utf8.count
            let read = SessionConversation.read(paths: paths, id: Self.id, headBytes: first + 10, tailBytes: 400)
            #expect(read.turns.first == Turn(ask: Ask("Save items for later.")))
            #expect(read.unreadBefore == 1)
            #expect(SessionConversation.turns(in: Data(#"ssage","data":{"content":"Cut"}}"#.utf8)).isEmpty)
        }
    }

    /// The digest fits a prompt: what was asked first, which says what the session was for, then as many of the latest
    /// turns as fit, in order, and how many were left out between.
    @Test func keepsWhatWasAskedFirstAndTheLatestTurnsThatFit() {
        let turns = (1...30).map { Turn(ask: Ask("Ask \($0)"), answers: ["Answer \($0)"]) }
        #expect(SessionConversation.digest(Conversation(turns: turns), limit: 100) == """
            You: Ask 1
            (27 earlier turns left out)
            You: Ask 29
            Copilot: Answer 29
            You: Ask 30
            Copilot: Answer 30
            """)
        #expect(SessionConversation.digest(Conversation(turns: Array(turns.prefix(2))), limit: 100) == """
            You: Ask 1
            Copilot: Answer 1
            You: Ask 2
            Copilot: Answer 2
            """)

        // As they are: each message cut short, the last answer less, and all of it at most 3,800 characters.
        let words = { (count: Int) in (1...count).map { "word\($0)" }.joined(separator: " ") }
        let long = (1...20).map { Turn(ask: Ask("Ask \($0): " + words(150)), answers: ["Answer \($0): " + words(300)]) }
        let digest = SessionConversation.digest(Conversation(turns: long))
        let lines = digest.components(separatedBy: "\n")
        #expect(digest.count <= 3_800)
        #expect(digest.count > 3_000)
        #expect(lines.first?.hasPrefix("You: Ask 1: word1 word2") == true)
        #expect(lines.allSatisfy { $0.count <= "Copilot: ".count + 1_200 })
        #expect(lines.filter { $0.hasPrefix("Copilot: ") }.dropLast().allSatisfy { $0.count <= "Copilot: ".count + 900 })
        #expect(lines.filter { $0.hasPrefix("You: ") }.allSatisfy { $0.count <= "You: ".count + 600 && $0.hasSuffix("…") })
        #expect(lines.last?.hasPrefix("Copilot: Answer 20: word1") == true)
        #expect(lines.last.map { $0.count > "Copilot: ".count + 900 } == true)
        // A turn shown in part, its last answer, isn't left out.
        let shown = lines.compactMap { $0.prefixMatch(of: /(?:You: Ask|Copilot: Answer) ([0-9]+):/).flatMap { Int($0.output.1) } }
        #expect(shown == shown.sorted())
        #expect(shown.first == 1)
        #expect(lines[1] == "(\(20 - Set(shown).count) earlier turns left out)")
    }

    /// A turn too long to fit whole shows its last answer, what was asked, then as many of its other answers as fit.
    @Test func aTurnTooLongToFitShowsItsLatestAnswers() {
        let words = { (count: Int) in (1...count).map { "word\($0)" }.joined(separator: " ") }
        let turn = Turn(ask: Ask("Roll out dark mode."), answers: (1...6).map { "Answer \($0): " + words(200) })
        let digest = SessionConversation.digest(Conversation(turns: [turn]))
        let lines = digest.components(separatedBy: "\n")
        #expect(digest.count <= 3_800)
        #expect(lines.first == "You: Roll out dark mode.")
        #expect(lines.dropFirst().map { $0.prefix(18) } == ["Copilot: Answer 4:", "Copilot: Answer 5:", "Copilot: Answer 6:"])
    }

    /// Each message is one paragraph: Markdown's links as their text, without emphasis, code marks, headings or fences,
    /// a list's items after a dash or their number, without the lines that say nothing, and a period after a block
    /// that ends without one.
    @Test func saysEachMessageAsOneParagraph() {
        #expect(SessionConversation.paragraph("""
            ## Done

            Added **Save for later** to `CartItemRow`:

            - Saves through [the API](https://example.com/api)
            * Hidden from guests
            2. Tested with an empty cart
            ---
            ```sh
            npm test
            ```
            Then push it
            """) == "Done. Added Save for later to CartItemRow: - Saves through the API - Hidden from guests 2. Tested with an "
            + "empty cart. npm test. Then push it")
        // Lines of a block, such as a paragraph wrapped short, run on.
        #expect(SessionConversation.paragraph("Saved items keep\nthe price they had.\n\n(See !4120)\n\nDone") == "Saved items "
            + "keep the price they had. (See !4120) Done")
        #expect(SessionConversation.paragraph("---\n\n```\n```") == "")
    }

    /// A session's folder is one any program running as you can write to, and BriefBar may have Full Disk Access: a link
    /// there could point it at any file, so none is followed, and nothing is read for an ID that isn't a session's.
    @Test func followsNoLinkAndReadsOnlyASessionsLog() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
            try writeLog(
                [Line.userMessage("Not the session's", at: t(1)), Line.message("Not the session's", at: t(2))],
                to: elsewhere.appendingPathComponent("events.jsonl")
            )
            let linkedLog = "47c1d8e2-9a3b-4f65-b8d0-6c2e1a9f4b08"
            try FileManager.default.createDirectory(at: paths.sessionDirectory(linkedLog), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: paths.eventsFile(linkedLog), withDestinationURL: elsewhere.appendingPathComponent("events.jsonl")
            )
            try FileManager.default.createSymbolicLink(at: paths.sessionDirectory(Self.id), withDestinationURL: elsewhere)
            #expect(SessionConversation.read(paths: paths, id: linkedLog) == Conversation())
            #expect(SessionConversation.read(paths: paths, id: Self.id) == Conversation())

            try writeLog([Line.userMessage("Not a session", at: t(1))], to: paths.eventsFile("s1"))
            for id in ["s1", "../elsewhere", "", "9d59036c-4479-437f-b4b5-20cccc53e849"] {
                #expect(SessionConversation.read(paths: paths, id: id) == Conversation(), "\(id)")
                #expect(SessionConversation.digest(paths: paths, id: id) == "", "\(id)")
            }
        }
    }
}
