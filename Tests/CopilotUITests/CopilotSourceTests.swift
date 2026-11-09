import BriefBarCore
import BriefBarUI
import CopilotCore
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import CopilotUI

@MainActor
@Suite struct CopilotSourceTests {
    /// As Summarize with Copilot writes a summary, Copilot reads what was asked in each session it sums up and what Copilot
    /// answered, from the session's log, the app's sessions' and the tasks' that Azure DevOps sent alike: nothing before
    /// the source starts, for a session where nothing was said, or while Show Links is off.
    @Test func readsWhatWasSaidInASessionForASummary() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarCopilotSource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = CopilotPaths(root: folder.resolvingSymlinksInPath())
        let id = "c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11"
        try FileManager.default.createDirectory(at: paths.sessionDirectory(id), withIntermediateDirectories: true)
        try """
            {"type":"session.start","data":{"producer":"copilot-agent"},"id":"1","timestamp":"2026-10-18T10:00:00.000Z","parentId":null}
            {"type":"user.message","data":{"content":"Save items for later."},"id":"2","timestamp":"2026-10-18T10:00:01.000Z","parentId":null}
            {"type":"assistant.message","data":{"content":"Reading the cart.","toolRequests":[{"toolCallId":"c1","name":"view"}]},"id":"3","timestamp":"2026-10-18T10:00:02.000Z","parentId":null}
            {"type":"assistant.message","data":{"content":"Added a **Save for later** button.","toolRequests":[]},"id":"4","timestamp":"2026-10-18T10:00:03.000Z","parentId":null}

            """.write(to: paths.eventsFile(id), atomically: true, encoding: .utf8)

        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = CopilotSource(services: services, paths: paths)
        let session = try #require(ItemRef.session(id))
        #expect(await services.stories.context(for: [session]).isEmpty)

        source.tellStories()
        #expect(await services.stories.context(for: [session]) == [
            session: [ItemStory.Fact("Conversation", "You: Save items for later.\nCopilot: Added a Save for later button.")],
        ])
        let quiet = try #require(ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01"))
        #expect(await services.stories.context(for: [quiet]).isEmpty)

        services.links.setOn(false)
        #expect(await services.stories.context(for: [session]).isEmpty)
    }

    /// A session whose question the session coordinating it asks you: opening it opens that one, where you answer it, and
    /// opening it itself, as ↗ on its Ask… answer does on its page, opens it.
    @Test func opensARelayedSessionItselfForWhatItSaid() throws {
        let child = "5e2a9c41-7d3b-4f86-b0e1-9c4d2a7f3e21", coordinator = "8b1f4d72-3c9e-4a05-a6d8-2e7c1b9f0d32"
        let at = Date().addingTimeInterval(-60)
        var asking = SessionLogState()
        asking.apply(LogEvent(timestamp: at, kind: .userMessage))
        asking.apply(LogEvent(timestamp: at.addingTimeInterval(1), kind: .toolStart(.init(
            callId: "q", name: "ask_user", question: "Which color?"
        ))))
        var relaying = SessionLogState()
        relaying.apply(LogEvent(timestamp: at, kind: .userMessage))
        relaying.apply(LogEvent(timestamp: at.addingTimeInterval(2), kind: .toolStart(.init(
            callId: "r", name: "relay_session_input", relayedSession: "w-child"
        ))))
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: "copilot.showRelayedQuestionsOnce")
        let services = AppServices(defaults: defaults, isDemo: true)
        let source = CopilotSource(services: services, paths: nil)
        source.start()
        defer { source.stop() }
        source.store.receive(EngineSnapshot(records: [
            SessionRecord(meta: SessionMeta(id: child, name: "Pick colors", isRunning: true, workspaceId: "w-child"), log: asking),
            SessionRecord(meta: SessionMeta(id: coordinator, name: "Release 2.5", isRunning: true), log: relaying),
        ]))
        #expect(source.store.sessions.first { $0.id == child }?.answerIn?.id == coordinator)

        let item = services.links.describe(try #require(ItemRef.session(child)))
        // Where it opens it: the demo has the Copilot app.
        #expect(item.openItself?.help == "Opens the session in GitHub Copilot")
        let notes = ThisMac.Notes()
        ThisMac.$noting.withValue(notes) {
            item.open?()
            item.openItself?.perform()
        }
        #expect(notes.refused.count == 2)
        #expect(notes.refused.first?.hasPrefix("open ghapp://sessions/\(coordinator)") == true)
        #expect(notes.refused.last?.hasPrefix("open ghapp://sessions/\(child)") == true)
    }

    /// How many questions Ask… asked, and how many of them stopped.
    private final class Asked: Sendable {
        private let counts = Mutex((asked: 0, stopped: 0))
        var asked: Int { counts.withLock { $0.asked } }
        var stopped: Int { counts.withLock { $0.stopped } }
        func ask() { counts.withLock { $0.asked += 1 } }
        func stop() { counts.withLock { $0.stopped += 1 } }
    }

    /// Turning GitHub Copilot off, as `AppModel.turnOff` does: Ask… of the app's sessions stops, and what they were asked
    /// and answered goes, with an open field, as their summaries do; a task BriefBar sent keeps its own, as Azure DevOps
    /// lists it. And no source says what the app's session is anymore, so a page of it left open offers no Ask….
    @Test func turningCopilotOffForgetsWhatItsSessionsWereAsked() async throws {
        let id = "5e2a9c41-7d3b-4f86-b0e1-9c4d2a7f3e21", idle = "c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11"
        let taskID = "9a4f2b17-c3d8-4e61-b5a0-2e8d7c6b4a03"
        let services = AppServices(defaults: MemoryDefaults(), isDemo: false)
        services.links.setOn(true)
        let source = CopilotSource(services: services, paths: nil)
        source.start()
        let at = Date().addingTimeInterval(-120)
        var log = SessionLogState()
        log.apply(LogEvent(timestamp: at, kind: .userMessage))
        log.apply(LogEvent(timestamp: at.addingTimeInterval(1), kind: .turnEnd(isSubagent: false)))
        source.store.receive(EngineSnapshot(records: [
            SessionRecord(meta: SessionMeta(id: id, name: "Retry backoff", isRunning: false), log: log),
            SessionRecord(meta: SessionMeta(id: idle, name: "Save items for later", isRunning: false), log: log),
        ]))
        services.sentTasks.publish(.azureDevOps, tasks: [
            SentTask(
                id: taskID, name: "Fix Comments: !4071 Fix the checkout total", place: nil, stage: .finished, detail: nil,
                since: at, opens: "!4071", open: {}, menu: { AnyView(EmptyView()) }
            ),
        ])
        let asked = Asked()
        let asks = services.sessionAsks
        asks.setAsker { _ in
            asked.ask()
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                asked.stop()
                return .failure(SessionAsks.Problem("Stopped"))
            }
            return .success("Too late")
        }
        defer { asks.setAsker(nil) }
        let session = try #require(ItemRef.session(id)), other = try #require(ItemRef.session(idle))
        let task = try #require(ItemRef.session(taskID))
        try await Self.until("the session to be described") { services.links.isDescribed(session) }
        asks.ask(session, question: nil)
        try await Self.until("the session to be asked") { asked.asked == 1 }
        asks.useForRendering(task, question: SessionAsks.Question(
            asked: nil, askedAt: at, state: .answered("Fixed the comments."), endedAt: at
        ))
        asks.openField(for: other)
        #expect(asks.isFieldOpen(for: other))

        // As AppModel.turnOff(.copilot).
        source.stop()
        source.deleteSavedData()
        services.sessionUpdates.forget(.copilot)

        try await Self.until("what's asked to stop") { asked.stopped == 1 }
        #expect(asks.question(for: session) == nil)
        #expect(asks.field == nil)
        #expect(asks.question(for: task)?.state == .answered("Fixed the comments."))
        #expect(asks.canAsk)
        #expect(!services.links.isDescribed(session))
    }

    private struct Timeout: Error, CustomStringConvertible {
        let description: String
    }

    /// Lets the main queue deliver what the source hears until `condition` holds, for as long as a busy machine could
    /// need (`waitLimit`).
    private static func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout(description: "Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
