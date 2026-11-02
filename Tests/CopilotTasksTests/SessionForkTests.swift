import BriefBarCore
import CopilotCore
import Foundation
import Synchronization
import Testing
@testable import CopilotTasks

/// Messages from the Copilot CLI's server, cut out of what it writes as it comes, each after its `Content-Length`.
@Suite struct MessageReaderTests {
    private let first = Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8)
    /// With a character that takes two bytes: the length counts bytes.
    private let second = Data(#"{"jsonrpc":"2.0","method":"session.event","params":{"name":"Café"}}"#.utf8)

    @Test func cutsMessagesOutAsTheyCome() throws {
        let stream = MessageReader.frame(first)
            + Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: \(second.count)\r\n\r\n".utf8) + second
        #expect(MessageReader.frame(first) == Data("Content-Length: \(first.count)\r\n\r\n".utf8) + first)
        #expect(second.count == String(decoding: second, as: UTF8.self).count + 1)
        // A byte at a time: each message once it's whole.
        var reader = MessageReader()
        var messages: [Data] = []
        for byte in stream {
            messages += reader.read(Data([byte]))
        }
        #expect(messages == [first, second])
        // All at once, with the start of another.
        var whole = MessageReader()
        #expect(whole.read(stream + Data("Content-Len".utf8)) == [first, second])
        #expect(whole.read(Data("gth: 2\r\n\r\n{}".utf8)) == [Data("{}".utf8)])
        #expect(!whole.isMalformed)
    }

    /// What the server says unasked can carry a whole conversation: it's skipped as it comes, without being kept.
    @Test func skipsMessagesTooLongToKeep() throws {
        var reader = MessageReader(maxLength: 100)
        let long = Data(repeating: UInt8(ascii: "a"), count: 1_000)
        var messages = reader.read(MessageReader.frame(long).prefix(500))
        messages += reader.read(MessageReader.frame(long).dropFirst(500) + MessageReader.frame(first).prefix(10))
        messages += reader.read(MessageReader.frame(first).dropFirst(10))
        #expect(messages == [first])
    }

    @Test func refusesWhatIsntAHeader() {
        for stream in [
            "Content-Length: 2\r\nGarbage\r\n\r\n{}", "Content-Type: text/plain\r\n\r\n{}", "Content-Length: -1\r\n\r\n",
            "Content-Length: 2x\r\n\r\n{}", "Content-Length:\r\n\r\n", "{\"jsonrpc\":\"2.0\"}\n\r\n\r\n",
            "Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
        ] {
            var reader = MessageReader()
            #expect(reader.read(Data(stream.utf8)).isEmpty, "\(stream)")
            #expect(reader.isMalformed, "\(stream)")
        }
        // A header that never ends.
        var reader = MessageReader()
        #expect(reader.read(Data(("Content-Length: 2\r\nX-Padding: " + String(repeating: "a", count: 9_000)).utf8)).isEmpty)
        #expect(reader.isMalformed)
    }

    /// What came whole before a header that isn't one, such as the answer that says which fork the server made, is read
    /// all the same; nothing after it is.
    @Test func keepsWhatCameBeforeAHeaderThatIsntOne() {
        var reader = MessageReader()
        #expect(reader.read(MessageReader.frame(first) + Data("Not a header\r\n\r\n".utf8) + MessageReader.frame(second)) == [first])
        #expect(reader.isMalformed)
        #expect(reader.read(MessageReader.frame(second)).isEmpty)
    }
}

/// Which Copilot CLI forks a session without changing it.
@Suite struct CopilotServerVersionTests {
    private func version(_ text: String) throws -> CopilotServer.Version {
        try #require(CopilotServer.Version(text), "\(text)")
    }

    @Test func comparesVersionsAsTheCLISaysThem() throws {
        let safe = CopilotServer.forksSafelyFrom
        #expect(safe.description == "1.0.95-3")
        // Tried: these leave the session they fork as it was.
        for tried in ["1.0.95-3", "1.0.99-2", "1.0.102", "1.0.102-0.unstable.r40949665530.gab1eef5", "1.0.103", "1.0.105"] {
            #expect(try version(tried) >= safe, "\(tried)")
        }
        // These don't: 1.0.78 added a line to it, and 1.0.87 replaced its whole log with that line.
        for tried in ["1.0.78-2", "1.0.87-0", "1.0.95-2", "0.0.400"] {
            #expect(try version(tried) < safe, "\(tried)")
        }
        // A release comes after its prereleases, and numbers compare as numbers.
        #expect(try version("1.0.95") > version("1.0.95-3"))
        #expect(try version("1.0.100") > version("1.0.99"))
        #expect(try version("1.0.95-10") > version("1.0.95-9"))
        #expect(try version("2.0.0") > version("1.9.99"))
        #expect(try version("1.0.95-beta") < version("1.0.95-1"))
        for text in ["", "1.0", "1.0.x", "1.0.105.1", "v1.0.105", "1.0.105 ", "1..105"] {
            #expect(CopilotServer.Version(text) == nil, "\(text)")
        }
    }
}

/// The Copilot CLI's server, through a stand-in that speaks as it does.
@Suite struct CopilotServerTests {
    private func start(_ fixture: FakeCopilot.Fixture, grace: TimeInterval = 5) throws -> CopilotServer {
        try CopilotServer.start(fixture.copilot, environment: fixture.environment, grace: grace)
    }

    @Test(.timeLimit(.minutes(1)))
    func forksASessionAndQuitsOnceItsInputEnds() async throws {
        let fixture = try FakeCopilot.Fixture()
        defer { fixture.remove() }
        let server = try start(fixture)
        let version = try await server.connectForForking(timeout: 20)
        #expect(version.description == "1.0.105")
        #expect(try await server.fork(FakeCopilot.session, name: "Fix Comments: !4071", timeout: 20) == FakeCopilot.fork)
        #expect(await server.close() == 0)
        #expect(fixture.methods == ["connect", "sessions.fork"])
        #expect(fixture.messages.first?["jsonrpc"] as? String == "2.0")
        #expect(fixture.parameters(of: "sessions.fork") as? [String: String] == ["sessionId": FakeCopilot.session, "name": "Fix Comments: !4071"])
        // Calls once it's gone fail at once.
        await #expect(throws: CopilotServer.Failure.exited(0)) { try await server.fork(FakeCopilot.session, name: nil, timeout: 20) }
    }

    /// It asks for permission while it answers, which BriefBar refuses, and tells of its session's events, which BriefBar
    /// ignores: the answer still comes.
    @Test(.timeLimit(.minutes(1)))
    func refusesWhatTheServerAsksAndIgnoresWhatItSaysUnasked() async throws {
        let fixture = try FakeCopilot.Fixture()
        defer { fixture.remove() }
        let server = try start(fixture)
        try await server.openToAsk(FakeCopilot.fork, options: nil, timeout: 20)
        #expect(try await server.askAside("Why?", in: FakeCopilot.fork, timeout: 20) == "Sam wants the retries capped.")
        try await server.delete(FakeCopilot.fork, timeout: 20)
        await server.close()
        let refusal = try #require(fixture.messages.first { $0["id"] as? String == "server-1" })
        #expect((refusal["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(refusal["result"] == nil)
        #expect(fixture.methods == ["session.resume", "session.ui.ephemeralQuery", "session.delete"])
    }

    @Test(.timeLimit(.minutes(1)))
    func saysWhatTheServerSaid() async throws {
        let unsupported = try FakeCopilot.Fixture(["FAKE_FORK": "unsupported"])
        defer { unsupported.remove() }
        var server = try start(unsupported)
        await #expect(throws: CopilotServer.Failure.unsupported("Unhandled method sessions.fork")) {
            try await server.fork(FakeCopilot.session, name: nil, timeout: 20)
        }
        await server.close()

        // Its own words, without the server's wrapping.
        let fails = try FakeCopilot.Fixture(["FAKE_FORK": "fails"])
        defer { fails.remove() }
        server = try start(fails)
        await #expect(throws: CopilotServer.Failure.failed("Cannot fork session: no persisted or in-memory events found")) {
            try await server.fork(FakeCopilot.session, name: nil, timeout: 20)
        }
        await server.close()
    }

    /// Tried on a session the Copilot CLI 1.0.105 wrote, 1.0.87's fork replaced its whole log with one line.
    @Test(.timeLimit(.minutes(1)))
    func refusesACLITooOldToForkASessionWithoutChangingIt() async throws {
        for old in ["1.0.87-0", "1.0.78-2"] {
            let fixture = try FakeCopilot.Fixture(["FAKE_VERSION": old])
            defer { fixture.remove() }
            let server = try start(fixture)
            await #expect(throws: CopilotServer.Failure.tooOld(old)) { try await server.connectForForking(timeout: 20) }
            await server.close()
            #expect(fixture.methods == ["connect"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func givesUpOnAnAnswerThatDoesntCome() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_ANSWER": "hang"])
        defer { fixture.remove() }
        let server = try start(fixture)
        await #expect(throws: CopilotServer.Failure.timedOut) { try await server.askAside("Why?", in: FakeCopilot.fork, timeout: 0.5) }
        // It's still there for what comes next.
        try await server.delete(FakeCopilot.fork, timeout: 20)
        #expect(await server.close() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopsWaitingWhenItsTaskIsCancelled() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_ANSWER": "hang"])
        defer { fixture.remove() }
        let server = try start(fixture)
        let asking = Task { try await server.askAside("Why?", in: FakeCopilot.fork, timeout: 60) }
        for _ in 0..<2000 where !fixture.methods.contains("session.ui.ephemeralQuery") {
            try await Task.sleep(for: .milliseconds(10))
        }
        asking.cancel()
        await #expect(throws: CopilotServer.Failure.cancelled) { try await asking.value }
        // Cancelled before it's sent, nothing's sent.
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await server.fork(FakeCopilot.session, name: nil, timeout: 60)
        }
        await #expect(throws: CopilotServer.Failure.cancelled) { try await cancelled.value }
        await server.close()
        #expect(!fixture.methods.contains("sessions.fork"))
    }

    /// A fork's answer is the only word of it: once it's asked for, it's waited for, even once the task that asked is
    /// cancelled, so that the fork can be deleted.
    @Test(.timeLimit(.minutes(1)))
    func waitsForAForkEvenOnceItsTaskIsCancelled() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_FORK": "late"])
        defer { fixture.remove() }
        let server = try start(fixture)
        let forking = Task { try await server.fork(FakeCopilot.session, name: nil, timeout: 20) }
        for _ in 0..<2000 where !fixture.methods.contains("sessions.fork") {
            try await Task.sleep(for: .milliseconds(10))
        }
        forking.cancel()
        #expect(try await forking.value == FakeCopilot.fork)
        await server.close()
    }

    /// One that takes too long gives up on the server, which then finishes what it's at, and may still say which fork it
    /// made, before it quits.
    @Test(.timeLimit(.minutes(1)))
    func givesUpOnTheServerWhenAForkTakesTooLong() async throws {
        let late = try FakeCopilot.Fixture(["FAKE_FORK": "late"])
        defer { late.remove() }
        // Given up on, it has as long as it takes to answer, however busy the Mac, before it's made to stop.
        var server = try start(late, grace: 30)
        #expect(try await server.fork(FakeCopilot.session, name: nil, timeout: 0.3) == FakeCopilot.fork)
        await #expect(throws: CopilotServer.Failure.timedOut) { try await server.delete(FakeCopilot.fork, timeout: 20) }
        #expect(await server.close() == 0)

        let hung = try FakeCopilot.Fixture(["FAKE_FORK": "hang"])
        defer { hung.remove() }
        server = try start(hung)
        await #expect(throws: CopilotServer.Failure.timedOut) { try await server.fork(FakeCopilot.session, name: nil, timeout: 0.3) }
        #expect(await server.close() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func failsWhatWaitsWhenTheServerEnds() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_ANSWER": "exit"])
        defer { fixture.remove() }
        let server = try start(fixture)
        await #expect(throws: CopilotServer.Failure.exited(3)) { try await server.askAside("Why?", in: FakeCopilot.fork, timeout: 20) }
        #expect(await server.close() == 3)
    }

    /// The fork it made is handed over, though what it writes right after can't be read; nothing more is asked of it.
    @Test(.timeLimit(.minutes(1)))
    func handsOverTheForkItMadeBeforeWhatCantBeRead() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_FORK": "garbled"])
        defer { fixture.remove() }
        let server = try start(fixture)
        #expect(try await server.fork(FakeCopilot.session, name: nil, timeout: 20) == FakeCopilot.fork)
        await #expect(throws: CopilotServer.Failure.unreadable) { try await server.connectForForking(timeout: 20) }
        await server.close()
    }

    /// One that doesn't quit when its input ends is ended, with whatever it started.
    @Test(.timeLimit(.minutes(1)))
    func endsAServerThatDoesntQuit() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stubborn = folder.appendingPathComponent("copilot")
        try "#!/bin/sh\nexec sleep 30\n".write(to: stubborn, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubborn.path)
        let server = try CopilotServer.start(stubborn, environment: ["PATH": "/usr/bin:/bin"], grace: 0.3)
        #expect(await server.close() == SIGTERM)
    }

    /// What it started that ignores being asked to stop is made to, once the server itself has quit when its input
    /// ended, or when it was asked to stop.
    @Test(.timeLimit(.minutes(1)), arguments: [
        // It quits when its input ends.
        (quits: "read line; exit 0", status: Int32(0)),
        // It doesn't, and is asked to stop.
        (quits: "while :; do sleep 1; done", status: SIGTERM),
    ])
    func endsWhatTheServerStartedEvenOnceItHasQuit(_ server: (quits: String, status: Int32)) async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copilot = folder.appendingPathComponent("copilot")
        let childFile = folder.appendingPathComponent("child")
        // What it starts says who it is once it ignores being asked to stop.
        try "#!/bin/sh\n/bin/sh -c 'trap \"\" TERM; echo $$ > \"$CHILD\"; exec > /dev/null; while :; do sleep 1; done' &\n\(server.quits)\n"
            .write(to: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)
        let started = try CopilotServer.start(copilot, environment: ["PATH": "/usr/bin:/bin", "CHILD": childFile.path], grace: 0.3)
        var child: pid_t?
        for _ in 0..<2000 {
            child = (try? String(contentsOf: childFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if child != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(child)
        #expect(await started.close() == server.status)
        for _ in 0..<2000 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    /// One that quits by itself before it's closed, rather than when its input ends, takes what it started along all the
    /// same, even what ignores being asked to stop.
    @Test(.timeLimit(.minutes(1)))
    func endsWhatTheServerStartedWhenItQuitsByItself() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copilot = folder.appendingPathComponent("copilot")
        let childFile = folder.appendingPathComponent("child")
        // What it starts says who it is once it ignores being asked to stop, and then the server quits.
        try """
            #!/bin/sh
            /bin/sh -c 'trap "" TERM; echo $$ > "$CHILD"; exec > /dev/null; while :; do sleep 1; done' &
            while [ ! -s "$CHILD" ]; do sleep 0.05; done
            exit 5

            """.write(to: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)
        let server = try CopilotServer.start(copilot, environment: ["PATH": "/usr/bin:/bin", "CHILD": childFile.path], grace: 0.3)
        await #expect(throws: CopilotServer.Failure.exited(5)) { try await server.connectForForking(timeout: 20) }
        let child = (try? String(contentsOf: childFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let pid = try #require(child)
        // Without being closed, what it started is made to stop.
        for _ in 0..<2000 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(await server.close() == 5)
    }

    /// One that ignores both its input ending and being asked to stop, while BriefBar waits for a fork it may have made,
    /// is made to stop, and nothing waits for it any longer.
    @Test(.timeLimit(.minutes(1)))
    func aForkIsWaitedForOnlySoLong() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let deaf = folder.appendingPathComponent("copilot")
        let ready = folder.appendingPathComponent("ready")
        try "#!/bin/sh\ntrap '' TERM\n: > \"$READY\"\nwhile :; do sleep 1; done\n".write(to: deaf, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deaf.path)
        let server = try CopilotServer.start(deaf, environment: ["PATH": "/usr/bin:/bin", "READY": ready.path], grace: 0.3)
        for _ in 0..<2000 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = Date()
        await #expect(throws: CopilotServer.Failure.timedOut) { try await server.fork(FakeCopilot.session, name: nil, timeout: 0.3) }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(await server.close() == SIGKILL)
    }

    @Test func saysWhenItCantStart() {
        #expect(throws: CopilotServer.Failure.self) {
            try CopilotServer.start(URL(fileURLWithPath: "/nonexistent/copilot"), environment: [:])
        }
    }
}

/// A task in a fork of a session: a new session with its whole history, in a worktree of its own.
@Suite struct ForkLaunchTests {
    private let pullRequest = TaskPullRequest(
        organization: "contoso", project: "Storefront", repository: "checkout", id: 4071, title: "Fix the checkout total",
        url: URL(string: "https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071")!,
        sourceBranch: "users/robin/fix-total", targetBranch: "main"
    )

    private func launcher(_ fixture: FakeCopilot.Fixture, leftovers: (any LeftoverForks)? = nil) -> CopilotLauncher {
        let environment = fixture.environment
        let copilot = fixture.copilot
        return CopilotLauncher(
            outputFolder: fixture.folder.appendingPathComponent("output"), environment: { environment }, locate: { _ in copilot },
            appHome: fixture.home, leftovers: leftovers
        )
    }

    /// The session to fork, working in `folder`.
    private func session(in folder: URL, repository: URL) -> CopilotRun {
        CopilotRun(
            id: FakeCopilot.session, workItem: sampleItem.reference, options: CopilotModel.standard, repository: repository,
            worktree: folder, startedAt: Date(), process: DetachedProgram.Handle(pid: 0, startedAt: nil)
        )
    }

    private func launch(_ launcher: CopilotLauncher, _ request: CopilotLauncher.Request) async throws -> (CopilotRun, forked: String?) {
        let (exits, sink) = AsyncStream.makeStream(of: Int32.self)
        let forked = Mutex<String?>(nil)
        let run = try await launcher.launch(request, forked: { id in forked.withLock { $0 = id } }) { status in
            sink.yield(status)
            sink.finish()
        }
        var iterator = exits.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        return (run, forked.withLock { $0 })
    }

    private func git(_ fixture: RepositoryFixture, _ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, environment: fixture.environment, timeout: 60
        )
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test(.timeLimit(.minutes(1)))
    func forksTheSessionIntoAWorktreeAtItsCheckoutsCommit() async throws {
        let repository = try await RepositoryFixture()
        defer { repository.remove() }
        let fixture = try FakeCopilot.Fixture(in: repository.folder, base: repository.environment)
        // The session's checkout: a worktree with a commit of its own, not pushed, and a change it didn't commit.
        let checkout = repository.folder.appendingPathComponent("session-checkout")
        try await repository.git(["-C", repository.checkout.path, "worktree", "add", "--quiet", "--detach", checkout.path, "origin/main"])
        try "struct Total {}\n".write(to: checkout.appendingPathComponent("Total.swift"), atomically: true, encoding: .utf8)
        try await repository.git(["-C", checkout.path, "add", "Total.swift"])
        try await repository.git(["-C", checkout.path, "-c", "user.name=Robin Diaz", "-c", "user.email=robin@example.com", "commit", "--quiet", "-m", "Total"])
        try "draft\n".write(to: checkout.appendingPathComponent("Draft.swift"), atomically: true, encoding: .utf8)
        let head = try await git(repository, ["-C", checkout.path, "rev-parse", "HEAD"])
        let sessionLog = try Data(contentsOf: fixture.sessionLog)

        let request = CopilotLauncher.Request(
            subject: .workItem(sampleItem), prompt: "Try it with a cap", options: CopilotModel.quick, repository: repository.checkout,
            worktreesFolder: nil, forking: session(in: checkout, repository: repository.checkout)
        )
        let kept = RecordingLeftoverForks()
        let (run, forked) = try await launch(launcher(fixture, leftovers: kept), request)
        // Kept to delete from the moment it's made, should BriefBar quit first; no longer once the task has taken it on.
        #expect(await kept.calls == ["keep \(FakeCopilot.fork)", "drop \(FakeCopilot.fork)"])
        #expect(await kept.forks.isEmpty)

        // The run is the fork's, which the CLI named, and says what it forked.
        #expect(run.id == FakeCopilot.fork)
        #expect(forked == FakeCopilot.fork)
        #expect(run.forkedFrom == FakeCopilot.session)
        #expect(run.workItem == sampleItem.reference)
        #expect(run.isAppSession == nil)
        #expect(run.isValid)
        #expect(fixture.methods == ["connect", "sessions.fork"])
        #expect(fixture.parameters(of: "sessions.fork") as? [String: String] == [
            "sessionId": FakeCopilot.session, "name": "Task 4217: Show the order total in the cart",
        ])
        // In a worktree of its own, at the session's commit, with what it committed but not what it didn't.
        let worktree = repository.folder.appendingPathComponent("copilot-worktrees/checkout/wi-4217-fork")
        #expect(run.worktree.path == worktree.path)
        #expect(try await git(repository, ["-C", worktree.path, "rev-parse", "HEAD"]) == head)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("Total.swift").path))
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("Draft.swift").path))
        // The session is as it was: its log, and its checkout with its change.
        #expect(try Data(contentsOf: fixture.sessionLog) == sessionLog)
        #expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("Draft.swift").path))
        // Copilot goes on in the fork, in that worktree, under the fork's own name.
        let arguments = try String(contentsOf: fixture.arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments.first == "-p" && arguments.dropFirst().first == "Try it with a cap")
        #expect(arguments.contains("--session-id") && arguments.contains(FakeCopilot.fork))
        #expect(!arguments.contains(FakeCopilot.session))
        #expect(arguments.suffix(3) == ["-C", worktree.path, "--silent"])
        #expect(!arguments.contains("--name"))
    }

    /// Going on with a fork, the run is still that session's fork.
    @Test(.timeLimit(.minutes(1)))
    func goesOnWithAForkAsTheForkItIs() async throws {
        let repository = try await RepositoryFixture()
        defer { repository.remove() }
        let fixture = try FakeCopilot.Fixture(in: repository.folder, base: repository.environment)
        let launcher = launcher(fixture)
        let (fork, _) = try await launch(launcher, CopilotLauncher.Request(
            subject: .workItem(sampleItem), prompt: "Try it with a cap", options: CopilotModel.quick, repository: repository.checkout,
            worktreesFolder: nil, forking: session(in: repository.checkout, repository: repository.checkout)
        ))
        let (next, forked) = try await launch(launcher, CopilotLauncher.Request(
            subject: .workItem(sampleItem), prompt: "Now the tests", options: CopilotModel.quick, repository: repository.checkout,
            worktreesFolder: nil, continuing: fork
        ))
        #expect(next.id == fork.id)
        #expect(next.worktree == fork.worktree)
        #expect(next.forkedFrom == FakeCopilot.session)
        #expect(forked == nil)
        #expect(fixture.methods == ["connect", "sessions.fork"])
    }

    /// One of the Copilot app's sessions that works in a folder of repositories, or another clone: the fork starts where a
    /// new task's worktree would, at the pull request's latest commit.
    @Test(.timeLimit(.minutes(1)))
    func aForkOfASessionOutsideTheRepositoryStartsWhereANewTasksWould() async throws {
        let repository = try await RepositoryFixture()
        defer { repository.remove() }
        let seed = repository.folder.appendingPathComponent("seed")
        try await repository.git(["-C", seed.path, "checkout", "--quiet", "-b", pullRequest.sourceBranch])
        try "Storefront, with totals\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await repository.git(["-C", seed.path, "-c", "user.name=Robin Diaz", "-c", "user.email=robin@example.com", "commit", "--quiet", "-am", "Totals"])
        try await repository.git(["-C", seed.path, "push", "--quiet", repository.origin.path, pullRequest.sourceBranch])
        let remote = "https://dev.azure.com/contoso/Storefront/_git/checkout"
        try await repository.git(["-C", repository.checkout.path, "remote", "set-url", "origin", remote])
        try await repository.git(["-C", repository.checkout.path, "config", "url.\(repository.origin.path).insteadOf", remote])
        let fixture = try FakeCopilot.Fixture(in: repository.folder, base: repository.environment)
        let projects = repository.folder.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        var appSession = session(in: projects, repository: projects)
        appSession.workItem = nil
        appSession.isAppSession = true

        let request = CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .fixComments), prompt: "Fix it another way", options: CopilotModel.quick,
            repository: repository.checkout, worktreesFolder: nil, forking: appSession
        )
        let (run, _) = try await launch(launcher(fixture), request)
        let worktree = repository.folder.appendingPathComponent("copilot-worktrees/checkout/pr-4071-fork")
        #expect(run.worktree.path == worktree.path)
        #expect(try String(contentsOf: worktree.appendingPathComponent("README.md"), encoding: .utf8) == "Storefront, with totals\n")
        // A task of its own on the pull request, in BriefBar's worktree: not the app's session, and not its folder.
        #expect(run.forkedFrom == FakeCopilot.session)
        #expect(run.isAppSession == nil)
        #expect(run.onPullRequest == pullRequest.reference)
        #expect(run.workItem == nil)
        #expect(run.worksInPullRequestWorktree)
        // What fixing comments may do, it may in the fork too.
        let arguments = try String(contentsOf: fixture.arguments, encoding: .utf8)
        #expect(arguments.contains("shell(git push)"))
    }

    /// The fork has the session's whole log, which ends with its task done. If Copilot then stops before it writes
    /// anything, as when the CLI refuses its options, the task failed: it didn't finish as the session had.
    @Test(.timeLimit(.minutes(1)))
    func aForkWhoseCopilotStopsAtOnceFailedThoughTheSessionHadFinished() async throws {
        let repository = try await RepositoryFixture()
        defer { repository.remove() }
        let fixture = try FakeCopilot.Fixture(in: repository.folder, base: repository.environment, ["FAKE_RUN": "fails"])
        let history = try FileHandle(forWritingTo: fixture.sessionLog)
        try history.seekToEnd()
        try history.write(contentsOf: Data((Line.taskComplete("Capped the retries", at: 20) + "\n").utf8))
        try history.close()
        let request = CopilotLauncher.Request(
            subject: .workItem(sampleItem), prompt: "Try it with a cap", options: CopilotModel.quick, repository: repository.checkout,
            worktreesFolder: nil, forking: session(in: repository.checkout, repository: repository.checkout)
        )
        let (exits, sink) = AsyncStream.makeStream(of: Int32.self)
        let run = try await launcher(fixture).launch(request) { status in
            sink.yield(status)
            sink.finish()
        }
        var iterator = exits.makeAsyncIterator()
        let exitStatus = await iterator.next()
        #expect(exitStatus == 1)
        // The fork's log is the session's, as the CLI copied it: it says the task is done.
        let log = try #require(await RunMonitor().log(id: run.id, events: run.events(in: fixture.home)))
        #expect(log.phase == .finished)
        #expect(try Data(contentsOf: run.events(in: fixture.home)) == Data(contentsOf: fixture.sessionLog))
        let printed = try String(contentsOf: run.output(in: fixture.folder.appendingPathComponent("output")), encoding: .utf8)
        let status = RunStatus.derive(
            log: log, startedAt: run.launchedAt, isRunning: false, exitStatus: exitStatus, stoppedByYou: false, output: printed
        )
        #expect(status == RunStatus(phase: .failed, detail: "error: unknown option '--autopilot'"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aCopilotCLIThatCantForkSafelyLeavesNothingBehind() async throws {
        for (settings, reason) in [
            (["FAKE_VERSION": "1.0.87-0"], "The Copilot CLI 1.0.87-0 can't fork a session without changing it. Update it with copilot update."),
            (["FAKE_FORK": "unsupported"], "This Copilot CLI can't fork a session. Update it with copilot update."),
            (["FAKE_FORK": "fails"], "The Copilot CLI couldn't fork the session: Cannot fork session: no persisted or in-memory events found"),
        ] {
            let repository = try await RepositoryFixture()
            defer { repository.remove() }
            let fixture = try FakeCopilot.Fixture(in: repository.folder, base: repository.environment, settings)
            let request = CopilotLauncher.Request(
                subject: .workItem(sampleItem), prompt: "Fix it", options: CopilotModel.quick, repository: repository.checkout,
                worktreesFolder: nil, forking: session(in: repository.checkout, repository: repository.checkout)
            )
            await #expect(throws: LaunchError.cantFork(reason)) { try await launcher(fixture).launch(request) { _ in } }
            #expect(LaunchError.cantFork(reason).description == reason)
            #expect(!FileManager.default.fileExists(atPath: repository.folder.appendingPathComponent("copilot-worktrees").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.arguments.path))
            #expect(!fixture.methods.contains("session.delete"))
        }
    }

    /// Cancelled while the CLI forks the session, the launcher waits for the fork, deletes it, and makes nothing more.
    @Test(.timeLimit(.minutes(1)))
    func cancelledWhileTheSessionIsForkedItDeletesTheFork() async throws {
        let repository = try await RepositoryFixture()
        defer { repository.remove() }
        let fixture = try FakeCopilot.Fixture(in: repository.folder, base: repository.environment, ["FAKE_FORK": "late"])
        let request = CopilotLauncher.Request(
            subject: .workItem(sampleItem), prompt: "Fix it", options: CopilotModel.quick, repository: repository.checkout,
            worktreesFolder: nil, forking: session(in: repository.checkout, repository: repository.checkout)
        )
        let launcher = launcher(fixture)
        let launching = Task { try await launcher.launch(request) { _ in } }
        for _ in 0..<2000 where !fixture.methods.contains("sessions.fork") {
            try await Task.sleep(for: .milliseconds(10))
        }
        launching.cancel()
        await #expect(throws: LaunchError.cantFork("Forking the session was cancelled.")) { try await launching.value }
        #expect(fixture.methods == ["connect", "sessions.fork", "session.delete"])
        #expect(!FileManager.default.fileExists(atPath: repository.folder.appendingPathComponent("copilot-worktrees").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.arguments.path))
    }

    /// A fork that's no use is deleted: here, the pull request's branch is gone, so its worktree can't be made.
    @Test(.timeLimit(.minutes(1)))
    func deletesTheForkWhenItsWorktreeCantBeMade() async throws {
        let repository = try await RepositoryFixture()
        defer { repository.remove() }
        let remote = "https://dev.azure.com/contoso/Storefront/_git/checkout"
        try await repository.git(["-C", repository.checkout.path, "remote", "set-url", "origin", remote])
        try await repository.git(["-C", repository.checkout.path, "config", "url.\(repository.origin.path).insteadOf", remote])
        let fixture = try FakeCopilot.Fixture(in: repository.folder, base: repository.environment)
        let elsewhere = repository.folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let request = CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .fixComments), prompt: "Fix it", options: CopilotModel.quick,
            repository: repository.checkout, worktreesFolder: nil, forking: session(in: elsewhere, repository: elsewhere)
        )
        let kept = RecordingLeftoverForks()
        await #expect(throws: LaunchError.self) { try await launcher(fixture, leftovers: kept).launch(request) { _ in } }
        #expect(fixture.methods == ["connect", "sessions.fork", "session.delete"])
        #expect(fixture.parameters(of: "session.delete") as? [String: String] == ["sessionId": FakeCopilot.fork])
        #expect(!FileManager.default.fileExists(atPath: fixture.arguments.path))
        #expect(await kept.calls == ["keep \(FakeCopilot.fork)", "drop \(FakeCopilot.fork)"])
    }

    /// A fork that's no use and can't be deleted now is kept where BriefBar keeps its runs, and deleted before the next task,
    /// even once BriefBar has started again.
    @Test(.timeLimit(.minutes(1)))
    func keepsAForkItCouldntDeleteAndDeletesItBeforeTheNextTask() async throws {
        let repository = try await RepositoryFixture()
        defer { repository.remove() }
        let remote = "https://dev.azure.com/contoso/Storefront/_git/checkout"
        try await repository.git(["-C", repository.checkout.path, "remote", "set-url", "origin", remote])
        try await repository.git(["-C", repository.checkout.path, "config", "url.\(repository.origin.path).insteadOf", remote])
        var fixture = try FakeCopilot.Fixture(in: repository.folder, base: repository.environment)
        let busy = repository.folder.appendingPathComponent("busy")
        try Data().write(to: busy)
        fixture.environment["FAKE_DELETE_FAILS"] = busy.path
        let kept = InMemoryLeftoverForks()
        func launcher() -> CopilotLauncher {
            let environment = fixture.environment
            let copilot = fixture.copilot
            return CopilotLauncher(
                outputFolder: repository.folder.appendingPathComponent("output"), environment: { environment },
                locate: { _ in copilot }, appHome: fixture.home, leftovers: kept
            )
        }
        // The pull request's branch is gone, so the fork's worktree can't be made, and the fork can't be deleted now.
        let elsewhere = repository.folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let forking = CopilotLauncher.Request(
            subject: .pullRequest(pullRequest, .fixComments), prompt: "Fix it", options: CopilotModel.quick,
            repository: repository.checkout, worktreesFolder: nil, forking: session(in: elsewhere, repository: elsewhere)
        )
        await #expect(throws: LaunchError.self) { try await launcher().launch(forking) { _ in } }
        #expect(fixture.methods == ["connect", "sessions.fork", "session.delete"])
        #expect(await kept.leftoverForks() == [LeftoverFork(home: AppSessions.folderKey(fixture.home), id: FakeCopilot.fork)])
        #expect(FileManager.default.fileExists(atPath: fixture.forkFolder.path))

        // The next task, of any kind, deletes it first.
        try FileManager.default.removeItem(at: busy)
        _ = try await launch(launcher(), CopilotLauncher.Request(
            subject: .workItem(sampleItem), prompt: "Fix it", options: CopilotModel.quick, repository: repository.checkout,
            worktreesFolder: nil
        ))
        #expect(fixture.methods == ["connect", "sessions.fork", "session.delete", "session.delete"])
        #expect(!FileManager.default.fileExists(atPath: fixture.forkFolder.path))
        #expect(await kept.leftoverForks().isEmpty)
    }

    /// What's kept is checked first: one that isn't a session's, or whose folder is gone, is dropped without asking the
    /// CLI; one that something has open now is left for later, and so is one in another CLI's folder, should your shell's
    /// `COPILOT_HOME` have changed, until that's the CLI's folder again.
    @Test(.timeLimit(.minutes(1)))
    func deletesWhatsLeftOverOnlyOnceItsCheckedFirst() async throws {
        let fixture = try FakeCopilot.Fixture()
        defer { fixture.remove() }
        let home = AppSessions.folderKey(fixture.home)
        let gone = "3a4b5c6d-7e8f-4a0b-9c1d-2e3f4a5b6c7d"
        let open = "4b5c6d7e-8f9a-4b1c-8d2e-3f4a5b6c7d8e"
        let openFolder = fixture.home.appendingPathComponent("session-state/\(open)")
        try FileManager.default.createDirectory(at: openFolder, withIntermediateDirectories: true)
        // As a running program, this one, keeps it while it has the session open.
        try Data().write(to: openFolder.appendingPathComponent("inuse.\(getpid()).lock"))
        try FileManager.default.createDirectory(at: fixture.forkFolder, withIntermediateDirectories: true)
        let otherHome = fixture.folder.appendingPathComponent("other-copilot-home")
        let elsewhere = "5c6d7e8f-9a0b-4c2d-9e3f-4a5b6c7d8e9f"
        try FileManager.default.createDirectory(at: otherHome.appendingPathComponent("session-state/\(elsewhere)"), withIntermediateDirectories: true)
        let other = LeftoverFork(home: AppSessions.folderKey(otherHome), id: elsewhere)
        let kept = InMemoryLeftoverForks([
            LeftoverFork(home: home, id: "../../Library/Messages"), LeftoverFork(home: "copilot-home", id: gone),
            LeftoverFork(home: home, id: gone), LeftoverFork(home: home, id: open), other,
            LeftoverFork(home: home, id: FakeCopilot.fork),
        ])
        let forker = SessionForker(copilot: fixture.copilot, environment: fixture.environment, timeout: 20, leftovers: kept)

        await forker.deleteLeftovers()
        #expect(fixture.methods == ["session.delete"])
        #expect(fixture.parameters(of: "session.delete") as? [String: String] == ["sessionId": FakeCopilot.fork])
        #expect(await kept.leftoverForks() == [LeftoverFork(home: home, id: open), other])
        #expect(FileManager.default.fileExists(atPath: openFolder.path))
        #expect(FileManager.default.fileExists(atPath: otherHome.appendingPathComponent("session-state/\(elsewhere)").path))

        // With nothing to delete in its folder, nothing starts.
        try FileManager.default.removeItem(at: openFolder)
        await forker.deleteLeftovers()
        #expect(fixture.methods == ["session.delete"])
        #expect(await kept.leftoverForks() == [other])

        // Once the other folder is the CLI's again, its fork goes.
        var environment = fixture.environment
        environment["COPILOT_HOME"] = otherHome.path
        await SessionForker(copilot: fixture.copilot, environment: environment, timeout: 20, leftovers: kept).deleteLeftovers()
        #expect(fixture.methods == ["session.delete", "session.delete"])
        #expect(!FileManager.default.fileExists(atPath: otherHome.appendingPathComponent("session-state/\(elsewhere)").path))
        #expect(await kept.leftoverForks().isEmpty)
    }

    @Test func forksOnlyASessionTheCLIHas() async throws {
        let repository = try await RepositoryFixture()
        defer { repository.remove() }
        let fixture = try FakeCopilot.Fixture(in: repository.folder, base: repository.environment)
        var unknown = session(in: repository.checkout, repository: repository.checkout)
        unknown.id = "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
        let request = CopilotLauncher.Request(
            subject: .workItem(sampleItem), prompt: "Fix it", options: CopilotModel.quick, repository: repository.checkout,
            worktreesFolder: nil, forking: unknown
        )
        await #expect(throws: LaunchError.couldntStart("the Copilot CLI has no session \(unknown.id) in \(fixture.home.path)")) {
            try await launcher(fixture).launch(request) { _ in }
        }
        // Nor anything that isn't a session's ID, nor both a fork and a session to go on with.
        var stray = unknown
        stray.id = "../../Library/Messages"
        await #expect(throws: LaunchError.couldntStart("a session's ID is a lowercase UUID")) {
            try await launcher(fixture).launch(CopilotLauncher.Request(
                subject: .workItem(sampleItem), prompt: "Fix it", options: CopilotModel.quick, repository: repository.checkout,
                worktreesFolder: nil, forking: stray
            )) { _ in }
        }
        let both = CopilotLauncher.Request(
            subject: .workItem(sampleItem), prompt: "Fix it", options: CopilotModel.quick, repository: repository.checkout,
            worktreesFolder: nil, continuing: session(in: repository.checkout, repository: repository.checkout),
            forking: session(in: repository.checkout, repository: repository.checkout)
        )
        await #expect(throws: LaunchError.couldntStart("a task goes on with a session or forks one, not both")) {
            try await launcher(fixture).launch(both) { _ in }
        }
        #expect(fixture.methods.isEmpty)
    }
}

/// A side question to a session, asked of a fork of it, which is deleted after.
@Suite struct SessionQuestionsTests {
    private func questions(
        _ fixture: FakeCopilot.Fixture, finds: Bool = true, timeouts: SessionQuestions.Timeouts = .init(),
        leftovers: any LeftoverForks = InMemoryLeftoverForks()
    ) -> SessionQuestions {
        let environment = fixture.environment
        let copilot = fixture.copilot
        return SessionQuestions(
            leftovers: leftovers, loadEnvironment: { environment }, locate: { _ in finds ? copilot : nil }, timeouts: timeouts
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func asksAForkOfTheSessionWithNoToolsThenDeletesIt() async throws {
        let fixture = try FakeCopilot.Fixture()
        defer { fixture.remove() }
        let log = try Data(contentsOf: fixture.sessionLog)
        let kept = RecordingLeftoverForks()
        let answer = await questions(fixture, leftovers: kept).ask(
            "Why did Sam ask for a cap on the retries?", session: FakeCopilot.session,
            options: CopilotRunOptions(model: "claude-haiku-5.5", effort: "low")
        )
        #expect(answer == .success("Sam wants the retries capped."))
        // Kept to delete from the moment it's made, should BriefBar quit first, and no longer once it's gone.
        #expect(await kept.calls == ["keep \(FakeCopilot.fork)", "drop \(FakeCopilot.fork)"])
        #expect(fixture.methods == ["connect", "sessions.fork", "session.resume", "session.ui.ephemeralQuery", "session.delete"])
        #expect(fixture.parameters(of: "sessions.fork") as? [String: String] == ["sessionId": FakeCopilot.session, "name": "BriefBar question"])
        let resume = try #require(fixture.parameters(of: "session.resume"))
        #expect(resume["sessionId"] as? String == FakeCopilot.fork)
        #expect(resume["model"] as? String == "claude-haiku-5.5")
        #expect(resume["reasoningEffort"] as? String == "low")
        // No tools at all, and none of your skills, MCP servers or plugins.
        #expect(resume["availableTools"] as? [String] == ["briefbar_no_tools"])
        #expect(resume["enableConfigDiscovery"] as? Bool == false)
        #expect(resume["enableSkills"] as? Bool == false)
        #expect(fixture.parameters(of: "session.ui.ephemeralQuery") as? [String: String] == [
            "sessionId": FakeCopilot.fork, "question": "Why did Sam ask for a cap on the retries?",
        ])
        #expect(fixture.parameters(of: "session.delete") as? [String: String] == ["sessionId": FakeCopilot.fork])
        #expect(!FileManager.default.fileExists(atPath: fixture.forkFolder.path))
        // The session itself isn't asked anything.
        #expect(try Data(contentsOf: fixture.sessionLog) == log)
        #expect(!fixture.messages.contains { ($0["params"] as? [String: Any])?["sessionId"] as? String == FakeCopilot.session && $0["method"] as? String != "sessions.fork" })
    }

    /// With no model chosen, the session's own answers.
    @Test(.timeLimit(.minutes(1)))
    func asksWithTheSessionsOwnModelUnlessToldOtherwise() async throws {
        let fixture = try FakeCopilot.Fixture()
        defer { fixture.remove() }
        #expect(await questions(fixture).ask("Why?", session: FakeCopilot.session) == .success("Sam wants the retries capped."))
        let resume = try #require(fixture.parameters(of: "session.resume"))
        #expect(resume["model"] == nil && resume["reasoningEffort"] == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func saysWhyThereIsNoAnswerAndStillDeletesTheFork() async throws {
        for (settings, failure) in [
            (["FAKE_ANSWER": "signed-out"], SessionQuestions.Failure.notSignedIn("Error: No authentication information found.")),
            (["FAKE_ANSWER": "  "], .empty),
        ] {
            let fixture = try FakeCopilot.Fixture(settings)
            defer { fixture.remove() }
            #expect(await questions(fixture).ask("Why?", session: FakeCopilot.session) == .failure(failure))
            #expect(fixture.methods.last == "session.delete")
        }
        // Gone before it answered, its server can't delete the fork, so another does.
        let ended = try FakeCopilot.Fixture(["FAKE_ANSWER": "exit"])
        defer { ended.remove() }
        #expect(await questions(ended).ask("Why?", session: FakeCopilot.session)
            == .failure(.failed("The Copilot CLI ended, with status 3, before it answered.")))
        #expect(ended.methods.last == "session.delete")
        #expect(ended.parameters(of: "session.delete") as? [String: String] == ["sessionId": FakeCopilot.fork])
    }

    /// A fork the server said it made right before writing what can't be read is deleted all the same, and not kept.
    @Test(.timeLimit(.minutes(1)))
    func deletesAForkTheServerMadeBeforeWhatCantBeRead() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_FORK": "garbled"])
        defer { fixture.remove() }
        let kept = RecordingLeftoverForks()
        #expect(await questions(fixture, leftovers: kept).ask("Why?", session: FakeCopilot.session)
            == .failure(.failed("The Copilot CLI answered in a way BriefBar can't read.")))
        #expect(await kept.calls == ["keep \(FakeCopilot.fork)", "drop \(FakeCopilot.fork)"])
        #expect(fixture.methods.last == "session.delete")
        #expect(fixture.parameters(of: "session.delete") as? [String: String] == ["sessionId": FakeCopilot.fork])
        #expect(!FileManager.default.fileExists(atPath: fixture.forkFolder.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func refusesACLITooOldToForkTheSessionWithoutChangingIt() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_VERSION": "1.0.87-0"])
        defer { fixture.remove() }
        let answer = await questions(fixture).ask("Why?", session: FakeCopilot.session)
        #expect(answer == .failure(.unsupported(version: "1.0.87-0")))
        #expect(fixture.methods == ["connect"])
        let unsupported = try FakeCopilot.Fixture(["FAKE_FORK": "unsupported"])
        defer { unsupported.remove() }
        #expect(await questions(unsupported).ask("Why?", session: FakeCopilot.session) == .failure(.unsupported(version: nil)))
    }

    @Test func asksNothingWithoutTheSessionOrTheCLI() async throws {
        let fixture = try FakeCopilot.Fixture()
        defer { fixture.remove() }
        #expect(await questions(fixture).ask("Why?", session: "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f") == .failure(.noSession))
        #expect(await questions(fixture).ask("Why?", session: "../../Library/Messages") == .failure(.noSession))
        #expect(await questions(fixture, finds: false).ask("Why?", session: FakeCopilot.session) == .failure(.noCLI))
        #expect(!FileManager.default.fileExists(atPath: fixture.log.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func givesUpOnALateAnswerAndDeletesTheFork() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_ANSWER": "hang"])
        defer { fixture.remove() }
        let answer = await questions(fixture, timeouts: .init(answer: 0.5)).ask("Why?", session: FakeCopilot.session)
        #expect(answer == .failure(.timedOut))
        #expect(fixture.methods.last == "session.delete")
    }

    /// Cancelled while the fork is made, it waits for it, to delete it unasked.
    @Test(.timeLimit(.minutes(1)))
    func cancelledWhileTheForkIsMadeItDeletesTheFork() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_FORK": "late"])
        defer { fixture.remove() }
        let questions = questions(fixture)
        let asking = Task { await questions.ask("Why?", session: FakeCopilot.session) }
        for _ in 0..<2000 where !fixture.methods.contains("sessions.fork") {
            try await Task.sleep(for: .milliseconds(10))
        }
        asking.cancel()
        #expect(await asking.value == .failure(.cancelled))
        #expect(fixture.methods == ["connect", "sessions.fork", "session.delete"])
        #expect(fixture.parameters(of: "session.delete") as? [String: String] == ["sessionId": FakeCopilot.fork])
    }

    /// A fork the server says it made after BriefBar gave up on it is deleted all the same, through another server.
    @Test(.timeLimit(.minutes(1)))
    func aForkMadeAfterItsTimeoutIsDeletedThroughAnotherServer() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_FORK": "late"])
        defer { fixture.remove() }
        let answer = await questions(fixture, timeouts: .init(fork: 0.3)).ask("Why?", session: FakeCopilot.session)
        #expect(answer == .failure(.timedOut))
        #expect(fixture.methods == ["connect", "sessions.fork", "session.delete"])
        #expect(fixture.parameters(of: "session.delete") as? [String: String] == ["sessionId": FakeCopilot.fork])
    }

    /// A fork that no server can delete for now is kept where BriefBar keeps its runs, and deleted before the next
    /// question, even once BriefBar has started again.
    @Test(.timeLimit(.minutes(1)))
    func aForkThatCouldntBeDeletedIsDeletedBeforeTheNextQuestion() async throws {
        var fixture = try FakeCopilot.Fixture()
        defer { fixture.remove() }
        let busy = fixture.folder.appendingPathComponent("busy")
        try Data().write(to: busy)
        fixture.environment["FAKE_DELETE_FAILS"] = busy.path
        let kept = InMemoryLeftoverForks()
        #expect(await questions(fixture, leftovers: kept).ask("Why?", session: FakeCopilot.session) == .success("Sam wants the retries capped."))
        // Through its own server, then another.
        #expect(fixture.methods.suffix(2) == ["session.delete", "session.delete"])
        #expect(FileManager.default.fileExists(atPath: fixture.forkFolder.path))
        #expect(await kept.leftoverForks() == [LeftoverFork(home: AppSessions.folderKey(fixture.home), id: FakeCopilot.fork)])

        // BriefBar starts again: what it kept is still there.
        try FileManager.default.removeItem(at: busy)
        let before = fixture.methods.count
        #expect(await questions(fixture, leftovers: kept).ask("And then?", session: FakeCopilot.session) == .success("Sam wants the retries capped."))
        #expect(Array(fixture.methods.dropFirst(before)) == [
            "connect", "session.delete", "sessions.fork", "session.resume", "session.ui.ephemeralQuery", "session.delete",
        ])
        #expect(!FileManager.default.fileExists(atPath: fixture.forkFolder.path))
        #expect(await kept.leftoverForks().isEmpty)
    }

    /// A question's fork is kept to delete from the moment it's made, should BriefBar quit before it's deleted; while the
    /// question still uses it, no other question or task deletes it as left over.
    @Test(.timeLimit(.minutes(1)))
    func keepsTheForkItAsksToDeleteButNotWhileItAsks() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_ANSWER": "hang"])
        defer { fixture.remove() }
        let kept = InMemoryLeftoverForks()
        let questions = questions(fixture, leftovers: kept)
        let asking = Task { await questions.ask("Why?", session: FakeCopilot.session) }
        for _ in 0..<2000 where !fixture.methods.contains("session.ui.ephemeralQuery") {
            try await Task.sleep(for: .milliseconds(10))
        }
        let fork = LeftoverFork(home: AppSessions.folderKey(fixture.home), id: FakeCopilot.fork)
        #expect(await kept.leftoverForks() == [fork])
        await SessionForker(copilot: fixture.copilot, environment: fixture.environment, timeout: 20, leftovers: kept).deleteLeftovers()
        #expect(!fixture.methods.contains("session.delete"))
        #expect(await kept.leftoverForks() == [fork])

        asking.cancel()
        #expect(await asking.value == .failure(.cancelled))
        #expect(fixture.methods.last == "session.delete")
        #expect(await kept.leftoverForks().isEmpty)
        #expect(!ForksInFlight.contains(fork))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledItStopsAndDeletesTheFork() async throws {
        let fixture = try FakeCopilot.Fixture(["FAKE_ANSWER": "hang"])
        defer { fixture.remove() }
        let questions = questions(fixture)
        let asking = Task { await questions.ask("Why?", session: FakeCopilot.session) }
        for _ in 0..<2000 where !fixture.methods.contains("session.ui.ephemeralQuery") {
            try await Task.sleep(for: .milliseconds(10))
        }
        asking.cancel()
        #expect(await asking.value == .failure(.cancelled))
        #expect(fixture.methods.last == "session.delete")
    }

    @Test func saysWhyInASentence() {
        typealias Failure = SessionQuestions.Failure
        #expect(Failure.unsupported(version: "1.0.87-0").message(model: nil)
            == "The Copilot CLI 1.0.87-0 can't ask a session a side question without changing it. Update it with copilot update.")
        #expect(Failure.unsupported(version: nil).message(model: nil)
            == "The Copilot CLI can't ask a session a side question without changing it. Update it with copilot update.")
        #expect(Failure.modelUnavailable("Model x isn't available").message(model: "Claude Haiku 5.5") == "Claude Haiku 5.5 isn't on your Copilot plan.")
        #expect(Failure.modelUnavailable("Model x isn't available").message(model: nil) == "The session's model isn't on your Copilot plan.")
        #expect(Failure.modelUnavailable("Model x isn't available").detail == "Model x isn't available")
        #expect(Failure.failed("Rate limited").message(model: nil) == "Copilot couldn't answer: Rate limited")
        #expect(Failure.failed("Rate limited").detail == nil)
        // What the CLI says, as for a summary.
        #expect(SessionQuestions.failure(CopilotServer.Failure.failed("Error: You have exceeded your premium request allowance for this month."))
            == .outOfRequests("Error: You have exceeded your premium request allowance for this month."))
        #expect(SessionQuestions.failure(CopilotServer.Failure.failed(#"Model "gpt-x" from --model flag is not available."#))
            == .modelUnavailable(#"Model "gpt-x" from --model flag is not available."#))
        #expect(SessionQuestions.failure(CopilotServer.Failure.timedOut) == .timedOut)
        #expect(SessionQuestions.failure(CopilotServer.Failure.cancelled) == .cancelled)
    }
}
