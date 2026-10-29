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
        #expect(scrolling.steps(delta: 1, isPrecise: false) == 1)
        #expect(scrolling.steps(delta: 6, isPrecise: false) == 1)
        #expect(scrolling.steps(delta: -2, isPrecise: false) == -1)
        #expect(scrolling.steps(delta: 0, isPrecise: false) == 0)
    }

    @Test func aSwipeStepsOncePerStretch() {
        var scrolling = TextSizeScrolling()
        let stretch = TextSizeScrolling.stretch
        #expect(scrolling.steps(delta: stretch / 2, isPrecise: true, begins: true) == 0)
        #expect(scrolling.steps(delta: stretch / 2, isPrecise: true) == 1)
        #expect(scrolling.steps(delta: stretch * 0.75, isPrecise: true) == 0)
        // A long scroll at once is as many steps as it's stretches, and what's left counts toward the next.
        #expect(scrolling.steps(delta: stretch * 2.5, isPrecise: true) == 3)
        #expect(scrolling.steps(delta: stretch * 0.5, isPrecise: true) == 0)
        #expect(scrolling.steps(delta: stretch * 0.25, isPrecise: true) == 1)
        // Down, smaller.
        #expect(scrolling.steps(delta: -stretch * 2, isPrecise: true, begins: true) == -2)
    }

    /// However macOS divides a swipe into events, it's as many steps.
    @Test(arguments: [[120.0, 0], [40.0, 40, 40, 0], [30.0, 30, 30, 30], [10.0, 110], [119.0, 1, 39]])
    func aSwipesStepsDontDependOnItsEvents(_ deltas: [Double]) {
        var scrolling = TextSizeScrolling()
        let steps = deltas.enumerated().reduce(0) { total, delta in
            total + scrolling.steps(delta: CGFloat(delta.element), isPrecise: true, begins: delta.offset == 0)
        }
        #expect(steps == Int(deltas.reduce(0, +) / Double(TextSizeScrolling.stretch)))
    }

    @Test func turningBackOrStartingAgainTakesAWholeStretch() {
        var scrolling = TextSizeScrolling()
        let stretch = TextSizeScrolling.stretch
        #expect(scrolling.steps(delta: stretch * 0.9, isPrecise: true, begins: true) == 0)
        #expect(scrolling.steps(delta: -stretch * 0.5, isPrecise: true) == 0)
        #expect(scrolling.steps(delta: -stretch * 0.5, isPrecise: true) == -1)
        #expect(scrolling.steps(delta: stretch * 0.9, isPrecise: true, begins: true) == 0)
        #expect(scrolling.steps(delta: stretch * 0.9, isPrecise: true, begins: true) == 0)
    }

    @Test func momentumAfterLiftingYourFingersChangesNothing() {
        var scrolling = TextSizeScrolling()
        let stretch = TextSizeScrolling.stretch
        #expect(scrolling.steps(delta: stretch * 0.9, isPrecise: true, begins: true) == 0)
        for _ in 0..<20 {
            #expect(scrolling.steps(delta: stretch * 3, isPrecise: true, isMomentum: true) == 0)
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
