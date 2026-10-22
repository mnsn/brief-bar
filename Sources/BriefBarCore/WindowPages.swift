import Foundation

/// A window's pages: an Overview first, when it shows several sections, then a page for each section.
public struct WindowPages: Equatable, Sendable {
    /// The Overview's page: everything on the window's other pages by state, with the brief.
    public static let overview = SectionID(rawValue: "briefbar.overview")

    public var sections: [SectionID]

    public init(sections: [SectionID]) {
        self.sections = sections
    }

    public var pages: [SectionID] {
        sections.count > 1 ? [Self.overview] + sections : sections
    }

    public var hasOverview: Bool {
        pages.first == Self.overview
    }

    /// The page that shows: the one chosen, while the window still has it, or the first, which is the Overview.
    public func current(chosen: SectionID?) -> SectionID? {
        chosen.flatMap { pages.contains($0) ? $0 : nil } ?? pages.first
    }

    /// The page to choose when asked for `section`: its page, if the window has one. Asked for none, a window opens on
    /// its Overview; one without keeps what it shows (nil).
    public func page(for section: SectionID?) -> SectionID? {
        guard let section else { return hasOverview ? Self.overview : nil }
        return pages.contains(section) ? section : nil
    }
}
