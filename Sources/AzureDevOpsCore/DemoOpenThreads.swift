import Foundation

extension DemoData {
    /// Open threads on the demo's pull requests besides what their rows are about, for their details to show more of what
    /// Copilot can do with a comment: on !4102, Priya's suggested change, on the line the second push added, which you said
    /// you'd take, so it waits on her rather than you, and what needs you there stays as its row has it. It was last said in
    /// before Sam's reply, so the row's latest activity stays his.
    static func openThreads(of number: Int, now: Date) -> [ReviewThread] {
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
                ReviewThread(id: 18, filePath: "/src/RetryOptions.cs", line: 12, comments: [
                    comment(1, priya, """
                        If we cap the backoff as Sam asks, could the cap live here, next to the attempts, so it's configured the \
                        same way?

                        ```suggestion
                            public int MaxAttempts { get; set; } = 5;

                            /// <summary>The longest to wait between two tries.</summary>
                            public TimeSpan MaxDelay { get; set; } = TimeSpan.FromSeconds(30);
                        ```
                        """, 2.7),
                    comment(2, me, "Good idea: I'll take it with the cap.", 2.4),
                ], location: .init(path: "/src/RetryOptions.cs", right: .init(lines: 12...12), madeOn: .init(base: 2), changeTrackingId: 4)),
            ]
        default:
            return []
        }
    }
}
