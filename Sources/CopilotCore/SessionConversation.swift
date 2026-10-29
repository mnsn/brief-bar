import BriefBarCore
import Foundation

/// What was asked in a Copilot session and what Copilot answered, in order, from its log, `events.jsonl`: for Summarize
/// with Copilot, so a summary can tell what a session did without anyone asking it. What you asked counts, and what
/// another session asked, such as the one that started it, and each answer that ended Copilot's turn, or the summary it
/// called its task done with: not what Copilot said as it called tools, nor what it and its subagents said to each
/// other. A log can be huge, so only its start, for what was asked first, and its end, for the latest turns, are read,
/// without following a symbolic link, and only the lines that can hold either are decoded.
public enum SessionConversation {
    /// Something asked: by you, or by another session, such as the one that started this one and coordinates it.
    public struct Ask: Sendable, Equatable {
        /// What was asked, as one paragraph.
        public var text: String
        public var isFromAnotherSession: Bool

        public init(_ text: String, isFromAnotherSession: Bool = false) {
            self.text = text
            self.isFromAnotherSession = isFromAnotherSession
        }
    }

    /// A turn: what was asked, and what Copilot answered, each as one paragraph, in order. One read from the middle of
    /// a log may lack what was asked; one Copilot is still at, its answers.
    public struct Turn: Sendable, Equatable {
        public var ask: Ask?
        public var answers: [String]

        public init(ask: Ask? = nil, answers: [String] = []) {
            self.ask = ask
            self.answers = answers
        }
    }

    /// A conversation as its log has it, the oldest turn first.
    public struct Conversation: Sendable, Equatable {
        public var turns: [Turn]
        /// Where the part that wasn't read is, when the log was too long to read whole: before the turn at this index,
        /// 1 after what was asked first, or 0 when the log's start didn't have it. Nil when it was read whole.
        public var unreadBefore: Int?

        public init(turns: [Turn] = [], unreadBefore: Int? = nil) {
            self.turns = turns
            self.unreadBefore = unreadBefore
        }
    }

    /// How long each message may be in the digest: what was asked, an answer, and the last answer, which says where
    /// the session got to.
    enum Limit {
        static let ask = 600
        static let answer = 900
        static let lastAnswer = 1_200
    }

    // MARK: Reading

    /// The digest (`digest(_:limit:)`) of the conversation in a session's log in the Copilot folder
    /// (`read(paths:id:)`).
    public static func digest(paths: CopilotPaths, id: String) -> String {
        digest(read(paths: paths, id: id))
    }

    /// The conversation in a session's log in the Copilot folder, `session-state/<id>/events.jsonl`, opened without
    /// following a symbolic link below that folder (`LocalFile.openFile(below:_:)`): all of it when it's no longer than
    /// `headBytes` and `tailBytes` together, or else what was asked first, from its first `headBytes`, and the turns in
    /// its last `tailBytes`. Nothing for an ID that isn't a session's, a UUID.
    public static func read(
        paths: CopilotPaths, id: String, headBytes: Int = 512 << 10, tailBytes: Int = 4 << 20
    ) -> Conversation {
        let log = [paths.sessionState.lastPathComponent, id, "events.jsonl"]
        let both = max(headBytes, 0) + max(tailBytes, 0)
        // A byte more than both tells a log that's no longer than both, and is read whole, from one that's longer.
        guard UUID(uuidString: id) != nil, let end = LocalFile.tail(below: paths.root, log, maxBytes: both + 1)
        else { return Conversation() }
        guard end.count > both else { return Conversation(turns: turns(in: end)) }
        let first = LocalFile.head(below: paths.root, log, maxBytes: headBytes).flatMap { firstAsk(in: $0.data) }
        let latest = turns(in: end.suffix(max(tailBytes, 0)))
        return Conversation(turns: (first.map { [Turn(ask: $0)] } ?? []) + latest, unreadBefore: first == nil ? 0 : 1)
    }

    /// The turns in a log's lines, in order. Its first line and its last may be cut short: each then decodes to
    /// nothing.
    static func turns(in data: Data) -> [Turn] {
        var turns: [Turn] = []
        for line in data.split(separator: newline) {
            switch said(line) {
            case .ask(let ask)?:
                turns.append(Turn(ask: ask))
            case .answer(let answer)?:
                if turns.isEmpty { turns.append(Turn()) }
                // The summary a task was called done with often says what Copilot's message before it, or after it,
                // says: once is enough.
                if turns[turns.count - 1].answers.last != answer { turns[turns.count - 1].answers.append(answer) }
            case nil:
                continue
            }
        }
        return turns
    }

    /// What was asked first in a log's lines.
    static func firstAsk(in data: Data) -> Ask? {
        for line in data.split(separator: newline) where line.starts(with: userMessage) {
            if case .ask(let ask)? = said(line) { return ask }
        }
        return nil
    }

    /// What a line says, when it's something asked or answered.
    private enum Said {
        case ask(Ask)
        case answer(String)
    }

    private static let newline = UInt8(ascii: "\n")
    private static let userMessage = Data(#"{"type":"user.message""#.utf8)
    private static let assistantMessage = Data(#"{"type":"assistant.message""#.utf8)
    private static let taskComplete = Data(#"{"type":"session.task_complete""#.utf8)

    /// What a line says: what you or another session asked, what Copilot answered, or the summary it called its task
    /// done with. Nothing for what Copilot says as it calls tools, for a notice the app sends a session, such as that
    /// another one is idle, nor for what an agent and its subagent say to each other, a line with an `agentId` of its
    /// own or, in its `data`, a `parentToolCallId`.
    private static func said(_ line: Data) -> Said? {
        let isAsk = line.starts(with: userMessage)
        let isSummary = !isAsk && line.starts(with: taskComplete)
        guard isAsk || isSummary || line.starts(with: assistantMessage),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let data = object["data"] as? [String: Any],
              nonEmpty(object["agentId"]) == nil, nonEmpty(data["parentToolCallId"]) == nil
        else { return nil }
        if isAsk {
            // What you sent is `content`; `transformedContent` adds what Copilot is told with it.
            guard let content = data["content"] as? String, !isNotice(content) else { return nil }
            let isFromAnotherSession = (data["source"] as? String)?.hasPrefix("agent-") == true
            return nonEmpty(paragraph(content)).map { .ask(Ask($0, isFromAnotherSession: isFromAnotherSession)) }
        }
        if isSummary { return nonEmpty(paragraph(data["summary"] as? String ?? "")).map(Said.answer) }
        guard (data["toolRequests"] as? [Any])?.isEmpty ?? true else { return nil }
        return nonEmpty(paragraph(data["content"] as? String ?? "")).map(Said.answer)
    }

    /// A notice the app sends a session, which nobody asked: `<system_notification>…`.
    private static func isNotice(_ content: String) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<system_notification")
    }

    /// Markdown as one paragraph: links as their text, without emphasis, code marks, headings or code fences, each item
    /// of a list after a dash or its number, without the lines that say nothing, such as rules, and with a period after
    /// a block that ends without one, such as a heading or a list.
    static func paragraph(_ markdown: String) -> String {
        var paragraph = ""
        var startsBlock = false
        for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            let text = line.hasPrefix("```") || line.hasPrefix("~~~") ? "" : PlainText.fromMarkdown(line)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
                startsBlock = true
                continue
            }
            if let last = paragraph.last { paragraph += startsBlock && (last.isLetter || last.isNumber) ? ". " : " " }
            startsBlock = false
            if let item = line.prefixMatch(of: /([-*+]|[0-9]{1,9}\.)[ \t]/) {
                paragraph += (item.output.1.first?.isNumber == true ? String(item.output.1) : "-") + " "
            }
            paragraph += text
        }
        return paragraph
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    // MARK: The digest

    /// A conversation for a prompt, in at most `limit` characters: a line for each message, "You:" or "Another
    /// session:" for what was asked, and "Copilot:" for each answer, each cut to about 600 characters for what was
    /// asked and 900 for an answer, or 1,200 for the last answer, which says where the session got to. All of it when
    /// it fits; or else what was asked first, which says what the session was for, then as many of the latest turns as
    /// fit, with a line that says what's left out between. Empty when nothing was asked or answered.
    public static func digest(_ conversation: Conversation, limit: Int = 3_800) -> String {
        let turns = conversation.turns
        guard !turns.isEmpty else { return "" }
        let newest = turns.lastIndex { !$0.answers.isEmpty }
        let told = turns.indices.map { cut(turns[$0], endsWithLastAnswer: $0 == newest) }
        let isWhole = conversation.unreadBefore == nil
        // Lines joined take a character fewer than their sizes add up to.
        if isWhole, size(told.flatMap(\.lines)) <= limit + 1 {
            return told.flatMap(\.lines).joined(separator: "\n")
        }

        let first = conversation.unreadBefore == 0 ? nil : told[0].ask
        let start = first == nil ? 0 : 1
        let widestNote = isWhole ? leftOut(turns.count) : unread
        var room = limit + 1 - (first.map { $0.count + 1 } ?? 0) - (widestNote.count + 1)
        // The latest turns, the newest first, as many as fit, and what fits of the one before them.
        var latest: [[String]] = []
        var next = turns.count - 1
        while next >= start {
            let lines = told[next].lines
            guard size(lines) > room else {
                latest.append(lines)
                room -= size(lines)
                next -= 1
                continue
            }
            let fitted = part(of: told[next], room: &room, withAsk: true)
            if !fitted.isEmpty {
                latest.append(fitted)
                next -= 1
            }
            break
        }

        var lines = first.map { [$0] } ?? []
        // With every turn after it there, what fits of the first one's answers.
        if first != nil, next < start { lines += part(of: told[0], room: &room, withAsk: false) }
        let skipped = next - start + 1
        if !isWhole {
            lines.append(unread)
        } else if skipped > 0 {
            lines.append(leftOut(skipped))
        }
        lines += latest.reversed().joined()
        return lines.joined(separator: "\n")
    }

    /// A turn's lines, each message cut to fit.
    private struct Told {
        var ask: String?
        var answers: [String]

        var lines: [String] { (ask.map { [$0] } ?? []) + answers }
    }

    private static func cut(_ turn: Turn, endsWithLastAnswer: Bool) -> Told {
        Told(
            ask: turn.ask.map { ask in
                (ask.isFromAnotherSession ? "Another session: " : "You: ") + StoryText.line(ask.text, limit: Limit.ask)
            },
            answers: turn.answers.indices.map { index in
                let limit = endsWithLastAnswer && index == turn.answers.count - 1 ? Limit.lastAnswer : Limit.answer
                return "Copilot: " + StoryText.line(turn.answers[index], limit: limit)
            }
        )
    }

    /// What fits of a turn that doesn't fit whole, in its order: its last answer, then what was asked, then its other
    /// answers, the latest first, as long as each fits. Nothing when its last answer doesn't.
    private static func part(of told: Told, room: inout Int, withAsk: Bool) -> [String] {
        func fits(_ line: String) -> Bool {
            guard line.count + 1 <= room else { return false }
            room -= line.count + 1
            return true
        }
        var earlier = told.answers[...]
        var answers: [String] = []
        if let last = earlier.popLast() {
            guard fits(last) else { return [] }
            answers.append(last)
        }
        let ask = withAsk ? told.ask.flatMap { fits($0) ? $0 : nil } : nil
        while let answer = earlier.last, fits(answer) {
            answers.insert(answer, at: 0)
            earlier.removeLast()
        }
        return (ask.map { [$0] } ?? []) + answers
    }

    /// How many characters lines take, each with the line break after it.
    private static func size(_ lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.count + 1 }
    }

    /// Says how many turns were left out, between what was asked first and the latest ones.
    private static func leftOut(_ count: Int) -> String {
        "(\(count) earlier \(count == 1 ? "turn" : "turns") left out)"
    }

    /// Says that a part of a log too long to read whole was left out.
    private static let unread = "(part of the conversation left out)"
}
