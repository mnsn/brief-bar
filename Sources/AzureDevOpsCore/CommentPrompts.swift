import Foundation

/// A change someone suggested in a comment thread, with a ```suggestion fence (`RichText.Block.suggestion`): what the lines
/// the thread is on would become, as written, which Fix can apply as it is.
public struct CommentSuggestion: Sendable, Equatable {
    /// Who suggested it.
    public var author: Person
    /// The comment it's in.
    public var commentId: Int
    /// The code, as written; empty to remove the lines.
    public var code: String

    public init(author: Person, commentId: Int, code: String) {
        self.author = author
        self.commentId = commentId
        self.code = code
    }

    /// The latest change suggested in a thread by someone other than you, the last of a comment's when it has several; nil
    /// when nobody else suggested one.
    /// - Parameter me: your identity ID in its organization (`PRRecord.me`).
    public static func latest(in thread: ReviewThread, me: String?) -> CommentSuggestion? {
        for comment in thread.comments.reversed() where !PullRequestPrompt.isMine(comment, me: me) {
            // Read only where one may be: a fence says what's in it on its first line.
            guard comment.markdown.contains("suggestion") else { continue }
            let suggested = RichText(markdown: comment.markdown).blocks.compactMap { block -> String? in
                if case .suggestion(let code) = block { code } else { nil }
            }
            if let code = suggested.last { return CommentSuggestion(author: comment.author, commentId: comment.id, code: code) }
        }
        return nil
    }
}

/// The prompts about one comment thread: Fix's, which addresses it alone, and Explain's, which asks why it was written and
/// what it wants. Each quotes the thread in full, the code it's on as its reviewer saw it when that's read, and what you
/// wrote, as yours.
extension PullRequestPrompt {
    /// Addresses one thread and nothing else, as you say, or by applying a suggested change as it's written: then builds and
    /// tests, without committing, pushing or replying, as Fix Comments does. Its entry for the thread is the one Fix
    /// Comments lists it with, which the hand-off for it looks for (`CommentHandOff.init(_:thread:dismissedCutoff:account:)`).
    /// - Parameters:
    ///   - code: the lines it's on, as its reviewer saw them, once read.
    ///   - how: what you want, in your words; nothing for nil or blank.
    ///   - suggestion: a suggested change to apply as it's written.
    public static func fixThread(
        _ record: PRRecord, thread: ReviewThread, code: ThreadExcerpt?, how: String?, applying suggestion: CommentSuggestion? = nil,
        workplace: Workplace = .worktree
    ) -> String {
        var parts = [header(record, workplace: workplace), "Address this review comment thread, and only this one:", quoted(thread, record: record)]
        if let code { parts.append(codeSection(code, thread: thread, record: record)) }
        if let suggestion {
            parts.append(applying(suggestion, to: thread))
        }
        if let how = yours(how) {
            parts.append((suggestion == nil ? "How I want it fixed, in my own words:" : "And, in my own words:") + "\n\n" + how)
        }
        parts.append("""
            Make the change, or say briefly why not. Keep to this thread: leave the others, and the rest of the code, as \
            they are. Build, and run the tests that cover what you changed. Don't commit, push or reply on the pull \
            request: end with a short summary of what you changed for it, so I can check it before it goes out.
            """)
        return parts.joined(separator: "\n\n")
    }

    /// What a session is asked, aside, about a thread (`SessionQuestions`): why its reviewer wrote it, what they want, how
    /// the code relates to it, and ways to address it, from what the session knows of the change. Asked of a throwaway fork
    /// with no tools, it reads nothing more, so the thread and its code are quoted in full.
    /// - Parameter question: what you want to know, in your words; nil or blank for why you got it.
    public static func explainThread(_ record: PRRecord, thread: ReviewThread, code: ThreadExcerpt?, question: String?) -> String {
        let pr = record.pullRequest
        var parts = [
            "Pull request !\(pr.key.number) “\(pr.title)” in \(pr.repositoryName), from \(pr.sourceBranch) into \(pr.targetBranch), has this review comment thread:",
            quoted(thread, record: record),
        ]
        if let code { parts.append(codeSection(code, thread: thread, record: record)) }
        parts += explanationAsk(thread, record: record, question: question)
        parts.append("Answer from what you know of this change in this conversation. Be brief and concrete, and don't change anything.")
        return parts.joined(separator: "\n\n")
    }

    /// The same question as a prompt the session takes up itself, as Fix's is, for when it can't be asked aside: in its own
    /// history, where it can read the code too, but changes nothing.
    public static func askAboutThread(_ record: PRRecord, thread: ReviewThread, code: ThreadExcerpt?, question: String?) -> String {
        let pr = record.pullRequest
        var parts = [
            "Pull request !\(pr.key.number) “\(pr.title)” in \(pr.repositoryName), from \(pr.sourceBranch) into \(pr.targetBranch):\n\(pr.webURL.absoluteString)",
            "It has this review comment thread:",
            quoted(thread, record: record),
        ]
        if let code { parts.append(codeSection(code, thread: thread, record: record)) }
        parts += explanationAsk(thread, record: record, question: question)
        parts.append("""
            Answer from what you know of this change, and read its code if that helps. Don't change any file, and don't \
            commit, push or reply on the pull request: only answer.
            """)
        return parts.joined(separator: "\n\n")
    }

    // MARK: Parts

    /// What Explain asks: your question, as yours, then what to answer.
    private static func explanationAsk(_ thread: ReviewThread, record: PRRecord, question: String?) -> [String] {
        let reviewer = reviewer(of: thread, me: record.me)?.name ?? "the reviewer"
        var parts: [String] = []
        if let question = yours(question) { parts.append("My question, in my own words:\n\n" + question) }
        parts.append("""
            Explain why \(reviewer) wrote this, what they want, how the code relates to it, and two or three ways to \
            address it, with what each would change.
            """)
        return parts
    }

    /// The thread as Fix Comments lists it, its entry then its comments, but each comment in full, as its author wrote it.
    static func quoted(_ thread: ReviewThread, record: PRRecord) -> String {
        let comments = thread.comments.map { comment in
            let who = isMine(comment, me: record.me) ? "You" : comment.author.name
            let lines = comment.markdown.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
            let rest = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "   " + $0 }
            return (["   \(who): " + (lines.first ?? "")] + rest).joined(separator: "\n")
        }
        return ([entry(0, thread)] + comments).joined(separator: "\n")
    }

    /// The lines a thread is on, as its reviewer saw them, numbered, with what was added and removed, and the thread's own
    /// lines marked.
    static func codeSection(_ excerpt: ThreadExcerpt, thread: ReviewThread, record: PRRecord) -> String {
        let file = excerpt.path.hasPrefix("/") ? String(excerpt.path.dropFirst()) : excerpt.path
        let reviewer = reviewer(of: thread, me: record.me).map { " as \($0.name) saw it" } ?? ""
        var heading = "The code it's on, in \(file),\(reviewer) (> marks the lines it's on, + what the change added, - what it removed)"
        if excerpt.changedSince == true { heading += ". The file changed since: look at it as it is now before you change it" }
        return heading + ":\n\n" + codeLines(excerpt)
    }

    /// Each line of an excerpt: whether the thread is on it, its number, how the change left it, and its text.
    static func codeLines(_ excerpt: ThreadExcerpt) -> String {
        func number(_ line: ThreadExcerpt.Line) -> Int? {
            excerpt.side == .left || line.kind == .removed ? line.oldNumber : line.newNumber
        }
        let width = excerpt.lines.compactMap(number).map { String($0).count }.max() ?? 1
        return excerpt.lines.map { line in
            let shown = number(line).map(String.init) ?? ""
            let sign: String
            switch line.kind {
            case .added: sign = "+"
            case .removed: sign = "-"
            case .unchanged: sign = " "
            }
            var text = "\(line.isCommented ? ">" : " ") \(String(repeating: " ", count: width - shown.count))\(shown) \(sign) \(line.text)"
            if line.omittedAfter > 0 { text += "\n  … \(line.omittedAfter) more" }
            return text
        }.joined(separator: "\n")
    }

    /// Applying a suggested change as it's written, to the lines the thread is on.
    static func applying(_ suggestion: CommentSuggestion, to thread: ReviewThread) -> String {
        var place = "the lines the thread is on"
        if let span = ThreadCode.span(of: thread), span.side == .right, let path = thread.filePath {
            let file = path.hasPrefix("/") ? String(path.dropFirst()) : path
            place = span.lines.count == 1
                ? "line \(span.lines.lowerBound) of \(file)"
                : "lines \(span.lines.lowerBound) to \(span.lines.upperBound) of \(file)"
        }
        guard !suggestion.code.isEmpty else {
            return "Apply the change \(suggestion.author.name) suggested, as it's written: remove \(place)."
        }
        let fence = suggestion.code.contains("```") ? "~~~~" : "```"
        return """
            Apply the change \(suggestion.author.name) suggested, exactly as it's written: replace \(place) with

            \(fence)
            \(suggestion.code)
            \(fence)
            """
    }

    /// What you wrote, quoted line by line as yours; nil when there's nothing.
    static func yours(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    /// Who the thread is from: whoever started it, unless that's you; then the last other person who spoke in it.
    public static func reviewer(of thread: ReviewThread, me: String?) -> Person? {
        if let first = thread.comments.first, !isMine(first, me: me) { return first.author }
        return thread.comments.last { !isMine($0, me: me) }?.author
    }

    static func isMine(_ comment: ReviewComment, me: String?) -> Bool {
        guard let me else { return false }
        return comment.author.id.caseInsensitiveCompare(me) == .orderedSame
    }
}

extension CommentHandOff {
    /// What a prompt on one thread, Fix's, hands to Copilot: that thread's comments that wait on you, as `record` has them,
    /// under the entry its prompt lists it with (`PullRequestPrompt.fixThread`). Nothing when none waits on you.
    public init(_ record: PRRecord, thread id: Int, dismissedCutoff: Date, account: String?) {
        let thread = record.details?.threads.first { $0.id == id && !$0.isResolved }
        let waiting = thread.flatMap { thread -> Waiting? in
            let comments = PRClassifier.waitingComments(in: thread, me: record.me, dismissedCutoff: dismissedCutoff)
            let times = comments.map(\.publishedAt)
            guard let first = times.min(), let last = times.max() else { return nil }
            return Waiting(thread: id, entry: PullRequestPrompt.entry(0, thread), comments: comments.map(\.id), first: first, last: last)
        }
        self.init(key: record.id, waiting: waiting.map { [$0] } ?? [], account: account, me: record.me, dismissedCutoff: dismissedCutoff)
    }
}
