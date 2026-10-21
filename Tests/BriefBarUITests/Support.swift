import BriefBarCore
import Foundation

/// Settings kept in memory, so that tests leave nothing in ~/Library/Preferences.
final class MemorySettings: SettingsStorage {
    private var values: [String: Any] = [:]

    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}
