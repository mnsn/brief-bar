import AppKit
import SwiftUI
import Testing
@testable import BriefBarUI

/// Words in a state's color read at 4.5:1 or more, as text should: in light mode on a list's white and on the window's
/// tinted backdrop where it's darkest, by the sidebar, and in dark mode on a raised card, a little lighter than the
/// window's; and what someone wrote under a row too.
@MainActor
struct TextTintTests {
    private static let white = NSColor.white
    private static let backdrop = NSColor(srgbRed: 0xDE / 255, green: 0xE4 / 255, blue: 0xF8 / 255, alpha: 1)
    private static let darkCard = NSColor(srgbRed: 0x41 / 255, green: 0x34 / 255, blue: 0x45 / 255, alpha: 1)

    @Test(arguments: TextTint.allCases)
    func eachTintReadsInBothAppearances(_ tint: TextTint) {
        let light = Self.resolved(tint.nsColor, in: .aqua)
        #expect(Self.contrast(light, Self.white) >= 4.5)
        #expect(Self.contrast(light, Self.backdrop) >= 4.5)
        #expect(Self.contrast(Self.resolved(tint.nsColor, in: .darkAqua), Self.darkCard) >= 4.5)
    }

    @Test func contentReadsAndStaysStrongerThanWhatsSaidAboutIt() {
        var environment = EnvironmentValues()
        for (scheme, background) in [(ColorScheme.light, Self.white), (.light, Self.backdrop), (.dark, Self.darkCard)] {
            environment.colorScheme = scheme
            let content = Self.over(Color.rowContent.resolve(in: environment), background)
            let secondary = Self.over(Color.secondary.resolve(in: environment), background)
            #expect(Self.contrast(content, background) >= 4.5)
            #expect(Self.contrast(content, background) > Self.contrast(secondary, background))
        }
    }

    private static func resolved(_ color: NSColor, in name: NSAppearance.Name) -> NSColor {
        var resolved = color
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    /// A resolved color with its opacity, laid over a background.
    private static func over(_ color: Color.Resolved, _ background: NSColor) -> NSColor {
        let top = NSColor(cgColor: color.cgColor)?.usingColorSpace(.sRGB) ?? .black
        let bottom = background.usingColorSpace(.sRGB) ?? background
        let alpha = top.alphaComponent
        return NSColor(
            srgbRed: top.redComponent * alpha + bottom.redComponent * (1 - alpha),
            green: top.greenComponent * alpha + bottom.greenComponent * (1 - alpha),
            blue: top.blueComponent * alpha + bottom.blueComponent * (1 - alpha), alpha: 1
        )
    }

    private static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func luminance(_ color: NSColor) -> Double {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent) + 0.0722 * linear(srgb.blueComponent)
    }
}
