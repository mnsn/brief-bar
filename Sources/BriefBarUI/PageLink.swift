import BriefBarCore
import SwiftUI

/// A list's title, which in a menu-bar item's list opens the section's page in BriefBar's window: the title, then a
/// ›, highlighted on hover. On the page itself, in a widget, or while no window has the page, it's only the title.
package struct PageLink<Title: View>: View {
    private let section: SectionID
    /// The page's name, for the tooltip and VoiceOver, such as "Pull Requests".
    private let name: String
    private let title: Title

    @EnvironmentObject private var services: AppServices
    @Environment(\.titleOpensPage) private var titleOpensPage
    @LocalState private var isHovered = false

    package init(_ section: SectionID, name: String, @ViewBuilder title: () -> Title) {
        self.section = section
        self.name = name
        self.title = title()
    }

    package var body: some View {
        if titleOpensPage && services.hasPage(section) {
            Button {
                services.openWindow(section)
            } label: {
                HStack(spacing: 5) {
                    title
                    Image(systemName: "chevron.right")
                        .font(size: 10, weight: .bold)
                        .foregroundStyle(isHovered ? HierarchicalShapeStyle.secondary : .tertiary)
                }
                // The highlight reaches a little past the title, which stays where it was.
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
                )
                .contentShape(Rectangle())
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Open \(name) in BriefBar's window")
            .accessibilityLabel(name)
            .accessibilityHint("Opens its page in BriefBar's window")
        } else {
            title
        }
    }
}

private struct TitleOpensPageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether a list's title opens its section's page in BriefBar's window, as it does in a menu-bar item's list:
    /// not on the page itself, nor in a widget.
    package var titleOpensPage: Bool {
        get { self[TitleOpensPageKey.self] }
        set { self[TitleOpensPageKey.self] = newValue }
    }
}
