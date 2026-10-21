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
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let size = content.sections.count > 1 ? CGSize(width: 980, height: 700) : CGSize(width: 560, height: 700)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
            model.windowDidClose(self)
        }
    }
}

/// A window's pages, and which one shows.
@MainActor
final class WindowContent: ObservableObject {
    let id: String
    @Published private(set) var sections: [SectionID] = []
    @Published private(set) var selected: SectionID?
    unowned let model: AppModel
    private var cancellables: Set<AnyCancellable> = []

    /// Each window's page, as you last left it, by the window's ID.
    private static let pagesKey = "windowPages"

    init(id: String, model: AppModel) {
        self.id = id
        self.model = model
        let saved = model.services.defaults.dictionary(forKey: Self.pagesKey) as? [String: String]
        selected = saved?[id].map(SectionID.init(rawValue:))
    }

    /// The page that shows: the one you chose, or the first.
    var current: SectionID? {
        selected.flatMap { sections.contains($0) ? $0 : nil } ?? sections.first
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

    /// Shows `section`'s page, or for nil, keeps the one that shows, and tells its source, which may refresh;
    /// `--render` doesn't.
    func select(_ section: SectionID?, notify: Bool = true) {
        if let section, sections.contains(section) {
            selected = section
            var saved = model.services.defaults.dictionary(forKey: Self.pagesKey) as? [String: String] ?? [:]
            saved[id] = section.rawValue
            model.services.defaults.set(saved, forKey: Self.pagesKey)
        }
        if notify, let current {
            model.source(for: current)?.pageWillShow(current)
        }
    }
}

/// A window: the sidebar, when it has several pages, floating over the page that shows.
struct WindowView: View {
    @ObservedObject var content: WindowContent

    static let sidebarWidth: CGFloat = 220
    /// The sidebar floats this far from the window's edges.
    static let inset: CGFloat = 10
    /// A page's lines stay readable on a wide window.
    static let pageWidth: CGFloat = 760

    var body: some View {
        HStack(spacing: 0) {
            if content.sections.count > 1 {
                WindowSidebar(content: content)
                    .frame(width: Self.sidebarWidth)
                    .floatingPanel(cornerRadius: 18)
                    .padding(Self.inset)
                    .ignoresSafeArea(edges: .top)
            }
            page
                .frame(maxWidth: Self.pageWidth, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(WindowBackdrop().ignoresSafeArea())
    }

    @ViewBuilder
    private var page: some View {
        if let section = content.current, let source = content.model.source(for: section) {
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
            // Room for the window's buttons, which sit in the sidebar's corner.
            Color.clear
                .frame(height: 30)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(content.sections.enumerated()), id: \.element) { index, section in
                        if let source = model.source(for: section), let info = source.info(for: section) {
                            if index == 0 || model.source(for: content.sections[index - 1])?.id != source.id {
                                Text(source.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 8)
                                    .padding(.top, index == 0 ? 2 : 12)
                                    .padding(.bottom, 2)
                            }
                            SidebarItem(
                                info: info, segment: source.segment(for: section), isSelected: content.current == section,
                                shortcut: index < 9 ? index + 1 : nil
                            ) {
                                content.select(section)
                            }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

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
        .frame(maxHeight: .infinity, alignment: .top)
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

// MARK: - Style

private struct RenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Drawing offscreen for `--render`, which can't draw materials: views use plain colors instead.
    var isRendering: Bool {
        get { self[RenderingKey.self] }
        set { self[RenderingKey.self] = newValue }
    }
}

/// The desktop the README's pictures put the window on: offscreen drawing can't see the real one.
struct DesktopWallpaper: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.10, green: 0.14, blue: 0.32), Color(red: 0.24, green: 0.15, blue: 0.40), Color(red: 0.38, green: 0.16, blue: 0.34)]
                : [Color(red: 0.62, green: 0.76, blue: 0.98), Color(red: 0.78, green: 0.72, blue: 0.96), Color(red: 0.97, green: 0.78, blue: 0.86)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// The window's translucent background: the desktop, blurred, through the sidebar material. Offscreen, where
/// materials don't draw, the made-up desktop with the material's tint over it.
struct WindowBackdrop: View {
    @Environment(\.isRendering) private var isRendering
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isRendering {
            DesktopWallpaper()
                .overlay(colorScheme == .dark ? Color(white: 0.08).opacity(0.72) : Color(white: 0.97).opacity(0.66))
        } else {
            VisualEffectBackground(material: .sidebar)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// A floating panel, such as the sidebar: Liquid Glass from macOS 26, a frosted fill before it and offscreen.
struct FloatingPanel: ViewModifier {
    var cornerRadius: CGFloat = 20

    @Environment(\.isRendering) private var isRendering
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !isRendering {
            content.glassEffect(.regular, in: shape)
        } else {
            frosted(content, shape)
        }
        #else
        frosted(content, shape)
        #endif
    }

    private func frosted(_ content: Content, _ shape: RoundedRectangle) -> some View {
        let dark = colorScheme == .dark
        return content
            .background(
                shape
                    .fill(dark ? Color.white.opacity(0.08) : Color.white.opacity(0.52))
                    .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.14 : 0.85), lineWidth: 1))
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.10), radius: 16, y: 6)
            )
    }
}

extension View {
    func floatingPanel(cornerRadius: CGFloat = 20) -> some View {
        modifier(FloatingPanel(cornerRadius: cornerRadius))
    }
}
