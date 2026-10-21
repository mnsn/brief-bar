import Foundation
import Testing
@testable import BriefBarCore

@Suite struct ElapsedTests {
    @Test(arguments: [
        (0.0, "now"), (59, "now"), (60, "1m"), (3_599, "59m"), (3_600, "1h"), (3_660, "1h 1m"),
        (86_399, "23h 59m"), (86_400, "1d"), (200_000, "2d"), (-5, "now"),
    ])
    func formatsElapsedTime(_ seconds: TimeInterval, _ expected: String) {
        #expect(Elapsed.short(since: t(0), now: t(seconds)) == expected)
    }

    @Test func elapsedTimeOfNothingIsEmpty() {
        #expect(Elapsed.short(since: nil, now: t(0)) == "")
    }
}
