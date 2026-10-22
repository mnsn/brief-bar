import Darwin
import Foundation
import Testing
@testable import BriefBarCore

@Suite struct DetachedProgramTests {
    private func exitStream() -> (AsyncStream<Int32>, @Sendable (Int32) -> Void) {
        let (stream, sink) = AsyncStream.makeStream(of: Int32.self)
        return (stream, { status in
            sink.yield(status)
            sink.finish()
        })
    }

    /// Its output and errors go to the file, only you can read it, and BriefBar hears how it ended. An agent runs
    /// whatever it decides on, so it mustn't have BriefBar's permissions.
    @Test(.timeLimit(.minutes(1)))
    func runsResponsibleForItselfWithItsOutputInAFile() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("run.log")
        try Data("earlier\n".utf8).write(to: output)
        let (exits, onExit) = exitStream()
        let handle = try DetachedProgram.start(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; sleep 0.3; exit 3"],
            environment: ["PATH": "/usr/bin:/bin"], output: output, queue: DispatchQueue(label: "DetachedProgramTests"),
            onExit: onExit
        )
        #expect(Responsibility.isResponsibleForItself(handle.pid) == true)
        #expect(handle.startedAt != nil)
        #expect(DetachedProgram.isRunning(handle))
        var iterator = exits.makeAsyncIterator()
        #expect(await iterator.next() == 3)
        #expect(!DetachedProgram.isRunning(handle))
        #expect(try String(contentsOf: output, encoding: .utf8) == "earlier\nout\nerr\n")
    }

    /// It runs in a session of its own, which `stop` ends with whatever it started.
    @Test(.timeLimit(.minutes(1)))
    func stopsWithWhatItStarted() async throws {
        let (exits, onExit) = exitStream()
        let handle = try DetachedProgram.start(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & wait"], environment: ["PATH": "/usr/bin:/bin"],
            output: nil, queue: DispatchQueue(label: "DetachedProgramTests"), onExit: onExit
        )
        #expect(getsid(handle.pid) == handle.pid)
        #expect(getpgid(handle.pid) == handle.pid)
        DetachedProgram.stop(handle)
        var iterator = exits.makeAsyncIterator()
        #expect(await iterator.next() == SIGTERM)
        #expect(!DetachedProgram.isRunning(handle))
    }

    /// A process that got its ID later, after BriefBar restarted, isn't it.
    @Test func tellsItFromALaterProcessWithItsID() throws {
        let started = try #require(DetachedProgram.startTime(of: getpid()))
        #expect(DetachedProgram.isRunning(.init(pid: getpid(), startedAt: started)))
        #expect(DetachedProgram.isRunning(.init(pid: getpid(), startedAt: nil)))
        #expect(!DetachedProgram.isRunning(.init(pid: getpid(), startedAt: started.addingTimeInterval(-3_600))))
        #expect(!DetachedProgram.isRunning(.init(pid: 0, startedAt: nil)))
    }
}
