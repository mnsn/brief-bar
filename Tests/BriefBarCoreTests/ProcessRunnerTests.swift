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
        let start = Date()
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: nil, timeout: 0.5)
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test(.timeLimit(.minutes(1)))
    func endsAProgramThatIgnoresBeingAskedToStop() async throws {
        // Both sleeps ignore SIGTERM, so only SIGKILL, a second later, ends them. The program becomes one of them
        // (exec), so it can't exit on its own when the other is killed first, as a shell waiting for it would.
        let start = Date()
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 30 & echo $!; exec sleep 30"],
            environment: nil, timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.status == SIGKILL)
        #expect(elapsed > 1.2 && elapsed < 5)
        // The sleep is ended too.
        let child = try #require(pid_t(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(try await ends(child))
    }

    @Test(.timeLimit(.minutes(1)))
    func doesntWaitForWhatTheProgramLeftRunning() async throws {
        // The shell exits at once, but the sleep it started in the background keeps its output open.
        let start = Date()
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & echo $!"], environment: nil, timeout: 20
        )
        #expect(result.status == 0)
        #expect(Date().timeIntervalSince(start) < 3)
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

    @Test(.timeLimit(.minutes(1)))
    func noticesEveryExitRightAway() async throws {
        // Many at once: an exit can be reported a moment before its status can be collected, and isn't reported again.
        let start = Date()
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
        #expect(Date().timeIntervalSince(start) < 15)
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

    /// What `osascript` reports about itself: its process ID, then the process macOS holds responsible for it.
    private static let selfReport = """
        ObjC.bindFunction("responsibility_get_pid_responsible_for_pid", ["int", ["int"]]);
        ObjC.bindFunction("getpid", ["int", []]);
        var pid = $.getpid(); pid + " " + $.responsibility_get_pid_responsible_for_pid(pid)
        """

    /// Started from an app, a program is otherwise attributed to it, and may use its privacy permissions.
    @Test func startsProgramsResponsibleForThemselves() async throws {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-l", "JavaScript", "-e", Self.selfReport],
            environment: nil, timeout: 30
        )
        let numbers = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: " ")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        try #require(numbers.count == 2, "osascript printed \(String(decoding: result.stdout + result.stderr, as: UTF8.self))")
        #expect(numbers[1] == numbers[0])
    }

    @Test func findsTheCallsThatKeepProgramsFromUsingItsPermissions() throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        try Responsibility.disclaim(&attributes)
        #expect(Responsibility.responsibleProcess(for: getpid()) != nil)
    }
}
