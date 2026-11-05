import BriefBarCore
import Foundation
import Testing

/// Settings kept in memory, so that tests leave nothing in ~/Library/Preferences.
final class MemorySettings: SettingsStorage {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    func dictionaryRepresentation() -> [String: Any] { values }
}

struct TestError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// How long a test waits for something before it fails. `make test` runs every test's async work on one thread
/// (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), and the tests on the main actor share the main thread, so a test may get
/// its turn only after most of the others. A wait that's answered still returns as soon as it is: only a test that fails
/// takes this long.
let waitLimit: Duration = .seconds(60)

/// Waits on the main actor until `condition` holds, for as long as a busy machine could need (`waitLimit`). It awaits
/// between looks, so that the main run loop does AppKit's and SwiftUI's work meanwhile, and the main actor goes on with
/// other tests' work. A test that ran that run loop itself would hold the main actor until it returned.
@MainActor
func until(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: waitLimit)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestError("Timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// For a suite whose tests make AppKit wait for an event, as VoiceOver's press does when it clicks a control: keeps the
/// main run loop running for the rest of the test process. Swift runs that run loop for the whole process, and ends the
/// process as soon as it returns, with status 0, though tests are still running and Swift Testing hasn't said how they
/// went. Once AppKit has waited for an event, it reads the window server's events on a thread of its own and stops the
/// main run loop as each comes, as an app's event loop expects. Started before any test runs, so that none is running
/// it then, this runs the main run loop again each time it stops, doing all it did.
struct KeepsTheMainRunLoopRunning: SuiteTrait {
    func prepare(for test: Test) async throws {
        try await MainRunLoop.keepRunning()
    }
}

extension Trait where Self == KeepsTheMainRunLoopRunning {
    /// Keeps the main run loop running, though AppKit stops it.
    static var keepsTheMainRunLoopRunning: Self { Self() }
}

@MainActor
private enum MainRunLoop {
    private static var isKeptRunning = false

    static func keepRunning() async throws {
        // Only where Swift runs the main run loop, as it does with Core Foundation: otherwise nothing stops it.
        guard !isKeptRunning, CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) != nil else { return }
        // A timer, rather than a block, since a block that never returns would hold back those queued after it.
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 0, 0, 0) { _ in
            MainActor.assumeIsolated { isKeptRunning = true }
            while true { _ = CFRunLoopRunInMode(.defaultMode, 1.0e10, false) }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        do {
            try await until("the main run loop to be kept running") { isKeptRunning }
        } catch {
            CFRunLoopTimerInvalidate(timer)
            throw error
        }
    }
}
