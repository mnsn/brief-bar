import Foundation
import Testing

/// A test with `onTestThreads` runs on `TestThreads`, and so does the synchronous work it calls, rather than in Swift's
/// cooperative pool.
@Suite struct TestThreadsTests {
    @Test(.onTestThreads) func aTestWithTheTraitRunsOnTheTestThreads() {
        #expect(currentQueue() == TestThreads.label)
    }

    /// And comes back to them after it waits.
    @Test(.onTestThreads) func anAsyncOneComesBackToThemAfterItWaits() async throws {
        try await Task.sleep(for: .milliseconds(1))
        #expect(currentQueue() == TestThreads.label)
    }
}

private func currentQueue() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}
