import AppKit
import BriefBarCore
import Combine
import SwiftUI

/// Where a desktop widget sits.
package enum WidgetPlacement: String, CaseIterable, Identifiable, Codable, Sendable {
    case desktop, floating

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .desktop: return "On Desktop (Behind Windows)"
        case .floating: return "Floating (Above Windows)"
        }
    }
}

/// How many rows a desktop widget shows.
package enum WidgetSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case compact, medium, large

    package var id: String { rawValue }
    package var title: String { rawValue.capitalized }

    package var rows: Int {
        switch self {
        case .compact: return 2
        case .medium: return 4
        case .large: return 8
        }
    }

    /// Rows for each section, in a widget that shows `count` sections.
    package func rows(sharedBy count: Int) -> Int {
        guard count > 1 else { return rows }
        switch self {
        case .compact: return 2
        case .medium: return 3
        case .large: return 5
        }
    }
}

/// A desktop widget's own settings.
package struct WidgetOptions: Codable, Equatable, Sendable {
    package var placement: WidgetPlacement = .desktop
    package var size: WidgetSize = .medium

    package init(placement: WidgetPlacement = .desktop, size: WidgetSize = .medium) {
        self.placement = placement
        self.size = size
    }

    /// Where every widget's settings are saved, by the widget's ID.
    package static let defaultsKey = "widgetOptions"

    package static func load(from defaults: some SettingsStorage) -> [String: WidgetOptions] {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([String: WidgetOptions].self, from: $0) } ?? [:]
    }

    package static func save(_ options: [String: WidgetOptions], to defaults: some SettingsStorage) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(options) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

/// A borderless, non-activating panel pinned to the desktop (or floating), styled like a macOS widget.
/// It's an ordinary window that the app redraws itself, so it updates the instant data changes, with no
/// WidgetKit timeline budget involved.
@MainActor
package final class DesktopWidgetController {
    private static let cornerRadius: CGFloat = 20
    private static let margin: CGFloat = 24
    private static let spacing: CGFloat = 16

    private let autosaveName: String?
    private let formerAutosaveName: String?
    private var title: String
    private let content: () -> AnyView
    private var panel: WidgetPanel?
    /// A new widget, with no saved position: placed once it has its size.
    private var needsPosition = false
    private var cancellables: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - autosaveName: where the widget's position is kept; nil to keep it nowhere, as in the demo.
    ///   - formerAutosaveName: where an earlier version kept it, to start from there.
    ///   - content: the widget's view, with its environment.
    package init(autosaveName: String?, formerAutosaveName: String? = nil, title: String, content: @escaping () -> AnyView) {
        self.autosaveName = autosaveName
        self.formerAutosaveName = formerAutosaveName
        self.title = title
        self.content = content

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.keepOnScreen() } }
            .store(in: &cancellables)
    }

    /// Shows the widget at this size and placement, or hides it.
    package func update(show: Bool, placement: WidgetPlacement, size: CGSize) {
        guard show else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        panel.level = placement == .desktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
        resize(panel, to: size)
        if needsPosition {
            needsPosition = false
            placeAtDefaultPosition(panel)
        }
        keepOnScreen()
        panel.orderFrontRegardless()
        Log.app.info("\(self.title, privacy: .public) widget \(placement.rawValue, privacy: .public) at \(NSStringFromRect(panel.frame), privacy: .public)")
    }

    package func hide() {
        panel?.orderOut(nil)
    }

    /// Removes the widget for good. Its position stays saved.
    package func close() {
        panel?.close()
        panel = nil
    }

    /// For VoiceOver and the window list, such as "Azure DevOps and GitHub Copilot".
    package func setTitle(_ title: String) {
        self.title = title
        panel?.title = title
    }

    private func makePanel() -> WidgetPanel {
        let panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.title = title

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        let host = FirstMouseHostingView(rootView: content())
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background

        if let autosaveName {
            if !panel.setFrameUsingName(autosaveName) {
                if let formerAutosaveName, panel.setFrameUsingName(formerAutosaveName) {
                    UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(formerAutosaveName)")
                } else {
                    needsPosition = true
                }
            }
            panel.setFrameAutosaveName(autosaveName)
        } else {
            needsPosition = true
        }
        self.panel = panel
        return panel
    }

    /// Resizes while keeping the top-left corner where the user put it.
    private func resize(_ panel: NSPanel, to size: CGSize) {
        var frame = panel.frame
        guard frame.size != size else { return }
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// The top-right corner of the screen, or below the other widgets there, so a new widget doesn't cover one.
    private func placeAtDefaultPosition(_ panel: NSPanel) {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let size = panel.frame.size
        var frame = NSRect(
            origin: NSPoint(x: visible.maxX - size.width - Self.margin, y: visible.maxY - size.height - Self.margin),
            size: size
        )
        let others = NSApp.windows
            .filter { $0 is WidgetPanel && $0 !== panel && $0.isVisible }
            .map(\.frame)
        while let covered = others.first(where: { $0.intersects(frame) }), covered.minY - Self.spacing - size.height >= visible.minY {
            frame.origin.y = covered.minY - Self.spacing - size.height
        }
        panel.setFrameOrigin(frame.origin)
    }

    /// Brings the widget back if a display was disconnected or rearranged under it.
    private func keepOnScreen() {
        guard let panel else { return }
        let frame = panel.frame
        let isVisible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= 60 && overlap.height >= 40
        }
        if !isVisible {
            placeAtDefaultPosition(panel)
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Never takes focus from the app you're working in.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on an inactive widget hit the row under the cursor.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
