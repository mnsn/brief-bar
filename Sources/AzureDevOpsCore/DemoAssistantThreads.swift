import Foundation

extension DemoData {
    /// A made-up assistant that comments on pull requests as a person would, so BriefBar can't tell it's a bot.
    static let assistant = person("c002", "Storefront Assistant")

    /// A resolved thread that waits on you, for the details to show one, with Mark as Read: on !4097, which you review, the
    /// assistant mentions you as it sums the change up, in a thread it closed itself. It's new, so it waits on you until
    /// you've seen it or marked it as read; it came before Alex's mention, so its row still says his.
    static func assistantThreads(of number: Int, now: Date) -> [ReviewThread] {
        switch number {
        case 4097:
            let markdown = "@Robin Diaz I added a summary of the change to the description, for your review."
            return [
                ReviewThread(id: 23, status: "closed", comments: [
                    ReviewComment(
                        id: 1, author: assistant, text: CommentText.plain(markdown, names: [:]), markdown: markdown, mentions: [me.id],
                        publishedAt: now.addingTimeInterval(-45 * 60)
                    ),
                ]),
            ]
        default:
            return []
        }
    }
}
