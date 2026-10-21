import AppKit
import SwiftUI

/// Draws views into images, offscreen, for `--render`: README pictures, and checking layouts without
/// screen-recording permission.
@MainActor
package enum Snapshot {
    /// Draws a SwiftUI view at its fitting size.
    package static func render<V: View>(_ view: V, appearance: NSAppearance?) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        // Let SwiftUI settle measured sizes (lists measure themselves) before sizing the image.
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        return cache(host)
    }

    /// Draws an AppKit view at its current size, in an offscreen window with the given appearance.
    package static func snapshot(_ view: NSView, appearance: NSAppearance?) -> NSBitmapImageRep? {
        view.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: view.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return cache(view)
    }

    private static func cache(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Writes a PNG, and returns its path.
    package static func write(_ image: NSBitmapImageRep, to url: URL) -> String? {
        guard let data = image.representation(using: .png, properties: [:]) else { return nil }
        do {
            try data.write(to: url)
            return url.path
        } catch {
            fputs("Can't write \(url.path): \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    /// Overlay scrollers, as on most Macs, whatever this Mac's scroll bar setting.
    package static func useOverlayScrollers() {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
