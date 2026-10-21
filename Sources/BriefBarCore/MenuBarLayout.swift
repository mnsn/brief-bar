import Foundation

/// BriefBar's menu-bar items, left to right, the sections each one shows, and the sections you've hidden.
///
/// Each section has its own item until you put it in another one, such as Azure DevOps with Copilot, or hide it.
/// Where a section goes is remembered while its source is off or it's hidden, so it comes back to the same item.
/// Sections that this version doesn't know are kept, for a later version, but never shown.
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
    /// Sections no item shows. Each keeps its place in `items`, for when you show it again.
    public private(set) var hidden: [SectionID]

    public init(items: [Item] = [], hidden: [SectionID] = []) {
        self.items = []
        self.hidden = []
        for item in items {
            let sections = item.sections.reduce(into: [SectionID]()) { kept, section in
                if !kept.contains(section) && self.item(containing: section) == nil { kept.append(section) }
            }
            guard !sections.isEmpty else { continue }
            self.items.append(Item(id: uniqueID(item.id), sections: sections))
        }
        for section in hidden where !self.hidden.contains(section) {
            self.hidden.append(section)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            items: try container.decode([Item].self, forKey: .items),
            hidden: try container.decodeIfPresent([SectionID].self, forKey: .hidden) ?? []
        )
    }

    /// The items for the sections that are on and not hidden, in order, each with the sections of its own that
    /// show. Sections that aren't placed yet get items of their own, after the others.
    public func visibleItems(showing sections: [SectionID]) -> [Item] {
        let shown = sections.filter { !isHidden($0) }
        var visible = items.compactMap { item -> Item? in
            let sections = item.sections.filter(shown.contains)
            return sections.isEmpty ? nil : Item(id: item.id, sections: sections)
        }
        var layout = self
        for section in shown where item(containing: section) == nil {
            let id = layout.uniqueID(section.rawValue)
            layout.items.append(Item(id: id, sections: [section]))
            visible.append(Item(id: id, sections: [section]))
        }
        return visible
    }

    public func item(containing section: SectionID) -> Item? {
        items.first { $0.sections.contains(section) }
    }

    public func isHidden(_ section: SectionID) -> Bool {
        hidden.contains(section)
    }

    /// Hides `section`. It keeps its place, so showing it again puts it back in the same item.
    public mutating func hide(_ section: SectionID) {
        place([section])
        if !isHidden(section) { hidden.append(section) }
    }

    /// Shows `section` again, in the item it was in.
    public mutating func show(_ section: SectionID) {
        hidden.removeAll { $0 == section }
    }

    /// For a source you've just turned on: places its sections, and shows them again if you'd hidden all of them,
    /// so turning it on always puts it in the menu bar.
    public mutating func sourceTurnedOn(_ sections: [SectionID]) {
        place(sections)
        if sections.allSatisfy(isHidden) {
            sections.forEach { show($0) }
        }
    }

    /// Gives each section that isn't in an item yet an item of its own, at the end, in the given order.
    public mutating func place(_ sections: [SectionID]) {
        for section in sections where item(containing: section) == nil {
            items.append(Item(id: uniqueID(section.rawValue), sections: [section]))
        }
    }

    /// Moves `section` into the item that shows `other`, after its sections, and shows it if it was hidden. An
    /// item left empty disappears.
    public mutating func combine(_ section: SectionID, with other: SectionID) {
        guard section != other else { return }
        show(section)
        place([other])
        remove(section)
        guard let index = items.firstIndex(where: { $0.sections.contains(other) }) else { return }
        items[index].sections.append(section)
    }

    /// Moves `section` into an item of its own, right after the item it was in, and shows it if it was hidden.
    public mutating func separate(_ section: SectionID) {
        show(section)
        guard let index = items.firstIndex(where: { $0.sections.contains(section) }) else {
            place([section])
            return
        }
        guard items[index].sections.count > 1 else { return }
        items[index].sections.removeAll { $0 == section }
        items.insert(Item(id: uniqueID(section.rawValue), sections: [section]), at: index + 1)
    }

    /// Puts every section in one item: `sections` first, in their order, then the others already placed, so a
    /// source you turn on later joins it too. The item keeps the ID of the one that had the first section, so it
    /// stays where that one was in the menu bar. Hidden sections stay hidden.
    public mutating func combineAll(_ sections: [SectionID]) {
        var all: [SectionID] = []
        for section in sections + items.flatMap(\.sections) where !all.contains(section) {
            all.append(section)
        }
        guard let first = all.first else { return }
        items = [Item(id: item(containing: first)?.id ?? first.rawValue, sections: all)]
    }

    /// Gives every section an item of its own, in their order. Each item stays with its first section; the
    /// others get new ones.
    public mutating func separateAll() {
        var taken = Set(items.map(\.id))
        items = items.flatMap { item in
            item.sections.enumerated().map { index, section in
                guard index > 0 else { return Item(id: item.id, sections: [section]) }
                let id = Self.uniqueID(section.rawValue, taken: taken)
                taken.insert(id)
                return Item(id: id, sections: [section])
            }
        }
    }

    private mutating func remove(_ section: SectionID) {
        for index in items.indices {
            items[index].sections.removeAll { $0 == section }
        }
        items.removeAll { $0.sections.isEmpty }
    }

    /// `base`, or `base-2`, `base-3`… if an item already has it.
    private func uniqueID(_ base: String) -> String {
        Self.uniqueID(base, taken: Set(items.map(\.id)))
    }

    private static func uniqueID(_ base: String, taken: Set<String>) -> String {
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
