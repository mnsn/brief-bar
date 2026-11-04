import Foundation

/// The demo's changes to its threads, made up as Azure DevOps would answer them: it never sends anything, and they change
/// only its made-up data, in memory, while it runs.
public enum DemoThreadChanges {
    /// Your reply in a thread, as Azure DevOps would add it: after its other comments, by you, now.
    public static func reply(_ markdown: String, to thread: ReviewThread, at date: Date, by me: Person = DemoData.me) -> ThreadChange {
        let id = (thread.comments.map(\.id).max() ?? 0) + 1
        let comment = ReviewComment(
            id: id, author: me, text: CommentText.plain(markdown, names: [:]), markdown: markdown, publishedAt: date
        )
        return ThreadChange(thread: thread.id, comments: [comment])
    }

    /// A thread's status, as Azure DevOps would set it.
    public static func status(_ status: ThreadStatus, of thread: ReviewThread) -> ThreadChange {
        ThreadChange(thread: thread.id, status: status.rawValue)
    }
}
