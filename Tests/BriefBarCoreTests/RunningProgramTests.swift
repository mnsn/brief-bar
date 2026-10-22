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

    /// Started from an app, a program is otherwise attributed to it, and may use its privacy permissions. (Run from a
    /// terminal, programs aren't attributed to their parents at all, so scripts/test-updater-isolation.sh checks this
    /// in an app that macOS opened, with a control.)
    @Test(.timeLimit(.minutes(1)))
    func startsAProgramResponsibleForItself() async throws {
        let recorder = Recorder()
        let program = try recorder.start("/bin/cat")
        #expect(Responsibility.responsibleProcess(for: program.pid) == program.pid)
        program.closeInput()
        var exits = recorder.exits.makeAsyncIterator()
        #expect(await exits.next() == 0)
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
