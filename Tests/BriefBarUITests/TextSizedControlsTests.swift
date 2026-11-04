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
}
