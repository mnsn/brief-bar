import Foundation

/// How big text is on the pages of BriefBar's windows, where you read long descriptions and comments: a percentage of
/// the sizes the pages are designed at. The menu bar's lists, the widgets and Settings keep their own sizes.
public struct TextSize: Equatable, Hashable, Comparable, Sendable {
    /// From the designed sizes up to half as big again, a step at a time.
    public static let percentages = [100, 110, 120, 130, 140, 150]
    /// The designed sizes, until you choose another.
    public static let standard = TextSize(percent: 100)
    public static let defaultsKey = "interface.textSize"

    /// One of `percentages`.
    public let percent: Int

    /// The size BriefBar offers nearest to `percent`.
    public init(percent: Int) {
        self.percent = Self.percentages.min { abs($0 - percent) < abs($1 - percent) } ?? 100
    }

    /// How much bigger than the designed sizes: 1 at 100%.
    public var scale: Double {
        Double(percent) / 100
    }

    /// The next size up, or this one at the largest.
    public var bigger: TextSize {
        stepped(by: 1)
    }

    /// The next size down, or this one at the standard size.
    public var smaller: TextSize {
        stepped(by: -1)
    }

    /// `steps` sizes bigger, or smaller for a negative number, as far as there are sizes.
    public func stepped(by steps: Int) -> TextSize {
        guard let index = Self.percentages.firstIndex(of: percent) else { return self }
        return TextSize(percent: Self.percentages[min(max(index + steps, 0), Self.percentages.count - 1)])
    }

    public static func < (lhs: TextSize, rhs: TextSize) -> Bool {
        lhs.percent < rhs.percent
    }

    /// The size you chose, or the standard size. Loading writes nothing.
    public static func load(from defaults: some SettingsStorage) -> TextSize {
        guard let percent = defaults.object(forKey: defaultsKey) as? Int else { return .standard }
        return TextSize(percent: percent)
    }

    public func save(to defaults: some SettingsStorage) {
        defaults.set(percent, forKey: Self.defaultsKey)
    }
}
