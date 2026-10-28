import BriefBarUI
import Foundation
import SwiftUI
import Testing
@testable import CopilotCore
@testable import CopilotUI

/// The tasks BriefBar sent to the Copilot CLI, in Copilot's list with the app's sessions: the app doesn't list them.
@MainActor
@Suite struct SentTaskListTests {
    private let now = Date()

    private func task(
        _ id: String, stage: SentTask.Stage, since: Date?, stoppedByYou: Bool = false, open: @escaping () -> Void = {}
    ) -> SentTask {
        SentTask(
            id: id, name: "Fix Comments: !4071 Fix totals", place: "shop-web", stage: stage, detail: "Run the **cart** tests",
            since: since, stoppedByYou: stoppedByYou, opens: "Pull Request", open: open, menu: { AnyView(EmptyView()) }
        )
    }

    /// One of the app's own sessions, working.
    private func appSession(_ id: String) -> SessionRecord {
        SessionRecord(meta: SessionMeta(id: id, name: "Add dark mode", isRunning: true, updatedAt: now), log: nil)
    }

    private func store(_ sent: SentTasks, settings: AppSettings = AppSettings(defaults: MemoryDefaults())) -> SessionStore {
        SessionStore(settings: settings, paths: nil, sentTasks: sent)
    }

    @Test func listsTheTasksWithTheAppsSessions() throws {
        let sent = SentTasks()
        sent.publish(.azureDevOps, tasks: [
            task("t1", stage: .working, since: now.addingTimeInterval(-60)),
            task("t2", stage: .finished, since: now.addingTimeInterval(-120)),
            task("t3", stage: .starting, since: now),
        ])
        let store = store(sent)
        store.receive(EngineSnapshot(records: [appSession("s1")]))
        #expect(store.sessions.map(\.id) == ["s1", "t3", "t1", "t2"])
        #expect(store.counts.running == 3)
        #expect(store.counts.done == 1)
        #expect(store.task(for: "t1")?.opens == "Pull Request")
        #expect(store.task(for: "s1") == nil)

        let working = try #require(store.sessions.first { $0.id == "t1" })
        #expect(working.phase == .running)
        #expect(working.headline == "Working")
        #expect(working.displayName == "Fix Comments: !4071 Fix totals")
        #expect(working.subtitle == "Working · shop-web")
        #expect(working.detail == "Run the cart tests")
        #expect(store.sessions.first { $0.id == "t3" }?.reason == .starting)
        #expect(store.sessions.first { $0.id == "t2" }?.phase == .done)
    }

    /// The app lists a task's session once you open it there: then it's the app's.
    @Test func theAppsOwnSessionWinsWhenItListsTheTasksSession() {
        let sent = SentTasks()
        sent.publish(.azureDevOps, tasks: [task("s1", stage: .working, since: now)])
        let store = store(sent)
        store.receive(EngineSnapshot(records: [appSession("s1")]))
        #expect(store.sessions.map(\.id) == ["s1"])
        #expect(store.sessions.first?.displayName == "Add dark mode")
        #expect(store.task(for: "s1") == nil)
    }

    /// Without the app's database, the list is every recent session folder, the tasks' too: those are the tasks', with
    /// what they open and their menus.
    @Test func aTasksFolderFoundWithoutTheAppsDatabaseIsTheTask() {
        let sent = SentTasks()
        sent.publish(.azureDevOps, tasks: [task("t1", stage: .working, since: now)])
        let store = store(sent)
        let folder = SessionRecord(
            meta: SessionMeta(id: "t1", name: "Session t1", sessionType: "unknown", isRunning: nil, updatedAt: now), log: nil
        )
        store.receive(EngineSnapshot(records: [folder, appSession("s1")], listedByApp: false))
        #expect(store.sessions.map(\.id).sorted() == ["s1", "t1"])
        #expect(store.task(for: "t1") != nil)
        #expect(store.sessions.first { $0.id == "t1" }?.displayName == "Fix Comments: !4071 Fix totals")
        #expect(store.task(for: "s1") == nil)
    }

    @Test(arguments: [false, true])
    func openingAFinishedTaskOnlyDismissesItWhenEnabled(_ moveViewedToIdle: Bool) throws {
        var opened = 0
        let sent = SentTasks()
        sent.publish(.azureDevOps, tasks: [task("t1", stage: .finished, since: now.addingTimeInterval(-60)) { opened += 1 }])
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.moveViewedToIdle = moveViewedToIdle
        let store = store(sent, settings: settings)
        store.receive(EngineSnapshot())
        let finished = try #require(store.sessions.first)
        #expect(finished.phase == .done)

        store.open(finished)
        #expect(opened == 1)
        #expect((settings.viewed["t1"] != nil) == moveViewedToIdle)
        #expect(settings.cleared.isEmpty)
        store.receive(EngineSnapshot())
        #expect(store.sessions.first?.phase == (moveViewedToIdle ? .idle : .done))
        #expect(store.counts.active == (moveViewedToIdle ? 0 : 1))

        settings.moveViewedToIdle = false
        store.receive(EngineSnapshot())
        #expect(store.sessions.first?.phase == .done)
        store.clear(.done)
        #expect(store.counts.done == 0)
        #expect(settings.cleared["t1"] != nil)
        sent.publish(.azureDevOps, tasks: [task("t1", stage: .finished, since: Date().addingTimeInterval(1))])
        store.receive(EngineSnapshot())
        #expect(store.sessions.first?.phase == .done)
    }

    /// A task you stopped yourself is nothing to look at; one that failed or stopped by itself stays until dismissed.
    @Test func aTaskYouStoppedIsNothingToLookAt() {
        let sent = SentTasks()
        sent.publish(.azureDevOps, tasks: [
            task("t1", stage: .stopped, since: now, stoppedByYou: true),
            task("t2", stage: .failed, since: now),
            task("t3", stage: .stopped, since: now.addingTimeInterval(-1)),
        ])
        let store = store(sent)
        store.receive(EngineSnapshot())
        #expect(store.sessions(in: .idle).map(\.id) == ["t1"])
        #expect(store.sessions(in: .stopped).map(\.id) == ["t2", "t3"])
        #expect(store.sessions.first { $0.id == "t2" }?.reason == .failed)
        #expect(store.sessions.first { $0.id == "t3" }?.reason == .interrupted)
    }

    /// Once the list starts, it follows the tasks as they're sent and end, and forgets them when it stops.
    @Test func followsTheTasksAsTheyGo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sent = SentTasks()
        let store = SessionStore(settings: AppSettings(defaults: MemoryDefaults()), paths: CopilotPaths(root: folder), sentTasks: sent)
        store.start()
        sent.publish(.azureDevOps, tasks: [task("t1", stage: .working, since: now)])
        for _ in 0..<150 where store.task(for: "t1") == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.sessions(in: .running).map(\.id) == ["t1"])

        sent.withdraw(.azureDevOps)
        for _ in 0..<150 where store.task(for: "t1") != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.sessions.isEmpty)

        sent.publish(.azureDevOps, tasks: [task("t1", stage: .working, since: now)])
        for _ in 0..<150 where store.task(for: "t1") == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        store.stop()
        #expect(store.sessions.isEmpty)
        #expect(store.task(for: "t1") == nil)
    }
}
