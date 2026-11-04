import AppKit
import BriefBarCore
import SwiftUI

// Text on windows' pages follows the text size you choose in Settings › Appearance, or with ⌘-scrolling in a window.
// The menu bar's lists, the widgets and Settings keep their designed sizes, since only a window's page sets the scale.

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// How much bigger than designed text is: the text size you chose, on a window's page; 1 everywhere else.
    package var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension View {
    /// The system font at `size` points, bigger on a window's page when you chose bigger text. Use it rather than
    /// `.font(.system(size:))`, so text follows the text size wherever it shows.
    package func font(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(SizedFont(size: size, weight: weight, design: design))
    }

    /// A text style's font, such as `.headline`, bigger on a window's page when you chose bigger text. Use it rather
    /// than `.font(.headline)`.
    package func font(style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(StyledFont(style: style, weight: weight))
    }

    /// Text as big as you chose for windows' pages.
    package func textSize(from services: AppServices) -> some View {
        modifier(TextSizeEnvironment(services: services))
    }
}

private struct SizedFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

private struct StyledFont: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        content.font(.scaled(style, weight: weight, by: scale))
    }
}

private struct TextSizeEnvironment: ViewModifier {
    @ObservedObject var services: AppServices

    func body(content: Content) -> some View {
        content.environment(\.textScale, CGFloat(services.textSize.scale))
    }
}

// MARK: - Controls

// AppKit draws a bordered, prominent or glass button's title, and a menu's, in the control's own font, whatever font is
// around it, so it would keep its designed size at any text size. Once its label sets its own font, as `ControlLabel`
// does, it's drawn in that font: the control's, as much bigger as the text on windows' pages is. A segmented control and
// a menu with a primary action draw their titles in their own fonts whatever their labels say: AppKit's own controls,
// given the font, take their place (`SegmentedPicker`, `SplitMenuButton`).

extension View {
    /// A menu drawn as its label alone, as `.borderlessButton` draws one, but by SwiftUI, so its label's fonts follow the
    /// text size on windows' pages, which AppKit's never would: its label shows its own ▾ where it should have one
    /// (`MenuChevron`).
    package func labelMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}

/// A menu's ▾ after its title, for one drawn as its label alone (`labelMenuStyle()`), as AppKit draws it.
package struct MenuChevron: View {
    package init() {}

    package var body: some View {
        Image(systemName: "chevron.down")
            .font(size: 9, weight: .bold)
            .accessibilityHidden(true)
    }
}

/// A menu's symbol and title, as AppKit spaces them in a borderless menu, for one drawn as its label alone
/// (`labelMenuStyle()`).
package struct MenuLabelStyle: LabelStyle {
    package init() {}

    package func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

/// A bordered, prominent or glass button's title, or a menu's, its symbol before it, in the control's font as big as the
/// text on windows' pages, which AppKit draws once the label sets it. Its symbol alone with `labelStyle(.iconOnly)`, as in
/// a page's header too narrow for titles.
package struct ControlLabel: View {
    let title: String?
    let systemImage: String?

    @Environment(\.controlSize) private var controlSize
    @Environment(\.textScale) private var scale

    /// - Parameter title: nil for the symbol alone.
    package init(_ title: String?, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    package var body: some View {
        let font = Font.control(controlSize, by: scale)
        if let systemImage, let title {
            Label {
                Text(title).font(font)
            } icon: {
                Image(systemName: systemImage).font(font)
            }
        } else if let systemImage {
            Image(systemName: systemImage).font(font)
        } else {
            Text(title ?? "").font(font)
        }
    }
}

extension ControlSize {
    /// This size, or the next one up from 120%, for a bezel that holds a title as big as the text, which AppKit sizes by
    /// its control's size alone: a size up holds the title at 150% as a bordered button grows to, within a few points.
    package func followingText(_ scale: CGFloat) -> ControlSize {
        let sizes: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]
        guard scale >= 1.2, let index = sizes.firstIndex(of: self) else { return self }
        return sizes[min(index + 1, sizes.count - 1)]
    }

    var appKit: NSControl.ControlSize {
        switch self {
        case .mini: .mini
        case .small: .small
        case .large: .large
        case .extraLarge: .extraLarge
        default: .regular
        }
    }
}

extension Font {
    /// The system font AppKit gives a control of `size`, `scale` times as big: 13 points for a regular one, 11 for a small
    /// one.
    package static func control(_ size: ControlSize, weight: Weight? = nil, by scale: CGFloat) -> Font {
        .system(size: NSFont.systemFontSize(for: size.appKit) * scale, weight: weight)
    }

    /// At 1, the text style's own font; otherwise the system font at the style's size, times `scale`.
    package static func scaled(_ style: TextStyle, weight: Weight? = nil, by scale: CGFloat) -> Font {
        guard scale != 1 else {
            return weight.map { style.font.weight($0) } ?? style.font
        }
        return .system(size: style.size * scale, weight: weight ?? style.weight)
    }
}

extension Font.TextStyle {
    /// Its font, such as `Font.headline`.
    var font: Font {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        @unknown default: .body
        }
    }

    /// Its size on macOS, which has no Dynamic Type: the size of `NSFont.preferredFont(forTextStyle:)`.
    package var size: CGFloat {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }

    /// Bold for a headline; regular for the rest.
    package var weight: Font.Weight {
        self == .headline ? .bold : .regular
    }
}

/// Turns ⌘-scrolling into steps of text size: a step for each notch of a mouse's wheel, and for each stretch of a
/// trackpad's or a Magic Mouse's swipe, however its events divide it, but none for the momentum that carries on once you
/// lift your fingers. Scrolling up, as toward the top of a page, makes text bigger, and down, smaller, whichever way your
/// scrolling goes.
package struct TextSizeScrolling: Sendable {
    /// How far a swipe scrolls for each step, in points.
    package static let stretch: CGFloat = 40

    /// How far the swipe scrolled since its last step, up or down: less than a stretch.
    private var travelled: CGFloat = 0

    package init() {}

    /// - Parameters:
    ///   - delta: how far it scrolled up, such as an event's `scrollingDeltaY`: negative for down.
    ///   - isPrecise: from a trackpad or a Magic Mouse, in points, rather than a wheel's notches.
    ///   - isMomentum: momentum, after you lifted your fingers.
    ///   - begins: a new swipe begins.
    /// - Returns: how many steps bigger, or smaller for a negative number: 0 for none.
    package mutating func steps(delta: CGFloat, isPrecise: Bool, isMomentum: Bool = false, begins: Bool = false) -> Int {
        guard !isMomentum else { return 0 }
        guard isPrecise else {
            travelled = 0
            return delta > 0 ? 1 : delta < 0 ? -1 : 0
        }
        // Turning back takes a whole stretch too.
        if begins || (delta > 0 && travelled < 0) || (delta < 0 && travelled > 0) {
            travelled = 0
        }
        travelled += delta
        let steps = Int(travelled / Self.stretch)
        travelled -= CGFloat(steps) * Self.stretch
        return steps
    }
}
