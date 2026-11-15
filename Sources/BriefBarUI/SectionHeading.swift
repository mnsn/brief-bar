import SwiftUI

/// How big a group's heading is, in points, before a window's text size.
private let headingSize: CGFloat = 12
/// How wide its symbol's column is, in points, before a window's text size: symbols are as wide as their shapes, so in a
/// column of their own, every heading's title starts at the same place.
private let symbolWidth: CGFloat = 16

/// A group's heading in a list, the same in the menu bar's lists and on a window's pages: its symbol in its color, its
/// title, and how many it has, in secondary, such as "✋ Needs You 3". What acts on the group, such as its Clear, goes on
/// the right.
package struct SectionHeading<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let count: Int
    let trailing: Trailing

    @Environment(\.textScale) private var textScale

    /// - Parameter color: the symbol's; the title and the count keep the text's.
    package init(symbol: String, color: Color, title: String, count: Int, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.color = color
        self.title = title
        self.count = count
        self.trailing = trailing()
    }

    package var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: symbolWidth * textScale)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.primary)
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .font(size: headingSize, weight: .semibold)
    }
}

extension SectionHeading where Trailing == EmptyView {
    package init(symbol: String, color: Color, title: String, count: Int) {
        self.init(symbol: symbol, color: color, title: title, count: count) { EmptyView() }
    }
}

/// The heading of a group that folds, such as Idle, below the others: a chevron that turns as it opens, in the column of
/// the other headings' symbols, then its title and how many it has, in secondary, as what it holds matters less. A click
/// opens or folds it.
package struct FoldingSectionHeading: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool

    @Environment(\.textScale) private var textScale

    package init(title: String, count: Int, isExpanded: Binding<Bool>) {
        self.title = title
        self.count = count
        _isExpanded = isExpanded
    }

    package var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(size: 9, weight: .bold)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: symbolWidth * textScale)
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
            }
            .font(size: headingSize, weight: .semibold)
            .foregroundStyle(.secondary)
            // The whole line takes the click, as a disclosure's does.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isHeader)
    }
}
