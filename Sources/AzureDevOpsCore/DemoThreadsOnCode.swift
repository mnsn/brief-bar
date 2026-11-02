import Foundation

extension DemoData {
    /// More resolved threads on the made-up code of the demo's pull requests (`DemoCode`), for their details to show code as
    /// a reviewer saw it: one on lines the pull request removed, and a long one, whose middle folds. Each was last said in
    /// before its pull request's latest activity, so its row stays as it is.
    static func codeThreads(of number: Int, now: Date) -> [ReviewThread] {
        /// Written in Markdown, as Azure DevOps keeps comments.
        func comment(_ id: Int, _ author: Person, _ markdown: String, _ hoursAgo: Double) -> ReviewComment {
            ReviewComment(
                id: id, author: author, text: CommentText.plain(markdown, names: [:]), markdown: markdown,
                publishedAt: now.addingTimeInterval(-hoursAgo * 3_600)
            )
        }
        switch number {
        case 4102:
            return [
                // On the check that the first push replaced with retries: lines 46 to 49 before it.
                ReviewThread(id: 16, status: "fixed", filePath: "/src/PaymentsClient.cs", line: 46, comments: [
                    comment(1, priya, "This threw on any failure before. Does a 400 still throw right away, rather than "
                        + "being sent again?", 21),
                    comment(2, me, "Yes: only what `RetryPolicy.IsTransient` lists is sent again, and the rest throws on "
                        + "the first answer, as before.", 19.5),
                ], location: .init(path: "/src/PaymentsClient.cs", left: .init(lines: 46...49), madeOn: .init(base: 1), changeTrackingId: 1)),
                // On the tests the second push added.
                ReviewThread(id: 17, status: "closed", filePath: "/tests/PaymentsClientTests.cs", line: 13, comments: [
                    comment(1, sam, "Could the fake provider answer **429** once too? *Too Many Requests* is what the "
                        + "provider sends most when it's busy.", 2.5),
                    comment(2, me, "`IsTransient` covers 429 already, so it would pass the same way as the 503s.", 2.3),
                    comment(3, sam, "It would, but nothing would catch it if someone took 429 out of `IsTransient`.", 2.1),
                    comment(4, priya, "Agreed. A theory over each transient status would cover all of them in one test.", 1.9),
                    comment(5, me, "Makes sense. I'll turn it into a theory over every status `IsTransient` lists, in a "
                        + "follow-up.", 1.5),
                ], location: .init(path: "/tests/PaymentsClientTests.cs", right: .init(lines: 13...13), madeOn: .init(base: 2),
                                   changeTrackingId: 2)),
            ]
        default:
            return []
        }
    }
}
