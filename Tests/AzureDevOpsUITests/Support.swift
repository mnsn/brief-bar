import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Fails a test whose code did what BriefBar does on your Mac beyond its own windows: opening a link, such as a session's
/// in the Copilot app, a file or an app, showing files in the Finder, putting text on the clipboard, or asking in an alert.
/// In tests, `ThisMac` refuses each, so a test whose code meets one tests what BriefBar does when it fails, unawares: such
/// a test stands in for it, as `showForTests` does for showing a session. A test that checks what's refused notes it
/// itself, which this doesn't see (`ThisMac.$noting`).
struct OpensNothing: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        let notes = ThisMac.Notes()
        defer { #expect(notes.refused.isEmpty, "The test's code did on this Mac what tests stand in for: \(notes.refused)") }
        try await ThisMac.$noting.withValue(notes) { try await function() }
    }
}

extension Trait where Self == OpensNothing {
    /// Fails a test whose code opens, shows or copies anything on this Mac, or asks in an alert, which `ThisMac` refuses
    /// in tests: each test of the suite stands in for what it would do.
    static var opensNothing: Self { Self() }
}

/// How long a test waits for something before it fails. `make test` runs every test's async work on one thread
/// (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), and the tests on the main actor share the main thread, so a test may get
/// its turn only after most of the others. On CI's busy runner, tests waited half a minute or more, about as long as the
/// whole run takes. A wait that's answered still returns as soon as it is: only a test that fails takes this long.
let waitLimit: Duration = .seconds(60)

/// Threads of the tests' own, beside Swift's cooperative pool, which `make test` gives one thread for every test at
/// once: a stand-in that looks at an outbox every 25 ms would hold up every other test there. Async code under test
/// stays in the pool, where a blocking wait hangs as it would on a runner with few cores.
final class TestThreads: TaskExecutor {
    static let shared = TestThreads()
    private let queue = DispatchQueue(label: "BriefBarTests.TestThreads", attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

extension Summarizer {
    /// A summarizer that never asks Apple Intelligence's on-device model, for every store a test makes, itself or through
    /// a source. Where the model is on, asking it holds a thread of Swift's pool for seconds, and with it every test that
    /// waits for its turn there. CI's runner has no model, so this is what tests see there too.
    static var withoutModel: Summarizer { Summarizer(isAvailable: { false }) }
}

/// Every store the tests here make, themselves or through a source, has a summarizer `withoutModel`. CI can't tell when
/// one asks the on-device model, since its runner has none: only a Mac with Apple Intelligence on gets slower.
@Test func testsMakeStoresWithoutTheOnDeviceModel() throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    var asking: [String] = []
    for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    where file.pathExtension == "swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        for call in text.matches(of: /\b(?:PRStore|AzureDevOpsSource)\(/) {
            // Its arguments, to the parenthesis that closes them.
            var depth = 1
            var end = call.range.upperBound
            while end < text.endIndex, depth > 0 {
                if text[end] == "(" { depth += 1 } else if text[end] == ")" { depth -= 1 }
                end = text.index(after: end)
            }
            if !text[call.range.upperBound..<end].contains("summarizer: .withoutModel") {
                let line = text[..<call.range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                asking.append("\(file.lastPathComponent):\(line)")
            }
        }
    }
    #expect(asking.isEmpty, "These make a store that may ask the on-device model: \(asking.joined(separator: ", "))")
}
