import AppKit
import SwiftUI
import Testing
@testable import BriefBarUI

/// AppKit's own controls, given the font, where SwiftUI's draw their titles at their control's size whatever the text size.
@MainActor
@Suite struct TextSizedControlsTests {
    private final class Choice<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Lays `view` out in a window, and returns the first AppKit view of `type` in it.
    private func laidOut<V: View, T: NSView>(_ view: V, find type: T.Type) throws -> T {
        let host = NSHostingView(rootView: view.fixedSize())
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> T? {
            if let found = view as? T { return found }
            return view.subviews.lazy.compactMap(find).first
        }
        return try #require(find(host))
    }

    /// Lays `view` out in a window, which stays while `body` runs with the first AppKit view of `type` in it.
    private func inWindow<V: View, T: NSView>(_ view: V, find type: T.Type, _ body: (T) throws -> Void) throws {
        let host = NSHostingView(rootView: view.fixedSize())
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> T? {
            if let found = view as? T { return found }
            return view.subviews.lazy.compactMap(find).first
        }
        try body(try #require(find(host)))
    }

    /// What VoiceOver finds in an AppKit view: it, and its accessibility children, all the way down.
    private func elements(of view: NSView) -> [NSAccessibilityProtocol & NSObject] {
        func all(_ element: Any) -> [NSAccessibilityProtocol & NSObject] {
            guard let element = element as? NSAccessibilityProtocol & NSObject else { return [] }
            return [element] + (element.accessibilityChildren() ?? []).flatMap(all)
        }
        return all(view)
    }

    /// Lets AppKit send what a press sent.
    private func settle() {
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// VoiceOver hears a split button's two parts, each named with its title and saying what it does, presses its button and
    /// can open its menu; and it takes the keyboard's focus, as AppKit's controls do with keyboard navigation on.
    @Test func voiceOverHearsAndPressesEachPartOfASplitButton() throws {
        let pressed = Choice(0)
        try inWindow(
            SplitMenuButton("Resolve", systemImage: "checkmark", help: "Resolve it", hint: "Its menu sets another status",
                            entries: [.item("Won't Fix") {}]) { pressed.value += 1 },
            find: NSComboButton.self
        ) { button in
            let parts = elements(of: button)
            let primary = try #require(parts.first { $0.accessibilityRole() == .button })
            let menu = try #require(parts.first { $0.accessibilityRole() == .menuButton })
            #expect(primary.accessibilityLabel() == "Resolve")
            #expect(primary.accessibilityHelp() == "Resolve it")
            #expect(menu.accessibilityLabel() == "Resolve")
            #expect(menu.accessibilityHelp() == "Its menu sets another status")
            #expect(menu.responds(to: #selector(NSAccessibilityProtocol.accessibilityPerformShowMenu)))
            _ = primary.accessibilityPerformPress()
            settle()
            #expect(pressed.value == 1)
            let takesFocus = button.subviews.contains { $0.acceptsFirstResponder }
            #expect(takesFocus)
        }
    }

    /// VoiceOver hears a segmented picker's segments by their titles, symbols alone too, and chooses among them; and it takes
    /// the keyboard's focus, as AppKit's controls do with keyboard navigation on.
    @Test func voiceOverHearsAndChoosesASegmentedPickersSegments() throws {
        let chosen = Choice(0)
        try inWindow(
            SegmentedPicker("View", selection: Binding(get: { chosen.value }, set: { chosen.value = $0 }), segments: [
                .init(0, title: "List", systemImage: "list.bullet"), .init(1, title: "Map", systemImage: "map"),
            ])
            .environment(\.showsSymbolsAlone, true),
            find: NSSegmentedControl.self
        ) { picker in
            let segments = elements(of: picker).filter { $0.accessibilityRole() == .radioButton }
            #expect(segments.map { $0.accessibilityLabel() } == ["List", "Map"])
            #expect(segments.map { $0.accessibilityHelp() } == ["List", "Map"])
            _ = segments.last?.accessibilityPerformPress()
            settle()
            #expect(chosen.value == 1)
            #expect(picker.acceptsFirstResponder)
        }
    }

    @Test func aSplitButtonsTitleIsAsBigAsTheTextAndItsBezelHoldsIt() throws {
        func button(scale: CGFloat) throws -> NSComboButton {
            try laidOut(
                SplitMenuButton("Resolve", systemImage: "checkmark", help: "Resolve it", entries: [.item("Won't Fix") {}]) {}
                    .controlSize(.small)
                    .environment(\.textScale, scale),
                find: NSComboButton.self
            )
        }
        let usual = try button(scale: 1)
        #expect(usual.font?.pointSize == NSFont.systemFontSize(for: .small))
        #expect(usual.controlSize == .small)
        let biggest = try button(scale: 1.5)
        #expect(biggest.font?.pointSize == NSFont.systemFontSize(for: .small) * 1.5)
        #expect(biggest.controlSize == .regular)
        #expect(biggest.intrinsicContentSize.width > usual.intrinsicContentSize.width)
        #expect(biggest.toolTip == "Resolve it")
    }

    @Test func aSplitButtonsMenuChoosesAndItsButtonActs() throws {
        let chosen = Choice<[String]>([])
        let button = try laidOut(
            SplitMenuButton("Fix Grammar", systemImage: "text.badge.checkmark", help: "Fix it", entries: [
                .header("On this Mac"), .item("Apple Intelligence", isChecked: true) { chosen.value.append("apple") },
                .divider, .item("Claude Haiku 5.5") { chosen.value.append("haiku") },
            ]) { chosen.value.append("fix") },
            find: NSComboButton.self
        )
        let items = button.menu.items
        #expect(items.map(\.title) == ["On this Mac", "Apple Intelligence", "", "Claude Haiku 5.5"])
        #expect(items[1].state == .on && items[3].state == .off)
        if let action = items[3].action { NSApp.sendAction(action, to: items[3].target, from: items[3]) }
        if let action = button.action { NSApp.sendAction(action, to: button.target, from: button) }
        #expect(chosen.value == ["haiku", "fix"])
    }

    @Test func aSegmentedPickersTitlesAreAsBigAsTheTextAndItChooses() throws {
        let chosen = Choice(false)
        func picker(scale: CGFloat) throws -> NSSegmentedControl {
            try laidOut(
                SegmentedPicker("Show", selection: Binding(get: { chosen.value }, set: { chosen.value = $0 }), segments: [
                    .init(false, title: "Everyone"), .init(true, title: "Just Mine"),
                ])
                .environment(\.textScale, scale),
                find: NSSegmentedControl.self
            )
        }
        let usual = try picker(scale: 1)
        #expect(usual.font?.pointSize == NSFont.systemFontSize(for: .regular))
        #expect(usual.label(forSegment: 1) == "Just Mine")
        #expect(usual.selectedSegment == 0)
        let biggest = try picker(scale: 1.5)
        #expect(biggest.font?.pointSize == NSFont.systemFontSize(for: .regular) * 1.5)
        #expect(biggest.intrinsicContentSize.height > usual.intrinsicContentSize.height)
        biggest.selectedSegment = 1
        if let action = biggest.action { NSApp.sendAction(action, to: biggest.target, from: biggest) }
        #expect(chosen.value)
    }

    /// In a page's header too narrow for titles, a segment with a symbol shows it alone, its title in its tooltip and to
    /// VoiceOver; one without keeps its title.
    @Test func aSegmentedPickerShowsSymbolsAloneWhereTheHeaderAsks() throws {
        let picker = try laidOut(
            SegmentedPicker("View", selection: .constant(0), segments: [
                .init(0, title: "List", systemImage: "list.bullet"), .init(1, title: "Other"),
            ])
            .environment(\.showsSymbolsAlone, true),
            find: NSSegmentedControl.self
        )
        #expect(picker.label(forSegment: 0) == "")
        #expect(picker.image(forSegment: 0)?.accessibilityDescription == "List")
        #expect(picker.toolTip(forSegment: 0) == "List")
        #expect(picker.label(forSegment: 1) == "Other")
        #expect(picker.image(forSegment: 1) == nil)
        #expect(picker.accessibilityLabel() == "View")
    }

    private func picker(_ title: String, symbol: String, alone: Bool) -> some View {
        SegmentedPicker("View", selection: .constant(0), segments: [.init(0, title: title, systemImage: symbol)])
            .environment(\.showsSymbolsAlone, alone)
            .fixedSize()
    }

    /// A segment shown as its symbol alone that changes its symbol or its title shows the new one, and VoiceOver hears its
    /// new title; and once the header has room for titles again, it shows its title, without the symbol.
    @Test func aSegmentsSymbolAloneFollowsWhatItsMadeOf() throws {
        let host = NSHostingView(rootView: picker("List", symbol: "list.bullet", alone: true))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSSegmentedControl? {
            view as? NSSegmentedControl ?? view.subviews.lazy.compactMap(find).first
        }
        let control = try #require(find(host))
        #expect(control.image(forSegment: 0)?.accessibilityDescription == "List")

        host.rootView = picker("Map", symbol: "map", alone: true)
        host.layoutSubtreeIfNeeded()
        #expect(control.image(forSegment: 0)?.accessibilityDescription == "Map")
        #expect(control.toolTip(forSegment: 0) == "Map")
        #expect(elements(of: control).contains { $0.accessibilityRole() == .radioButton && $0.accessibilityLabel() == "Map" })

        host.rootView = picker("Map", symbol: "map", alone: false)
        host.layoutSubtreeIfNeeded()
        #expect(control.image(forSegment: 0) == nil)
        #expect(control.label(forSegment: 0) == "Map")
        #expect(control.toolTip(forSegment: 0) == nil)
    }
}
