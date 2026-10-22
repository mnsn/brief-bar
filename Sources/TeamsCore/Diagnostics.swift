import BriefBarCore
import Foundation
import NotificationCenterDB

/// A report on Notification Center's database and Teams' notifications that holds only their
/// structure: table and field names, counts, and the shapes of values. Never names, message text
/// or IDs, so it's safe to paste into an issue.
public enum Diagnostics {
    /// - Parameters:
    ///   - cache: Teams' own data, where it keeps how far you've read each chat; nil when only made-up data may be read.
    ///   - followsReadsInTeams: whether **Mark Chats Read When You Read Them in Teams** is on.
    public static func report(
        paths: NotificationPaths, cache: TeamsCacheLocation?, followsReadsInTeams: Bool, appVersion: String
    ) async -> String {
        var lines = [
            "BriefBar \(appVersion) diagnostics (structure only: no names, messages or IDs)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        let access = DatabaseAccess.check(paths.database)
        lines.append("Database: \(paths.isSystemDatabase ? "Notification Center's" : "overridden by \(NotificationPaths.databaseVariable)"), access \(access.rawValue)")
        let badge = await dockBadge()
        lines.append("Teams' dock badge, from lsappinfo: \(badge)")
        var messages: [ChatMessage] = []
        if access == .granted {
            do {
                let contents = try NotificationDatabase.load(at: paths.database, bundleIdentifiers: TeamsBundle.identifiers)
                lines += describe(contents)
                messages = contents.records.compactMap { TeamsNotificationParser.parse($0).item.message }
            } catch NotificationDatabaseError.layoutChanged(let missing, let layout) {
                lines.append("Layout changed, missing: \(missing.joined(separator: ", "))")
                lines.append("Tables:")
                lines += layout.lines.map { "  \($0)" }
            } catch {
                lines.append("Read failed: \(error)")
            }
        }
        if !followsReadsInTeams {
            lines.append("Teams' read markers: not read (Mark Chats Read When You Read Them in Teams is off)")
        } else if let cache {
            let snapshot = ReadMarkerEngine.loadOnce(location: cache)
            lines += describe(snapshot, location: cache)
            if snapshot.access == .granted, !messages.isEmpty {
                lines.append(compare(messages, with: snapshot.markers))
            }
        } else {
            lines.append("Teams' read markers: not read (another Notification Center database, and no \(TeamsCacheLocation.variable))")
        }
        return lines.joined(separator: "\n")
    }

    /// Whether Teams' read markers name the chats Notification Center has, and cover their newest messages: the IDs of
    /// both, by counts only.
    static func compare(_ messages: [ChatMessage], with markers: [String: ReadMarker]) -> String {
        let newest = Dictionary(grouping: messages, by: \.conversationID)
            .compactMapValues { $0.max(by: UnreadTracker.chronological) }
        let marked = newest.filter { markers[$0.key] != nil }
        let read = marked.filter { markers[$0.key]?.covers($0.value) == true }
        return "  Chats in Notification Center: \(newest.count), with a read marker: \(marked.count), "
            + "read in Teams up to their newest notification: \(read.count)"
    }

    /// What BriefBar reads of Teams' own data, by counts and formats only.
    static func describe(_ snapshot: ReadMarkerSnapshot, location: TeamsCacheLocation) -> [String] {
        var lines = ["Teams' read markers: "
            + (location.isTeamsOwn ? "Teams' own data" : "overridden by \(TeamsCacheLocation.variable)")
            + ", access \(snapshot.access.rawValue)"]
        guard snapshot.access == .granted else { return lines }
        let report = snapshot.report
        let folders = location.folders().map {
            $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent
        }
        lines.append("  Folders: " + (folders.isEmpty ? "none" : folders.joined(separator: ", ")))
        lines.append("  Conversation stores: \(report.stores), conversations: \(report.conversations), "
            + "chats with a read marker: \(report.withMarker)")
        for (format, count) in report.formats.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            lines.append("  \(count) x \(format)")
        }
        for (reason, count) in report.unreadable.sorted(by: { $0.key < $1.key }) {
            lines.append("  unreadable, \(reason): \(count)")
        }
        lines.append("  Unreadable files: \(report.unreadableFiles), corrupt log records: \(report.corruptLogRecords), "
            + "table blocks read: \(report.blocksRead), skipped: \(report.blocksSkipped)")
        lines.append("  Verdict: " + (report.problem?.title ?? "OK"))
        return lines
    }

    static func describe(_ contents: DatabaseContents) -> [String] {
        var lines: [String] = []
        lines.append("Teams entries: \(contents.appIdentifiers.isEmpty ? "none" : contents.appIdentifiers.joined(separator: ", "))")
        lines.append("Badge column: \(contents.badge.map(String.init) ?? "empty")")

        let parsed = contents.records.map(TeamsNotificationParser.parse)
        let report = FormatReport(parsed)
        lines.append("Teams notifications: \(report.total) (chat messages \(report.chatMessages), "
            + "chat activity \(report.chatActivity), channel posts \(report.channelPosts), "
            + "other kinds \(report.otherNotifications), unrecognized \(report.unreadable))")
        for (reason, count) in report.unrecognized.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append("  unrecognized, \(reason.rawValue): \(count)")
        }
        let messages = parsed.compactMap(\.item.message)
        let conversations = Dictionary(grouping: messages, by: \.conversationID)
        let kinds = Dictionary(grouping: conversations.values.compactMap(\.first), by: \.kind)
        lines.append("Chats with messages: " + ConversationKind.allCases.filter { $0 != .channel }
            .map { "\($0.rawValue) \(kinds[$0]?.count ?? 0)" }.joined(separator: ", "))
        lines.append("Messages with a message ID: \(messages.filter { $0.messageID != nil }.count) of \(messages.count)")
        let grouped = messages.filter { $0.kind != .oneOnOne }
        lines.append("Group messages with a sender prefix: \(grouped.filter { $0.sender != nil }.count) of \(grouped.count)")
        lines.append("Verdict: \(verdict(report.verdict))")

        let raws = parsed.compactMap(\.raw)
        var shapes: [String: [String: Int]] = [:]
        for raw in raws {
            for name in raw.userInfoKeys {
                shapes[label(name), default: [:]][raw.userInfo[name].map(shape) ?? "<not text>", default: 0] += 1
            }
            shapes["req.titl", default: [:]][raw.title.isEmpty ? "\"\"" : "<text>", default: 0] += 1
            shapes["req.body", default: [:]][raw.body.isEmpty ? "\"\"" : "<text>", default: 0] += 1
        }
        let states = Dictionary(grouping: raws, by: \.userInfoState).mapValues(\.count)
        lines.append("User info: " + states.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", "))
        lines.append("Fields, most common shapes first:")
        for name in shapes.keys.sorted() {
            let counts = shapes[name, default: [:]].sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            lines.append("  \(name): " + counts.prefix(4).map { "\($0.value) x \($0.key)" }.joined(separator: "; ")
                + (counts.count > 4 ? "; and \(counts.count - 4) more" : ""))
        }
        lines.append("Tables:")
        lines += contents.layout.lines.map { "  \($0)" }
        return lines
    }

    private static func verdict(_ verdict: FormatVerdict) -> String {
        switch verdict {
        case .ok: return "OK"
        case .empty: return "no Teams notifications stored"
        case .partlyUnreadable(let unreadable, let total): return "\(unreadable) of \(total) unrecognized"
        case .unrecognized(let total): return "none of \(total) recognized"
        }
    }

    /// What BriefBar sees of Teams' dock badge, which tells it when everything was read.
    private static func dockBadge() async -> String {
        for identifier in TeamsBundle.identifiers {
            switch await DockBadge.read(bundleIdentifier: identifier) {
            case .count(let count): return "\(count) (\(identifier))"
            case .mark: return "a mark (\(identifier))"
            case .noBadge: return "none (\(identifier))"
            case nil: continue
            }
        }
        return "nothing to read (Teams isn't running, or lsappinfo's output changed)"
    }

    /// Field names as they are, unless they look like an ID rather than a field name.
    static func label(_ name: String) -> String {
        let isFieldName = name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]{0,40}/) != nil
        return isFieldName && name.filter(\.isASCIIDigit).count <= 6 ? name : "<key>"
    }

    /// Known terms Teams uses as values; any other word is replaced.
    private static let vocabulary: Set<String> = [
        "chats", "channels", "chat", "channel", "view", "quickReply", "tmpcore_work", "DoNotMove",
        "true", "false", "reply", "send", "none", "calls", "call", "meetings", "meeting", "activity",
        "mentions", "reactions", "teams",
    ]

    /// The shape of a value: placeholders for IDs, numbers and text; JSON objects by their keys.
    static func shape(_ value: String) -> String {
        shape(value, depth: 0)
    }

    private static func shape(_ value: String, depth: Int) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "\"\"" }
        if ConversationID.isValid(text) {
            if text.lowercased().hasSuffix("@thread.tacv2") { return "<channel ID>" }
            return "<\(ConversationKind(chatID: text).rawValue) ID>"
        }
        if text.wholeMatch(of: /\d{13}/) != nil { return "<13-digit>" }
        if text.wholeMatch(of: /[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}/) != nil { return "<guid>" }
        if text.wholeMatch(of: /\d+/) != nil { return "<number>" }
        if vocabulary.contains(text) { return text }
        if depth < 3, let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
            return "json " + shape(json: object, depth: depth + 1)
        }
        return "<text>"
    }

    private static func shape(json object: Any, depth: Int) -> String {
        switch object {
        case let dictionary as [String: Any]:
            let fields = dictionary.keys.sorted().map { "\(label($0)): \(shape(json: dictionary[$0]!, depth: depth))" }
            return "{" + fields.joined(separator: ", ") + "}"
        case let array as [Any]:
            let items = Array(Set(array.map { shape(json: $0, depth: depth) })).sorted()
            return "[" + items.prefix(3).joined(separator: ", ") + "]"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue.wholeMatch(of: /\d{13}/) != nil ? "<13-digit>" : "<number>"
        case let text as String:
            return shape(text, depth: depth)
        case is NSNull:
            return "null"
        default:
            return "<value>"
        }
    }
}
