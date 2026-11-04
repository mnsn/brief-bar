import AppKit
import SwiftUI

/// A segmented control, as a segmented picker is, but its titles as big as the text on windows' pages: SwiftUI's draws
/// them at the control's size whatever its items say. In a page's header too narrow for titles, the segments that have a
/// symbol show it alone, named in their tooltips and to VoiceOver (`showsSymbolsAlone`). `.controlSize` and `.disabled`
/// apply.
package struct SegmentedPicker<Value: Hashable>: NSViewRepresentable {
    package struct Segment {
        let value: Value
        let title: String
        let systemImage: String?

        package init(_ value: Value, title: String, systemImage: String? = nil) {
            self.value = value
            self.title = title
            self.systemImage = systemImage
        }
    }

    let segments: [Segment]
    @Binding var selection: Value
    /// What VoiceOver calls it: "By Mission View".
    let label: String

    package init(_ label: String, selection: Binding<Value>, segments: [Segment]) {
        self.label = label
        _selection = selection
        self.segments = segments
    }

    package final class Coordinator: NSObject {
        var choose: (Int) -> Void = { _ in }

        @objc func changed(_ control: NSSegmentedControl) { choose(control.selectedSegment) }
    }

    package func makeCoordinator() -> Coordinator { Coordinator() }

    package func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.required, for: .horizontal)
        update(control, context: context)
        return control
    }

    package func updateNSView(_ control: NSSegmentedControl, context: Context) {
        update(control, context: context)
    }

    private func update(_ control: NSSegmentedControl, context: Context) {
        let segments = segments
        let binding = $selection
        context.coordinator.choose = { index in
            if segments.indices.contains(index) { binding.wrappedValue = segments[index].value }
        }
        let environment = context.environment
        // Its titles as big as the text, and its bezel, which AppKit sizes by its control's size alone, a size up to hold
        // them.
        let base = environment.controlSize
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: base.appKit) * environment.textScale)
        let size = base.followingText(environment.textScale).appKit
        var changed = control.segmentCount != segments.count || control.font != font || control.controlSize != size
        control.segmentCount = segments.count
        control.font = font
        control.controlSize = size
        for (index, segment) in segments.enumerated() {
            let symbol = environment.showsSymbolsAlone ? segment.systemImage : nil
            let title = symbol == nil ? segment.title : ""
            if control.label(forSegment: index) != title {
                control.setLabel(title, forSegment: index)
                changed = true
            }
            let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: segment.title) }
            if (control.image(forSegment: index) == nil) != (image == nil) {
                control.setImage(image, forSegment: index)
                changed = true
            }
            control.setToolTip(symbol == nil ? nil : segment.title, forSegment: index)
        }
        control.selectedSegment = segments.firstIndex { $0.value == selection } ?? -1
        control.isEnabled = environment.isEnabled
        control.setAccessibilityLabel(label)
        if changed { control.invalidateIntrinsicContentSize() }
    }
}
