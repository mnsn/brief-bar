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

        func start(_ path: String, _ arguments: [String] = [], maxLineLength: Int = 16_384) throws -> RunningProgram {
            try RunningProgram.start(
                URL(fileURLWithPath: path), arguments: arguments, maxLineLength: maxLineLength,
                callbackQueue: DispatchQueue(label: "RunningProgramTests"),
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
    @Test(.timeLimit(.minutes(1)))
    func startsAProgramResponsibleForItself() async throws {
        let recorder = Recorder()
        let program = try recorder.start("/bin/cat")
        #expect(Responsibility.responsibleProcess(for: program.pid) == program.pid)
        program.closeInput()
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == 0)
    }

    /// Whether this test process is attributed to another process, as in Terminal or on CI. Some shells, such as some
    /// agents', start every program responsible for itself, and then nothing they start is attributed to its parent.
    static var isAttributedElsewhere: Bool {
        Responsibility.responsibleProcess(for: getpid()).map { $0 != getpid() } ?? false
    }

    /// The control for the test above: started the usual way, the same program is attributed to what this process is
    /// attributed to. Where this process is responsible for itself, it can't show that, so it's skipped, and
    /// scripts/test-updater-isolation.sh shows it in an app that macOS opens instead.
    @Test(.enabled(if: isAttributedElsewhere, "this process is responsible for itself, so its programs are too"))
    func aProgramStartedTheUsualWayIsAttributedToWhatStartedIt() throws {
        let host = try #require(Responsibility.responsibleProcess(for: getpid()))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(Responsibility.responsibleProcess(for: process.processIdentifier) == host)
    }

    /// The program gets its input, its output and /dev/null, and nothing else BriefBar has open, such as a database it
    /// opened with Full Disk Access.
    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
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

    @Test(.timeLimit(.minutes(1)))
    func sendingToAProgramThatQuitDoesNothing() async throws {
        let recorder = Recorder()
        let program = try recorder.start("/usr/bin/true")
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == 0)
        program.send(Data("anyone there?".utf8))
        #expect(!program.inputState.isOpen)
    }

    @Test(.timeLimit(.minutes(1)))
    func writingToAProgramThatStoppedReadingFailsQuietly() async throws {
        let recorder = Recorder()
        // It closes its input at once, and keeps running a moment.
        let program = try recorder.start("/bin/sh", ["-c", "exec 0<&-; sleep 1"])
        #expect(program.inputState.failsWithoutSIGPIPE)
        try await Task.sleep(for: .milliseconds(300))
        // Nothing reads its input now. Without F_SETNOSIGPIPE, this write would end the tests with SIGPIPE; with it,
        // the write fails, and the input is closed.
        program.send(Data("anyone there?".utf8))
        #expect(!program.inputState.isOpen)
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func endsAProgramWhenAsked() async throws {
        let recorder = Recorder()
        let program = try recorder.start("/bin/sleep", ["30"])
        program.terminate()
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == SIGTERM)
    }

    @Test func reportsAProgramThatCantRun() {
        #expect(throws: (any Error).self) {
            try Recorder().start("/nonexistent/BriefBarUpdater")
        }
    }
}
