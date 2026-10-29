import BriefBarCore
import Foundation

/// What Copilot said last in a session, from the end of its log, `events.jsonl`: the summary it called its task done
/// with, and its last message to you, each with when it said it. A log can be large, so only its end is read, without
/// following a symbolic link, and only the lines that can hold either are decoded.
public enum SessionTranscript {
    /// Something Copilot said, and when.
    public struct Words: Sendable, Equatable {
        public var text: String
        /// When, as its log says; nil when it doesn't.
        public var date: Date?

        public init(text: String, date: Date? = nil) {
            self.text = text
            self.date = date
        }
    }

    /// The summary it last called its task done with, and its last message to you: its own, not a subagent's. Nil for
    /// each it didn't say in the end of the log that's read.
    public struct LastWords: Sendable, Equatable {
        public var summary: Words?
        public var message: Words?

        public init(summary: Words? = nil, message: Words? = nil) {
            self.summary = summary
            self.message = message
        }
    }

    /// From a log, its last `maxBytes` at most: nothing for a symbolic link, a folder, or a log that isn't there.
    public static func lastWords(events: URL, maxBytes: Int = 4 << 20) -> LastWords {
        LocalFile.tail(of: events, maxBytes: maxBytes).map(lastWords(in:)) ?? LastWords()
    }

    /// From a session's log in the Copilot folder, `session-state/<id>/events.jsonl`, its last `maxBytes` at most,
    /// opened without following a symbolic link below that folder (`LocalFile.openFile(below:_:)`). Nothing for an ID
    /// that isn't a session's, a UUID.
    public static func lastWords(paths: CopilotPaths, id: String, maxBytes: Int = 4 << 20) -> LastWords {
        let log = [paths.sessionState.lastPathComponent, id, "events.jsonl"]
        guard UUID(uuidString: id) != nil, let data = LocalFile.tail(below: paths.root, log, maxBytes: maxBytes) else {
            return LastWords()
        }
        return lastWords(in: data)
    }

    /// From a log's lines, the last first. The first line may be cut short: it then decodes to nothing.
    private static func lastWords(in data: Data) -> LastWords {
        var words = LastWords()
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            if words.summary == nil, line.starts(with: taskComplete) {
                words.summary = said(line, key: "summary")
            } else if words.message == nil, line.starts(with: assistantMessage) {
                words.message = said(line, key: "content", mainAgentOnly: true)
            }
            if words.summary != nil && words.message != nil { break }
        }
        return words
    }

    private static let taskComplete = Data(#"{"type":"session.task_complete""#.utf8)
    private static let assistantMessage = Data(#"{"type":"assistant.message""#.utf8)

    /// The text a line holds at `key` in its `data`, and its timestamp. A subagent's line, which has a
    /// `parentToolCallId` in its `data` or an `agentId` of its own, says nothing to you.
    private static func said(_ line: Data, key: String, mainAgentOnly: Bool = false) -> Words? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let data = object["data"] as? [String: Any]
        else { return nil }
        if mainAgentOnly, data["parentToolCallId"] is String || object["agentId"] is String { return nil }
        guard let text = (data[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return Words(text: text, date: (object["timestamp"] as? String).flatMap(Timestamp.parse))
    }
}
