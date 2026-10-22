import Foundation

/// How a menu-bar item shows its sections: side by side, each with its source's own symbols, as items always did, or
/// added up by what they mean (`ItemState`), the same for every source; and its list, with a tab for each section,
/// or one list by state. Each item starts as items always did, until you switch it over in Settings.
public struct MenuBarItemOptions: Codable, Equatable, Sendable {
    /// Adds its sections' counts up by state. Only for an item that shows several sections.
    public var byState: Bool
    /// The states it shows when it adds them up. Running starts off.
    public var states: Set<ItemState>
    /// Its list shows every section's things together, by state, rather than a tab for each section. Only for an item
    /// that shows several sections.
    public var listByState: Bool

    public static let defaultStates: Set<ItemState> = [.needsYou, .failing, .done]

    /// The order an item shows states in: ✋ ✕ ✓, then ⚡.
    public static let order: [ItemState] = [.needsYou, .failing, .done, .running]

    public init(byState: Bool = false, states: Set<ItemState> = defaultStates, listByState: Bool = false) {
        self.byState = byState
        self.states = states
        self.listByState = listByState
    }

    /// The states it shows, in the menu bar's order.
    public var shownStates: [ItemState] {
        Self.order.filter(states.contains)
    }

    private enum CodingKeys: String, CodingKey {
        case byState, states, listByState
    }

    /// What's missing keeps its default, and states this version doesn't know are left out, so options that a
    /// later version saves still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        byState = try container.decodeIfPresent(Bool.self, forKey: .byState) ?? false
        if let names = try container.decodeIfPresent([String].self, forKey: .states) {
            states = Set(names.compactMap(ItemState.init(rawValue:)))
        } else {
            states = Self.defaultStates
        }
        listByState = try container.decodeIfPresent(Bool.self, forKey: .listByState) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(byState, forKey: .byState)
        try container.encode(ItemState.allCases.filter(states.contains), forKey: .states)
        try container.encode(listByState, forKey: .listByState)
    }

    // MARK: Saving

    /// Where every menu-bar item's options are saved, by the item's ID.
    public static let defaultsKey = "menuBarItemOptions"

    public static func load(from defaults: some SettingsStorage) -> [String: MenuBarItemOptions] {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([String: MenuBarItemOptions].self, from: $0) } ?? [:]
    }

    public static func save(_ options: [String: MenuBarItemOptions], to defaults: some SettingsStorage) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(options) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// The options of the items `layout` still has, without those that are the defaults: an item that goes away
    /// takes its options with it, so one that later gets its ID starts over.
    public static func kept(_ options: [String: MenuBarItemOptions], in layout: SectionLayout) -> [String: MenuBarItemOptions] {
        let ids = Set(layout.items.map(\.id))
        return options.filter { ids.contains($0.key) && $0.value != MenuBarItemOptions() }
    }
}
