import Foundation

/// Fallback session discovery straight from `session-state/`, used only if the app database
/// has never been readable. Lists sessions whose event log changed recently.
public enum SessionStateScanner {
    public static func recentSessions(
        paths: CopilotPaths, maxAge: TimeInterval = 24 * 3_600, now: Date = Date()
    ) -> [SessionMeta] {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: paths.sessionState, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return directories.compactMap { directory -> SessionMeta? in
            let events = directory.appendingPathComponent("events.jsonl")
            guard let attributes = try? fileManager.attributesOfItem(atPath: events.path),
                  let modified = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) <= maxAge
            else { return nil }
            let id = directory.lastPathComponent
            return SessionMeta(
                id: id,
                name: workspaceName(in: directory) ?? "Session \(id.prefix(8))",
                sessionType: "unknown",
                isRunning: nil,
                updatedAt: modified
            )
        }
    }

    static func workspaceName(in directory: URL) -> String? {
        let file = directory.appendingPathComponent("workspace.yaml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        // A name in double quotes can have line breaks, written `\n`.
        return value("name", inWorkspace: text).map(PlainText.singleLine).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// One of the top-level values in a session's `workspace.yaml`, such as its `name`, or its `cwd`, the folder it
    /// works in, as YAML reads it (`scalar(_:)`); nil when it isn't there or is empty.
    public static func value(_ key: String, inWorkspace text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("\(key):") {
            let value = scalar(line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// A value on one line, without its quotes: in single quotes, `''` is a quote; in double quotes, `\` starts an
    /// escape, such as `\"`, `\\`, `\n` or `\u00e9`. One that isn't quoted is as it is.
    static func scalar(_ text: String) -> String {
        guard text.count >= 2, let quote = text.first, quote == "\"" || quote == "'", text.last == quote else { return text }
        let inner = text.dropFirst().dropLast()
        guard quote == "\"" else { return inner.replacingOccurrences(of: "''", with: "'") }
        let scalars = Array(inner.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            guard scalar == "\\", index < scalars.count else {
                result.append(scalar)
                continue
            }
            let escape = scalars[index]
            index += 1
            switch escape {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "\"", "\\", "/", " ": result.append(escape)
            case "x", "u", "U":
                let length = escape == "x" ? 2 : escape == "u" ? 4 : 8
                let end = min(index + length, scalars.count)
                let digits = String(String.UnicodeScalarView(scalars[index..<end]))
                if digits.unicodeScalars.count == length, let code = UInt32(digits, radix: 16), let decoded = Unicode.Scalar(code) {
                    result.append(decoded)
                    index = end
                } else {
                    result.append(scalar)
                    result.append(escape)
                }
            default:
                result.append(scalar)
                result.append(escape)
            }
        }
        return String(result)
    }
}
