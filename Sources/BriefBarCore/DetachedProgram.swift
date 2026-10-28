import Darwin
import Foundation
import os

/// A program that works on its own for as long as it takes, and keeps going after BriefBar quits, such as a Copilot
/// agent working on a task. It runs in a session of its own, which also makes it a process group of its own, so `stop`
/// ends it with whatever it started. It reads nothing, and what it writes, output and errors alike, is appended to a
/// file, or goes nowhere.
///
/// Like every program BriefBar starts, it's responsible for itself (see `Responsibility`), and that's checked before any
/// of its code runs, as for `RunningProgram`: it starts suspended, and a program that macOS doesn't hold responsible for
/// itself is ended instead, and `start` throws. An agent runs whatever commands it decides on, so it mustn't have
/// BriefBar's Full Disk Access.
public enum DetachedProgram {
    /// A program that was started, as BriefBar remembers it, across launches.
    public struct Handle: Sendable, Codable, Equatable {
        public var pid: Int32
        /// When it started, as macOS records it: a process that gets the same ID later started later. Nil if macOS
        /// didn't say.
        public var startedAt: Date?

        public init(pid: Int32, startedAt: Date?) {
            self.pid = pid
            self.startedAt = startedAt
        }
    }

    /// Starts a program.
    /// - Parameters:
    ///   - environment: its environment; BriefBar's when nil.
    ///   - output: the file its output and errors are appended to, created only you can read; nowhere when nil.
    ///   - onExit: if it ends while BriefBar runs, its exit status (or the signal that ended it), on `queue`. Once
    ///     BriefBar has quit, macOS collects its exit instead.
    public static func start(
        _ executable: URL, arguments: [String], environment: [String: String]?, output: URL?,
        queue: DispatchQueue = .main, onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> Handle {
        let destination = open(output?.path ?? "/dev/null", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw currentError() }
        defer { close(destination) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, destination, 1)
        posix_spawn_file_actions_adddup2(&actions, destination, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A session of its own, no open descriptors but those three, every signal handled the default way and none
        // blocked, whatever BriefBar does with them, and stopped until it's checked.
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_START_SUSPENDED
        ))
        try Responsibility.disclaim(&attributes)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let variables = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, variables)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
        guard Responsibility.isResponsibleForItself(pid) == true else {
            kill(pid, SIGKILL)
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            let name = executable.lastPathComponent
            Logger(subsystem: "com.asaf.BriefBar", category: "app").fault(
                "\(name, privacy: .public) wasn't responsible for itself, so it was ended before it ran"
            )
            throw ProcessRunnerError.notResponsibleForItself
        }
        let handle = Handle(pid: pid, startedAt: startTime(of: pid))
        // Watched before it runs, so its exit can't come first.
        ExitWatches.shared.watch(pid, queue: queue, onExit: onExit)
        kill(pid, SIGCONT)
        return handle
    }

    /// Whether it's still running: a process with its ID that isn't a zombie and, when BriefBar knows when it started,
    /// started then.
    public static func isRunning(_ handle: Handle) -> Bool {
        guard handle.pid > 0, kill(handle.pid, 0) == 0 || errno == EPERM else { return false }
        guard let info = bsdInfo(of: handle.pid) else { return false }
        if info.pbi_status == UInt32(SZOMB) { return false }
        guard let expected = handle.startedAt else { return true }
        return abs(startTime(info).timeIntervalSince(expected)) < 1
    }

    /// Asks it, and everything in its process group, to stop, then ends them `grace` seconds later if they haven't.
    public static func stop(_ handle: Handle, grace: TimeInterval = 5) {
        guard isRunning(handle) else { return }
        // In a session of its own, its process group has its ID.
        killpg(handle.pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if isRunning(handle) { killpg(handle.pid, SIGKILL) }
        }
    }

    /// When a process started, as macOS records it.
    public static func startTime(of pid: pid_t) -> Date? {
        bsdInfo(of: pid).map(startTime)
    }

    private static func startTime(_ info: proc_bsdinfo) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Collects the exit of every detached program that ends while BriefBar runs, so none lingers as a zombie.
private final class ExitWatches: @unchecked Sendable {
    static let shared = ExitWatches()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "BriefBar.DetachedProgram")
    private var sources: [pid_t: DispatchSourceProcess] = [:]

    func watch(_ pid: pid_t, queue callbackQueue: DispatchQueue, onExit: (@Sendable (Int32) -> Void)?) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            var raw: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &raw, 0)
            } while result == -1 && errno == EINTR
            self?.forget(pid)
            guard result == pid else { return }
            let signal = raw & 0x7f
            let status = signal == 0 ? (raw >> 8) & 0xff : signal
            if let onExit { callbackQueue.async { onExit(status) } }
        }
        lock.withLock { sources[pid] = source }
        source.resume()
    }

    private func forget(_ pid: pid_t) {
        let source = lock.withLock { sources.removeValue(forKey: pid) }
        source?.cancel()
    }
}
