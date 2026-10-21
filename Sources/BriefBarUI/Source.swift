import AppKit
import BriefBarCore
import Combine
import SwiftUI

/// What a source tells you before you turn it on, in the Settings window.
package struct SourceDescription: Sendable {
    /// Goes up whenever the source starts reading more than it says here, so that it waits until you've
    /// seen the new description (see `SourceChoices`).
    package var version: Int
    /// One line, for the list of sources.
    package var summary: String
    /// What BriefBar reads for it, and what it keeps.
    package var reads: String
    /// Where it connects, or that it doesn't.
    package var network: String
    /// What it needs, and why.
    package var needs: String
    package var requirements: [Requirement]

    package init(
        version: Int, summary: String, reads: String, network: String, needs: String, requirements: [Requirement]
    ) {
        self.version = version
        self.summary = summary
        self.reads = reads
        self.network = network
        self.needs = needs
        self.requirements = requirements
    }
}

/// One of a source's sections: a list it shows in the menu bar, a page in a window and, for some, a part of a
/// desktop widget.
package struct SectionInfo: Sendable, Identifiable {
    package var id: SectionID
    /// Such as "Group Chats": its tab when a menu-bar item shows several sections, and its page.
    package var title: String
    /// An SF Symbol: its tab when tabs are small, and its page in a window's sidebar.
    package var symbol: String
    /// The color of its page's tile in a window's sidebar.
    package var tint: Color
    /// Where it can show. Every section can show in the menu bar and in windows.
    package var surfaces: Set<Surface>
    /// Where it's hidden until you show it, such as a widget that would cover your desktop after an update.
    package var hiddenAtFirst: Set<Surface>

    package init(
        id: SectionID, title: String, symbol: String, tint: Color,
        surfaces: Set<Surface> = [.menuBar, .windows], hiddenAtFirst: Set<Surface> = []
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.surfaces = surfaces.union([.menuBar, .windows])
        self.hiddenAtFirst = hiddenAtFirst
    }
}

/// What a section shows in the menu bar right now.
package struct MenuBarSegment: Equatable {
    /// A symbol shown first, in the menu bar's own color, such as the source's icon. Nil for none.
    package var glyph: String?
    /// What follows the glyph: colored symbols and counts. Empty for the glyph alone.
    package var title: NSAttributedString
    /// For the tooltip and VoiceOver, such as "Teams: 2 unread chats".
    package var summary: String
    /// How many things need you, for the section's tab when an item shows several. 0 for none.
    package var count: Int
    /// Something needs you here, or something's wrong: an item that shows several sections opens at it.
    package var needsAttention: Bool

    package init(glyph: String?, title: NSAttributedString, summary: String, count: Int, needsAttention: Bool) {
        self.glyph = glyph
        self.title = title
        self.summary = summary
        self.count = count
        self.needsAttention = needsAttention
    }
}

/// Where the Settings window opens.
package enum SettingsDestination: Hashable, Sendable {
    case general
    case source(SourceID)
    /// Which sections the menu bar, the widgets or the windows show, and which share an item.
    case layout(Surface)
}

/// One source, as the app sees it. It's created at launch whether it's on or not, and does nothing,
/// reads nothing and checks nothing until `start()`.
@MainActor
package protocol BriefBarSource: AnyObject {
    var id: SourceID { get }
    /// Such as "Microsoft Teams".
    var name: String { get }
    /// An SF Symbol for the source in Settings.
    var symbol: String { get }
    var description: SourceDescription { get }
    /// Its menu-bar sections, in their default order.
    var sections: [SectionInfo] { get }

    /// Starts reading: at launch while the source is on, and when you turn it on.
    func start()
    /// Stops reading, and closes its windows and widget.
    func stop()
    /// Deletes what it saved about your data, but not its settings. Called after `stop()` when you turn it off.
    func deleteSavedData()
    /// Called once you've turned it on, after `start()`: asks for what it needs.
    func didTurnOn()

    func segment(for section: SectionID) -> MenuBarSegment
    /// Fires when what its sections show in the menu bar may have changed.
    var segmentsChanged: AnyPublisher<Void, Never> { get }
    /// What the section's popover shows. It reads `\.panelStyle` to fit a popover or a window's page.
    func panel(for section: SectionID) -> AnyView
    /// How wide its panels are in a popover. An item that shows several sections makes each as wide as the
    /// widest.
    var panelWidth: CGFloat { get }
    /// The section's popover is about to open.
    func panelWillShow(_ section: SectionID)

    /// The section's page in a window. By default, its panel, filling the page.
    func page(for section: SectionID) -> AnyView
    /// The section's page is about to show. By default, what `panelWillShow` does.
    func pageWillShow(_ section: SectionID)

    /// The section's part of a desktop widget, for sections that can show in widgets: a header, then up to
    /// `rows` rows. It fills the widget's width.
    func widget(for section: SectionID, size: WidgetSize, rows: Int) -> AnyView
    /// How tall the section's part of a widget is with `rows` rows.
    func widgetHeight(for section: SectionID, rows: Int) -> CGFloat
    /// How wide a widget of this size needs to be for the section.
    func widgetWidth(for section: SectionID, size: WidgetSize) -> CGFloat
    /// The source's items in the context menu of a widget that shows the section: its settings, and a way to
    /// open the app it reads.
    func widgetMenu(for section: SectionID) -> AnyView

    /// Its settings in the Settings window, while it's on.
    func settingsView() -> AnyView
    /// How what it needs stands (signed in, allowed…), above its settings while it's on. Nil for nothing.
    func statusView() -> AnyView?
    /// A click on one of its notifications.
    func openNotification(_ userInfo: [String: String])

    /// Loads its data once, without watching for changes, for `--render`.
    func loadForRendering() async
    /// More pictures for `--render`, such as its widget at each size: a name for the file, and the view.
    func extraRenderings() -> [(name: String, view: AnyView)]
}

extension BriefBarSource {
    package func didTurnOn() {}
    package func statusView() -> AnyView? { nil }
    package func openNotification(_ userInfo: [String: String]) {}
    package func loadForRendering() async {}
    package func extraRenderings() -> [(name: String, view: AnyView)] { [] }

    package func page(for section: SectionID) -> AnyView {
        AnyView(panel(for: section).environment(\.panelStyle, .page))
    }

    package func pageWillShow(_ section: SectionID) {
        panelWillShow(section)
    }

    package func widget(for section: SectionID, size: WidgetSize, rows: Int) -> AnyView { AnyView(EmptyView()) }
    package func widgetHeight(for section: SectionID, rows: Int) -> CGFloat { 0 }
    package func widgetWidth(for section: SectionID, size: WidgetSize) -> CGFloat { size == .compact ? 280 : 320 }
    package func widgetMenu(for section: SectionID) -> AnyView { AnyView(EmptyView()) }

    package func info(for section: SectionID) -> SectionInfo? {
        sections.first { $0.id == section }
    }
}

/// Where a section's panel shows.
package enum PanelStyle: Equatable, Sendable {
    /// In a menu-bar item's popover: as wide as `width` when the item shows several sections (the widest of
    /// their panels, so the popover keeps its width as you switch tabs), or nil for the panel's own width.
    case popover(width: CGFloat?)
    /// As a window's page, filling it.
    case page
}

private struct PanelStyleKey: EnvironmentKey {
    static let defaultValue = PanelStyle.popover(width: nil)
}

private struct ShownSectionKey: EnvironmentKey {
    static let defaultValue: SectionID? = nil
}

extension EnvironmentValues {
    package var panelStyle: PanelStyle {
        get { self[PanelStyleKey.self] }
        set { self[PanelStyleKey.self] = newValue }
    }

    /// The section whose panel, page or part of a widget this is, for menus that act on it.
    package var shownSection: SectionID? {
        get { self[ShownSectionKey.self] }
        set { self[ShownSectionKey.self] = newValue }
    }
}

extension View {
    /// A panel's list: in a popover, as tall as what it shows, up to `maxHeight`; on a page, the page's height.
    package func panelListHeight(_ contentHeight: CGFloat, max maxHeight: CGFloat) -> some View {
        modifier(PanelListHeight(contentHeight: contentHeight, maxHeight: maxHeight))
    }

    /// A panel: `width` wide in a popover of its own, the popover's width when it shares one, or a page's width.
    package func panelFrame(width: CGFloat) -> some View {
        modifier(PanelFrame(width: width))
    }
}

private struct PanelListHeight: ViewModifier {
    let contentHeight: CGFloat
    let maxHeight: CGFloat
    @Environment(\.panelStyle) private var style

    func body(content: Content) -> some View {
        if style == .page {
            content.frame(maxHeight: .infinity)
        } else {
            content.frame(height: min(max(contentHeight, 60), maxHeight))
        }
    }
}

private struct PanelFrame: ViewModifier {
    let width: CGFloat
    @Environment(\.panelStyle) private var style

    func body(content: Content) -> some View {
        switch style {
        case .popover(let shared):
            content.frame(width: shared ?? width)
        case .page:
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// What the app gives every source: shared services, and ways to reach the app's own windows and items.
@MainActor
package final class AppServices: ObservableObject {
    /// The preferences sources keep their settings in: the app's own, or a throwaway suite for `--demo`.
    package let defaults: UserDefaults
    /// Made-up data instead of yours (`--demo`).
    package let isDemo: Bool
    package let loginItem: LoginItem
    package let notifier: Notifier
    package let fullDiskAccess: FullDiskAccess

    package var openSettings: (SettingsDestination) -> Void = { _ in }
    /// Opens the list that shows a section: false when it's hidden from the menu bar.
    package var showPanel: (SectionID) -> Bool = { _ in false }
    package var closePanels: () -> Void = {}
    /// Opens the window that shows a section's page, at that page, or the first window for nil.
    package var openWindow: (SectionID?) -> Void = { _ in }

    package init(defaults: UserDefaults, isDemo: Bool) {
        self.defaults = defaults
        self.isDemo = isDemo
        loginItem = LoginItem()
        notifier = Notifier()
        fullDiskAccess = FullDiskAccess(defaults: defaults)
    }
}
