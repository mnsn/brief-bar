import AppKit
import SwiftUI

// The look of BriefBar's windows, and of the pages sources put in them: translucent, with floating panels and
// frosted cards, in light and dark mode. Liquid Glass from macOS 26; offscreen, for `--render`, plain colors.

private struct RenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Drawing offscreen for `--render`, which can't draw materials: views use plain colors instead.
    package var isRendering: Bool {
        get { self[RenderingKey.self] }
        set { self[RenderingKey.self] = newValue }
    }
}

/// The desktop the README's pictures put the window on: offscreen drawing can't see the real one.
package struct DesktopWallpaper: View {
    @Environment(\.colorScheme) private var colorScheme

    package init() {}

    package var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.10, green: 0.14, blue: 0.32), Color(red: 0.24, green: 0.15, blue: 0.40), Color(red: 0.38, green: 0.16, blue: 0.34)]
                : [Color(red: 0.62, green: 0.76, blue: 0.98), Color(red: 0.78, green: 0.72, blue: 0.96), Color(red: 0.97, green: 0.78, blue: 0.86)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// The window's translucent background: the desktop, blurred, through the sidebar material. Offscreen, where
/// materials don't draw, the made-up desktop with the material's tint over it.
package struct WindowBackdrop: View {
    @Environment(\.interfaceOptions) private var options
    @Environment(\.isRendering) private var isRendering
    @Environment(\.colorScheme) private var colorScheme

    package init() {}

    package var body: some View {
        if options.quietAppearance {
            Color(nsColor: .windowBackgroundColor)
        } else if isRendering {
            DesktopWallpaper()
                .overlay(colorScheme == .dark ? Color(white: 0.08).opacity(0.72) : Color(white: 0.97).opacity(0.66))
        } else {
            VisualEffectBackground(material: .sidebar)
        }
    }
}

package struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    package init(material: NSVisualEffectView.Material) {
        self.material = material
    }

    package func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    package func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// A floating panel, such as the sidebar: Liquid Glass from macOS 26, a frosted fill before it and offscreen.
package struct FloatingPanel: ViewModifier {
    var cornerRadius: CGFloat = 20

    @Environment(\.isRendering) private var isRendering
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceOptions) private var options

    package func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if options.quietAppearance {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *), !isRendering {
                content.glassEffect(.regular, in: shape)
            } else {
                frosted(content, shape)
            }
            #else
            frosted(content, shape)
            #endif
        }
    }

    private func frosted(_ content: Content, _ shape: RoundedRectangle) -> some View {
        let dark = colorScheme == .dark
        return content
            .background(
                shape
                    .fill(dark ? Color.white.opacity(0.08) : Color.white.opacity(0.52))
                    .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.14 : 0.85), lineWidth: 1))
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.10), radius: 16, y: 6)
            )
    }
}

/// A frosted card on the window's translucent background: a soft fill that lets the desktop's colors through,
/// a light edge along the top, and a soft shadow. A little brighter on hover.
package struct GlassCard: View {
    var cornerRadius: CGFloat = 16
    var isHovered = false
    /// Stronger, for something on top of a card, such as a task.
    var raised = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceOptions) private var options

    package init(cornerRadius: CGFloat = 16, isHovered: Bool = false, raised: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isHovered = isHovered
        self.raised = raised
    }

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        if options.quietAppearance {
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .overlay(shape.fill(isHovered ? Color.primary.opacity(0.04) : .clear))
        } else {
            shape
                .fill(fill(dark: dark))
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(dark ? 0.16 : 0.95), Color.white.opacity(dark ? 0.04 : 0.35)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(dark ? 0.28 : 0.07), radius: raised ? 4 : 12, y: raised ? 1 : 5)
        }
    }

    private func fill(dark: Bool) -> Color {
        if dark {
            return Color.white.opacity((raised ? 0.07 : 0.06) + (isHovered ? 0.04 : 0))
        }
        return Color.white.opacity((raised ? 0.78 : 0.55) + (isHovered ? 0.15 : 0))
    }
}

extension View {
    package func floatingPanel(cornerRadius: CGFloat = 20) -> some View {
        modifier(FloatingPanel(cornerRadius: cornerRadius))
    }

    /// A glass button from macOS 26; a bordered one before it, and offscreen, where glass doesn't draw.
    package func glassButtonStyle() -> some View {
        modifier(GlassButtonStyle())
    }
}

private struct GlassButtonStyle: ViewModifier {
    @Environment(\.isRendering) private var isRendering

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !isRendering {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
        #else
        content.buttonStyle(.bordered)
        #endif
    }
}

// MARK: - Pages

/// A page's title, what it's about, and its controls on the right. Dragging it moves the window.
package struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    package init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    package var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(size: 26, weight: .bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .help(title)
                if let subtitle {
                    Text(subtitle)
                        .font(size: 12.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.leading, 18)
        .padding(.trailing, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}

/// A page's body: scrolls, and fills the window's width, so a wide window, such as full screen, gets longer lines.
package struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    package init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    package var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.leading, 18)
                .padding(.trailing, 24)
                .padding(.top, 4)
                .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// An empty page: a symbol, what's missing, and what to do about it.
package struct EmptyPage<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    package init(symbol: String, title: String, message: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions
    }

    package var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(size: 34, weight: .light)
                .foregroundStyle(.secondary)
            Text(title)
                .font(size: 15, weight: .semibold)
            Text(message)
                .font(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            actions()
                .padding(.top, 4)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
