import AppKit

/// The README's menu-bar pictures: the top-right corner of a desktop, with BriefBar's items, one of them pressed
/// and its list open below in a popover. AppKit draws the status buttons, set up the way the real items are; the
/// wallpaper, bar, highlight and popover use plain colors, since offscreen rendering doesn't capture materials.
@MainActor
package enum MenuBarPicture {
    /// In points, at least: the README's width for a picture that sits next to the widget's. Wider when the
    /// items need it.
    private static let minimumWidth: CGFloat = 440
    private static let barHeight: CGFloat = 24
    /// Between status buttons, on top of their own padding.
    private static let itemGap: CGFloat = 4
    private static let trailingInset: CGFloat = 6
    /// Room around the popover for its shadow.
    private static let margin: CGFloat = 20
    private static let arrow = NSSize(width: 30, height: 12)
    private static let cornerRadius: CGFloat = 12
    /// Where a widget's picture goes on the desktop, from its top-left corner. The picture has room for its shadow.
    private static let widgetOrigin = NSPoint(x: 16, y: 6)

    /// The status bar's items, right-aligned like the system's: BriefBar's, then battery, Wi-Fi, Control Center and
    /// the clock.
    private struct Bar {
        let image: NSBitmapImageRep
        let width: CGFloat
        /// Each of BriefBar's items, in the bar.
        let frames: [NSRect]
    }

    /// - Parameters:
    ///   - items: what each item shows, left to right.
    ///   - pressed: the item whose list is open.
    package static func draw(
        panel: NSBitmapImageRep, items: [MenuBarItemContent], pressed: Int, appearance: NSAppearance
    ) -> NSBitmapImageRep? {
        guard let bar = bar(items, width: minimumWidth, appearance: appearance), bar.frames.indices.contains(pressed)
        else { return nil }
        let size = NSSize(width: bar.width, height: barHeight + 1 + arrow.height + panel.size.height + margin * 1.5)
        let scale = CGFloat(panel.pixelsWide) / panel.size.width
        return picture(size: size, scale: scale, appearance: appearance) { dark in
            drawWallpaper(in: NSRect(origin: .zero, size: size), dark: dark)
            drawBar(bar, in: size, pressed: pressed, dark: dark)
            drawPopover(panel: panel, under: bar.frames[pressed], in: size, dark: dark, scale: scale)
        }
    }

    /// The desktop the README's tour plays on: a screen's top-right corner, `size` points, with BriefBar's items across
    /// the menu bar, a widget on the left and, when `open` says which item is pressed, that item's list below it.
    package static func desktop(
        size: NSSize, items: [MenuBarItemContent], open: (pressed: Int, panel: NSBitmapImageRep)? = nil,
        widget: NSBitmapImageRep? = nil, appearance: NSAppearance
    ) -> NSBitmapImageRep? {
        guard let bar = bar(items, width: size.width, appearance: appearance) else { return nil }
        if let open, !bar.frames.indices.contains(open.pressed) { return nil }
        let scale = CGFloat(bar.image.pixelsWide) / bar.width
        return picture(size: size, scale: scale, appearance: appearance) { dark in
            drawWallpaper(in: NSRect(origin: .zero, size: size), dark: dark)
            if let widget {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.45 : 0.18)
                shadow.shadowBlurRadius = 14 * scale
                shadow.shadowOffset = NSSize(width: 0, height: -4 * scale)
                shadow.set()
                let frame = NSRect(x: widgetOrigin.x, y: size.height - barHeight - widgetOrigin.y - widget.size.height,
                                   width: widget.size.width, height: widget.size.height)
                widget.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            drawBar(bar, in: size, pressed: open?.pressed, dark: dark)
            if let open {
                drawPopover(panel: open.panel, under: bar.frames[open.pressed], in: size, dark: dark, scale: scale)
            }
        }
    }

    /// The items in a bar `width` points wide, or wider when they need it.
    private static func bar(_ items: [MenuBarItemContent], width: CGFloat, appearance: NSAppearance) -> Bar? {
        let buttons = items.map { item in
            let button = NSStatusBarButton(frame: .zero)
            MenuBarDrawing.configure(button, item: item)
            return button
        }
        let all = buttons + [symbolButton("battery.75percent"), symbolButton("wifi"), symbolButton("switch.2"),
                             clockButton()]
        let itemsWidth = all.reduce(0) { $0 + ceil($1.fittingSize.width) + itemGap }
        let width = max(width, ceil(itemsWidth + trailingInset + margin))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: barHeight))
        var x = width - trailingInset
        for item in all.reversed() {
            let itemWidth = ceil(item.fittingSize.width)
            x -= itemWidth
            item.frame = NSRect(x: x, y: 0, width: itemWidth, height: barHeight)
            view.addSubview(item)
            x -= itemGap
        }
        guard let image = Snapshot.snapshot(view, appearance: appearance) else { return nil }
        return Bar(image: image, width: width, frames: buttons.map(\.frame))
    }

    /// A picture `size` points big, at `scale` pixels a point, that `draw` draws with the appearance current.
    private static func picture(
        size: NSSize, scale: CGFloat, appearance: NSAppearance, draw: (_ dark: Bool) -> Void
    ) -> NSBitmapImageRep? {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        appearance.performAsCurrentDrawingAppearance { draw(dark) }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        return rep
    }

    /// The menu bar across the top of a picture `size` points big, with the `pressed` item's highlight.
    private static func drawBar(_ bar: Bar, in size: NSSize, pressed: Int?, dark: Bool) {
        let barRect = NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)
        (dark ? NSColor(white: 0.1, alpha: 0.4) : NSColor(white: 1, alpha: 0.5)).setFill()
        barRect.fill(using: .sourceOver)
        if let pressed {
            // Pressed, since its popover is open.
            (dark ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.1)).setFill()
            NSBezierPath(roundedRect: bar.frames[pressed].offsetBy(dx: 0, dy: barRect.minY).insetBy(dx: 0, dy: 1),
                         xRadius: 5, yRadius: 5).fill()
        }
        bar.image.draw(in: NSRect(x: 0, y: barRect.minY, width: bar.width, height: barHeight), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static func symbolButton(_ name: String) -> NSStatusBarButton {
        let button = NSStatusBarButton(frame: .zero)
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        return button
    }

    private static func clockButton() -> NSStatusBarButton {
        let button = NSStatusBarButton(frame: .zero)
        button.font = NSFont.menuBarFont(ofSize: 0)
        button.title = "Mon Oct 19  9:41 AM"
        return button
    }

    private static func drawWallpaper(in rect: NSRect, dark: Bool) {
        let colors = dark
            ? [NSColor(srgbRed: 0.10, green: 0.14, blue: 0.32, alpha: 1),
               NSColor(srgbRed: 0.24, green: 0.15, blue: 0.40, alpha: 1),
               NSColor(srgbRed: 0.38, green: 0.16, blue: 0.34, alpha: 1)]
            : [NSColor(srgbRed: 0.62, green: 0.76, blue: 0.98, alpha: 1),
               NSColor(srgbRed: 0.78, green: 0.72, blue: 0.96, alpha: 1),
               NSColor(srgbRed: 0.97, green: 0.78, blue: 0.86, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: rect, angle: -60)
    }

    /// The list below `item`, in a picture `size` points big. The arrow points at the item's center; the body stays as
    /// centered under it as the picture's edges allow.
    private static func drawPopover(panel: NSBitmapImageRep, under item: NSRect, in size: NSSize, dark: Bool, scale: CGFloat) {
        let anchor = item.midX
        let bodyX = min(max(anchor - panel.size.width / 2, margin), size.width - margin - panel.size.width)
        let body = NSRect(origin: NSPoint(x: bodyX, y: size.height - barHeight - 1 - arrow.height - panel.size.height),
                          size: panel.size)
        let outline = popoverOutline(body: body, anchor: anchor)

        NSGraphicsContext.saveGraphicsState()
        // Core Graphics measures shadows in pixels, unaffected by the context's scale.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
        shadow.shadowBlurRadius = 22 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        panel.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        if dark {
            hairline(outline, color: NSColor.black.withAlphaComponent(0.6), inside: false)
            hairline(outline, color: NSColor.white.withAlphaComponent(0.16), inside: true)
        } else {
            hairline(outline, color: NSColor.black.withAlphaComponent(0.16), inside: false)
        }
    }

    /// The body's rounded rectangle with an arrow on top whose tip is above `anchor`.
    private static func popoverOutline(body: NSRect, anchor: CGFloat) -> NSBezierPath {
        let top = body.maxY
        let half = arrow.width / 2
        let tip = NSPoint(x: anchor, y: top + arrow.height)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: anchor - half, y: top))
        path.curve(to: tip, controlPoint1: NSPoint(x: anchor - half * 0.5, y: top),
                   controlPoint2: NSPoint(x: anchor - half * 0.2, y: tip.y))
        path.curve(to: NSPoint(x: anchor + half, y: top), controlPoint1: NSPoint(x: anchor + half * 0.2, y: tip.y),
                   controlPoint2: NSPoint(x: anchor + half * 0.5, y: top))
        path.appendArc(from: NSPoint(x: body.maxX, y: top), to: NSPoint(x: body.maxX, y: body.minY), radius: cornerRadius)
        path.appendArc(from: NSPoint(x: body.maxX, y: body.minY), to: NSPoint(x: body.minX, y: body.minY), radius: cornerRadius)
        path.appendArc(from: NSPoint(x: body.minX, y: body.minY), to: NSPoint(x: body.minX, y: top), radius: cornerRadius)
        path.appendArc(from: NSPoint(x: body.minX, y: top), to: NSPoint(x: anchor - half, y: top), radius: cornerRadius)
        path.close()
        return path
    }

    /// A one-pixel line (at @2x) just inside or just outside the outline.
    private static func hairline(_ outline: NSBezierPath, color: NSColor, inside: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath()
        if !inside {
            clip.append(NSBezierPath(rect: outline.bounds.insetBy(dx: -10, dy: -10)))
            clip.windingRule = .evenOdd
        }
        clip.append(outline)
        clip.addClip()
        color.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
