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
    let result: ProcessResult
    let delay: Duration

    init(_ result: ProcessResult, delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    var calls: [[String]] { lock.withLock { log } }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { log.append(arguments) }
        if delay > .zero { try await Task.sleep(for: delay) }
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

@MainActor
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<300 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
func liveStore(_ makeTokens: @escaping () -> GitHubCLITokenProvider, settings: AppSettings = AppSettings(defaults: MemoryDefaults())) -> GitHubStore {
    GitHubStore(settings: settings, mode: .live, makeTokens: makeTokens)
}
