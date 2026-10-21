import AppKit

/// Draws menu-bar items: one section the way its source draws it, several side by side.
@MainActor
package enum MenuBarDrawing {
    /// Between the sections of an item that shows several.
    private static let sectionGap = "\u{2002}"

    /// Sets up a status button for the segments of the sections it shows. `--render` uses it too, so the
    /// README's pictures can't drift from the real items.
    package static func configure(_ button: NSButton, segments: [MenuBarSegment]) {
        if segments.count == 1, let segment = segments.first {
            if let glyph = segment.glyph {
                let image = NSImage(systemSymbolName: glyph, accessibilityDescription: segment.summary)
                image?.isTemplate = true
                button.image = image
            } else {
                button.image = nil
            }
            button.attributedTitle = segment.title
            button.imagePosition = segment.title.length == 0 ? .imageOnly : (segment.glyph == nil ? .noImage : .imageLeading)
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
        button.image = nil
        button.attributedTitle = title
        button.imagePosition = .noImage
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
