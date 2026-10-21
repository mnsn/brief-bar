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

/// One of a source's menu-bar sections.
package struct SectionInfo: Sendable, Identifiable {
    package var id: SectionID
    /// Such as "Group Chats", for its tab when an item shows several sections.
    package var title: String

    package init(id: SectionID, title: String) {
        self.id = id
        self.title = title
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
    case menuBar
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
    /// What the section's popover shows.
    func panel(for section: SectionID) -> AnyView
    /// The section's popover is about to open.
    func panelWillShow(_ section: SectionID)

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
    package var showPanel: (SectionID) -> Void = { _ in }
    package var closePanels: () -> Void = {}

    package init(defaults: UserDefaults, isDemo: Bool) {
        self.defaults = defaults
        self.isDemo = isDemo
        loginItem = LoginItem()
        notifier = Notifier()
        fullDiskAccess = FullDiskAccess(defaults: defaults)
    }
}
