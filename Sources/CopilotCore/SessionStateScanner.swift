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
        return value("name", inWorkspace: text)
    }

    /// One of the top-level values in a session's `workspace.yaml`, such as its `name`, or its `cwd`, the folder it
    /// works in, without its quotes; nil when it isn't there or is empty.
    public static func value(_ key: String, inWorkspace text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("\(key):") {
            var value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
