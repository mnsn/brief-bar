import AppKit
import BriefBarCore
import SwiftUI

/// How every source's things look by state: as Azure DevOps' and Copilot's own groups draw them, so a merged item
/// reads the same as the items you know.
extension ItemState {
    /// A group's heading.
    package var title: String {
        switch self {
        case .needsYou: return "Needs You"
        case .failing: return "Something's Wrong"
        case .running: return "Running"
        case .done: return "Done or Ready"
        }
    }

    /// Starts a line of an item's tooltip: "Needs you: 2 chats, 3 pull requests".
    package var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .failing: return "Something's wrong"
        case .running: return "Running"
        case .done: return "Done or ready"
        }
    }

    /// After a count, as in "11 need you · 4 went wrong · 2 running · 3 done or ready".
    package var countLabel: String {
        switch self {
        case .needsYou: return "need you"
        case .failing: return "went wrong"
        case .running: return "running"
        case .done: return "done or ready"
        }
    }

    /// What it counts, for Settings.
    package var explanation: String {
        switch self {
        case .needsYou: return "Unread chats, pull requests that need you, and Copilot's questions, plans and permission prompts"
        case .failing: return "Failing pull requests, failed pipelines, and Copilot sessions that stopped"
        case .running: return "Copilot sessions at work, and pipelines that are running"
        case .done: return "Pull requests ready to complete, and finished Copilot sessions"
        }
    }

    package var symbol: String {
        switch self {
        case .needsYou: return "hand.raised.fill"
        case .failing: return "xmark.circle.fill"
        case .running: return "bolt.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    package var nsColor: NSColor {
        switch self {
        case .needsYou: return .systemOrange
        case .failing: return .systemRed
        case .running: return .systemBlue
        case .done: return .systemGreen
        }
    }

    package var color: Color { Color(nsColor: nsColor) }

    /// Its color for words, such as a sentence's opening phrase or a row's reason: `color` is for symbols (`TextTint`).
    package var textColor: Color {
        switch self {
        case .needsYou: return TextTint.orange.color
        case .failing: return TextTint.red.color
        case .running: return TextTint.blue.color
        case .done: return TextTint.green.color
        }
    }
}

/// Words in one of the colors that symbols are drawn in: the symbols' colors, such as `ItemState.color`, are too light for
/// words on a light background, so in light mode these are darker, to read at 4.5:1 or more on a list's white and on the
/// window's tinted backdrop, also in a capsule tinted with the symbol's color, such as a link's or a stage's; in dark mode,
/// red, blue, pink, purple and gray are lighter, to read on a raised card too. Symbols keep their bright colors.
package enum TextTint: CaseIterable, Sendable {
    case orange, red, blue, green, teal, purple, pink, mint, gray, yellow, cyan, magenta

    package var color: Color { Color(nsColor: nsColor) }

    /// The same color each time, as SwiftUI tells apart two made alike: views and links compare what they draw in it to
    /// tell what changed.
    package var nsColor: NSColor { Self.colors[self] ?? light }

    private static let colors = Dictionary(uniqueKeysWithValues: allCases.map { tint in
        (tint, NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? tint.dark : tint.light
        })
    })

    private var light: NSColor {
        switch self {
        case .orange: return NSColor(srgbRed: 0.63, green: 0.24, blue: 0.02, alpha: 1)
        case .red: return NSColor(srgbRed: 0.70, green: 0.08, blue: 0.10, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.04, green: 0.33, blue: 0.75, alpha: 1)
        case .green: return NSColor(srgbRed: 0.10, green: 0.42, blue: 0.18, alpha: 1)
        case .teal: return NSColor(srgbRed: 0, green: 0.41, blue: 0.49, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.47, green: 0.20, blue: 0.66, alpha: 1)
        case .pink: return NSColor(srgbRed: 0.66, green: 0.07, blue: 0.32, alpha: 1)
        case .mint: return NSColor(srgbRed: 0, green: 0.41, blue: 0.38, alpha: 1)
        case .gray: return NSColor(srgbRed: 0.33, green: 0.33, blue: 0.36, alpha: 1)
        case .yellow: return NSColor(srgbRed: 0.48, green: 0.36, blue: 0, alpha: 1)
        case .cyan: return NSColor(srgbRed: 0, green: 0.38, blue: 0.59, alpha: 1)
        case .magenta: return NSColor(srgbRed: 0.60, green: 0.16, blue: 0.50, alpha: 1)
        }
    }

    private var dark: NSColor {
        switch self {
        case .orange: return .systemOrange
        case .red: return NSColor(srgbRed: 1, green: 0.54, blue: 0.5, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.42, green: 0.71, blue: 1, alpha: 1)
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .purple: return NSColor(srgbRed: 0.80, green: 0.63, blue: 1, alpha: 1)
        case .pink: return NSColor(srgbRed: 1, green: 0.56, blue: 0.70, alpha: 1)
        case .mint: return .systemMint
        case .gray: return NSColor(srgbRed: 0.76, green: 0.76, blue: 0.79, alpha: 1)
        case .yellow: return .systemYellow
        case .cyan: return .systemCyan
        case .magenta: return NSColor(srgbRed: 0.95, green: 0.58, blue: 0.88, alpha: 1)
        }
    }
}

extension ShapeStyle where Self == Color {
    /// What someone wrote, under a row's title, such as a comment's first lines or what a session asks: quieter than the
    /// title, but stronger than `.secondary`, which is for what's said about it, such as times, repositories and who
    /// wrote it, so that it reads at 4.5:1 or more on a list and on the window's tinted backdrop.
    package static var rowContent: Color { .primary.opacity(0.7) }
}

/// BriefBar's own symbols.
package enum AppSymbols {
    /// BriefBar's own symbol, in the menu bar and in Settings.
    package static let app = "rectangle.stack"
}

/// A header's counts, each group's chip in the order given, such as its symbol and how many: they keep their width, ahead
/// of the title beside them, and where they don't all fit, the least urgent groups go first, rather than any count being
/// cut short.
package struct StateCountChips<Group: Hashable, Chip: View>: View {
    private let groups: [Group]
    private let leastUrgentFirst: [Group]
    private let spacing: CGFloat
    private let chip: (Group) -> Chip

    /// - Parameters:
    ///   - groups: The groups to count, in their order: those with something.
    ///   - leastUrgentFirst: The order they go in where they don't all fit.
    package init(
        _ groups: [Group], leastUrgentFirst: [Group], spacing: CGFloat = 8, @ViewBuilder chip: @escaping (Group) -> Chip
    ) {
        self.groups = groups
        self.leastUrgentFirst = leastUrgentFirst
        self.spacing = spacing
        self.chip = chip
    }

    package var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(0..<max(groups.count, 1), id: \.self) { dropped in
                let gone = Set(leastUrgentFirst.filter(groups.contains).prefix(dropped))
                HStack(spacing: spacing) {
                    ForEach(groups.filter { !gone.contains($0) }, id: \.self) { group in
                        chip(group)
                    }
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
        }
        .layoutPriority(1)
    }
}
