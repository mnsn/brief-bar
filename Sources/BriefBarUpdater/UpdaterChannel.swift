import BriefBarCore
import Darwin
import Foundation
import Sparkle

/// The updater's side of what it and BriefBar tell each other (`UpdaterMessage`): requests come in on its standard
/// input, events go out on its standard output.
enum UpdaterChannel {
    /// Sends an event to BriefBar. Once BriefBar is gone, nothing happens.
    static func send(_ message: UpdaterMessage) {
        let data = message.line + Data([UInt8(ascii: "\n")])
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// `--hello`: says that the updater started, with Sparkle loaded and where from, then waits until BriefBar has
    /// looked at it: until its input ends.
    static func hello() -> Int32 {
        let sparkle = Bundle(for: SPUUpdater.self)
        let version = sparkle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        send(UpdaterMessage(.hello, version: version, path: sparkle.bundlePath))
        var byte: UInt8 = 0
        while read(STDIN_FILENO, &byte, 1) > 0 {}
        return 0
    }
}

/// BriefBar's requests, line by line, from standard input, on the main queue. When the input ends, BriefBar quit.
@MainActor
final class InputLines {
    private static let maxLineLength = 4_096
    private let source: DispatchSourceRead
    private let handle: (UpdaterMessage) -> Void
    private let ended: () -> Void
    private var pending = Data()
    private var skippingLine = false

    init(handle: @escaping (UpdaterMessage) -> Void, ended: @escaping () -> Void) {
        self.handle = handle
        self.ended = ended
        _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.read() }
        }
        source.resume()
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 {
                take(buffer[0..<count])
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                source.cancel()
                ended()
                return
            }
        }
    }

    private func take(_ bytes: ArraySlice<UInt8>) {
        pending.append(contentsOf: bytes)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(pending[pending.startIndex..<newline])
            pending = Data(pending[(newline + 1)...])
            if skippingLine {
                skippingLine = false
            } else if line.count <= Self.maxLineLength, let message = UpdaterMessage(line: line) {
                handle(message)
            }
        }
        if pending.count > Self.maxLineLength {
            pending = Data()
            skippingLine = true
        }
    }
}
