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
        let store = SessionStore(settings: settings, paths: nil, openSession: { opened.append($0) }, isAppInstalled: { true })
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

    /// With the Copilot app on this Mac, sessions open in it, as they always have; without it, with the Copilot CLI. It's
    /// looked at again on each click, in case you installed or removed it since.
    @Test func opensInTheAppWhenItsInstalledAndWithTheCLIWithout() throws {
        let app = InstalledApp()
        var inApp: [String] = []
        var withCLI: [String] = []
        let store = SessionStore(
            settings: AppSettings(defaults: MemoryDefaults()), paths: nil,
            openSession: { inApp.append($0) }, openCLISession: { withCLI.append($0) }, isAppInstalled: { app.isInstalled }
        )
        store.receive(EngineSnapshot(records: [ended("finished", at: Date().addingTimeInterval(-120))]))
        let session = try #require(store.sessions.first)
        #expect(store.appInstalled)
        store.open(session)
        #expect(inApp == ["finished"])
        #expect(withCLI.isEmpty)

        app.isInstalled = false
        store.open(session)
        #expect(!store.appInstalled)
        #expect(inApp == ["finished"])
        #expect(withCLI == ["finished"])
    }

    /// Whether the Copilot app is on this Mac, as a test installs or removes it.
    @MainActor private final class InstalledApp {
        var isInstalled = true
    }

    /// A Mac with only the Copilot CLI has no app database, which is no problem there. With the app, it's one, as before;
    /// and a database that's there but can't be read is one either way.
    @Test func saysNothingOfAMissingDatabaseOnlyWithoutTheApp() {
        let missing = EngineSnapshot(
            problem: "Could not open Copilot database: unable to open database file", listedByApp: false, databaseMissing: true
        )
        let cliOnly = SessionStore(settings: AppSettings(defaults: MemoryDefaults()), paths: nil, isAppInstalled: { false })
        cliOnly.receive(missing)
        #expect(cliOnly.problem == nil)

        let withApp = SessionStore(settings: AppSettings(defaults: MemoryDefaults()), paths: nil, isAppInstalled: { true })
        withApp.receive(missing)
        #expect(withApp.problem == missing.problem)

        var unreadable = missing
        unreadable.databaseMissing = false
        cliOnly.receive(unreadable)
        #expect(cliOnly.problem == unreadable.problem)
    }

    /// Without the app, a session a Copilot CLI still has open is in that CLI's terminal; any other is resumed.
    @Test func showsACLISessionWhereItsOpenOrResumesIt() {
        let paths = CopilotPaths(root: URL(fileURLWithPath: "/Users/robin/.copilot"))
        let id = "5d2e8a90-1f3b-4e7c-8a26-7b9c0d4e5f02"
        var asked: [URL] = []
        #expect(CLISession.way(for: id, paths: paths, holder: { asked.append($0); return 4242 }) == .show(4242))
        #expect(asked == [paths.sessionDirectory(id)])
        #expect(CLISession.way(for: id, paths: paths, holder: { _ in nil }) == .resume)
    }

    /// A session that's starting in Terminal isn't held by its CLI yet: clicking it again meanwhile starts nothing more,
    /// which would fork its history, until it's open, it couldn't be, or long enough has passed.
    @Test func opensASessionInTerminalOnceWhileItStarts() {
        var starting = CLISession.Starting()
        let now = Date()
        let window = CLISession.Starting.window
        let first = starting.begin("a", now: now)
        let again = starting.begin("a", now: now.addingTimeInterval(1))
        let another = starting.begin("b", now: now.addingTimeInterval(1))
        let stillStarting = starting.begin("a", now: now.addingTimeInterval(window - 1))
        let afterTheWindow = starting.begin("a", now: now.addingTimeInterval(window))
        starting.end("b")
        let afterItOpened = starting.begin("b", now: now.addingTimeInterval(2))
        #expect(first)
        #expect(!again)
        #expect(another)
        #expect(!stillStarting)
        #expect(afterTheWindow)
        #expect(afterItOpened)
    }

    /// Turning Copilot off removes the scripts that would have opened its sessions in Terminal but never ran, and
    /// nothing else.
    @Test func forgetsOnlyItsOwnScripts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Copilot session 5d2e8a90.command", "Copilot PR 4071.command", "Copilot session notes.txt"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        CLISession.forgetScripts(in: folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [
            "Copilot PR 4071.command", "Copilot session notes.txt",
        ])
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
