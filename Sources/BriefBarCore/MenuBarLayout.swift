import Foundation

/// BriefBar's menu-bar items, left to right, and the sections each one shows.
///
/// Each section has its own item until you put it in another one, such as Azure DevOps with Copilot. Where a
/// section goes is remembered while its source is off, so it comes back to the same item. Sections that this
/// version doesn't know are kept, for a later version, but never shown.
public struct MenuBarLayout: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        /// Stable, so the item keeps the place you dragged it to in the menu bar.
        public var id: String
        public var sections: [SectionID]

        public init(id: String, sections: [SectionID]) {
            self.id = id
            self.sections = sections
        }
    }

    public private(set) var items: [Item]

    public init(items: [Item] = []) {
        self.items = []
        for item in items {
            let sections = item.sections.reduce(into: [SectionID]()) { kept, section in
                if !kept.contains(section) && self.item(containing: section) == nil { kept.append(section) }
            }
            guard !sections.isEmpty else { continue }
            self.items.append(Item(id: uniqueID(item.id), sections: sections))
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(items: try container.decode([Item].self, forKey: .items))
    }

    /// The items for the sections that are on, in order, each with the sections of its own that are on.
    /// Sections that aren't placed yet get items of their own, after the others.
    public func visibleItems(showing sections: [SectionID]) -> [Item] {
        var visible = items.compactMap { item -> Item? in
            let shown = item.sections.filter(sections.contains)
            return shown.isEmpty ? nil : Item(id: item.id, sections: shown)
        }
        var layout = self
        for section in sections where item(containing: section) == nil {
            let id = layout.uniqueID(section.rawValue)
            layout.items.append(Item(id: id, sections: [section]))
            visible.append(Item(id: id, sections: [section]))
        }
        return visible
    }

    public func item(containing section: SectionID) -> Item? {
        items.first { $0.sections.contains(section) }
    }

    /// Gives each section that isn't in an item yet an item of its own, at the end, in the given order.
    public mutating func place(_ sections: [SectionID]) {
        for section in sections where item(containing: section) == nil {
            items.append(Item(id: uniqueID(section.rawValue), sections: [section]))
        }
    }

    /// Moves `section` into the item that shows `other`, after its sections. An item left empty disappears.
    public mutating func combine(_ section: SectionID, with other: SectionID) {
        guard section != other else { return }
        place([other])
        remove(section)
        guard let index = items.firstIndex(where: { $0.sections.contains(other) }) else { return }
        items[index].sections.append(section)
    }

    /// Moves `section` into an item of its own, right after the item it was in.
    public mutating func separate(_ section: SectionID) {
        guard let index = items.firstIndex(where: { $0.sections.contains(section) }) else {
            place([section])
            return
        }
        guard items[index].sections.count > 1 else { return }
        items[index].sections.removeAll { $0 == section }
        items.insert(Item(id: uniqueID(section.rawValue), sections: [section]), at: index + 1)
    }

    private mutating func remove(_ section: SectionID) {
        for index in items.indices {
            items[index].sections.removeAll { $0 == section }
        }
        items.removeAll { $0.sections.isEmpty }
    }

    /// `base`, or `base-2`, `base-3`… if an item already has it.
    private func uniqueID(_ base: String) -> String {
        let taken = Set(items.map(\.id))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    // MARK: Saving

    public static let defaultsKey = "menuBarLayout"

    /// What's saved, or no items when there's nothing saved or it can't be read: every section then gets an
    /// item of its own.
    public static func load(from defaults: some SettingsStorage) -> MenuBarLayout {
        guard let data = defaults.data(forKey: defaultsKey),
              let layout = try? JSONDecoder().decode(MenuBarLayout.self, from: data)
        else { return MenuBarLayout() }
        return layout
    }

    public func save(to defaults: some SettingsStorage) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
