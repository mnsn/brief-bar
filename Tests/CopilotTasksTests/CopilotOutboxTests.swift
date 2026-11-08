import BriefBarCore
import CopilotCore
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CopilotTasks

/// BriefBar's side of the outbox it shares with its extension in the Copilot app's sessions: requests as the contract has
/// them, in folders only you can open, withdrawn until claimed; results and listeners read only as the contract has them;
/// old files removed; and sending, or forking then sending, through a stand-in for the extension, without blocking.
@Suite struct CopilotOutboxTests {
    private let session = "a1111111-1111-4111-8111-11111111111f"
    private let fork = "b2222222-2222-4222-8222-22222222222e"
    private let other = "c3333333-3333-4333-8333-33333333333d"
    private let now = Date(timeIntervalSince1970: 1_790_000_000.75)

    private func outbox() throws -> (CopilotOutbox, URL) {
        let folder = try makeTemporaryDirectory()
        return (CopilotOutbox(root: folder, path: ["Outbox"]), folder)
    }

    private func mode(_ url: URL) -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return -1 }
        return Int(info.st_mode & 0o7777)
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// Writes a file as an extension would, only yours to read.
    private func write(_ fields: [String: Any], to folder: URL, named name: String, mode: mode_t = 0o600) throws {
        try FakeExtension.write(JSONSerialization.data(withJSONObject: fields), to: folder, named: name)
        chmod(folder.appendingPathComponent(name).path, mode)
    }

    // MARK: Requests

    @Test func writesRequestsAsTheContractHasThem() throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let send = OutboxRequest.send("Fix the comments\non !4071", to: session, now: now)
        try outbox.write(send)

        let requests = outbox.url.appendingPathComponent("requests")
        #expect(names(requests) == ["\(session).\(send.requestId).json"])
        #expect(mode(outbox.url) == 0o700)
        #expect(mode(requests) == 0o700)
        let file = requests.appendingPathComponent(send.fileName)
        #expect(mode(file) == 0o600)
        let fields = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(fields.keys) == ["version", "requestId", "sessionId", "kind", "prompt", "createdAt", "expiresAt"])
        #expect(fields["version"] as? Int == 1)
        #expect(fields["sessionId"] as? String == session)
        #expect(fields["kind"] as? String == "send")
        #expect(fields["prompt"] as? String == "Fix the comments\non !4071")
        #expect(AppSessions.isSessionID(send.requestId))
        // In whole seconds, exactly the longest an extension may be given apart.
        #expect(fields["createdAt"] as? String == "2026-09-21T14:13:20Z")
        #expect(fields["expiresAt"] as? String == "2026-09-21T14:15:20Z")
        // As the extension checks it.
        #expect(FakeExtension.check(file, requestId: send.requestId, sessionId: session) == nil, "it has expired by now")

        let fork = OutboxRequest.fork(session)
        try outbox.write(fork)
        let forkFile = requests.appendingPathComponent(fork.fileName)
        let forkFields = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: forkFile)) as? [String: Any])
        #expect(forkFields["kind"] as? String == "fork")
        #expect(forkFields["prompt"] == nil)
        #expect(FakeExtension.check(forkFile, requestId: fork.requestId, sessionId: session) == .init(kind: "fork", prompt: nil))
        // Nothing half written stays behind.
        #expect(names(requests).allSatisfy { !$0.hasPrefix(".") })
    }

    @Test func writesOnlyWhatTheContractAllows() throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: OutboxError.invalidRequest) { try outbox.write(.send("Fix it", to: "../elsewhere")) }
        #expect(throws: OutboxError.invalidRequest) { try outbox.write(.send("Fix it", to: session.uppercased())) }
        #expect(throws: OutboxError.invalidRequest) { try outbox.write(.send("", to: session)) }
        #expect(throws: OutboxError.tooLarge) { try outbox.write(.send(String(repeating: "x", count: 256 << 10), to: session)) }
        #expect(names(outbox.url.appendingPathComponent("requests")).isEmpty)
    }

    /// The outbox and its folders are real folders that only you can open, or BriefBar doesn't use them: not one that's
    /// another's to read, and not a symbolic link to somewhere else, which BriefBar's writes would then reach.
    @Test func usesOnlyFoldersThatOnlyYouCanOpen() throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: outbox.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(throws: OutboxError.unsafeFolder("Outbox")) { try outbox.write(.send("Fix it", to: session)) }

        chmod(outbox.url.path, 0o700)
        let elsewhere = folder.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: outbox.url.appendingPathComponent("requests"), withDestinationURL: elsewhere)
        #expect(throws: OutboxError.unsafeFolder("requests")) { try outbox.write(.send("Fix it", to: session)) }
        #expect(names(elsewhere).isEmpty)

        let linked = CopilotOutbox(root: folder, path: ["Linked"])
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Linked"), withDestinationURL: elsewhere)
        #expect(throws: OutboxError.unsafeFolder("Linked")) { try linked.write(.send("Fix it", to: session)) }
        #expect(names(elsewhere).isEmpty)
    }

    /// A request is withdrawn until its extension claims it; after that, its result is still to come.
    @Test func withdrawsARequestUntilItsClaimed() throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = OutboxRequest.send("Fix it", to: session)
        try outbox.write(first)
        #expect(outbox.isWaiting(first))
        #expect(outbox.withdraw(first))
        #expect(!outbox.isWaiting(first))
        #expect(names(outbox.url.appendingPathComponent("requests")).isEmpty)

        let second = OutboxRequest.send("Fix it", to: session)
        try outbox.write(second)
        let requests = outbox.url.appendingPathComponent("requests")
        #expect(rename(requests.appendingPathComponent(second.fileName).path, requests.appendingPathComponent(".\(second.fileName).claimed-1").path) == 0)
        #expect(!outbox.isWaiting(second))
        #expect(!outbox.withdraw(second))
    }

    // MARK: Results

    @Test func readsResultsOnlyAsTheContractHasThemAndRemovesThem() throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let results = outbox.url.appendingPathComponent("results", isDirectory: true)
        let send = OutboxRequest.send("Fix it", to: session)
        let base: [String: Any] = ["version": 1, "requestId": send.requestId, "sessionId": session, "kind": "send"]
        #expect(outbox.takeResult(of: send) == nil)

        try write(base.merging(["ok": true, "messageId": "m-1", "finishedAt": "2026-09-21T14:13:21.250Z"]) { $1 }, to: results, named: "\(send.requestId).json")
        let done = try #require(outbox.takeResult(of: send))
        #expect(done.isDone)
        #expect(done.messageId == "m-1")
        #expect(done.finishedAt == Date(timeIntervalSince1970: 1_790_000_001.25))
        // Read once: it's removed.
        #expect(outbox.takeResult(of: send) == nil)
        #expect(names(results).isEmpty)

        try write(base.merging(["ok": false, "error": ["code": "send_failed", "message": "The session\nisn't there"]]) { $1 }, to: results, named: "\(send.requestId).json")
        let failed = try #require(outbox.takeResult(of: send))
        #expect(failed.failure == .sendFailed)
        #expect(failed.message == "The session isn't there")

        try write(base.merging(["ok": false, "error": ["code": "out_of_coffee"]]) { $1 }, to: results, named: "\(send.requestId).json")
        #expect(outbox.takeResult(of: send)?.failure == .unknown)

        // Not as the contract has it: for another request, at another version, a boolean for a number, only `ok`
        // without its kind, a file others may read, or a link.
        for fields in [
            base.merging(["requestId": UUID().uuidString.lowercased(), "ok": true]) { $1 },
            base.merging(["version": 2, "ok": true]) { $1 },
            base.merging(["version": true, "ok": true]) { $1 },
            base.merging(["ok": 1]) { $1 },
            base.merging(["kind": "fork", "ok": true]) { $1 },
        ] {
            try write(fields, to: results, named: "\(send.requestId).json")
            #expect(outbox.takeResult(of: send)?.failure == .unreadable)
        }
        try write(base.merging(["ok": true]) { $1 }, to: results, named: "\(send.requestId).json", mode: 0o644)
        #expect(outbox.takeResult(of: send)?.failure == .unreadable)
        let secret = folder.appendingPathComponent("secret.json")
        try JSONSerialization.data(withJSONObject: base.merging(["ok": true]) { $1 }).write(to: secret)
        try FileManager.default.createSymbolicLink(at: results.appendingPathComponent("\(send.requestId).json"), withDestinationURL: secret)
        #expect(outbox.takeResult(of: send)?.failure == .unreadable)
        // The link is gone, and what it pointed to stays.
        #expect(names(results).isEmpty)
        #expect(FileManager.default.fileExists(atPath: secret.path))

        // A fork's names its fork, a session that isn't the one forked.
        let forking = OutboxRequest.fork(session)
        let forkBase: [String: Any] = ["version": 1, "requestId": forking.requestId, "sessionId": session, "kind": "fork", "ok": true]
        try write(forkBase.merging(["forkSessionId": fork]) { $1 }, to: results, named: "\(forking.requestId).json")
        #expect(outbox.takeResult(of: forking)?.forkSessionId == fork)
        for bad in [session, fork.uppercased(), "../\(fork)"] {
            try write(forkBase.merging(["forkSessionId": bad]) { $1 }, to: results, named: "\(forking.requestId).json")
            #expect(outbox.takeResult(of: forking)?.failure == .unreadable)
        }
    }

    // MARK: Listeners

    /// An extension listens while its process runs and started no later than it says, give or take two seconds: a process
    /// that got its ID later doesn't count.
    @Test func tellsWhetherAnExtensionStillListens() throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Reading makes nothing.
        #expect(outbox.listener(of: session) == nil)
        #expect(!FileManager.default.fileExists(atPath: outbox.url.path))

        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        try ext.listen(kinds: ["send", "fork", "dance"])
        let listener = try #require(outbox.listener(of: session))
        #expect(listener.pid == getpid())
        #expect(listener.kinds == [.send, .fork])
        #expect(CopilotOutbox.isLive(listener))

        let started = Date(timeIntervalSince1970: 1_793_000_000)
        let stale = OutboxListener(sessionId: session, pid: 4321, startedAt: started, kinds: [.send])
        #expect(CopilotOutbox.isLive(stale, isRunning: { _ in true }, startTime: { _ in started.addingTimeInterval(1.5) }))
        #expect(!CopilotOutbox.isLive(stale, isRunning: { _ in true }, startTime: { _ in started.addingTimeInterval(2.5) }))
        #expect(!CopilotOutbox.isLive(stale, isRunning: { _ in false }, startTime: { _ in started }))
        #expect(!CopilotOutbox.isLive(stale, isRunning: { _ in true }, startTime: { _ in nil }))
        // This process started long before that.
        try ext.listen(startedAt: Date().addingTimeInterval(-3 * 86_400))
        #expect(outbox.listener(of: session).map { CopilotOutbox.isLive($0) } == false)

        // Only files as the contract has them, named for their sessions.
        let listening = outbox.url.appendingPathComponent("listening")
        try write(["version": 1, "sessionId": other, "pid": 1, "startedAt": "2026-11-02T10:00:00Z", "kinds": ["send"]], to: listening, named: "\(fork).json")
        try write(["version": 1, "sessionId": other, "pid": true, "startedAt": "2026-11-02T10:00:00Z", "kinds": ["send"]], to: listening, named: "\(other).json")
        #expect(outbox.listener(of: fork) == nil)
        #expect(outbox.listener(of: other) == nil)
        ext.stopListening()
        #expect(outbox.listener(of: session) == nil)
    }

    // MARK: Cleaning up

    @Test func removesOldRequestsAndResultsButNotListeners() throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = OutboxRequest.send("Fix it", to: session)
        let recent = OutboxRequest.send("Fix it again", to: session)
        try outbox.write(old)
        try outbox.write(recent)
        let results = outbox.url.appendingPathComponent("results")
        try write(["ok": true], to: results, named: "\(old.requestId).json")
        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        try ext.listen()
        let requests = outbox.url.appendingPathComponent("requests")
        let claimed = requests.appendingPathComponent(".\(session).\(UUID().uuidString.lowercased()).claimed-77")
        try Data().write(to: claimed)
        let hourAndMore = Date().addingTimeInterval(-3_700)
        for file in [requests.appendingPathComponent(old.fileName), results.appendingPathComponent("\(old.requestId).json"), claimed] {
            try FileManager.default.setAttributes([.modificationDate: hourAndMore], ofItemAtPath: file.path)
        }

        outbox.removeOld()
        #expect(names(requests) == [recent.fileName])
        #expect(names(results).isEmpty)
        #expect(outbox.listener(of: session) != nil)

        outbox.forget()
        #expect(names(requests).isEmpty)
        #expect(outbox.listener(of: session) != nil)
    }

    /// Forgetting them, as when Azure DevOps is turned off, removes BriefBar's requests even from a folder of yours that
    /// others can open by then, which BriefBar no longer uses, and which goes too, for the next request to make it anew;
    /// and unlinks a link where their results should be, without following it. What extensions say stays, and what can't be
    /// removed, it says.
    @Test func forgetsRequestsInAFolderThatIsntOnlyYoursAnymore() throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = OutboxRequest.send("Fix it", to: session)
        try outbox.write(request)
        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        try ext.listen()
        let requests = outbox.url.appendingPathComponent("requests")
        chmod(requests.path, 0o755)
        #expect(!outbox.isWaiting(request))
        let elsewhere = folder.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: elsewhere.appendingPathComponent("keep.json"))
        let results = outbox.url.appendingPathComponent("results")
        try FileManager.default.createSymbolicLink(at: results, withDestinationURL: elsewhere)

        #expect(outbox.forget())
        #expect(!FileManager.default.fileExists(atPath: requests.path))
        #expect(mode(results) == -1)
        #expect(names(elsewhere) == ["keep.json"])
        #expect(outbox.listener(of: session) != nil)

        // The next request makes the folder anew, only yours.
        try outbox.write(request)
        #expect(mode(requests) == 0o700)
        #expect(outbox.isWaiting(request))
        // A folder in it, which neither BriefBar nor an extension makes, stays, and forgetting says so.
        try FileManager.default.createDirectory(at: requests.appendingPathComponent("stray"), withIntermediateDirectories: true)
        #expect(!outbox.forget())
        #expect(names(requests) == ["stray"])
        #expect(!outbox.isWaiting(request))
        // Nor is a folder whose names can't be read taken for an empty one: it may hold prompts still.
        let descriptor = open(requests.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(descriptor) }
        #expect(CopilotOutbox.listing(descriptor) == ["stray"])
        #expect(CopilotOutbox.listing(-1) == nil)
        #expect(CopilotOutbox.names(in: -1).isEmpty)
    }

    // MARK: Sending

    /// What a send does beyond the outbox, recorded.
    private final class Effects: Sendable {
        let opened = Mutex<[String]>([])
        let held = Mutex<Set<String>>([])
        let record = Mutex<ForkRecord>(.unreadable)
        /// How many times what the app records of a fork was read.
        let recordReads = Mutex(0)
        let onOpen = Mutex<(@Sendable (String) -> Bool)?>(nil)
        /// How far the sender's clock is ahead of the Mac's.
        let ahead = Mutex<TimeInterval>(0)
        /// Send Work to Copilot and Send Prompts to Copilot Sessions are on.
        let allowed = Mutex(true)
        /// The send is stopped as BriefBar asks whether it may go on, as when its window closes then.
        let stopsWhenAsked = Mutex(false)
        /// The forks the app's database records, made since the time asked: nil while it can't be read.
        let madeForks = Mutex<[String]?>(nil)
        /// The times the forks were asked for since.
        let forksSince = Mutex<[Date]>([])
        /// No other prompt is on its way to a fork.
        let reservable = Mutex(true)

        var sender: SessionSender.Effects {
            SessionSender.Effects(
                open: { [self] id in
                    opened.withLock { $0.append(id) }
                    return onOpen.withLock { $0 }?(id) ?? true
                },
                isHeld: { [self] id in held.withLock { $0.contains(id) } },
                forkRecord: { [self] _ in
                    recordReads.withLock { $0 += 1 }
                    return record.withLock { $0 }
                },
                forks: { [self] _, since in
                    forksSince.withLock { $0.append(since) }
                    return madeForks.withLock { $0 }
                },
                mayGoOn: { [self] in
                    if stopsWhenAsked.withLock({ $0 }) { withUnsafeCurrentTask { $0?.cancel() } }
                    return allowed.withLock { $0 }
                },
                reserve: { [self] _ in reservable.withLock { $0 } ? nil : .busy },
                now: { [self] in Date().addingTimeInterval(ahead.withLock { $0 }) }
            )
        }
    }

    private func sender(_ outbox: CopilotOutbox, _ effects: Effects, timing: SessionSender.Timing = .patient) -> SessionSender {
        SessionSender(outbox: outbox, effects: effects.sender, timing: timing)
    }

    @Test func sendsThroughTheSessionsExtension() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        try ext.listen()
        ext.start()
        defer { ext.stop() }
        let effects = Effects()
        effects.held.withLock { $0 = [session] }

        #expect(await sender(outbox, effects).send("Fix the comments", to: session) == .sent)
        #expect(ext.received == [.init(kind: "send", prompt: "Fix the comments")])
        #expect(ext.refused == 0)
        // Held already: nothing opened it.
        #expect(effects.opened.withLock { $0 }.isEmpty)
        try await Task.sleep(for: .milliseconds(30))
        #expect(names(outbox.url.appendingPathComponent("requests")).isEmpty)
        #expect(names(outbox.url.appendingPathComponent("results")).isEmpty)
    }

    /// A session that nothing holds loads as it opens in the app, with its extension, which takes the request then.
    @Test func loadsASessionThatNothingHolds() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        defer { ext.stop() }
        let effects = Effects()
        effects.onOpen.withLock {
            $0 = { [effects] id in
                effects.held.withLock { $0.insert(id) }
                try? ext.listen()
                ext.start()
                return true
            }
        }
        #expect(await sender(outbox, effects).send("Fix the comments", to: session) == .sent)
        #expect(effects.opened.withLock { $0 } == [session])
        #expect(ext.received.map(\.prompt) == ["Fix the comments"])

        // When nothing opens it, the request is withdrawn.
        ext.stop()
        ext.stopListening()
        effects.held.withLock { $0 = [] }
        effects.onOpen.withLock { $0 = { _ in false } }
        #expect(await sender(outbox, effects).send("Again", to: session) == .notSent(.notLoaded))
        #expect(names(outbox.url.appendingPathComponent("requests")).isEmpty)
        // Opened, but it never loads.
        effects.onOpen.withLock { $0 = { _ in true } }
        #expect(await sender(outbox, effects, timing: .patient.with { $0.load = 0.3 }).send("Again", to: session) == .notSent(.notLoaded))
        #expect(names(outbox.url.appendingPathComponent("requests")).isEmpty)
    }

    /// A session that a program holds without the extension, which started before it was installed, never takes it: once
    /// that's clear, the request is withdrawn, and the session isn't opened, which for a CLI's would fork its history.
    @Test func withdrawsWhatNoExtensionTakes() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let effects = Effects()
        effects.held.withLock { $0 = [session] }
        let impatient = SessionSender.Timing.patient.with {
            $0.listen = 0.3
            $0.claim = 0.3
        }
        #expect(await sender(outbox, effects, timing: impatient).send("Fix it", to: session) == .notSent(.noListener))
        #expect(effects.opened.withLock { $0 }.isEmpty)
        #expect(names(outbox.url.appendingPathComponent("requests")).isEmpty)

        // One that says it listens, but doesn't take it.
        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        try ext.listen()
        #expect(await sender(outbox, effects, timing: impatient).send("Fix it", to: session) == .notSent(.unanswered))
        #expect(names(outbox.url.appendingPathComponent("requests")).isEmpty)
    }

    /// Once claimed, a request is finished however long it takes: BriefBar waits for its result, and only once its
    /// extension seems to have ended says it can't tell.
    @Test func waitsForAClaimedRequestsResult() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        try ext.listen()
        let effects = Effects()
        effects.held.withLock { $0 = [session] }
        // As it claims it, two minutes pass: longer than an extension has to claim one.
        ext.start { [effects] _ in
            effects.ahead.withLock { $0 += 120 }
            return .after(.milliseconds(50), .done())
        }
        #expect(await sender(outbox, effects).send("Fix it", to: session) == .sent)
        ext.stop()

        let silent = FakeExtension(outbox: outbox.url, sessionId: session)
        silent.start { _ in .never }
        defer { silent.stop() }
        #expect(await sender(outbox, effects, timing: .patient.with { $0.sent = 0.5 }).send("Fix it", to: session) == .notSent(.lost))
        #expect(silent.received.count == 1)
    }

    @Test func saysWhyTheExtensionDidntSendIt() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        try ext.listen()
        ext.start { _ in .failed("send_failed", "The session ended") }
        defer { ext.stop() }
        let outcome = await sender(outbox, Effects()).send("Fix it", to: session)
        #expect(outcome == .notSent(.failed(.sendFailed, "The session ended")))
        #expect(SendFailure.failed(.sendFailed, "The session ended").description == "The session didn't take the prompt: The session ended")
        // What may have happened all the same, and so what a fallback warns of.
        let uncertain: [SendFailure] = [.lost, .failed(.sendFailed, nil), .failed(.forkFailed, nil), .failed(.unreadable, nil), .unconfirmedFork]
        #expect(uncertain.allSatisfy { $0.mayHaveGone })
        let certain: [SendFailure] = [.noListener, .notLoaded, .unanswered, .unsupported, .failed(.forkUnavailable, nil), .cancelled, .turnedOff]
        #expect(!certain.contains { $0.mayHaveGone })
    }

    /// The session's extension forks it with the app's own fork; the fork's own extension, which listens by the time the
    /// fork is made, sends the fork the prompt once the app records it as a fork of the session. The session gets no
    /// message.
    @Test func forksTheSessionThenSendsTheFork() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = FakeExtension(outbox: outbox.url, sessionId: session)
        let forked = FakeExtension(outbox: outbox.url, sessionId: fork)
        try original.listen()
        original.start { [fork] _ in
            try? forked.listen()
            forked.start()
            return .after(.milliseconds(50), .done(fork: fork))
        }
        defer {
            original.stop()
            forked.stop()
        }
        let effects = Effects()
        effects.held.withLock { $0 = [session, fork] }
        effects.record.withLock { $0 = .forked(from: session) }
        effects.madeForks.withLock { $0 = [fork] }

        #expect(await sender(outbox, effects).forkAndSend("Try it another way", from: session) == .forkedAndSent(fork: fork))
        #expect(original.received == [.init(kind: "fork", prompt: nil)])
        #expect(forked.received == [.init(kind: "send", prompt: "Try it another way")])
        // The fork opens, once its request is written.
        #expect(effects.opened.withLock { $0 } == [fork])

        // Another prompt on its way to the fork already: this one isn't written.
        effects.reservable.withLock { $0 = false }
        #expect(await sender(outbox, effects).forkAndSend("Try it", from: session) == .forkedNotSent(fork: fork, .busy))
        #expect(forked.received.count == 1)
    }

    /// BriefBar sends to the fork only once the app records it as a fork of the session made since the request, waiting
    /// while it doesn't list it yet, or its database can't be read.
    @Test func sendsOnlyToWhatTheAppRecordsAsTheFork() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = FakeExtension(outbox: outbox.url, sessionId: session)
        let forked = FakeExtension(outbox: outbox.url, sessionId: fork)
        try original.listen()
        try forked.listen()
        original.start { [fork] _ in .done(fork: fork) }
        forked.start()
        defer {
            original.stop()
            forked.stop()
        }
        let effects = Effects()
        effects.held.withLock { $0 = [session, fork] }
        let sender = sender(outbox, effects)

        effects.record.withLock { $0 = .forked(from: other) }
        effects.madeForks.withLock { $0 = [] }
        #expect(await sender.forkAndSend("Try it", from: session) == .notSent(.unconfirmedFork))
        effects.record.withLock { $0 = .notListed }
        let impatient = self.sender(outbox, effects, timing: .patient.with { $0.confirm = 0.3 })
        #expect(await impatient.forkAndSend("Try it", from: session) == .notSent(.unconfirmedFork))
        #expect(forked.received.isEmpty)

        // Listed a moment later, as the session's fork since the request.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            effects.madeForks.withLock { $0 = [fork] }
            effects.record.withLock { $0 = .forked(from: session) }
        }
        #expect(await sender.forkAndSend("Try it", from: session) == .forkedAndSent(fork: fork))
        effects.record.withLock { $0 = .unreadable }
        effects.madeForks.withLock { $0 = nil }
        #expect(await impatient.forkAndSend("Try it again", from: session) == .notSent(.unconfirmedFork))
        #expect(forked.received.map(\.prompt) == ["Try it"])
    }

    /// The session its extension names is the fork only once the app records it as a fork of the session made since the
    /// request. Its text may name another, as when the name a session was given holds another session's ID: an older fork
    /// of the session, which the one fork since gets the prompt instead of, at once; or a session that's no fork at all.
    @Test func sendsOnlyToAForkMadeSinceTheRequest() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let older = "c6666666-6666-4666-8666-66666666666d"
        let reported = Mutex(older)
        let original = FakeExtension(outbox: outbox.url, sessionId: session)
        let forked = FakeExtension(outbox: outbox.url, sessionId: fork)
        let misnamed = FakeExtension(outbox: outbox.url, sessionId: older)
        let notAFork = FakeExtension(outbox: outbox.url, sessionId: other)
        for ext in [original, forked, misnamed, notAFork] { try ext.listen() }
        original.start { _ in .done(fork: reported.withLock { $0 }) }
        for ext in [forked, misnamed, notAFork] { ext.start() }
        defer {
            for ext in [original, forked, misnamed, notAFork] { ext.stop() }
        }
        let effects = Effects()
        effects.held.withLock { $0 = [session, fork, older, other] }
        // The older fork is one of the session's, but only the new one was made since the request.
        effects.record.withLock { $0 = .forked(from: session) }
        effects.madeForks.withLock { $0 = [fork] }

        #expect(await sender(outbox, effects).forkAndSend("Try it", from: session) == .forkedAndSent(fork: fork))
        #expect(forked.received.map(\.prompt) == ["Try it"])
        #expect(misnamed.received.isEmpty)
        // Turned down at the first look, without waiting for the app to record it otherwise.
        #expect(effects.recordReads.withLock { $0 } == 1)

        // No fork at all, and none made since.
        reported.withLock { $0 = other }
        effects.record.withLock { $0 = .notAFork }
        effects.madeForks.withLock { $0 = [] }
        let impatient = sender(outbox, effects, timing: .patient.with { $0.confirm = 0.3 })
        #expect(await impatient.forkAndSend("Try it", from: session) == .notSent(.unconfirmedFork))
        #expect(notAFork.received.isEmpty)
        #expect(forked.received.count == 1)
    }

    @Test func saysWhenTheForkDidntGetThePrompt() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = FakeExtension(outbox: outbox.url, sessionId: session)
        try original.listen()
        original.start { [fork] _ in .done(fork: fork) }
        defer { original.stop() }
        let effects = Effects()
        effects.held.withLock { $0 = [session, fork] }
        effects.record.withLock { $0 = .forked(from: session) }
        effects.madeForks.withLock { $0 = [fork] }
        // The fork's runtime runs, but no extension listens in it.
        let impatient = sender(outbox, effects, timing: .patient.with { $0.listen = 0.3 })
        #expect(await impatient.forkAndSend("Try it", from: session) == .forkedNotSent(fork: fork, .noListener))
        #expect(names(outbox.url.appendingPathComponent("requests")).isEmpty)
    }

    /// Stopped, as when its window closes, a send takes its request back, unless an extension took it already.
    @Test func takesBackARequestWhenItsStopped() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        try ext.listen()
        let effects = Effects()
        effects.held.withLock { $0 = [session] }
        let sender = sender(outbox, effects)
        let sending = Task { await sender.send("Fix it", to: session) }
        let requests = outbox.url.appendingPathComponent("requests")
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while names(requests).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: FakeExtension.lookEvery)
        }
        sending.cancel()
        #expect(await sending.value == .notSent(.cancelled))
        #expect(names(requests).isEmpty)
        // Nothing's written once it's stopped.
        let stopped = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await sender.forkAndSend("Try it", from: session)
        }
        #expect(await stopped.value == .notSent(.cancelled))
        #expect(names(requests).isEmpty)
    }

    /// Once Send Work to Copilot or Send Prompts to Copilot Sessions is off, no request is written, and one that waits is
    /// taken back.
    @Test func sendsNothingOnceItsTurnedOff() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        try ext.listen()
        let effects = Effects()
        effects.held.withLock { $0 = [session] }
        effects.allowed.withLock { $0 = false }
        #expect(await sender(outbox, effects).send("Fix it", to: session) == .notSent(.turnedOff))
        #expect(names(outbox.url.appendingPathComponent("requests")).isEmpty)

        effects.allowed.withLock { $0 = true }
        let sending = Task { [sender = sender(outbox, effects)] in await sender.send("Fix it", to: session) }
        let requests = outbox.url.appendingPathComponent("requests")
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while names(requests).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: FakeExtension.lookEvery)
        }
        effects.allowed.withLock { $0 = false }
        #expect(await sending.value == .notSent(.turnedOff))
        #expect(names(requests).isEmpty)

        // Stopped while BriefBar asks: nothing's written.
        effects.allowed.withLock { $0 = true }
        effects.stopsWhenAsked.withLock { $0 = true }
        #expect(await sender(outbox, effects).send("Fix it", to: session) == .notSent(.cancelled))
        #expect(names(requests).isEmpty)
        #expect(effects.opened.withLock { $0 }.isEmpty)
    }

    /// Once an extension took it, a request goes on whatever BriefBar does: stopped, BriefBar still waits for how it went,
    /// but writes nothing more, such as the fork's prompt.
    @Test func waitsForWhatAnExtensionTookOnceItsStopped() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let effects = Effects()
        effects.held.withLock { $0 = [session, fork] }
        effects.record.withLock { $0 = .forked(from: session) }
        effects.madeForks.withLock { $0 = [fork] }
        let sender = sender(outbox, effects)
        let original = FakeExtension(outbox: outbox.url, sessionId: session)
        let forked = FakeExtension(outbox: outbox.url, sessionId: fork)
        try original.listen()
        try forked.listen()
        forked.start()
        let claimed = Mutex(false)
        // It says how it went only once BriefBar is stopped.
        let stopped = Mutex(false)
        original.start { [fork] request in
            claimed.withLock { $0 = true }
            return .once({ stopped.withLock { $0 } }, request.kind == "fork" ? .done(fork: fork) : .done())
        }
        defer {
            original.stop()
            forked.stop()
        }

        let sending = Task { await sender.send("Fix it", to: session) }
        var deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !claimed.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: FakeExtension.lookEvery)
        }
        sending.cancel()
        stopped.withLock { $0 = true }
        #expect(await sending.value == .sent)

        claimed.withLock { $0 = false }
        stopped.withLock { $0 = false }
        let forking = Task { await sender.forkAndSend("Try it", from: session) }
        deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !claimed.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: FakeExtension.lookEvery)
        }
        forking.cancel()
        stopped.withLock { $0 = true }
        #expect(await forking.value == .forkedNotSent(fork: fork, .cancelled))
        #expect(forked.received.isEmpty)
    }

    /// The extension may fork the session but not name the fork, as when it can't read the fork's ID from what the app's
    /// fork says: the one fork of the session that the app records since the request gets the prompt, as if it had. With
    /// none, or more than one, there's no telling which, so nothing's sent.
    @Test func findsTheForkItsExtensionCouldntName() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = FakeExtension(outbox: outbox.url, sessionId: session)
        let forked = FakeExtension(outbox: outbox.url, sessionId: fork)
        try original.listen()
        try forked.listen()
        original.start { _ in .failed("fork_failed", "The fork gave no session ID") }
        forked.start()
        defer {
            original.stop()
            forked.stop()
        }
        let effects = Effects()
        effects.held.withLock { $0 = [session, fork] }
        let sender = sender(outbox, effects, timing: .patient.with { $0.confirm = 0.3 })
        let before = Date()

        effects.madeForks.withLock { $0 = [fork] }
        #expect(await sender.forkAndSend("Try it another way", from: session) == .forkedAndSent(fork: fork))
        #expect(forked.received.map(\.prompt) == ["Try it another way"])
        // Made since the request started, to the instant, not to the second its file says: a fork made earlier that
        // second is none of its own.
        let since = try #require(effects.forksSince.withLock { $0.last })
        #expect(since >= before)
        #expect(since <= Date())

        let failed = SendOutcome.notSent(.failed(.forkFailed, "The fork gave no session ID"))
        effects.madeForks.withLock { $0 = [fork, other] }
        #expect(await sender.forkAndSend("Try it", from: session) == failed)
        effects.madeForks.withLock { $0 = [] }
        #expect(await sender.forkAndSend("Try it", from: session) == failed)
        // A database that can't be read is read again, then given up on.
        effects.madeForks.withLock { $0 = nil }
        #expect(await sender.forkAndSend("Try it", from: session) == failed)
        #expect(forked.received.count == 1)

        // Nor when the session can't be forked: nothing's looked for.
        original.stop()
        let unavailable = FakeExtension(outbox: outbox.url, sessionId: session)
        unavailable.start { _ in .failed("fork_unavailable", "Not offered") }
        defer { unavailable.stop() }
        effects.madeForks.withLock { $0 = [fork] }
        let asked = effects.forksSince.withLock { $0.count }
        #expect(await sender.forkAndSend("Try it", from: session) == .notSent(.failed(.forkUnavailable, "Not offered")))
        #expect(effects.forksSince.withLock { $0.count } == asked)
    }

    /// Turned off once the session's extension took the fork, BriefBar still waits for how it went, but reads nothing more
    /// of the app's database to confirm it, or to find it, and sends the fork nothing.
    @Test func readsNothingMoreOnceAForkIsTurnedOff() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let effects = Effects()
        effects.held.withLock { $0 = [session, fork] }
        effects.record.withLock { $0 = .forked(from: session) }
        effects.madeForks.withLock { $0 = [fork] }
        let sender = sender(outbox, effects)
        let original = FakeExtension(outbox: outbox.url, sessionId: session)
        let forked = FakeExtension(outbox: outbox.url, sessionId: fork)
        try original.listen()
        try forked.listen()
        forked.start()
        let claimed = Mutex(false)
        let answer = Mutex<FakeExtension.Answer>(.done(fork: fork))
        // It says how it went only once BriefBar is turned off.
        original.start { [effects] _ in
            claimed.withLock { $0 = true }
            return .once({ !effects.allowed.withLock { $0 } }, answer.withLock { $0 })
        }
        defer {
            original.stop()
            forked.stop()
        }

        for (answered, expected) in [
            (FakeExtension.Answer.done(fork: fork), SendOutcome.forkedNotSent(fork: fork, .turnedOff)),
            (.failed("fork_failed", "The fork gave no session ID"), .notSent(.turnedOff)),
        ] {
            answer.withLock { $0 = answered }
            claimed.withLock { $0 = false }
            effects.allowed.withLock { $0 = true }
            let forking = Task { await sender.forkAndSend("Try it", from: session) }
            let deadline = ContinuousClock.now.advanced(by: waitLimit)
            while !claimed.withLock({ $0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: FakeExtension.lookEvery)
            }
            effects.allowed.withLock { $0 = false }
            #expect(await forking.value == expected)
        }
        #expect(effects.recordReads.withLock { $0 } == 0)
        #expect(effects.forksSince.withLock { $0 }.isEmpty)
        #expect(forked.received.isEmpty)
    }

    /// One that the session's extension doesn't do, or that can't be forked, isn't.
    @Test func forksNothingThatCantBe() async throws {
        let (outbox, folder) = try outbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ext = FakeExtension(outbox: outbox.url, sessionId: session)
        try ext.listen(kinds: ["send"])
        ext.start()
        defer { ext.stop() }
        let effects = Effects()
        effects.held.withLock { $0 = [session] }
        #expect(await sender(outbox, effects).forkAndSend("Try it", from: session) == .notSent(.unsupported))
        #expect(names(outbox.url.appendingPathComponent("requests")).isEmpty)
        #expect(ext.received.isEmpty)

        try ext.listen()
        ext.stop()
        ext.start { _ in .failed("fork_unavailable", "fork_session isn't offered") }
        #expect(await sender(outbox, effects).forkAndSend("Try it", from: session) == .notSent(.failed(.forkUnavailable, "fork_session isn't offered")))
    }
}
