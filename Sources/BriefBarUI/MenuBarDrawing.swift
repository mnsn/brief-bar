import AppKit
import BriefBarCore

/// What a menu-bar item shows: its sections' segments, side by side, or added up by state.
package struct MenuBarItemContent {
    package var segments: [MenuBarSegment]
    /// What each section counts, in the same order, for the tooltip of an item that adds them up.
    package var counted: [CountNoun]
    /// The states it adds up, in the order it shows them; nil to show its sections side by side, as an item with
    /// one section always does.
    package var byState: [ItemState]?
    package var compact: Bool

    package init(segments: [MenuBarSegment], counted: [CountNoun] = [], byState: [ItemState]? = nil, compact: Bool = false) {
        self.segments = segments
        self.counted = counted
        self.byState = segments.count > 1 ? byState : nil
        self.compact = compact
    }

    /// What its sections count in each state, added up.
    package var totals: StateCounts {
        segments.reduce(StateCounts()) { $0 + $1.states }
    }

    package var attentionCount: Int { totals.needsYou + totals.failing }
    package var showsWarning: Bool { totals.failing > 0 || segments.contains { $0.problem != nil } }

    /// For the tooltip and VoiceOver: each section's own summary; or, for an item that adds them up, a line for each
    /// state it shows that has anything, with what each section has in it, then what keeps a section from showing.
    package var summary: String {
        if compact {
            let heading = segments.contains { $0.problem != nil }
                ? "Known items needing attention: \(attentionCount)"
                : attentionCount == 0 ? "Nothing needs attention" : "Needs attention: \(attentionCount)"
            return ([heading] + segments.map(\.summary) + segments.compactMap(\.problem)).joined(separator: "\n")
        }
        guard let states = byState else { return segments.map(\.summary).joined(separator: "\n") }
        var lines: [String] = []
        for state in states {
            let parts = segments.indices.compactMap { index -> String? in
                let count = segments[index].states[state]
                guard count > 0 else { return nil }
                return (counted.indices.contains(index) ? counted[index] : CountNoun("item", "items"))(count)
            }
            if !parts.isEmpty {
                lines.append("\(state.label): \(parts.joined(separator: ", "))")
            }
        }
        if lines.isEmpty {
            lines.append("Nothing needs you")
        }
        return (lines + segments.compactMap(\.problem)).joined(separator: "\n")
    }
}

/// Draws menu-bar items: one section the way its source draws it, several side by side or added up by state.
@MainActor
package enum MenuBarDrawing {
    /// Between the sections of an item that shows several.
    private static let sectionGap = "\u{2002}"

    /// Sets up a status button for an item. `--render` uses it too, so the README's pictures can't drift from the
    /// real items.
    package static func configure(_ button: NSButton, item: MenuBarItemContent) {
        if item.compact {
            let title = NSMutableAttributedString()
            if item.attentionCount > 0 {
                title.append(count(item.attentionCount))
            }
            if item.showsWarning {
                title.append(NSAttributedString(string: "\u{2009}"))
                title.append(symbol(
                    "exclamationmark.triangle.fill", color: item.totals.failing > 0 ? .systemRed : .systemOrange,
                    scale: 0.75, monochrome: true
                ))
            }
            let image = NSImage(systemSymbolName: AppSymbols.app, accessibilityDescription: item.summary)
            image?.isTemplate = true
            show(title, image: image, position: title.length == 0 ? .imageOnly : .imageLeading, in: button)
            return
        }
        guard let states = item.byState else {
            configure(button, segments: item.segments)
            return
        }
        // Each state's symbol and count, as Azure DevOps and Copilot draw theirs, then a small ⚠ if a section has a
        // problem.
        let font = NSFont.menuBarFont(ofSize: 0)
        let totals = item.totals
        let title = NSMutableAttributedString()
        for state in states where totals[state] > 0 {
            if title.length > 0 {
                title.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            title.append(symbol(state.symbol, color: state.nsColor, font: font, sizeDelta: -2, monochrome: true))
            title.append(count(totals[state], font: font))
        }
        if item.segments.contains(where: { $0.problem != nil }) {
            if title.length > 0 {
                title.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
            }
            title.append(symbol("exclamationmark.triangle.fill", color: .systemOrange, font: font, scale: 0.75))
        }
        guard title.length > 0 else {
            // Nothing to count: BriefBar's own symbol, so the item keeps its place.
            let image = NSImage(systemSymbolName: AppSymbols.app, accessibilityDescription: item.summary)
            image?.isTemplate = true
            show(NSAttributedString(), image: image, position: .imageOnly, in: button)
            return
        }
        show(title, image: nil, position: .noImage, in: button)
    }

    /// Sets up a status button for the segments of the sections it shows, side by side.
    package static func configure(_ button: NSButton, segments: [MenuBarSegment]) {
        if segments.count == 1, let segment = segments.first {
            let image = segment.glyph.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: segment.summary) }
            image?.isTemplate = true
            let position: NSControl.ImagePosition = segment.title.length == 0 ? .imageOnly : (segment.glyph == nil ? .noImage : .imageLeading)
            show(segment.title, image: image, position: position, in: button)
            return
        }
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: sectionGap, attributes: [.font: font]))
            }
            if let glyph = segment.glyph {
                // In the menu bar's own color, as a template image would be.
                title.append(symbol(glyph, color: .labelColor, font: font, weight: .regular))
            }
            title.append(segment.title)
        }
        show(title, image: nil, position: .noImage, in: button)
    }

    /// The item as the menu bar would show it, in an image, for Settings: drawn by a status button set up as the item
    /// sets up its own.
    package static func image(of item: MenuBarItemContent, appearance: NSAppearance?) -> NSImage? {
        let button = NSStatusBarButton(frame: .zero)
        configure(button, item: item)
        button.frame = NSRect(x: 0, y: 0, width: ceil(button.fittingSize.width), height: 22)
        guard let rep = Snapshot.snapshot(button, appearance: appearance) else { return nil }
        let image = NSImage(size: button.frame.size)
        image.addRepresentation(rep)
        return image
    }

    /// The image goes last: setting a title puts back the image a button had before.
    private static func show(_ title: NSAttributedString, image: NSImage?, position: NSControl.ImagePosition, in button: NSButton) {
        button.attributedTitle = title
        button.imagePosition = position
        button.image = image
    }

    /// A symbol as text, in one color, sized to the menu bar's text.
    package static func symbol(
        _ name: String, color: NSColor, font: NSFont = NSFont.menuBarFont(ofSize: 0), sizeDelta: CGFloat = -1,
        scale: CGFloat = 1, weight: NSFont.Weight = .semibold, monochrome: Bool = false
    ) -> NSAttributedString {
        var configuration = NSImage.SymbolConfiguration(pointSize: (font.pointSize + sizeDelta) * scale, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if monochrome {
            configuration = configuration.applying(.preferringMonochrome())
        }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0, y: (font.capHeight - image.size.height) / 2,
            width: image.size.width, height: image.size.height
        )
        return NSAttributedString(attachment: attachment)
    }

    /// A count in the menu bar's digits, after a thin space.
    package static func count(_ value: Int, font: NSFont = NSFont.menuBarFont(ofSize: 0)) -> NSAttributedString {
        NSAttributedString(
            string: "\u{2009}\(value)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .medium),
                         .foregroundColor: NSColor.labelColor]
        )
    }
}
