import Darwin
import Foundation
import Testing
@testable import BriefBarCore

@Suite struct RunningProgramTests {
    /// What a program writes and how it ends, as they arrive.
    private final class Recorder: @unchecked Sendable {
        let lines: AsyncStream<String>
        let exits: AsyncStream<Int32>
        private let lineSink: AsyncStream<String>.Continuation
        private let exitSink: AsyncStream<Int32>.Continuation

        init() {
            (lines, lineSink) = AsyncStream.makeStream(of: String.self)
            (exits, exitSink) = AsyncStream.makeStream(of: Int32.self)
        }

        func start(
            _ path: String, _ arguments: [String] = [], maxLineLength: Int = 16_384, endsWhatItStartedWhenItQuits: Bool = false
        ) throws -> RunningProgram {
            try RunningProgram.start(
                URL(fileURLWithPath: path), arguments: arguments, maxLineLength: maxLineLength,
                endsWhatItStartedWhenItQuits: endsWhatItStartedWhenItQuits, callbackQueue: DispatchQueue(label: "RunningProgramTests"),
                onLine: { [lineSink] in lineSink.yield(String(decoding: $0, as: UTF8.self)) },
                onExit: { [lineSink, exitSink] status in
                    lineSink.finish()
                    exitSink.yield(status)
                    exitSink.finish()
                }
            )
        }
    }

    /// Started from an app, a program is otherwise attributed to it, and may use its privacy permissions.
    @Test(.timeLimit(.minutes(5)))
    func startsAProgramResponsibleForItself() async throws {
        let recorder = Recorder()
        let program = try recorder.start("/bin/cat")
        #expect(Responsibility.isResponsibleForItself(program.pid) == true)
        program.closeInput()
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == 0)
    }

    /// Whether macOS says enough here to show that a program isn't responsible for itself: it names the executable
    /// whose permissions a process has, or this process is attributed to another. Where it names no executable and
    /// this process is its own responsible process, as in some agents' shells on an older macOS, every program looks
    /// responsible for itself.
    static var canTellProgramsApart: Bool {
        guard let responsible = Responsibility.responsible(for: getpid()) else { return false }
        return responsible.path != nil || responsible.pid != getpid()
    }

    /// The control for the test above: started the usual way, the same program has the permissions of what this
    /// process is attributed to, so the test above could fail. scripts/test-updater-isolation.sh shows the same in
    /// an app that macOS opens.
    @Test(.enabled(if: canTellProgramsApart, "macOS doesn't say enough here to tell"))
    func aProgramStartedTheUsualWayIsntResponsibleForItself() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(Responsibility.isResponsibleForItself(process.processIdentifier) == false)
    }

    /// The program gets its input, its output and /dev/null, and nothing else BriefBar has open, such as a database it
    /// opened with Full Disk Access.
    @Test(.timeLimit(.minutes(5)))
    func passesTheProgramNoOtherDescriptor() async throws {
        // Without FD_CLOEXEC, which nothing sets here, a program would inherit it.
        let opened = open("/dev/null", O_RDONLY)
        try #require(opened >= 0)
        let held = fcntl(opened, F_DUPFD, 100)
        close(opened)
        try #require(held >= 100)
        defer { close(held) }
        #expect(fcntl(held, F_GETFD) & FD_CLOEXEC == 0)
        let recorder = Recorder()
        _ = try recorder.start("/bin/ls", ["-1", "/dev/fd"])
        var open: [Int32] = []
        for await line in recorder.lines {
            if let descriptor = Int32(line) {
                open.append(descriptor)
            }
        }
        // 0 to 2, and the two that ls opens to read /dev/fd. (Started the usual way, it would list whatever this process
        // has open too.)
        #expect(open.contains(0) && open.contains(1) && open.contains(2))
        #expect(!open.contains(held))
        #expect(open.allSatisfy { $0 <= 4 }, "\(open)")
    }

    @Test(.timeLimit(.minutes(5)))
    func talksToItLineByLineUntilItsInputEnds() async throws {
        let recorder = Recorder()
        let program = try recorder.start("/bin/cat")
        program.send(Data("first".utf8))
        program.send(Data(#"{"kind":"check"}"#.utf8))
        var lines = recorder.lines.makeAsyncIterator()
        #expect(await lines.next() == "first")
        #expect(await lines.next() == #"{"kind":"check"}"#)
        program.closeInput()
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == 0)
        #expect(await lines.next() == nil)
    }

    @Test(.timeLimit(.minutes(5)))
    func deliversEveryLineBeforeTheExit() async throws {
        let recorder = Recorder()
        _ = try recorder.start("/bin/sh", ["-c", "echo one; printf 'two\\nthree'; echo; exit 3"])
        var received: [String] = []
        for await line in recorder.lines {
            received.append(line)
        }
        #expect(received == ["one", "two", "three"])
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == 3)
    }

    @Test(.timeLimit(.minutes(5)))
    func dropsLinesThatAreTooLong() async throws {
        let recorder = Recorder()
        _ = try recorder.start(
            "/bin/sh", ["-c", "echo short; head -c 50000 /dev/zero | tr '\\0' a; echo; echo after"], maxLineLength: 100
        )
        var received: [String] = []
        for await line in recorder.lines {
            received.append(line)
        }
        #expect(received == ["short", "after"])
    }

    @Test(.timeLimit(.minutes(5)))
    func sendingToAProgramThatQuitDoesNothing() async throws {
        let recorder = Recorder()
        let program = try recorder.start("/usr/bin/true")
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == 0)
        program.send(Data("anyone there?".utf8))
        #expect(!program.inputState.isOpen)
    }

    /// A program that frames what it writes itself, such as the Copilot CLI's server, whose messages say how long they
    /// are and end with no newline: it's heard as it writes, and written to as BriefBar writes, without a newline added.
    @Test(.timeLimit(.minutes(5)))
    func talksToAProgramThatFramesItsOwnMessages() async throws {
        let (chunks, chunkSink) = AsyncStream.makeStream(of: Data.self)
        let (exits, exitSink) = AsyncStream.makeStream(of: Int32.self)
        let program = try RunningProgram.start(
            URL(fileURLWithPath: "/bin/cat"), callbackQueue: DispatchQueue(label: "RunningProgramTests"),
            onOutput: { chunkSink.yield($0) },
            onExit: { status in
                chunkSink.finish()
                exitSink.yield(status)
                exitSink.finish()
            }
        )
        let message = Data("Content-Length: 2\r\n\r\n{}".utf8)
        program.write(message)
        var heard = Data()
        var iterator = chunks.makeAsyncIterator()
        // No newline ends it, and it's heard all the same.
        while heard.count < message.count, let chunk = await iterator.next() {
            heard += chunk
        }
        #expect(heard == message)
        program.write(Data("é".utf8))
        program.send(Data("line".utf8))
        program.closeInput()
        while let chunk = await iterator.next() {
            heard += chunk
        }
        #expect(String(decoding: heard, as: UTF8.self) == "Content-Length: 2\r\n\r\n{}éline\n")
        var exitIterator = exits.makeAsyncIterator()
        #expect(await exitIterator.next() == 0)
    }

    @Test(.timeLimit(.minutes(5)))
    func deliversEverythingAProgramWritesBeforeItsExit() async throws {
        let (chunks, chunkSink) = AsyncStream.makeStream(of: Data.self)
        let (exits, exitSink) = AsyncStream.makeStream(of: Int32.self)
        _ = try RunningProgram.start(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'one'; head -c 100000 /dev/zero | tr '\\0' a; printf 'end'; exit 4"],
            callbackQueue: DispatchQueue(label: "RunningProgramTests"), onOutput: { chunkSink.yield($0) },
            onExit: { status in
                chunkSink.finish()
                exitSink.yield(status)
                exitSink.finish()
            }
        )
        var heard = Data()
        for await chunk in chunks {
            heard += chunk
        }
        // Nothing is dropped, however long, nor split anywhere but where it came.
        #expect(heard.count == 100_006)
        #expect(heard.prefix(3) == Data("one".utf8) && heard.suffix(3) == Data("end".utf8))
        var exitIterator = exits.makeAsyncIterator()
        #expect(await exitIterator.next() == 4)
    }

    @Test(.timeLimit(.minutes(5)))
    func writingToAProgramThatStoppedReadingFailsQuietly() async throws {
        let recorder = Recorder()
        // It closes its input, says so, and becomes `sleep`, which runs until it's asked to stop: a shell that runs it
        // instead may outlive being asked. Had it quit before the write, its input would be closed whatever the write
        // did.
        let program = try recorder.start("/bin/sh", ["-c", "exec 0<&-; echo closed; exec sleep 30"])
        #expect(program.inputState.failsWithoutSIGPIPE)
        var lines = recorder.lines.makeAsyncIterator()
        #expect(await lines.next() == "closed")
        // Nothing reads its input now. Without F_SETNOSIGPIPE, this write would end the tests with SIGPIPE; with it,
        // the write fails, and the input is closed.
        program.send(Data("anyone there?".utf8))
        #expect(!program.inputState.isOpen)
        // It ends only as it's asked to stop, now: so it was running at the write, and the write closed its input.
        program.terminate()
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == SIGTERM)
    }

    @Test(.timeLimit(.minutes(5)))
    func endsAProgramWhenAsked() async throws {
        let recorder = Recorder()
        let program = try recorder.start("/bin/sleep", ["30"])
        program.terminate()
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == SIGTERM)
    }

    /// What it started that ignores being asked to stop is made to, once the program itself has quit when its input
    /// ended, or when it was asked to stop.
    @Test(.timeLimit(.minutes(5)), arguments: [
        // It quits when its input ends, long before it would be asked to stop, however busy the Mac.
        (quits: "read line; exit 0", grace: 30.0, status: Int32(0)),
        // It doesn't, and is asked to stop.
        (quits: "wait", grace: 0.3, status: SIGTERM),
    ])
    func endsWhatItStartedEvenOnceItHasQuit(_ program: (quits: String, grace: TimeInterval, status: Int32)) async throws {
        let recorder = Recorder()
        // What it starts says who it is once it ignores being asked to stop, then doesn't hold the output open, so the
        // program's own exit is heard at once.
        let started = try recorder.start(
            "/bin/sh", ["-c", "/bin/sh -c 'trap \"\" TERM; echo $$; exec > /dev/null; while :; do sleep 1; done' & \(program.quits)"]
        )
        var lines = recorder.lines.makeAsyncIterator()
        let child = try #require(await lines.next().flatMap { pid_t($0) })
        #expect(kill(child, 0) == 0)
        started.end(grace: program.grace)
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == program.status)
        // What it started is made to stop too, though it ignores being asked to and its program has quit.
        for _ in 0..<2000 where kill(child, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }

    /// A program that quits by itself, without being ended, takes what it started along, even what ignores being asked to
    /// stop, when it's started to, as the Copilot CLI's server is; otherwise what it started is left alone, as the
    /// updater's is.
    @Test(.timeLimit(.minutes(5)), arguments: [true, false])
    func endsWhatItStartedWhenItQuitsByItselfOnlyIfStartedTo(_ endsWhatItStarted: Bool) async throws {
        let recorder = Recorder()
        // What it starts says who it is once it ignores being asked to stop, then doesn't hold the output open. The
        // program quits once it reads a line, by itself, its input still open.
        let program = try recorder.start(
            "/bin/sh", ["-c", "/bin/sh -c 'trap \"\" TERM; echo $$; exec > /dev/null; while :; do sleep 1; done' & read line; exit 3"],
            endsWhatItStartedWhenItQuits: endsWhatItStarted
        )
        var lines = recorder.lines.makeAsyncIterator()
        let child = try #require(await lines.next().flatMap { pid_t($0) })
        program.send(Data("quit".utf8))
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == 3)
        if endsWhatItStarted {
            var deadline = ContinuousClock.now.advanced(by: waitLimit)
            while kill(child, 0) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(kill(child, 0) == -1 && errno == ESRCH)
            // And it's reaped then, leaving no zombie.
            deadline = ContinuousClock.now.advanced(by: waitLimit)
            while kill(program.pid, 0) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(kill(program.pid, 0) == -1 && errno == ESRCH)
        } else {
            // Longer than what it started would have been given to stop.
            try await Task.sleep(for: .milliseconds(2500))
            #expect(kill(child, 0) == 0)
            kill(child, SIGKILL)
        }
    }

    /// Ended again and again, as it ends and after, it's still reaped once it's gone, and leaves no zombie.
    @Test(.timeLimit(.minutes(5)))
    func endingItAgainAndAgainStillReapsIt() async throws {
        let recorder = Recorder()
        let program = try recorder.start("/bin/sh", ["-c", "trap '' TERM; echo ready; while :; do sleep 1; done"])
        var lines = recorder.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        let ending = Task {
            while !Task.isCancelled {
                program.end(grace: 0.1)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == SIGKILL)
        // A zombie still has its process ID: one that's reaped doesn't.
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while kill(program.pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        ending.cancel()
        #expect(kill(program.pid, 0) == -1 && errno == ESRCH)
    }

    @Test func reportsAProgramThatCantRun() {
        #expect(throws: (any Error).self) {
            try Recorder().start("/nonexistent/BriefBarUpdater")
        }
    }
}
