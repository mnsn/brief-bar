import AppKit
import SwiftUI

/// A button with a menu one ▾ away, as a menu with a primary action is, but in AppKit's own control for it, whose title
/// follows the text size on windows' pages: SwiftUI's draws its title at the control's size whatever its label says.
/// `.controlSize`, `.disabled` and the text size around it apply. VoiceOver hears its two parts, each named with its
/// title, the button with `help` and the menu with `hint`, which their tooltips say too.
package struct SplitMenuButton: NSViewRepresentable {
    /// What its menu has.
    package enum Entry {
        /// A section's title.
        case header(String)
        /// A choice, checked or not.
        case item(String, isChecked: Bool = false, action: () -> Void)
        case divider
    }

    let title: String
    let systemImage: String
    /// What the button does.
    let help: String
    /// What its menu does; `help` for nil.
    var hint: String?
    let entries: [Entry]
    let action: () -> Void

    package init(
        _ title: String, systemImage: String, help: String, hint: String? = nil, entries: [Entry], action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.hint = hint
        self.entries = entries
        self.action = action
    }

    package final class Coordinator: NSObject {
        var action: () -> Void = {}
        var choices: [() -> Void] = []

        @objc func press() { action() }

        @objc func choose(_ item: NSMenuItem) {
            if choices.indices.contains(item.tag) { choices[item.tag]() }
        }
    }

    package func makeCoordinator() -> Coordinator { Coordinator() }

    package func makeNSView(context: Context) -> NSComboButton {
        let button = NSComboButton(
            title: title, image: Self.image(systemImage), menu: NSMenu(), target: context.coordinator,
            action: #selector(Coordinator.press)
        )
        button.setContentHuggingPriority(.required, for: .horizontal)
        update(button, context: context)
        return button
    }

    package func updateNSView(_ button: NSComboButton, context: Context) {
        update(button, context: context)
    }

    private func update(_ button: NSComboButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.action = action
        coordinator.choices = []
        let menu = NSMenu()
        for entry in entries {
            switch entry {
            case .header(let title):
                menu.addItem(.sectionHeader(title: title))
            case .item(let title, let isChecked, let choose):
                let item = NSMenuItem(title: title, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
                item.target = coordinator
                item.tag = coordinator.choices.count
                item.state = isChecked ? .on : .off
                coordinator.choices.append(choose)
                menu.addItem(item)
            case .divider:
                menu.addItem(.separator())
            }
        }
        button.menu = menu
        let environment = context.environment
        // Its font as big as the text, and its bezel a size up as it grows, to hold it, as a bordered button's grows.
        let size = environment.controlSize
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: size.appKit) * environment.textScale)
        let bezel = size.followingText(environment.textScale).appKit
        if button.title != title || button.font != font || button.controlSize != bezel {
            button.title = title
            button.font = font
            button.controlSize = bezel
            button.invalidateIntrinsicContentSize()
        }
        button.image = Self.image(systemImage)
        button.isEnabled = environment.isEnabled
        button.toolTip = help
        button.setAccessibilityHelp(hint ?? help)
        // Its parts are the segments of a control of its own, which VoiceOver reads, and the pointer rests on: each says
        // what it does.
        for case let parts as NSSegmentedControl in button.subviews where parts.segmentCount == 2 {
            parts.setToolTip(help, forSegment: 0)
            parts.setToolTip(hint ?? help, forSegment: 1)
        }
    }

    private static func image(_ systemImage: String) -> NSImage {
        NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) ?? NSImage()
    }
}
