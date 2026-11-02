import Foundation
import Testing
@testable import BriefBarCore

@Suite struct RetryAfterTests {
    /// Sun, 18 Oct 2026 10:00:00 GMT.
    private let now = Date(timeIntervalSince1970: 1_792_317_600)

    @Test func readsSeconds() {
        #expect(RetryAfter.wait("120", now: now) == 120)
        #expect(RetryAfter.wait(" 0.5 ", now: now) == 0.5)
        for value in ["0", "-5", "soon", "", " "] {
            #expect(RetryAfter.wait(value, now: now) == nil, "\(value)")
        }
        #expect(RetryAfter.wait(nil, now: now) == nil)
    }

    /// RFC 9110's own format, and the two obsolete ones it says a recipient must accept too.
    @Test func readsADateInAnyOfItsFormats() {
        for value in ["Sun, 18 Oct 2026 10:02:00 GMT", "Sunday, 18-Oct-26 10:02:00 GMT", "Sun Oct 18 10:02:00 2026"] {
            #expect(RetryAfter.wait(value, now: now) == 120, "\(value)")
        }
        let example = Date(timeIntervalSince1970: 784_111_777)
        #expect(RetryAfter.date("Sun, 06 Nov 1994 08:49:37 GMT", now: now) == example)
        #expect(RetryAfter.date("Sunday, 06-Nov-94 08:49:37 GMT", now: now) == example)
        #expect(RetryAfter.date("Sun Nov  6 08:49:37 1994", now: now) == example)
    }

    /// A two-digit year is this century's, or the last's when this century's would be more than 50 years away.
    @Test func readsATwoDigitYearAsTheNearestThatIsntTooFarAhead() {
        #expect(RetryAfter.date("Wednesday, 01-Jan-76 00:00:00 GMT", now: now) == Date(timeIntervalSince1970: 3_345_062_400))
        #expect(RetryAfter.date("Saturday, 01-Jan-77 00:00:00 GMT", now: now) == Date(timeIntervalSince1970: 220_924_800))
    }

    @Test func aDateThatsPassedIsNoWait() {
        #expect(RetryAfter.wait("Sun, 18 Oct 2026 10:00:00 GMT", now: now) == nil)
        #expect(RetryAfter.wait("Sun, 18 Oct 2026 09:59:00 GMT", now: now) == nil)
    }

    @Test func anythingElseIsNoDate() {
        for value in [
            "18 Oct 2026 10:02:00 GMT", "Sun, 18 Oct 2026 10:02:00", "Sun, 18 Oct 2026 10:02:00 UTC", "Sun, 18 Oct 2026 10:02:00 +0000",
            "Sun, 18 oct 2026 10:02:00 GMT", "Sun, 8 Oct 2026 10:02:00 GMT", "Sun, +8 Oct 2026 10:02:00 GMT", "Sun, 18 Oct 26 10:02:00 GMT",
            "Sun, 31 Feb 2026 10:02:00 GMT", "Sun, 18 Oct 2026 24:00:00 GMT", "Sun, 18 Oct 2026 10:2:00 GMT",
            "Sunday, 18-Oct-2026 10:02:00 GMT", "Sun, 18-Oct-26 10:02:00 GMT", "Sun Oct 18 10:02:00 26", "2026-10-18T10:02:00Z", "",
        ] {
            #expect(RetryAfter.date(value, now: now) == nil, "\(value)")
        }
    }
}
