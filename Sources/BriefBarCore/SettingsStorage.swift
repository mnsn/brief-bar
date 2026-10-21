import Foundation

/// The UserDefaults methods that BriefBar's own settings use, so that tests can keep them in memory: a
/// UserDefaults suite leaves a file in ~/Library/Preferences, even once its domain is removed.
public protocol SettingsStorage: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: SettingsStorage {}
