import Darwin
import Foundation
import os

public struct ProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult
}

/// Every program BriefBar runs goes through here, so none of them gets BriefBar's privacy permissions.
///
/// macOS attributes a program to the app that started it, its "responsible process", and lets it use
/// that app's privacy permissions. Once Teams is on, BriefBar has Full Disk Access, and programs it
/// starts would have it too: the Azure CLI, a Python program in a folder you can write to, and your
/// login shell, which runs your shell's startup files. So each program here disclaims that: it's
/// responsible for itself, and gets only the permissions macOS gave it. Chromium does the same for
/// the processes it starts. The call is private to macOS, so it's looked up when needed; without it,
/// nothing is started.
public enum Responsibility {
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Bool) -> Int32
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
    }

    /// Makes a program started with these attributes responsible for itself.
    static func disclaim(_ attributes: inout posix_spawnattr_t?) throws {
        guard let address = symbol("responsibility_spawnattrs_setdisclaim") else {
            throw ProcessRunnerError.cantDisclaim
        }
        let disclaim = unsafeBitCast(address, to: Disclaim.self)
        guard disclaim(&attributes, true) == 0 else { throw ProcessRunnerError.cantDisclaim }
    }

    /// The process macOS holds responsible for `pid`, or nil if it can't tell.
    public static func responsibleProcess(for pid: pid_t) -> pid_t? {
        guard let address = symbol("responsibility_get_pid_responsible_for_pid") else { return nil }
        let responsible = unsafeBitCast(address, to: ResponsiblePID.self)(pid)
        return responsible > 0 ? responsible : nil
    }

    /// Logs a fault if a program BriefBar started is attributed to another process after all.
    static func verify(_ pid: pid_t, executable: String) {
        guard let responsible = responsibleProcess(for: pid), responsible != pid else { return }
        let name = (executable as NSString).lastPathComponent
        Logger(subsystem: "com.asaf.BriefBar", category: "app").fault(
            "\(name, privacy: .public) is attributed to process \(responsible), and may use its privacy permissions"
        )
    }
}

public enum ProcessRunnerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// macOS doesn't offer the call that keeps a program from using BriefBar's permissions.
    case cantDisclaim

    public var description: String {
        "BriefBar can't start programs on this version of macOS without giving them its permissions, so it doesn't."
    }
}

/// Runs a program to completion and collects its output, within the timeout. The program runs in a process group
/// of its own, so at the timeout it ends with everything it started. Once it exits, output that something it started
/// keeps open (a background upload, say) is waited for only briefly, and that is ended too. Like every program
/// BriefBar starts, it's responsible for itself (see `Responsibility`).
public struct ProcessRunner: ProcessRunning {
    /// How long to wait for the output to end after the program exits.
    var drainTime: TimeInterval = 0.5

    public init() {}

    public func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = try SpawnedProcess(executable: executable, arguments: arguments, environment: environment)
        return await process.result(timeout: timeout, drainTime: drainTime)
    }

    /// Runs a program to completion, like `run`, blocking the calling thread. Don't call it on the main
    /// thread of an app.
    public func runAndWait(
        _ executable: URL, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval
    ) throws -> ProcessResult {
        let outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                outcome.set(.success(try await self.run(executable, arguments: arguments, environment: environment, timeout: timeout)))
            } catch {
                outcome.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome.get()
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<ProcessResult, any Error> = .failure(ProcessRunnerError.cantDisclaim)

        func set(_ result: Result<ProcessResult, any Error>) {
            lock.withLock { self.result = result }
        }

        func get() throws -> ProcessResult {
            try lock.withLock { result }.get()
        }
    }

    /// Starts a program that outlives BriefBar, such as the one that opens it again after it quits, in a
    /// session of its own, with no input or output, and doesn't wait for it.
    public static func launch(_ executable: URL, arguments: [String]) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        try Responsibility.disclaim(&attributes)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let variables = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, variables)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
        Responsibility.verify(pid, executable: executable.path)
    }
}

/// One run of a program, its output read as it comes. Everything after `init` happens on `queue`.
private final class SpawnedProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BriefBar.ProcessRunner")
    private let pid: pid_t
    private let descriptors: [Int32]
    private var output = [Data(), Data()]
    private var reading: [DispatchSourceRead] = []
    private var exitWatch: DispatchSourceProcess?
    private var status: Int32?
    private var continuation: CheckedContinuation<ProcessResult, Never>?

    init(executable: URL, arguments: [String], environment: [String: String]?) throws {
        var stdout: [Int32] = [-1, -1]
        var stderr: [Int32] = [-1, -1]
        guard pipe(&stdout) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard pipe(&stderr) == 0 else {
            stdout.forEach { close($0) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderr[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A process group of its own, to end it with whatever it starts; and no open descriptors but those three.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        do {
            try Responsibility.disclaim(&attributes)
        } catch {
            (stdout + stderr).forEach { close($0) }
            throw error
        }

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let variables = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, variables)
        close(stdout[1])
        close(stderr[1])
        guard spawned == 0 else {
            close(stdout[0])
            close(stderr[0])
            throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
        }
        self.pid = pid
        descriptors = [stdout[0], stderr[0]]
        Responsibility.verify(pid, executable: executable.path)
    }

    func result(timeout: TimeInterval, drainTime: TimeInterval) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            queue.async { self.start(continuation, timeout: timeout, drainTime: drainTime) }
        }
    }

    private func start(_ continuation: CheckedContinuation<ProcessResult, Never>, timeout: TimeInterval, drainTime: TimeInterval) {
        self.continuation = continuation
        for (index, descriptor) in descriptors.enumerated() {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { self.read(descriptor, into: index, source: source) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            reading.append(source)
        }
        let exitWatch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitWatch.setEventHandler { self.reap(drainTime: drainTime) }
        exitWatch.resume()
        self.exitWatch = exitWatch
        // It may have exited before the watch began.
        reap(drainTime: drainTime)

        // At the timeout, ask it (and whatever it started) to stop, then make it; and stop waiting soon after either way.
        queue.asyncAfter(deadline: .now() + timeout) {
            guard self.continuation != nil else { return }
            killpg(self.pid, SIGTERM)
            self.queue.asyncAfter(deadline: .now() + 1) {
                guard self.continuation != nil else { return }
                killpg(self.pid, SIGKILL)
                self.queue.asyncAfter(deadline: .now() + 2) { self.stopReading(status: SIGKILL) }
            }
        }
    }

    private func read(_ descriptor: Int32, into index: Int, source: DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !source.isCancelled {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output[index].append(contentsOf: buffer[0..<count])
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                // The end of the output (or an error reading it).
                source.cancel()
                finishIfDone()
                return
            }
        }
    }

    private func reap(drainTime: TimeInterval) {
        var raw: Int32 = 0
        guard waitpid(pid, &raw, WNOHANG) == pid else { return }
        exitWatch?.cancel()
        // Reaped after giving up on it: the result is already out.
        guard status == nil else { return }
        // Exited normally: its exit code. Ended by a signal: the signal, as Foundation's Process reports it.
        let signal = raw & 0x7f
        status = signal == 0 ? (raw >> 8) & 0xff : signal
        finishIfDone()
        // Whatever still holds its output open is something it started.
        queue.asyncAfter(deadline: .now() + drainTime) { self.stopReading(status: nil) }
    }

    /// Stops waiting for output that's still open, and ends whatever in its process group holds it.
    private func stopReading(status fallback: Int32?) {
        guard continuation != nil else { return }
        killpg(pid, SIGKILL)
        for source in reading where !source.isCancelled { source.cancel() }
        if status == nil { status = fallback }
        finishIfDone()
    }

    private func finishIfDone() {
        guard let continuation, let status, reading.allSatisfy(\.isCancelled) else { return }
        self.continuation = nil
        continuation.resume(returning: ProcessResult(status: status, stdout: output[0], stderr: output[1]))
    }
}
