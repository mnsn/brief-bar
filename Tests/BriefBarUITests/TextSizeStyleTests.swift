import AppKit
import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

@MainActor
@Suite struct TextSizeStyleTests {
    @Test func theTextSizeChangesAtOnceAndSurvivesReloading() {
        let defaults = MemoryDefaults()
        let services = AppServices(defaults: defaults, isDemo: true)
        #expect(services.textSize == .standard)
        services.setTextSize(TextSize(percent: 130))
        #expect(services.textSize.percent == 130)
        #expect(AppServices(defaults: defaults, isDemo: true).textSize.percent == 130)
        // Apart from the other appearance options.
        #expect(services.interfaceOptions == InterfaceOptions())
    }

    @Test func eachNotchOfAWheelIsAStep() {
        var scrolling = TextSizeScrolling()
        #expect(scrolling.step(delta: 1, isPrecise: false) == 1)
        #expect(scrolling.step(delta: 6, isPrecise: false) == 1)
        #expect(scrolling.step(delta: -2, isPrecise: false) == -1)
        #expect(scrolling.step(delta: 0, isPrecise: false) == 0)
    }

    @Test func aSwipeStepsOncePerStretch() {
        var scrolling = TextSizeScrolling()
        let stretch = TextSizeScrolling.stretch
        #expect(scrolling.step(delta: stretch / 2, isPrecise: true, begins: true) == 0)
        #expect(scrolling.step(delta: stretch / 2, isPrecise: true) == 1)
        #expect(scrolling.step(delta: stretch * 0.75, isPrecise: true) == 0)
        // What's left of a long scroll counts toward the next step.
        #expect(scrolling.step(delta: stretch * 1.5, isPrecise: true) == 1)
        #expect(scrolling.step(delta: stretch * 0.25, isPrecise: true) == 1)
        // Down, smaller.
        #expect(scrolling.step(delta: -stretch, isPrecise: true, begins: true) == -1)
    }

    @Test func turningBackOrStartingAgainTakesAWholeStretch() {
        var scrolling = TextSizeScrolling()
        let stretch = TextSizeScrolling.stretch
        #expect(scrolling.step(delta: stretch * 0.9, isPrecise: true, begins: true) == 0)
        #expect(scrolling.step(delta: -stretch * 0.5, isPrecise: true) == 0)
        #expect(scrolling.step(delta: -stretch * 0.5, isPrecise: true) == -1)
        #expect(scrolling.step(delta: stretch * 0.9, isPrecise: true, begins: true) == 0)
        #expect(scrolling.step(delta: stretch * 0.9, isPrecise: true, begins: true) == 0)
    }

    @Test func momentumAfterLiftingYourFingersChangesNothing() {
        var scrolling = TextSizeScrolling()
        let stretch = TextSizeScrolling.stretch
        #expect(scrolling.step(delta: stretch * 0.9, isPrecise: true, begins: true) == 0)
        for _ in 0..<20 {
            #expect(scrolling.step(delta: stretch * 3, isPrecise: true, isMomentum: true) == 0)
        }
    }

    /// macOS has no Dynamic Type: a style's size is fixed, and bigger text uses it times the scale.
    @Test func textStylesKeepAppKitsSizes() {
        let styles: [(Font.TextStyle, NSFont.TextStyle)] = [
            (.largeTitle, .largeTitle), (.title, .title1), (.title2, .title2), (.title3, .title3), (.headline, .headline),
            (.subheadline, .subheadline), (.body, .body), (.callout, .callout), (.footnote, .footnote), (.caption, .caption1),
            (.caption2, .caption2),
        ]
        for (style, appKit) in styles {
            let font = NSFont.preferredFont(forTextStyle: appKit)
            #expect(style.size == font.pointSize, "\(style)")
            #expect((style.weight == .bold) == font.fontDescriptor.symbolicTraits.contains(.bold), "\(style)")
        }
    }

    @Test func atTheUsualSizeFontsAreTheirOwn() {
        #expect(Font.scaled(.headline, by: 1) == .headline)
        #expect(Font.scaled(.title2, weight: .semibold, by: 1) == Font.title2.weight(.semibold))
        #expect(Font.scaled(.headline, by: 1.5) == .system(size: 19.5, weight: .bold))
        #expect(Font.scaled(.title2, weight: .semibold, by: 1.2) == .system(size: 17 * 1.2, weight: .semibold))
    }
}
