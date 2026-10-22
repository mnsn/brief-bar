import Darwin
import Foundation
import os

/// A program that runs alongside BriefBar until it quits, such as its updater, with a pipe to its standard input
/// and one from its standard output; its standard error goes nowhere. It runs in a process group of its own, with
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
    private let maxLineLength: Int
    private let callbackQueue: DispatchQueue
    private let onLine: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private var pending = Data()
    private var skippingLine = false
    private var reading: DispatchSourceRead?
    private var exitWatch: DispatchSourceProcess?
    private var status: Int32?
    private var finished = false

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
            pid: pid, input: toProgram[1], output: fromProgram[0], maxLineLength: maxLineLength,
            callbackQueue: callbackQueue, onLine: onLine, onExit: onExit
        )
        program.queue.sync { program.watch() }
        kill(pid, SIGCONT)
        return program
    }

    private init(
        pid: pid_t, input: Int32, output: Int32, maxLineLength: Int, callbackQueue: DispatchQueue,
        onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.pid = pid
        self.input = input
        self.output = output
        self.maxLineLength = maxLineLength
        self.callbackQueue = callbackQueue
        self.onLine = onLine
        self.onExit = onExit
    }

    deinit {
        if input >= 0 { close(input) }
    }

    /// Writes a line to it, adding the newline. Once it's gone, or its input is closed, nothing happens.
    public func send(_ line: Data) {
        let data = line + Data([UInt8(ascii: "\n")])
        writeQueue.async { [self] in
            guard input >= 0 else { return }
            let complete = data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let written = write(input, bytes.baseAddress! + offset, bytes.count - offset)
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
            guard status == nil else { return }
            killpg(pid, SIGTERM)
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
        exitWatch.setEventHandler { self.reap(exited: true) }
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

    /// Delivers what it wrote line by line, dropping lines that are too long.
    private func take(_ bytes: ArraySlice<UInt8>) {
        pending.append(contentsOf: bytes)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(pending[pending.startIndex..<newline])
            pending = Data(pending[(newline + 1)...])
            if skippingLine {
                skippingLine = false
            } else if line.count <= maxLineLength {
                callbackQueue.async { [onLine] in onLine(line) }
            }
        }
        if pending.count > maxLineLength {
            pending = Data()
            skippingLine = true
        }
    }

    /// Collects its exit status. Once told it `exited`, it waits for that: the exit can be reported a moment before
    /// the status can be collected, and isn't reported again.
    private func reap(exited: Bool) {
        guard status == nil else { return }
        var raw: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &raw, exited ? 0 : WNOHANG)
        } while result == -1 && errno == EINTR
        guard result == pid else { return }
        exitWatch?.cancel()
        let signal = raw & 0x7f
        status = signal == 0 ? (raw >> 8) & 0xff : signal
        closeInput()
        // Output that something it started still holds open isn't waited for long.
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            if let reading, !reading.isCancelled { reading.cancel() }
            finishIfDone()
        }
        finishIfDone()
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
