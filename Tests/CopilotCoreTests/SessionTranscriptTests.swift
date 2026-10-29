import BriefBarCore
import Foundation
import Testing
@testable import CopilotCore

@Suite struct SessionTranscriptTests {
    private static let id = "6f0d3a85-4e2c-4b9a-8d17-9c5e2a1b3f06"

    /// The summary it called its task done with and its own last message, each with when it said it: not a subagent's
    /// message, nor one that only calls tools.
    @Test func readsCopilotsLastWordsWithWhenItSaidThem() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            try writeLog([
                Line.userMessage(at: t(1)),
                Line.message("Looking at the cart first.", at: t(2)),
                Line.taskComplete("Saved items now show under the cart.", at: t(20)),
                Line.message("Done: saved items show under the cart, with tests.", at: t(21)),
                Line.message("A subagent's report", at: t(22), subagent: true),
                Line.message("Another subagent's report", at: t(23), agentId: "explore-1"),
                Line.event("assistant.message", data: ["content": "", "toolRequests": [["toolCallId": "c1", "name": "bash"]]], at: t(24)),
                Line.shutdown(at: t(25)),
            ], to: paths.eventsFile(Self.id))

            let words = SessionTranscript.lastWords(paths: paths, id: Self.id)
            #expect(words.summary == SessionTranscript.Words(text: "Saved items now show under the cart.", date: t(20)))
            #expect(words.message == SessionTranscript.Words(text: "Done: saved items show under the cart, with tests.", date: t(21)))
            #expect(SessionTranscript.lastWords(events: paths.eventsFile(Self.id)) == words)
        }
    }

    /// A log can be large: only its end is read, so what it said before that isn't found.
    @Test func readsOnlyTheEndOfTheLog() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            let filler = (0..<20).map { Line.filler(bytes: 1_000, at: t(Double(10 + $0))) }
            try writeLog(
                [Line.taskComplete("An early summary", at: t(5))] + filler + [Line.message("Still at it.", at: t(40))],
                to: paths.eventsFile(Self.id)
            )
            let words = SessionTranscript.lastWords(paths: paths, id: Self.id, maxBytes: 8_000)
            #expect(words.summary == nil)
            #expect(words.message?.text == "Still at it.")
            #expect(SessionTranscript.lastWords(paths: paths, id: Self.id).summary?.text == "An early summary")
        }
    }

    /// A session's folder is one any program running as you can write to, and BriefBar may have Full Disk Access: a link
    /// there could point it at any file, so none is followed, and nothing is read for an ID that isn't a session's.
    @Test func followsNoLinkAndReadsOnlyASessionsLog() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
            try writeLog([Line.taskComplete("Not the session's", at: t(1))], to: elsewhere.appendingPathComponent("events.jsonl"))

            let linkedLog = "47c1d8e2-9a3b-4f65-b8d0-6c2e1a9f4b08"
            try FileManager.default.createDirectory(at: paths.sessionDirectory(linkedLog), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: paths.eventsFile(linkedLog), withDestinationURL: elsewhere.appendingPathComponent("events.jsonl")
            )
            try FileManager.default.createSymbolicLink(at: paths.sessionDirectory(Self.id), withDestinationURL: elsewhere)
            #expect(SessionTranscript.lastWords(paths: paths, id: linkedLog) == SessionTranscript.LastWords())
            #expect(SessionTranscript.lastWords(events: paths.eventsFile(linkedLog)) == SessionTranscript.LastWords())
            #expect(SessionTranscript.lastWords(paths: paths, id: Self.id) == SessionTranscript.LastWords())

            try writeLog([Line.taskComplete("Not a session", at: t(1))], to: paths.eventsFile("s1"))
            #expect(SessionTranscript.lastWords(paths: paths, id: "s1") == SessionTranscript.LastWords())
            #expect(SessionTranscript.lastWords(paths: paths, id: "../elsewhere") == SessionTranscript.LastWords())
            #expect(SessionTranscript.lastWords(paths: paths, id: "9d59036c-4479-437f-b4b5-20cccc53e849") == SessionTranscript.LastWords())
        }
    }
}
