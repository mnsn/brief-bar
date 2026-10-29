import BriefBarCore
import Foundation

/// What a Copilot session recorded of its work, in its folder in `session-state`: the checkpoints Copilot writes as it
/// compacts a long conversation, and what it said last (`SessionTranscript`). Their format is Copilot's own and
/// undocumented, so any part of it may be missing. Each file is opened without following a symbolic link below the
/// Copilot folder, and only so much of it is read. It reads the disk, so not on the main thread; it logs nothing.
public enum SessionAccount {
    /// What the session recorded: its checkpoints' titles, the latest one's overview, what's done and what's next, and
    /// what it said after that; without checkpoints, the summary it finished with, or else its last message. Nil when
    /// it recorded nothing, and for an ID that isn't a session's, a UUID.
    /// - Parameter maxMilestones: how many checkpoints' titles to keep, the latest ones.
    public static func read(paths: CopilotPaths, id: String, maxMilestones: Int = 8) -> ItemStory.Account? {
        guard UUID(uuidString: id) != nil else { return nil }
        let folder = [paths.sessionState.lastPathComponent, id, "checkpoints"]
        let checkpoints = LocalFile.tail(below: paths.root, folder + ["index.md"], maxBytes: Limit.index).map { index in
            Self.checkpoints(inIndex: String(decoding: index, as: UTF8.self), isCut: index.count >= Limit.index)
        } ?? []
        let words = SessionTranscript.lastWords(paths: paths, id: id, maxBytes: Limit.events)
        guard !checkpoints.isEmpty else { return account(words) }

        var account = ItemStory.Account(
            source: "Copilot's notes", milestones: checkpoints.suffix(max(maxMilestones, 0)).map(\.title),
            milestoneCount: checkpoints.count
        )
        if let file = checkpoints.last(where: { $0.file != nil })?.file,
           let latest = LocalFile.head(below: paths.root, folder + [file], maxBytes: Limit.checkpoint) {
            let sections = Self.sections(String(decoding: latest.data, as: UTF8.self))
            account.date = latest.modified
            account.overview = sections["overview"].flatMap { nonEmpty(plain($0.joined(separator: "\n"), limit: 700)) }
            account.done = Array(items(sections["work_done"] ?? [], headers: true).prefix(6))
            account.next = Array(items(sections["next_steps"] ?? [], headers: false).prefix(5))
        }
        if let last = later(words.summary, words.message), isAfter(last.date, account.date) {
            account.lastMessage = nonEmpty(plain(last.text, limit: 600))
        }
        return account.isEmpty ? nil : account
    }

    /// How much of each file is read, at most: the end of the index and of the log, and the start of a checkpoint.
    private enum Limit {
        static let index = 256 << 10
        static let checkpoint = 512 << 10
        static let events = 2 << 20
    }

    /// Without checkpoints: the summary it finished with, and its last message when it came after and says something
    /// else; or else its last message.
    private static func account(_ words: SessionTranscript.LastWords) -> ItemStory.Account? {
        let summary = words.summary.flatMap { nonEmpty(plain($0.text, limit: 700)) }
        let message = words.message.flatMap { nonEmpty(plain($0.text, limit: 700)) }
        let date = [words.summary?.date, words.message?.date].compactMap { $0 }.max()
        if let summary {
            var account = ItemStory.Account(source: "Copilot's summary", date: date, overview: summary)
            if let message, message != summary,
               (words.message?.date ?? .distantPast) > (words.summary?.date ?? .distantPast) {
                account.lastMessage = words.message.flatMap { nonEmpty(plain($0.text, limit: 600)) }
            }
            return account
        }
        return message.map { message in
            ItemStory.Account(source: "Copilot's last message", date: words.message?.date, overview: message)
        }
    }

    /// The later of the two, or the message when they're as late; either one without the other.
    private static func later(
        _ summary: SessionTranscript.Words?, _ message: SessionTranscript.Words?
    ) -> SessionTranscript.Words? {
        guard let summary, let message else { return summary ?? message }
        return (summary.date ?? .distantPast) > (message.date ?? .distantPast) ? summary : message
    }

    /// Whether it came after the other: it may have, when either date isn't known.
    private static func isAfter(_ date: Date?, _ other: Date?) -> Bool {
        guard let date, let other else { return true }
        return date > other
    }

    // MARK: The index

    /// A checkpoint, as the index lists it: its number, its title, and its file, when that's a name it's safe to open.
    struct Checkpoint: Equatable {
        var number: Int
        var title: String
        var file: String?
    }

    /// The checkpoints `index.md` lists, the oldest first: the rows of its table whose first cell is a number. When
    /// it's cut short, its first line may be cut too, so that one doesn't count.
    static func checkpoints(inIndex text: String, isCut: Bool = false) -> [Checkpoint] {
        var lines = text.split(whereSeparator: \.isNewline)
        if isCut, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap(checkpoint(inRow:)).enumerated()
            .sorted { ($0.element.number, $0.offset) < ($1.element.number, $1.offset) }
            .map(\.element)
    }

    /// `| 2 | Saved items table and API added | 002-saved-items-table-and-api-a.md |`: its number, its title, without
    /// formatting, and its file. A row without a title is called by its number.
    static func checkpoint(inRow line: Substring) -> Checkpoint? {
        let cells = Self.cells(line)
        guard cells.count >= 2, (1...9).contains(cells[0].count), cells[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(cells[0])
        else { return nil }
        let title = StoryText.line(PlainText.fromMarkdown(cells[1]), limit: 200)
        let file = cells.count > 2 && isSafeFileName(cells[2]) ? cells[2] : nil
        return Checkpoint(number: number, title: title.isEmpty ? "Checkpoint \(number)" : title, file: file)
    }

    /// A table row's cells, trimmed, with or without pipes at its ends; an escaped pipe, `\|`, is part of its cell.
    /// None for a line without a pipe.
    static func cells(_ line: Substring) -> [String] {
        let row = line.trimmingCharacters(in: .whitespaces)
        guard row.contains("|") else { return [] }
        var cells = row.replacingOccurrences(of: "\\|", with: "\u{0}")
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\u{0}", with: "|").trimmingCharacters(in: .whitespaces) }
        if row.hasPrefix("|") { cells.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
        return cells
    }

    /// Whether a checkpoint's file, as the index names it, may be opened: a single name, of letters, digits, dots,
    /// underscores and hyphens, that starts with a letter or a digit and ends in `.md`, of at most 200 characters, and
    /// not the index. Any other, such as `../x.md`, `a/b.md` or `.hidden.md`, never is.
    static func isSafeFileName(_ name: String) -> Bool {
        func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        let scalars = name.unicodeScalars
        guard let first = scalars.first, isLetterOrDigit(first), scalars.count <= 200,
              scalars.allSatisfy({ isLetterOrDigit($0) || $0 == "." || $0 == "_" || $0 == "-" })
        else { return false }
        return name.hasSuffix(".md") && name.lowercased() != "index.md"
    }

    // MARK: A checkpoint

    /// The sections a checkpoint has, in their order.
    private static let sectionNames: Set<String> = [
        "overview", "history", "work_done", "technical_details", "important_files", "next_steps",
    ]

    /// A checkpoint's sections, by their tags' names, such as `overview`, `work_done` and `next_steps`: the lines
    /// between a tag and its closing tag, each on a line of its own. The first of each counts. One that isn't closed
    /// ends where another section starts, or with the text, which may be cut short.
    static func sections(_ text: String) -> [String: [Substring]] {
        var sections: [String: [Substring]] = [:]
        var open: String?
        var lines: [Substring] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let current = open else {
                open = tagName(trimmed)
                lines = []
                continue
            }
            let next = tagName(trimmed).flatMap { sectionNames.contains($0) && $0 != current ? $0 : nil }
            if trimmed == "</\(current)>" || next != nil {
                if sections[current] == nil { sections[current] = lines }
                open = next
                lines = []
            } else {
                lines.append(line)
            }
        }
        if let open, sections[open] == nil { sections[open] = lines }
        return sections
    }

    /// `overview` for a line that's `<overview>`: a tag of lowercase letters and underscores, and nothing else.
    private static func tagName(_ line: String) -> String? {
        guard line.count > 2, line.first == "<", line.last == ">" else { return nil }
        let name = line.dropFirst().dropLast()
        return name.allSatisfy({ $0 == "_" || ($0.isASCII && $0.isLowercase) }) ? String(name) : nil
    }

    /// A list's top-level items, a line each without its marker or formatting: the lines outside code that start, not
    /// indented, with `- `, `* `, `+ ` or a number and `. `, and say something. The lists within them, indented, are
    /// left out. Without a list, the lines that are bold and nothing else, such as `**Tests**`, are the items, when
    /// `headers` says so.
    static func items(_ lines: [Substring], headers: Bool) -> [String] {
        var listed: [String] = []
        var bold: [String] = []
        var isCode = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isCode.toggle()
            } else if isCode {
                continue
            } else if line.prefixMatch(of: /(?:[-*+]|[0-9]{1,9}\.)[ \t]/) != nil {
                listed.append(item(line))
            } else if headers, line.wholeMatch(of: /(?:\*\*[^*]+\*\*|__[^_]+__):?[ \t]*/) != nil {
                var header = item(line)
                if header.hasSuffix(":") { header.removeLast() }
                bold.append(header)
            }
        }
        return (listed.isEmpty ? bold : listed).filter(saysSomething)
    }

    /// An item's line, without its marker, its checkbox or formatting, on one line of at most 200 characters.
    private static func item(_ line: Substring) -> String {
        StoryText.line(PlainText.fromMarkdown(String(line)).replacing(/^\[[ xX]\][ \t]+/, with: ""), limit: 200)
    }

    /// Markdown as plain text: each of its lines without its formatting, code without its fences, and a line with
    /// neither a letter nor a digit, such as a rule, left blank; at most `limit` characters all told.
    static func plain(_ markdown: String, limit: Int) -> String {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            return isFence || !saysSomething(trimmed) ? "" : PlainText.fromMarkdown(trimmed)
        }
        return StoryText.paragraph(lines.joined(separator: "\n"), limit: limit)
    }

    private static func saysSomething(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }
}
