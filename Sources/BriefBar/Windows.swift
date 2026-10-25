import AppKit
import BriefBarCore
import BriefBarUI
import Combine
import SwiftUI

/// One BriefBar window: a page for each of its sections, with a sidebar to switch between them when there are
/// several. BriefBar stays a menu-bar app: it shows a Dock icon only while a window is open.
@MainActor
final class WindowHost: NSObject, NSWindowDelegate {
    let id: String
    let content: WindowContent
    private unowned let model: AppModel
    private var window: NSWindow?

    init(id: String, model: AppModel) {
        self.id = id
        self.model = model
        content = WindowContent(id: id, model: model)
        super.init()
    }

    var isOpen: Bool {
        window?.isVisible == true
    }

    func update(sections: [SectionID]) {
        content.update(sections: sections)
        if let window {
            configure(window)
        }
    }

    /// Shows the window, at `section`'s page if it has one.
    func show(at section: SectionID?) {
        content.select(section)
        let window = self.window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        updateOnScreen()
    }

    /// Whether the window shows on screen: open, not minimized, and not hidden behind other windows. Sources read
    /// some sections only while they're on screen.
    private func updateOnScreen() {
        content.isOnScreen = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let size = content.sections.count > 1 ? CGSize(width: 980, height: 700) : CGSize(width: 560, height: 700)
        // A title bar of its own, as Settings has, so the window's buttons don't sit on the sidebar.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        let host = NSHostingView(rootView: WindowView(content: content)
            .environmentObject(model.services)
            .environmentObject(model.services.loginItem))
        host.sizingOptions = []
        window.contentView = host
        configure(window)
        // The demo's windows open in the middle, and never move yours.
        let autosaveName = "BriefBar.window.\(id)"
        if model.services.isDemo || !window.setFrameUsingName(autosaveName) {
            window.center()
        }
        if !model.services.isDemo {
            window.setFrameAutosaveName(autosaveName)
        }
        self.window = window
        return window
    }

    private func configure(_ window: NSWindow) {
        window.title = content.title
        window.minSize = content.sections.count > 1 ? NSSize(width: 720, height: 480) : NSSize(width: 380, height: 420)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            content.isOnScreen = false
            model.windowDidClose(self)
        }
    }

    nonisolated func windowDidChangeOcclusionState(_ notification: Notification) {
        MainActor.assumeIsolated { updateOnScreen() }
    }

    nonisolated func windowDidMiniaturize(_ notification: Notification) {
        MainActor.assumeIsolated { updateOnScreen() }
    }

    nonisolated func windowDidDeminiaturize(_ notification: Notification) {
        MainActor.assumeIsolated { updateOnScreen() }
    }
}

/// A window's pages, and which one shows.
@MainActor
final class WindowContent: ObservableObject {
    /// The Overview's page, first in a window with several pages.
    static let overview = WindowPages.overview

    let id: String
    @Published private(set) var sections: [SectionID] = []
    @Published private(set) var selected: SectionID?
    unowned let model: AppModel
    /// What the Overview shows.
    let overviewList: StateListModel
    private var cancellables: Set<AnyCancellable> = []
    /// Whether its window shows on screen, as its host says.
    var isOnScreen = false {
        didSet { updateVisible() }
    }
    /// The sections the window shows on screen, and as what: a page, or the Overview's list by state. Empty while it's
    /// closed, minimized or hidden behind other windows.
    private var visible: [SectionID: SectionViewer.Kind] = [:]

    /// Each window's page, as you last left it, by the window's ID.
    private static let pagesKey = "windowPages"

    init(id: String, model: AppModel) {
        self.id = id
        self.model = model
        overviewList = StateListModel(model: model)
        let saved = model.services.defaults.dictionary(forKey: Self.pagesKey) as? [String: String]
        selected = saved?[id].map(SectionID.init(rawValue:))
    }

    /// Its pages: the Overview first, when it has several sections, then a page for each.
    var pages: [SectionID] {
        WindowPages(sections: sections).pages
    }

    /// The page that shows: the one you chose, or the first.
    var current: SectionID? {
        WindowPages(sections: sections).current(chosen: selected)
    }

    /// Such as "GitHub Copilot: Sessions" for a window with one page, for the window list and VoiceOver.
    var title: String {
        guard sections.count == 1, let section = sections.first, let source = model.source(for: section) else {
            return AppIdentity.name
        }
        let title = source.info(for: section)?.title ?? source.name
        return source.sections.count > 1 || title != source.name ? "\(source.name): \(title)" : source.name
    }

    func update(sections: [SectionID]) {
        self.sections = sections
        overviewList.update(sections: sections.count > 1 ? sections : [])
        updateVisible()
        // The sidebar's counts follow the menu bar's.
        cancellables.removeAll()
        var seen = Set<SourceID>()
        for source in sections.compactMap(model.source(for:)) where seen.insert(source.id).inserted {
            source.segmentsChanged
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in MainActor.assumeIsolated { self?.objectWillChange.send() } }
                .store(in: &cancellables)
        }
    }

    /// Shows `section`'s page, or for nil, the Overview, which a window opens on, and tells their sources, which may
    /// refresh; `--render` doesn't. A window without an Overview keeps the page that shows.
    func select(_ section: SectionID?, notify: Bool = true) {
        if let page = WindowPages(sections: sections).page(for: section) {
            selected = page
            var saved = model.services.defaults.dictionary(forKey: Self.pagesKey) as? [String: String] ?? [:]
            saved[id] = page.rawValue
            model.services.defaults.set(saved, forKey: Self.pagesKey)
        }
        if notify, let current {
            for section in current == Self.overview ? overviewList.sections : [current] {
                model.source(for: section)?.pageWillShow(section)
            }
        }
        updateVisible()
    }

    /// What needs you on the window's pages, for the Overview's place in the sidebar.
    var overviewSegment: MenuBarSegment {
        let states = model.states(of: sections)
        return MenuBarSegment(
            glyph: nil, title: NSAttributedString(), summary: states.needsYou == 0 ? "Nothing needs you" : "Needs you: \(states.needsYou)",
            count: states.needsYou, needsAttention: states.needsYou > 0, states: states
        )
    }

    /// Tells the sources which sections show, after the window opened, closed, was covered or switched pages.
    private func updateVisible() {
        var shown: [SectionID: SectionViewer.Kind] = [:]
        if isOnScreen, let current {
            if current == Self.overview {
                for section in overviewList.sections { shown[section] = .stateList }
            } else {
                shown[current] = .window
            }
        }
        overviewList.isShowing = isOnScreen && current == Self.overview
        guard shown != visible else { return }
        let before = visible
        visible = shown
        for (section, kind) in before where shown[section] != kind {
            model.source(for: section)?.sectionVisibilityChanged(section, isShowing: false, by: SectionViewer(kind, id: id))
        }
        for (section, kind) in shown where before[section] != kind {
            model.source(for: section)?.sectionVisibilityChanged(section, isShowing: true, by: SectionViewer(kind, id: id))
        }
    }
}

/// A window: the sidebar, when it has several pages, floating over the page that shows.
struct WindowView: View {
    @ObservedObject var content: WindowContent

    static let sidebarWidth: CGFloat = 220
    /// The sidebar floats this far from the window's edges.
    static let inset: CGFloat = 10

    var body: some View {
        HStack(spacing: 0) {
            if content.sections.count > 1 {
                WindowSidebar(content: content)
                    .frame(width: Self.sidebarWidth)
                    .floatingPanel(cornerRadius: 18)
                    .padding(Self.inset)
            }
            // The page takes the rest of the window's width, so a wide one, such as full screen, gets longer lines.
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(WindowBackdrop().ignoresSafeArea())
    }

    @ViewBuilder
    private var page: some View {
        if content.current == WindowContent.overview {
            OverviewPage(list: content.overviewList, model: content.model)
        } else if let section = content.current, let source = content.model.source(for: section) {
            source.page(for: section)
                .environment(\.shownSection, section)
                .id(section)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "macwindow")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Nothing to show")
                    .font(.headline)
                Text("Turn on a source, or show its pages in Settings › Windows.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A window's pages, by source, each with its count, then BriefBar's menu.
struct WindowSidebar: View {
    @ObservedObject var content: WindowContent

    var body: some View {
        let model = content.model
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let first = content.pages.first == WindowContent.overview ? 1 : 0
                    if first == 1 {
                        SidebarItem(
                            info: SectionInfo(id: WindowContent.overview, title: "Overview", symbol: AppSymbols.app, tint: .accentColor),
                            segment: content.overviewSegment, isSelected: content.current == WindowContent.overview, shortcut: 1
                        ) {
                            content.select(WindowContent.overview)
                        }
                    }
                    ForEach(Array(content.sections.enumerated()), id: \.element) { index, section in
                        if let source = model.source(for: section), let info = source.info(for: section) {
                            if index == 0 || model.source(for: content.sections[index - 1])?.id != source.id {
                                Text(source.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 8)
                                    .padding(.top, index == 0 && first == 0 ? 2 : 12)
                                    .padding(.bottom, 2)
                            }
                            SidebarItem(
                                info: info, segment: source.segment(for: section), isSelected: content.current == section,
                                shortcut: index + first < 9 ? index + first + 1 : nil
                            ) {
                                content.select(section)
                            }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            WindowUpdateButton(updates: model.services.updates)
                .padding(.horizontal, 8)

            HStack {
                Spacer()
                Menu {
                    Button("Arrange Windows…") { model.openSettings(.layout(.windows)) }
                    Divider()
                    AppMenuItems(source: nil)
                        .environment(\.panelStyle, .page)
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// That an update is waiting, in the sidebar.
private struct WindowUpdateButton: View {
    @ObservedObject var updates: UpdateStatus

    var body: some View {
        if let version = updates.pendingVersion {
            Button {
                updates.check()
            } label: {
                Label("BriefBar \(version) is available", systemImage: "arrow.down.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Update BriefBar")
        }
    }
}

private struct SidebarItem: View {
    let info: SectionInfo
    let segment: MenuBarSegment
    let isSelected: Bool
    /// ⌘1 to ⌘9.
    let shortcut: Int?
    let action: () -> Void

    @LocalState private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [info.tint.opacity(0.85), info.tint], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
                    Image(systemName: info.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
                Text(info.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if segment.count > 0 {
                    Text("\(segment.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 18)
                        .background(Capsule().fill(segment.needsAttention ? info.tint : Color.secondary))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10) : isHovered ? Color.primary.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .modifier(PageShortcut(number: shortcut))
        .help(shortcut.map { "\(info.title) (⌘\($0))" } ?? info.title)
        .accessibilityLabel(info.title)
        .accessibilityValue(segment.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PageShortcut: ViewModifier {
    let number: Int?

    func body(content: Content) -> some View {
        if let number, let character = String(number).first {
            content.keyboardShortcut(KeyEquivalent(character), modifiers: .command)
        } else {
            content
        }
    }
}
