import Foundation

extension DemoData {
    /// Comment threads that were resolved before what each pull request's row is about, for its details to show what
    /// they hold: threads on lines of code and on the whole pull request, fixed, won't fix and closed. None waits on you,
    /// and each was last said in before its pull request's latest activity, so its group, what's left and since when stay
    /// as the rows have them.
    static func resolvedThreads(of number: Int, now: Date) -> [ReviewThread] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
        func comment(_ id: Int, _ author: Person, _ text: String, _ hoursAgo: Double) -> ReviewComment {
            ReviewComment(id: id, author: author, text: text, publishedAt: ago(hoursAgo))
        }
        switch number {
        case 4102:
            return [
                ReviewThread(id: 13, status: "fixed", filePath: "/src/PaymentsClient.cs", line: 41, comments: [
                    comment(1, priya, "Should the number of retries come from configuration rather than a constant?", 22),
                    comment(2, me, "Done: it reads RetryOptions.MaxAttempts now, five by default.", 20),
                ]),
                ReviewThread(id: 14, status: "wontFix", filePath: "/src/RetryPolicy.cs", line: 12, comments: [
                    comment(1, sam, "Nit: BackoffPolicy might say more about what this does.", 21),
                    comment(2, me, "I'd keep RetryPolicy: the other clients call theirs that too.", 19),
                ]),
                ReviewThread(id: 15, status: "closed", comments: [
                    comment(1, priya, "Is the stub that fails every other call checked in, so that CI runs it too?", 24),
                    comment(2, me, "Yes, it's in tests/Stubs, and it runs with the unit tests.", 23),
                ]),
            ] + codeThreads(of: number, now: now)
        case 4088:
            return [
                ReviewThread(id: 43, status: "fixed", filePath: "/src/Delivery/DeliveryEstimate.cs", line: 27, comments: [
                    comment(1, maria, "This uses the server's time zone, but the cutoff for next-day delivery is the warehouse's.", 30),
                    comment(2, me, "Fixed: it takes the warehouse's time zone now.", 28),
                ]),
            ]
        case 4091:
            return [
                ReviewThread(id: 67, status: "fixed", filePath: "/src/Coupons/CouponService.cs", line: 118, comments: [
                    comment(1, chen, "Does a negative total round away from zero too?", 26),
                    comment(2, me, "Yes, half away from zero both ways, with a test for each.", 25),
                ]),
                ReviewThread(id: 68, status: "fixed", comments: [
                    comment(1, priya, "Could you add the yen? It has no minor units.", 27),
                    comment(2, me, "Added: totals in yen round to whole yen.", 24.5),
                ]),
            ]
        default:
            return []
        }
    }
}
