import Darwin
import Foundation
import os

/// A program that runs alongside BriefBar until it quits, such as its updater, with a pipe to its standard input
/// and one from its standard output, which it hears line by line, or as it comes for a program that frames what it
/// writes itself; its standard error goes nowhere. It runs in a process group of its own, with
/// no other open descriptors. Like every program BriefBar starts, it's responsible for itself (see
/// `Responsibility`), and here that's checked before any of its code runs: it starts suspended, and a program that
/// macOS doesn't hold responsible for itself, and that could use BriefBar's privacy permissions, is ended instead, and
/// `start` throws. Its input ends when `closeInput()` is called or BriefBar quits, which tells it to quit.
public final class RunningProgram: @unchecked Sendable {
    public let pid: pid_t
    /// Reading its output and collecting its exit happen on `queue`; writing to it on `writeQueue`, so that a
    /// program that stops reading holds up neither.
    private let queue = DispatchQueue(label: "BriefBar.RunningProgram")
    private let writeQueue = DispatchQueue(label: "BriefBar.RunningProgram.input")
    private var input: Int32
    private let output: Int32
    private let delivery: Delivery
    private let callbackQueue: DispatchQueue
    private let onExit: @Sendable (Int32) -> Void
    private var pending = Data()
    private var skippingLine = false
    private var reading: DispatchSourceRead?
    private var exitWatch: DispatchSourceProcess?
    private var status: Int32?
    /// It was reaped: from then on, its process group's number can be another's, so nothing is sent to it.
    private var reaped = false
    /// It's being stopped, with whatever it started (`stop(grace:)`): it isn't reaped until they've been made to, so that
    /// its group's number stays its own.
    private var stopping = false
    private var finished = false

    /// How what it writes reaches BriefBar.
    private enum Delivery {
        /// Line by line, without the newline; lines longer than `maxLength` are dropped.
        case lines(maxLength: Int, onLine: @Sendable (Data) -> Void)
        /// As it comes, in pieces of any size, in order: for a program that frames what it writes itself.
        case chunks(@Sendable (Data) -> Void)
    }

    /// Starts a program.
    /// - Parameters:
    ///   - environment: its environment; BriefBar's when nil.
    ///   - maxLineLength: lines it writes that are longer are dropped.
    ///   - onLine: each line it writes, without the newline, on `callbackQueue`.
    ///   - onExit: once it has exited, its exit status (or the signal that ended it), on `callbackQueue`, after its
    ///     last line.
    public static func start(
        _ executable: URL, arguments: [String] = [], environment: [String: String]? = nil, maxLineLength: Int = 16_384,
        callbackQueue: DispatchQueue = .main, onLine: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningProgram {
        try start(
            executable, arguments: arguments, environment: environment, delivery: .lines(maxLength: maxLineLength, onLine: onLine),
            callbackQueue: callbackQueue, onExit: onExit
        )
    }

    /// Starts a program whose output BriefBar hears as it comes, rather than line by line: for one that frames what it
    /// writes itself, such as a server whose messages each say how long they are.
    /// - Parameters:
    ///   - environment: its environment; BriefBar's when nil.
    ///   - onOutput: what it writes, in pieces of any size, in order, on `callbackQueue`.
    ///   - onExit: once it has exited, its exit status (or the signal that ended it), on `callbackQueue`, after the last
    ///     of its output.
    public static func start(
        _ executable: URL, arguments: [String] = [], environment: [String: String]? = nil, callbackQueue: DispatchQueue = .main,
        onOutput: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningProgram {
        try start(
            executable, arguments: arguments, environment: environment, delivery: .chunks(onOutput), callbackQueue: callbackQueue,
            onExit: onExit
        )
    }

    private static func start(
        _ executable: URL, arguments: [String], environment: [String: String]?, delivery: Delivery, callbackQueue: DispatchQueue,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningProgram {
        var toProgram: [Int32] = [-1, -1]
        var fromProgram: [Int32] = [-1, -1]
        guard pipe(&toProgram) == 0 else { throw currentError() }
        guard pipe(&fromProgram) == 0 else {
            let error = currentError()
            toProgram.forEach { close($0) }
            throw error
        }
        // BriefBar's ends stay out of whatever else it starts.
        for descriptor in [toProgram[1], fromProgram[0]] {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toProgram[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromProgram[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A process group of its own, no open descriptors but those three, every signal handled the default way
        // and none blocked, whatever BriefBar does with them, and stopped until it's checked.
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_START_SUSPENDED
        ))
        posix_spawnattr_setpgroup(&attributes, 0)
        do {
            try Responsibility.disclaim(&attributes)
        } catch {
            (toProgram + fromProgram).forEach { close($0) }
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
        close(toProgram[0])
        close(fromProgram[1])
        guard spawned == 0 else {
            close(toProgram[1])
            close(fromProgram[0])
            throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
        }
        guard Responsibility.isResponsibleForItself(pid) == true else {
            kill(pid, SIGKILL)
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            close(toProgram[1])
            close(fromProgram[0])
            let name = executable.lastPathComponent
            Logger(subsystem: "com.asaf.BriefBar", category: "app").fault(
                "\(name, privacy: .public) wasn't responsible for itself, so it was ended before it ran"
            )
            throw ProcessRunnerError.notResponsibleForItself
        }
        // A write after it's gone fails, instead of ending BriefBar with SIGPIPE.
        _ = fcntl(toProgram[1], F_SETNOSIGPIPE, 1)

        let program = RunningProgram(
            pid: pid, input: toProgram[1], output: fromProgram[0], delivery: delivery, callbackQueue: callbackQueue, onExit: onExit
        )
        program.queue.sync { program.watch() }
        kill(pid, SIGCONT)
        return program
    }

    private init(
        pid: pid_t, input: Int32, output: Int32, delivery: Delivery, callbackQueue: DispatchQueue,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.pid = pid
        self.input = input
        self.output = output
        self.delivery = delivery
        self.callbackQueue = callbackQueue
        self.onExit = onExit
    }

    deinit {
        if input >= 0 { close(input) }
    }

    /// Writes a line to it, adding the newline. Once it's gone, or its input is closed, nothing happens.
    public func send(_ line: Data) {
        write(line + Data([UInt8(ascii: "\n")]))
    }

    /// Writes to it, as it is, after what was written before. Once it's gone, or its input is closed, nothing happens.
    public func write(_ data: Data) {
        writeQueue.async { [self] in
            guard input >= 0, !data.isEmpty else { return }
            let complete = data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(input, bytes.baseAddress! + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
            if !complete {
                close(input)
                input = -1
            }
        }
    }

    /// Ends its input, which tells it to quit.
    public func closeInput() {
        writeQueue.async { [self] in
            guard input >= 0 else { return }
            close(input)
            input = -1
        }
    }

    /// For tests: whether its input is open, and whether a write to it that nothing reads fails instead of raising
    /// SIGPIPE, which would end BriefBar.
    var inputState: (isOpen: Bool, failsWithoutSIGPIPE: Bool) {
        writeQueue.sync { input >= 0 ? (true, fcntl(input, F_GETNOSIGPIPE) == 1) : (false, false) }
    }

    /// Asks it, and whatever it started in its process group, to stop.
    public func terminate() {
        queue.async { [self] in
            guard !reaped else { return }
            killpg(pid, SIGTERM)
        }
    }

    /// Asks it, and whatever it started in its process group, to stop, and makes them `grace` seconds later, even once it
    /// has exited, since something it started may ignore being asked. It isn't reaped until then, so its group's number
    /// stays its own; its exit is heard as it happens all the same.
    public func stop(grace: TimeInterval) {
        queue.async { [self] in
            guard !reaped, !stopping else { return }
            stopping = true
            killpg(pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + grace) { [self] in
                killpg(pid, SIGKILL)
                stopping = false
                reapIfDone()
            }
        }
    }

    private func watch() {
        _ = fcntl(output, F_SETFL, fcntl(output, F_GETFL) | O_NONBLOCK)
        let reading = DispatchSource.makeReadSource(fileDescriptor: output, queue: queue)
        reading.setEventHandler { self.read() }
        reading.setCancelHandler { [output] in close(output) }
        reading.resume()
        self.reading = reading
        let exitWatch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitWatch.setEventHandler { self.noteExit() }
        exitWatch.resume()
        self.exitWatch = exitWatch
    }

    private func read() {
        guard let reading, !reading.isCancelled else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(output, &buffer, buffer.count)
            if count > 0 {
                take(buffer[0..<count])
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                // The end of its output (or an error reading it).
                reading.cancel()
                finishIfDone()
                return
            }
        }
    }

    /// Delivers what it wrote: as it came, or line by line, dropping lines that are too long.
    private func take(_ bytes: ArraySlice<UInt8>) {
        let maxLineLength: Int
        let onLine: @Sendable (Data) -> Void
        switch delivery {
        case .chunks(let onOutput):
            let chunk = Data(bytes)
            callbackQueue.async { onOutput(chunk) }
            return
        case .lines(let maxLength, let deliver):
            maxLineLength = maxLength
            onLine = deliver
        }
        pending.append(contentsOf: bytes)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(pending[pending.startIndex..<newline])
            pending = Data(pending[(newline + 1)...])
            if skippingLine {
                skippingLine = false
            } else if line.count <= maxLineLength {
                callbackQueue.async { onLine(line) }
            }
        }
        if pending.count > maxLineLength {
            pending = Data()
            skippingLine = true
        }
    }

    /// Reads its exit status once it has exited, without reaping it, then reaps it unless it's being stopped
    /// (`reapIfDone`). It waits for that: the exit can be reported a moment before the status can be read, and isn't
    /// reported again.
    private func noteExit() {
        guard status == nil else { return }
        var info = siginfo_t()
        var result: Int32
        repeat {
            result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
        } while result == -1 && errno == EINTR
        guard result == 0, info.si_pid == pid else { return }
        exitWatch?.cancel()
        // Exited normally: its exit code. Ended by a signal: the signal.
        status = info.si_code == CLD_EXITED ? info.si_status & 0xff : info.si_status & 0x7f
        reapIfDone()
        closeInput()
        // Output that something it started still holds open isn't waited for long.
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            if let reading, !reading.isCancelled { reading.cancel() }
            finishIfDone()
        }
        finishIfDone()
    }

    /// Reaps it once it has exited, unless it's being stopped, which reaps it once it's done.
    private func reapIfDone() {
        guard status != nil, !reaped, !stopping else { return }
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
        reaped = true
    }

    private func finishIfDone() {
        guard !finished, let status, reading?.isCancelled ?? true else { return }
        finished = true
        callbackQueue.async { [onExit] in onExit(status) }
    }

    private static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
