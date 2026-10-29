import BriefBarCore
import SwiftUI

private struct InterfaceOptionsKey: EnvironmentKey {
    static let defaultValue = InterfaceOptions()
}

extension EnvironmentValues {
    package var interfaceOptions: InterfaceOptions {
        get { self[InterfaceOptionsKey.self] }
        set { self[InterfaceOptionsKey.self] = newValue }
    }
}

extension InterfaceOptions {
    package var compactRowHeight: CGFloat { readableRows ? 46 : 42 }
    package var rowIconWidth: CGFloat { readableRows ? 30 : 20 }
    package var rowDetailSize: CGFloat { readableRows ? 12 : 11 }
    package var rowReasonSize: CGFloat { readableRows ? 13 : 11 }
}

extension View {
    package func interfaceOptions(from services: AppServices) -> some View {
        modifier(InterfaceEnvironment(services: services))
    }

    package func rowActions<Actions: View>(
        for title: String, openTitle: String, open: @escaping () -> Void,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        modifier(RowActions(title: title, openTitle: openTitle, open: open, actions: actions))
    }
}

private struct InterfaceEnvironment: ViewModifier {
    @ObservedObject var services: AppServices

    func body(content: Content) -> some View {
        content.environment(\.interfaceOptions, services.interfaceOptions)
    }
}

private struct RowActions<Actions: View>: ViewModifier {
    let title: String
    let openTitle: String
    let open: () -> Void
    @ViewBuilder var actions: () -> Actions
    @Environment(\.interfaceOptions) private var options

    func body(content: Content) -> some View {
        if options.visibleActions {
            HStack(alignment: .top, spacing: 0) {
                content.frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button(openTitle, action: open)
                    actions()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(size: 13, weight: .semibold)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.top, 5)
                .padding(.trailing, 4)
                .help("\(openTitle) and other actions")
                .accessibilityLabel("Actions for \(title)")
            }
        } else {
            content
        }
    }
}

/// Keeps the original summary treatment unless its compact or quiet option is enabled.
package struct BriefContainer<Content: View>: View {
    let count: Int
    let isWritten: Bool
    @ViewBuilder var content: (Bool) -> Content

    @Environment(\.interfaceOptions) private var options
    @LocalState private var expanded = false

    /// The colors of what a model wrote: the brief's, and a summary's.
    package static var gradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.98, green: 0.55, blue: 0.20), Color(red: 0.93, green: 0.30, blue: 0.55),
                     Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 0.25, green: 0.55, blue: 1.0)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    package init(count: Int, isWritten: Bool, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.count = count
        self.isWritten = isWritten
        self.content = content
    }

    package var body: some View {
        let colorful = isWritten && !options.quietAppearance
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if isWritten {
                    Image(systemName: "sparkles")
                        .font(size: 11, weight: .semibold)
                        .foregroundStyle(colorful ? AnyShapeStyle(Self.gradient) : AnyShapeStyle(Color.secondary))
                }
                Text("Brief")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                if options.compactBriefs, count > 0 {
                    Spacer()
                    Button(expanded ? "Show Less" : count > 2 ? "Show All \(count)" : "Expand") { expanded.toggle() }
                        .buttonStyle(.borderless)
                        .font(size: 11)
                        .frame(minHeight: 28)
                        .accessibilityLabel(expanded ? "Show fewer brief highlights" : "Show the full brief")
                }
            }
            content(options.compactBriefs && !expanded)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorful ? AnyShapeStyle(Self.gradient.opacity(0.09)) : AnyShapeStyle(Color.primary.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(colorful ? AnyShapeStyle(Self.gradient.opacity(0.35)) : AnyShapeStyle(Color.primary.opacity(0.1)), lineWidth: 1)
        )
        .padding(.horizontal, 4)
    }
}

package struct WidgetMore: View {
    let hidden: Int
    let total: Int
    let section: SectionID
    @Environment(\.interfaceOptions) private var options
    @EnvironmentObject private var services: AppServices

    package init(hidden: Int, total: Int, section: SectionID) {
        self.hidden = hidden
        self.total = total
        self.section = section
    }

    package var body: some View {
        Group {
            if options.visibleActions {
                Button(services.hasPage(section) ? "View All \(total)" : "Show in a Window…") {
                    if services.hasPage(section) {
                        services.openWindow(section)
                    } else {
                        services.openSettings(.layout(.windows))
                    }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 28)
                .help(services.hasPage(section) ? "Open the full list in BriefBar" : "This section is hidden from windows. Choose where to show it.")
            } else {
                Text("+\(hidden) more")
            }
        }
        .font(size: 11, weight: .medium)
        .foregroundStyle(options.visibleActions ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, options.readableRows ? 47 : 37)
        .padding(.top, 4)
    }
}

package struct AttentionSummary: View {
    let states: StateCounts

    package init(states: StateCounts) {
        self.states = states
    }

    package var body: some View {
        let count = states.needsYou + states.failing
        HStack(spacing: 4) {
            Image(systemName: states.needsYou == 0 && states.failing > 0 ? "exclamationmark.circle.fill" : "hand.raised.fill")
                .foregroundStyle(count == 0 ? Color.secondary : states.needsYou == 0 ? .red : .orange)
            Text(count == 1 ? "1 needs attention" : "\(count) need attention")
                .monospacedDigit()
        }
        .font(size: 11, weight: .semibold)
        .fixedSize()
        .help("\(states.needsYou) need you; \(states.failing) failing")
        .accessibilityElement(children: .combine)
    }
}
