import Foundation

/// Where BriefBar shows the sources' sections.
public enum Surface: String, CaseIterable, Codable, Sendable {
    /// Items in the menu bar, each with a list that has a tab for each of its sections.
    case menuBar
    /// Desktop widgets, each with its sections one above the other.
    case widgets
    /// Windows, each with a page for each of its sections.
    case windows

    /// Where its layout is saved.
    public var defaultsKey: String {
        switch self {
        case .menuBar: return "menuBarLayout"
        case .widgets: return "widgetLayout"
        case .windows: return "windowLayout"
        }
    }

    /// Whether sections that aren't placed yet join the first item, rather than getting items of their own:
    /// BriefBar starts with one window for every page, but with a menu-bar item and a widget for each section.
    public var startsTogether: Bool {
        self == .windows
    }

    /// The ID of the item that sections join when they start together.
    public static let firstItemID = "main"
}

/// Where you can drop a section in Settings: in an item with others, in an item of its own, or nowhere.
public enum SectionDestination: Hashable, Sendable {
    /// In the item that has this other section.
    case with(SectionID)
    /// In an item of its own.
    case alone
    /// Nowhere.
    case hidden
}

/// The items of a surface (menu-bar items, widgets or windows), in order, the sections each one shows, and the
/// sections you've hidden from it.
///
/// Each section starts in an item of its own, or for windows in the first one, until you put it in another
/// item, or hide it. Where a section goes is remembered while its source is off or it's hidden, so it comes
/// back to the same item. Sections that this version doesn't know are kept, for a later version, but never
/// shown.
public struct SectionLayout: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        /// Stable, so the item keeps its place: in the menu bar where you dragged it, and a widget's or a
        /// window's position on screen.
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
    /// Which surface this is. It isn't saved: it's where the layout is saved.
    public private(set) var surface: Surface

    private enum CodingKeys: String, CodingKey {
        case items, hidden
    }

    public init(_ surface: Surface = .menuBar, items: [Item] = [], hidden: [SectionID] = []) {
        self.surface = surface
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
    /// show. Sections that aren't placed yet go where `place` would put them.
    public func visibleItems(showing sections: [SectionID]) -> [Item] {
        let shown = sections.filter { !isHidden($0) }
        var layout = self
        layout.place(shown)
        return layout.items.compactMap { item in
            let visible = item.sections.filter(shown.contains)
            return visible.isEmpty ? nil : Item(id: item.id, sections: visible)
        }
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
    /// so turning it on always shows it.
    public mutating func sourceTurnedOn(_ sections: [SectionID]) {
        place(sections)
        if sections.allSatisfy(isHidden) {
            sections.forEach { show($0) }
        }
    }

    /// Places each section that isn't in an item yet, in the given order: in an item of its own at the end, or
    /// for a surface whose sections start together, in the first item.
    public mutating func place(_ sections: [SectionID]) {
        for section in sections where item(containing: section) == nil {
            if surface.startsTogether {
                if items.isEmpty {
                    items.append(Item(id: uniqueID(Surface.firstItemID), sections: [section]))
                } else {
                    items[0].sections.append(section)
                }
            } else {
                items.append(Item(id: uniqueID(section.rawValue), sections: [section]))
            }
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
            items.append(Item(id: uniqueID(section.rawValue), sections: [section]))
            return
        }
        guard items[index].sections.count > 1 else { return }
        items[index].sections.removeAll { $0 == section }
        items.insert(Item(id: uniqueID(section.rawValue), sections: [section]), at: index + 1)
    }

    /// Puts `section` where you dropped it in Settings. Dropped in the item it's already in, it stays in its place
    /// there, and shows if it was hidden.
    public mutating func move(_ section: SectionID, to destination: SectionDestination) {
        switch destination {
        case .with(let other):
            place([other])
            if item(containing: other)?.sections.contains(section) == true {
                show(section)
            } else {
                combine(section, with: other)
            }
        case .alone:
            separate(section)
        case .hidden:
            hide(section)
        }
    }

    /// Puts every section in one item: `sections` first, in their order, then the others already placed, so a
    /// source you turn on later joins it too. The item keeps the ID of the one that had the first section, so it
    /// stays where that one was. Hidden sections stay hidden.
    public mutating func combineAll(_ sections: [SectionID]) {
        var all: [SectionID] = []
        for section in sections + items.flatMap(\.sections) where !all.contains(section) {
            all.append(section)
        }
        guard let first = all.first else { return }
        let id = item(containing: first)?.id ?? (surface.startsTogether ? Surface.firstItemID : first.rawValue)
        items = [Item(id: id, sections: all)]
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

    /// What's saved for the surface, or no items when there's nothing saved or it can't be read: every section
    /// then starts where the surface puts it.
    public static func load(_ surface: Surface, from defaults: some SettingsStorage) -> SectionLayout {
        guard let data = defaults.data(forKey: surface.defaultsKey),
              var layout = try? JSONDecoder().decode(SectionLayout.self, from: data)
        else { return SectionLayout(surface) }
        layout.surface = surface
        return layout
    }

    public func save(to defaults: some SettingsStorage) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: surface.defaultsKey)
        }
    }
}
