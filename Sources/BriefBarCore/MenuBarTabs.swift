import Foundation

/// The tab each menu-bar item's list opens at, by the item's ID: the one it showed last, whether it opened
/// there or you switched to it. It's kept in the preferences, so it outlasts a restart.
public struct MenuBarTabs: Equatable, Sendable {
    private var tabs: [String: SectionID]

    public init(_ tabs: [String: SectionID] = [:]) {
        self.tabs = tabs
    }

    /// The tab `item`'s list showed last, if it has opened.
    public func last(for item: String) -> SectionID? {
        tabs[item]
    }

    public mutating func remember(_ section: SectionID, for item: String) {
        tabs[item] = section
    }

    /// The tab `item`'s list opens at, of its `sections`: `asked`, when something opens it at a section, such
    /// as a notification; otherwise the one it showed last; otherwise, the first time or once that one is in
    /// another item, the first that needs you, or the first. Nil for an item without sections.
    public func tab(
        for item: String, sections: [SectionID], asked: SectionID? = nil, needsYou: (SectionID) -> Bool
    ) -> SectionID? {
        if let asked, sections.contains(asked) {
            return asked
        }
        if let last = tabs[item], sections.contains(last) {
            return last
        }
        return sections.first(where: needsYou) ?? sections.first
    }

    // MARK: Saving

    public static let defaultsKey = "menuBarTabs"

    /// What's saved, or no tabs when there's nothing saved or it can't be read.
    public static func load(from defaults: some SettingsStorage) -> MenuBarTabs {
        let saved = defaults.object(forKey: defaultsKey) as? [String: String] ?? [:]
        return MenuBarTabs(saved.mapValues(SectionID.init(rawValue:)))
    }

    public func save(to defaults: some SettingsStorage) {
        defaults.set(tabs.mapValues(\.rawValue), forKey: Self.defaultsKey)
    }
}
