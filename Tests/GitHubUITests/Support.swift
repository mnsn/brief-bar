import BriefBarCore
import BriefBarUI
import Foundation
import GitHubCore
import Testing
@testable import GitHubUI

/// Runs nothing: answers each run, by what it runs, after a delay.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String]] = []
    private var stops = 0
    private let respond: @Sendable ([String]) -> ProcessResult
    let delay: Duration

    /// Answers every run the same way.
    init(_ result: ProcessResult, delay: Duration = .zero) {
        respond = { _ in result }
        self.delay = delay
    }

    /// Answers each run by its arguments.
    init(delay: Duration = .zero, _ respond: @escaping @Sendable ([String]) -> ProcessResult) {
        self.respond = respond
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
        return respond(arguments)
    }
}

enum FakeCLI {
    static let path = "/fake/bin/gh"
    static let signedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login"
    static let listing = ["auth", "status", "--json", "hosts", "--hostname", "github.com"]
    static let token = ["auth", "token", "--hostname", "github.com"]
    /// What `gh auth status --json hosts` prints when it's signed in to one account, robin.
    static let robin = #"{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"robin","tokenSource":"keyring"}]}}"#

    /// The GitHub CLI isn't installed: nothing runs, and nothing connects.
    static func missing() -> GitHubAccountsReader {
        let runner = FakeRunner(ProcessResult(status: 1))
        return reader(runner, locator: GitHubCLILocator(environment: [:], candidates: [], useLoginShell: false, runner: runner) { _ in false })
    }

    /// Installed, but signed out: it lists no account and never gets a token, so nothing connects.
    static func signedOut(_ runner: FakeRunner = FakeRunner(ProcessResult(status: 1, stderr: Data(signedOut.utf8)))) -> GitHubAccountsReader {
        installed(runner)
    }

    /// Installed, answering as `runner` does. Unless it gives a token, nothing connects.
    static func installed(_ runner: FakeRunner) -> GitHubAccountsReader {
        reader(runner, locator: GitHubCLILocator(environment: [:], candidates: [path], useLoginShell: false, runner: runner) { $0 == path })
    }

    /// Lists the accounts with `runner`, and gets their tokens with it, from where `locator` finds the GitHub CLI.
    private static func reader(_ runner: FakeRunner, locator: GitHubCLILocator) -> GitHubAccountsReader {
        GitHubAccountsReader(accounts: GitHubCLIAccounts(locator: locator, runner: runner)) { account in
            GitHubClient(tokens: GitHubCLITokenProvider(user: account.tokenUser, locator: locator, runner: runner))
        }
    }
}

/// How long a test waits for something before it fails. `make test` runs every test's async work on one thread
/// (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), and the tests on the main actor share the main thread, so a test may get
/// its turn only after most of the others. On CI's slow runners on 2026-11-08, whole runs took up to about three and a
/// half minutes, and waits of a minute ran out in tests nobody had changed: so four minutes. A wait that's answered
/// still returns as soon as it is: only a test that fails takes this long.
let waitLimit: Duration = .seconds(240)

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
func liveStore(_ makeReader: @escaping () -> GitHubAccountsReader, settings: AppSettings = AppSettings(defaults: MemoryDefaults())) -> GitHubStore {
    GitHubStore(settings: settings, mode: .live, makeReader: makeReader)
}
