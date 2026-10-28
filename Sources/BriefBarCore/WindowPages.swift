import Foundation

/// A window's pages: an Overview first, when it shows several sections, then the Notifications page, while it has one,
/// then a page for each section.
public struct WindowPages: Equatable, Sendable {
    /// The Overview's page: everything on the window's other pages by state, with the brief.
    public static let overview = SectionID(rawValue: "briefbar.overview")
    /// The Notifications page: what BriefBar notified you of lately, from every source (`NotificationHistory`). Only a
    /// window with an Overview has it.
    public static let notifications = SectionID(rawValue: "briefbar.notifications")

    public var sections: [SectionID]
    /// Whether it shows the Notifications page, after its Overview: a window without an Overview doesn't.
    public var showsNotifications: Bool

    public init(sections: [SectionID], notifications: Bool = false) {
        self.sections = sections
        showsNotifications = notifications
    }

    public var pages: [SectionID] {
        guard sections.count > 1 else { return sections }
        return [Self.overview] + (showsNotifications ? [Self.notifications] : []) + sections
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

    /// The window that the Overview at the top of every list opens: of `windows`, in order, the first with several
    /// pages, which is the first with an Overview. Nil when none has one, as when each window shows one section.
    public static func overviewWindow(in windows: [SectionLayout.Item]) -> SectionLayout.Item? {
        windows.first { WindowPages(sections: $0.sections).hasOverview }
    }
}
