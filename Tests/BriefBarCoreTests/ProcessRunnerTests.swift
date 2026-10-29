import Darwin
import Foundation
import Testing
@testable import BriefBarCore

@Suite struct ProcessRunnerTests {
    @Test func runsAProgramAndCollectsItsOutput() async throws {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"], environment: nil, timeout: 10
        )
        #expect(result.status == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
    }

    @Test(.timeLimit(.minutes(1)))
    func endsAProgramThatRunsTooLong() async throws {
        let (result, elapsed) = try await measured {
            try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: nil, timeout: 0.5)
        }
        #expect(result.status != 0)
        #expect(elapsed < .seconds(10))
    }

    @Test(.timeLimit(.minutes(1)))
    func endsAProgramThatIgnoresBeingAskedToStop() async throws {
        // Both sleeps ignore SIGTERM, so only SIGKILL, a second later, ends them. The program becomes one of them
        // (exec), so it can't exit on its own when the other is killed first, as a shell waiting for it would.
        // A program starts with SIGTERM's default, so SIGTERM can come before a shell that's slow to start, as on a
        // busy runner, ignores it. It then ends at once, before it writes anything: that isn't what's tested, so it's
        // tried again with twice the time, and the last time counts.
        for timeout in [0.5, 1, 2, 4, 8] {
            let (result, elapsed) = try await measured {
                try await ProcessRunner().run(
                    URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 30 & echo $!; exec sleep 30"],
                    environment: nil, timeout: timeout
                )
            }
            if result.status == SIGTERM, result.stdout.isEmpty, timeout < 8 { continue }
            #expect(result.status == SIGKILL)
            #expect(elapsed > .seconds(timeout + 0.7) && elapsed < .seconds(timeout + 4.5))
            // The sleep is ended too.
            let child = try #require(pid_t(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(try await ends(child))
            return
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func doesntWaitForWhatTheProgramLeftRunning() async throws {
        // The shell exits at once, but the sleep it started in the background keeps its output open.
        let (result, elapsed) = try await measured {
            try await ProcessRunner().run(
                URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & echo $!"], environment: nil, timeout: 20
            )
        }
        #expect(result.status == 0)
        #expect(elapsed < .seconds(3))
        // And what it left running is ended.
        let child = try #require(pid_t(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(try await ends(child))
    }

    /// Whether a process is gone within two seconds.
    private func ends(_ pid: pid_t) async throws -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// A task that's cancelled ends its program as the timeout does, rather than waiting for it. The shell writes down its
    /// process ID, then becomes `sleep`, for longer than a busy runner can take to cancel it.
    @Test(.timeLimit(.minutes(1)))
    func endsAProgramWhoseTaskIsCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pid")
        let ((pid, elapsed), _) = try await measured {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await ProcessRunner().run(
                        URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "echo $$ > \"$0.new\" && mv \"$0.new\" \"$0\" && exec /bin/sleep 30", file.path],
                        environment: nil, timeout: 30
                    )
                }
                var written: pid_t?
                for _ in 0..<2_000 where written == nil {
                    written = (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    if written == nil { try await Task.sleep(for: .milliseconds(10)) }
                }
                let pid = try #require(written, "the shell didn't write down its process ID")
                try await Task.sleep(for: .milliseconds(100))
                let cancelled = ContinuousClock.now
                group.cancelAll()
                await #expect(throws: CancellationError.self) { try await group.next() }
                return (pid, cancelled.duration(to: .now))
            }
        }
        #expect(elapsed < .seconds(5))
        #expect(try await ends(pid))
    }

    /// Asked to stop, a program may end at once, and leave something it started that ignores being asked and has closed
    /// its output, so that nothing waits for it: that's made to stop too, a second later. The shell's background shell
    /// writes nothing, and becomes `sleep`.
    /// As in `endsAProgramThatIgnoresBeingAskedToStop`, a shell that's slow to start, as on a busy runner, may be asked to
    /// stop before it writes anything: that isn't what's tested, so it's tried again with twice the time.
    @Test(.timeLimit(.minutes(1)))
    func endsWhatAProgramLeavesBehindWhenItStops() async throws {
        for timeout in [0.5, 1, 2, 4, 8] {
            let result = try await ProcessRunner().run(
                URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "(trap '' TERM; exec sleep 30 >/dev/null 2>&1) & echo $!; wait"],
                environment: nil, timeout: timeout
            )
            if result.stdout.isEmpty, timeout < 8 { continue }
            #expect(result.status == SIGTERM)
            let child = try #require(pid_t(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(try await ends(child))
            return
        }
    }

    /// So is what it leaves when its task is cancelled. The background shell writes down its process ID once it ignores
    /// being asked to stop, then becomes `sleep`.
    @Test(.timeLimit(.minutes(1)))
    func endsWhatAProgramLeavesBehindWhenItsTaskIsCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pid")
        let script = """
            (trap '' TERM; exec sh -c 'echo $$ > "$0.new" && mv "$0.new" "$0" && exec sleep 30' "$0" >/dev/null 2>&1) & wait
            """
        let child = try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await ProcessRunner().run(
                    URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, file.path], environment: nil, timeout: 30
                )
            }
            var written: pid_t?
            for _ in 0..<2_000 where written == nil {
                written = (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if written == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            let child = try #require(written, "the background shell didn't write down its process ID")
            group.cancelAll()
            await #expect(throws: CancellationError.self) { try await group.next() }
            return child
        }
        #expect(try await ends(child))
    }

    @Test func doesntStartAProgramForATaskThatsCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ran = directory.appendingPathComponent("ran")
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/touch"), arguments: [ran.path], environment: nil, timeout: 10)
        }
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(!FileManager.default.fileExists(atPath: ran.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func noticesEveryExitRightAway() async throws {
        // Many at once: an exit can be reported a moment before its status can be collected, and isn't reported again.
        let (_, elapsed) = try await measured {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                for _ in 0..<200 {
                    group.addTask {
                        try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], environment: nil, timeout: 20).status
                    }
                }
                for try await status in group {
                    #expect(status == 0)
                }
            }
        }
        #expect(elapsed < .seconds(15))
    }

    @Test func collectsLargeOutput() async throws {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 1000000 /dev/zero; head -c 300000 /dev/zero >&2"],
            environment: nil, timeout: 10
        )
        #expect(result.status == 0)
        #expect(result.stdout.count == 1_000_000)
        #expect(result.stderr.count == 300_000)
    }

    @Test func reportsAProgramThatCantRun() async {
        await #expect(throws: (any Error).self) {
            try await ProcessRunner().run(URL(fileURLWithPath: "/nonexistent/az"), arguments: [], environment: nil, timeout: 5)
        }
    }

    /// A program doesn't inherit the signals that the thread starting it blocks, as Dispatch's and Swift concurrency's
    /// workers do: Git Credential Manager, which git runs to fetch, hung until the timeout without the ones it needs.
    @Test(.timeLimit(.minutes(1)))
    func startsProgramsWithNoSignalsBlocked() async throws {
        let result = try await withTaskExecutorPreference(SignalBlockingExecutor()) {
            try await ProcessRunner().run(
                URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "kill -USR1 $$; echo survived"], environment: nil, timeout: 10
            )
        }
        #expect(result.status == SIGUSR1)
        #expect(result.stdout.isEmpty)
    }

    /// Runs its jobs on a thread that blocks SIGUSR1 while they run.
    private final class SignalBlockingExecutor: TaskExecutor {
        private let queue = DispatchQueue(label: "BriefBarTests.SignalBlocking")

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            queue.async {
                var blocked = sigset_t()
                sigemptyset(&blocked)
                sigaddset(&blocked, SIGUSR1)
                var previous = sigset_t()
                pthread_sigmask(SIG_BLOCK, &blocked, &previous)
                job.runSynchronously(on: self.asUnownedTaskExecutor())
                pthread_sigmask(SIG_SETMASK, &previous, nil)
            }
        }
    }

    /// Measure process deadlines without counting delays in resuming the test on the shared cooperative pool.
    private func measured<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async rethrows -> (Value, Duration) {
        try await withTaskExecutorPreference(ProcessTestExecutor()) {
            let start = ContinuousClock.now
            let value = try await operation()
            return (value, start.duration(to: .now))
        }
    }

    private final class ProcessTestExecutor: TaskExecutor {
        private let queue = DispatchQueue(label: "BriefBarTests.ProcessTiming")

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            queue.async {
                job.runSynchronously(on: self.asUnownedTaskExecutor())
            }
        }
    }

    /// Started from an app, a program is otherwise attributed to it, and may use its privacy permissions. The shell
    /// writes down its process ID, and waits while this test asks macOS about it; it goes on to run `sleep` in the
    /// same process, which macOS keeps attributed as the shell was.
    @Test(.timeLimit(.minutes(1)))
    func startsProgramsResponsibleForThemselves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pid")
        let run = Task {
            try await ProcessRunner().run(
                URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo $$ > \"$0.new\" && mv \"$0.new\" \"$0\" && exec sleep 30", file.path],
                environment: nil, timeout: 30
            )
        }
        var shell: pid_t?
        var tries = 0
        while shell == nil && tries < 500 {
            shell = (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            tries += 1
            if shell == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let pid = try #require(shell, "the shell didn't write down its process ID")
        #expect(Responsibility.isResponsibleForItself(pid) == true)
        // SIGKILL, which can't be blocked or ignored: a program started here keeps the signals that the thread that
        // started it blocks or ignores.
        kill(-pid, SIGKILL)
        _ = try await run.value
    }

    /// What decides it, as macOS reports it in each case: the executable it records, or with an older macOS that
    /// names none, the process.
    @Test func tellsWhetherAProgramIsResponsibleForItselfByItsExecutable() {
        let briefBar = "/Applications/BriefBar.app/Contents/MacOS/BriefBar"
        let host = "/Applications/GitHub Copilot.app/Contents/MacOS/github"
        let ours = Attribution.Responsible(pid: 100, path: briefBar)
        // Started the usual way from BriefBar, opened as an app: attributed to it.
        #expect(!Responsibility.isResponsibleForItself(200, theirs: .init(pid: 100, path: briefBar), ours: ours))
        // Disclaimed: its own executable, even after it went on to run another program, as a shell does.
        #expect(Responsibility.isResponsibleForItself(200, theirs: .init(pid: 200, path: "/bin/sh"), ours: ours))
        // Under a host that makes every program its own responsible process but keeps its own executable, such as
        // the GitHub Copilot app's agents: the process IDs alone would say it's responsible for itself.
        let underHost = Attribution.Responsible(pid: 100, path: host)
        #expect(!Responsibility.isResponsibleForItself(200, theirs: .init(pid: 200, path: host), ours: underHost))
        #expect(Responsibility.isResponsibleForItself(200, theirs: .init(pid: 200, path: "/bin/cat"), ours: underHost))
        // Without executables, the process IDs.
        #expect(Responsibility.isResponsibleForItself(200, theirs: .init(pid: 200, path: nil), ours: .init(pid: 100, path: nil)))
        #expect(!Responsibility.isResponsibleForItself(200, theirs: .init(pid: 100, path: nil), ours: .init(pid: 100, path: nil)))
    }

    @Test func findsTheCallsThatKeepProgramsFromUsingItsPermissions() throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        try Responsibility.disclaim(&attributes)
        #expect(Responsibility.responsible(for: getpid()) != nil)
    }
}
