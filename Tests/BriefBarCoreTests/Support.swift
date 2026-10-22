import BriefBarCore
import Foundation

/// Settings kept in memory, so that tests leave nothing in ~/Library/Preferences.
final class MemorySettings: SettingsStorage {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BriefBarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // FSEvents reports resolved paths (/private/var/…), so use that form throughout.
    return url.resolvingSymlinksInPath()
}

func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

func iso(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

/// Seconds after a fixed point in time.
func t(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_792_000_000 + seconds)
}

struct TestError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The package's Swift sources that match `pattern`, by path under `Sources/`, such as `BriefBarCore/Attribution.swift`.
func sourcesMatching(_ pattern: some RegexComponent, filePath: String = #filePath) throws -> Set<String> {
    // Resolved, as the enumerator's paths can be: a checkout under /tmp is under /private/tmp.
    let sources = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Sources").standardizedFileURL.resolvingSymlinksInPath()
    guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
        throw TestError("Can't list \(sources.path)")
    }
    var matching: Set<String> = []
    var scanned = 0
    for case let file as URL in files where file.pathExtension == "swift" {
        scanned += 1
        let text = try String(contentsOf: file, encoding: .utf8)
        guard text.contains(pattern) else { continue }
        let path = file.resolvingSymlinksInPath().pathComponents
        guard path.starts(with: sources.pathComponents) else { throw TestError("\(file.path) isn't in \(sources.path)") }
        matching.insert(path.dropFirst(sources.pathComponents.count).joined(separator: "/"))
    }
    guard scanned > 0 else { throw TestError("No sources in \(sources.path)") }
    return matching
}
