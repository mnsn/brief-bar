import BriefBarCore
import Foundation

/// Settings kept in memory, so that tests leave nothing in ~/Library/Preferences.
final class MemorySettings: SettingsStorage {
    private var values: [String: Any] = [:]

    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
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
