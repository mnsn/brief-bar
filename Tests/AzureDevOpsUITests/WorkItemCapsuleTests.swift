import AppKit
import SwiftUI
import Testing
import AzureDevOpsCore
@testable import AzureDevOpsUI

/// A work item's number on a row's link capsule, in its type's color for words on 14% of its type's color, reads at 4.5:1
/// or more, on a list's white and on the window's tinted backdrop where it's darkest.
@MainActor
struct WorkItemCapsuleTests {
    @Test(arguments: ["Bug", "Task", "Feature", "Epic", "Issue", "User Story"])
    func aTypesNumberReadsOnItsCapsule(_ type: String) {
        let fill = Self.resolved(NSColor(WorkItem.typeColor(of: type)))
        let text = Self.resolved(NSColor(WorkItem.typeTextColor(of: type)))
        let backdrop = NSColor(srgbRed: 0xDE / 255, green: 0xE4 / 255, blue: 0xF8 / 255, alpha: 1)
        for background in [NSColor.white, backdrop] {
            #expect(Self.contrast(text, Self.over(fill, opacity: 0.14, background)) >= 4.5, "\(type) on \(background)")
        }
    }

    private static func resolved(_ color: NSColor) -> NSColor {
        var resolved = color
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private static func over(_ color: NSColor, opacity alpha: CGFloat, _ background: NSColor) -> NSColor {
        let bottom = background.usingColorSpace(.sRGB) ?? background
        return NSColor(
            srgbRed: color.redComponent * alpha + bottom.redComponent * (1 - alpha),
            green: color.greenComponent * alpha + bottom.greenComponent * (1 - alpha),
            blue: color.blueComponent * alpha + bottom.blueComponent * (1 - alpha), alpha: 1
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
