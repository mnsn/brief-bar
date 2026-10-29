import BriefBarUI
import CopilotCore
import Foundation
import Testing
@testable import CopilotUI

@MainActor
@Suite struct SessionStoreTests {
    private func ended(_ id: String, at date: Date, failed: Bool = false) -> SessionRecord {
        var log = SessionLogState()
        log.apply(LogEvent(timestamp: date.addingTimeInterval(-30), kind: .userMessage))
        log.apply(LogEvent(
            timestamp: date,
            kind: failed ? .sessionError(errorType: nil, message: "Failed") : .agentStop(isSubagent: false)
        ))
        return SessionRecord(meta: SessionMeta(id: id, name: id, workspaceId: id), log: log)
    }

    @Test func viewingOrReadingInCopilotDoesNotClearCompletions() {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = SessionStore(settings: settings, paths: nil)
        let at = Date().addingTimeInterval(-120)
        let records = [ended("finished", at: at), ended("stopped", at: at, failed: true)]
        for id in ["finished", "stopped"] {
            store.receive(EngineSnapshot(
                records: records,
                view: AppViewState(unreadWorkspaceIds: [], unreadUpdatedAt: Date(), viewedSessionId: id)
            ))
            #expect(store.sessions(in: .done).map(\.id) == ["finished"])
            #expect(store.sessions(in: .stopped).map(\.id) == ["stopped"])
            #expect(store.counts.done == 1)
            #expect(store.counts.stopped == 1)
            #expect(settings.cleared.isEmpty)
        }
    }

    @Test func clearPersistsOnlyTheChosenGroupAndANewRunReappears() throws {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = SessionStore(settings: settings, paths: nil)
        let at = Date().addingTimeInterval(-120)
        let records = [
            ended("first", at: at), ended("second", at: at), ended("stopped", at: at, failed: true),
        ]
        store.receive(EngineSnapshot(records: records))
        store.clear(.done)
        #expect(store.counts.done == 0)
        #expect(store.counts.stopped == 1)
        #expect(Set(settings.cleared.keys) == ["first", "second"])

        let restored = AppSettings(defaults: defaults)
        for id in ["first", "second"] {
            let original = try #require(settings.cleared[id])
            let saved = try #require(restored.cleared[id])
            #expect(abs(saved.timeIntervalSince(original)) < 0.000001)
        }
        let relaunched = SessionStore(settings: restored, paths: nil)
        relaunched.receive(EngineSnapshot(records: records))
        #expect(relaunched.counts.done == 0)
        #expect(relaunched.counts.stopped == 1)

        let nextEnd = try #require(restored.cleared["first"]).addingTimeInterval(1)
        relaunched.receive(EngineSnapshot(records: [ended("first", at: nextEnd)]))
        #expect(relaunched.sessions(in: .done).map(\.id) == ["first"])
        #expect(relaunched.sessions.first?.since == nextEnd)
    }

    @Test func oldAutomaticAcknowledgmentsDoNotSuppressRecentCompletions() {
        let defaults = MemoryDefaults(values: [
            "copilot.acknowledgedSessions": ["finished": Date().timeIntervalSince1970],
        ])
        let settings = AppSettings(defaults: defaults)
        let store = SessionStore(settings: settings, paths: nil)
        store.receive(EngineSnapshot(records: [ended("finished", at: Date().addingTimeInterval(-120))]))
        #expect(store.counts.done == 1)
        #expect(settings.cleared.isEmpty)
        #expect(settings.viewed["finished"] != nil)
        #expect(!settings.moveViewedToIdle)
        settings.moveViewedToIdle = true
        store.receive(EngineSnapshot(records: [ended("finished", at: Date().addingTimeInterval(-120))]))
        #expect(store.counts.done == 0)
    }

    @Test func openingOnlyDismissesWhileTheOptionIsOn() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        var opened: [String] = []
        let store = SessionStore(settings: settings, paths: nil, openSession: { opened.append($0) })
        let records = [
            ended("finished", at: Date().addingTimeInterval(-120)),
            ended("stopped", at: Date().addingTimeInterval(-120), failed: true),
        ]
        store.receive(EngineSnapshot(records: records))
        store.open(try #require(store.sessions(in: .done).first))
        #expect(store.counts.done == 1)
        #expect(settings.viewed.isEmpty)
        settings.moveViewedToIdle = true
        store.open(try #require(store.sessions(in: .done).first))
        store.open(try #require(store.sessions(in: .stopped).first))
        #expect(store.counts.done == 0)
        #expect(store.counts.stopped == 0)
        #expect(Set(settings.viewed.keys) == ["finished", "stopped"])
        #expect(settings.cleared.isEmpty)
        #expect(opened == ["finished", "finished", "stopped"])

        settings.moveViewedToIdle = false
        store.receive(EngineSnapshot(records: records))
        #expect(store.counts.done == 1)
        #expect(store.counts.stopped == 1)
        store.clear(.done)
        store.receive(EngineSnapshot(records: records))
        #expect(store.counts.done == 0)
    }

    /// A session's question, which the session coordinating it asks you for it: once, where you answer it.
    @Test func aQuestionAskedForAnotherSessionShowsOnceAndOpensWhereItsAsked() throws {
        let at = Date().addingTimeInterval(-60)
        var child = SessionLogState()
        child.apply(LogEvent(timestamp: at, kind: .userMessage))
        child.apply(LogEvent(timestamp: at.addingTimeInterval(1), kind: .toolStart(.init(
            callId: "q", name: "ask_user", question: "Which color?"
        ))))
        var coordinator = SessionLogState()
        coordinator.apply(LogEvent(timestamp: at, kind: .userMessage))
        coordinator.apply(LogEvent(timestamp: at.addingTimeInterval(2), kind: .toolStart(.init(
            callId: "r", name: "relay_session_input", relayedSession: "w-child"
        ))))
        let state = EngineSnapshot(records: [
            SessionRecord(meta: SessionMeta(id: "child", name: "Pick colors", isRunning: true, workspaceId: "w-child"), log: child),
            SessionRecord(meta: SessionMeta(id: "coordinator", name: "Release 2.5", isRunning: true), log: coordinator),
        ])

        var opened: [String] = []
        let store = SessionStore(settings: AppSettings(defaults: MemoryDefaults()), paths: nil, openSession: { opened.append($0) })
        store.receive(state)
        #expect(store.counts.needsYou == 1)
        #expect(store.counts.running == 1)
        let asking = try #require(store.sessions(in: .needsYou).first)
        #expect(asking.id == "coordinator")
        #expect(asking.detail == "Which color?")
        let waiting = try #require(store.sessions(in: .running).first)
        #expect(waiting.headline == "Answer in “Release 2.5”")

        store.open(waiting)
        store.open(asking)
        store.openItself(waiting)
        #expect(opened == ["coordinator", "coordinator", "child"])

        // The command line and agents see the same.
        let resolved = CopilotCommandLine.resolve(state, now: Date(), defaults: MemoryDefaults())
        #expect(resolved.map(\.id) == ["coordinator", "child"])
        #expect(resolved.map(\.phase) == [.needsYou, .running])
    }

    @Test func theOptionIsOptInAndPersists() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.moveViewedToIdle)
        settings.moveViewedToIdle = true
        #expect(AppSettings(defaults: defaults).moveViewedToIdle)
        settings.moveViewedToIdle = false
        #expect(!AppSettings(defaults: defaults).moveViewedToIdle)
    }

    @Test func commandLineAndAgentResolutionFollowTheSamePreferences() {
        let now = Date()
        let defaults = MemoryDefaults(values: [
            "copilot.keepEndedMinutes": 15,
            "copilot.acknowledgedSessions": ["viewed": now.timeIntervalSince1970],
            "copilot.clearedSessions": ["cleared": now.timeIntervalSince1970],
        ])
        let state = EngineSnapshot(records: [
            ended("viewed", at: now.addingTimeInterval(-120)),
            ended("cleared", at: now.addingTimeInterval(-120)),
            ended("expired", at: now.addingTimeInterval(-901)),
        ])
        func phases() -> [String: DisplayPhase] {
            Dictionary(uniqueKeysWithValues: CopilotCommandLine.resolve(state, now: now, defaults: defaults).map { ($0.id, $0.phase) })
        }
        #expect(phases() == ["viewed": .done, "cleared": .idle, "expired": .idle])
        defaults.set(true, forKey: "copilot.moveViewedToIdle")
        #expect(phases() == ["viewed": .idle, "cleared": .idle, "expired": .idle])
        defaults.set(false, forKey: "copilot.moveViewedToIdle")
        #expect(phases() == ["viewed": .done, "cleared": .idle, "expired": .idle])
    }

    @Test func retentionStillExpiresAndTurningOffForgetsClears() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.keepEndedMinutes = 15
        let store = SessionStore(settings: settings, paths: nil)
        store.receive(EngineSnapshot(records: [
            ended("recent", at: Date().addingTimeInterval(-120)),
            ended("expired", at: Date().addingTimeInterval(-901)),
        ]))
        #expect(store.sessions(in: .done).map(\.id) == ["recent"])
        #expect(store.sessions(in: .idle).map(\.id) == ["expired"])
        store.clear(.done)
        #expect(!settings.cleared.isEmpty)
        settings.markViewed(["expired"])
        settings.forgetDismissed()
        #expect(settings.cleared.isEmpty)
        #expect(settings.viewed.isEmpty)
        #expect(defaults.object(forKey: "copilot.clearedSessions") == nil)
        #expect(defaults.object(forKey: "copilot.acknowledgedSessions") == nil)
    }
}
