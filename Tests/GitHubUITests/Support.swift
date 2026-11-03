import BriefBarCore
import BriefBarUI
import Foundation
import GitHubCore
import Testing
@testable import GitHubUI

/// Runs nothing: answers every run the same way, after a delay.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String]] = []
    private var stops = 0
    let result: ProcessResult
    let delay: Duration

    init(_ result: ProcessResult, delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    var calls: [[String]] { lock.withLock { log } }

    /// How many runs were stopped, as `ProcessRunner` stops one whose task is cancelled.
    var stopped: Int { lock.withLock { stops } }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { log.append(arguments) }
        if delay > .zero {
            do {
                try await Task.sleep(for: delay)
            } catch {
                lock.withLock { stops += 1 }
                throw error
            }
        }
        return result
    }
}

enum FakeCLI {
    static let path = "/fake/bin/gh"
    static let signedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"

    /// The GitHub CLI isn't installed: nothing runs, and nothing connects.
    static func missing() -> GitHubCLITokenProvider {
        let runner = FakeRunner(ProcessResult(status: 1))
        let locator = GitHubCLILocator(environment: [:], candidates: [], useLoginShell: false, runner: runner) { _ in false }
        return GitHubCLITokenProvider(locator: locator, runner: runner)
    }

    /// Installed, but signed out: it never gets a token, so nothing connects.
    static func signedOut(_ runner: FakeRunner = FakeRunner(ProcessResult(status: 1, stderr: Data(signedOut.utf8)))) -> GitHubCLITokenProvider {
        let locator = GitHubCLILocator(environment: [:], candidates: [path], useLoginShell: false, runner: runner) { $0 == path }
        return GitHubCLITokenProvider(locator: locator, runner: runner)
    }
}

/// How long a test waits for something before it fails. `make test` runs every test's async work on one thread
/// (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), and the tests on the main actor share the main thread, so a test may get
/// its turn only after most of the others. On CI's busy runner, tests waited half a minute or more, about as long as the
/// whole run takes. A wait that's answered still returns as soon as it is: only a test that fails takes this long.
let waitLimit: Duration = .seconds(60)

/// Waits until `condition` holds, for as long as a busy machine could need (`waitLimit`). The test then checks what it
/// waited for.
@MainActor
func eventually(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: waitLimit)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
func liveStore(_ makeTokens: @escaping () -> GitHubCLITokenProvider, settings: AppSettings = AppSettings(defaults: MemoryDefaults())) -> GitHubStore {
    GitHubStore(settings: settings, mode: .live, makeTokens: makeTokens)
}
