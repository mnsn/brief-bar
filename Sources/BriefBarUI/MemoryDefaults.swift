import Foundation

/// Preferences kept in memory, for `--demo` and `--render`: they never touch the app's own, and leave nothing
/// in ~/Library/Preferences, as a UserDefaults suite would even once its domain is removed. Every typed getter
/// and setter goes through `object(forKey:)` and `set(_:forKey:)`.
package final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any]

    /// - Parameter values: what it starts with, such as a copy of the app's preferences.
    package init(values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: nil)!
    }

    override package func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    override package func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    override package func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
    }

    override package func dictionaryRepresentation() -> [String: Any] {
        values
    }
}
