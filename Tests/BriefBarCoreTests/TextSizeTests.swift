import Foundation
import Testing
@testable import BriefBarCore

@Suite struct TextSizeTests {
    @Test func startsAtTheUsualSizeWithoutWritingPreferences() {
        let defaults = MemorySettings()
        #expect(TextSize.load(from: defaults) == .standard)
        #expect(TextSize.standard.percent == 100)
        #expect(TextSize.standard.scale == 1)
        #expect(defaults.object(forKey: TextSize.defaultsKey) == nil)
    }

    @Test func goesUpAStepAtATimeToHalfAsBigAgain() {
        var sizes = [TextSize.standard]
        while let last = sizes.last, last.bigger != last {
            sizes.append(last.bigger)
        }
        #expect(sizes.map(\.percent) == [100, 110, 120, 130, 140, 150])
        #expect(sizes.last?.scale == 1.5)
        #expect(sizes.last?.bigger == sizes.last)
        #expect(TextSize(percent: 150).smaller.percent == 140)
        #expect(TextSize.standard.smaller == .standard)
        #expect(TextSize(percent: 110) < TextSize(percent: 120))
    }

    @Test func anyPercentageBecomesTheNearestSizeOffered() {
        #expect(TextSize(percent: 124).percent == 120)
        #expect(TextSize(percent: 126).percent == 130)
        #expect(TextSize(percent: 0).percent == 100)
        #expect(TextSize(percent: -40).percent == 100)
        #expect(TextSize(percent: 400).percent == 150)
    }

    @Test func savesAndLoadsTheSizeYouChose() {
        let defaults = MemorySettings()
        TextSize(percent: 130).save(to: defaults)
        #expect(TextSize.load(from: defaults).percent == 130)
        TextSize.standard.save(to: defaults)
        #expect(TextSize.load(from: defaults) == .standard)
    }

    @Test func whatIsNoSizeLoadsAsTheNearestOrTheUsualOne() {
        let defaults = MemorySettings()
        defaults.set(1_000, forKey: TextSize.defaultsKey)
        #expect(TextSize.load(from: defaults).percent == 150)
        defaults.set("huge", forKey: TextSize.defaultsKey)
        #expect(TextSize.load(from: defaults) == .standard)
    }

    /// `.font(size:)` and `.font(style:)` follow the text size on windows' pages; `.font(.system(size:))` and `.font(.headline)`
    /// never would.
    @Test func everyViewsTextCanFollowTheTextSize() throws {
        let fixed = /\.font\((Font)?\.(system|largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b/
        for font in [".font(.system(size: 12))", ".font(.headline)", ".font(.title2.weight(.semibold))", ".font(Font.system(size: 11))"] {
            #expect(font.contains(fixed), "\(font)")
        }
        for font in [".font(size: 12)", ".font(style: .headline)", ".font(.scaled(.title2, by: scale))", "NSFont.systemFont(ofSize: 12)"] {
            #expect(!font.contains(fixed), "\(font)")
        }
        #expect(try sourcesMatching(fixed) == ["BriefBarUI/TextSizeStyle.swift"])
    }
}
