import AppKit
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

// The pieces of the window that sends work to Copilot, in BriefBar's look: a tile of color for each thing, as the window's
// sidebar has for its pages, rows that open a menu, choices side by side, capsules on the prompt, and Copy above it.

extension PullRequestAction {
    /// Its symbol, on the window's tile.
    var symbol: String {
        switch self {
        case .fixComments: return "text.bubble.fill"
        case .fixBuild: return "hammer.fill"
        case .resolveConflicts: return "arrow.triangle.merge"
        case .review: return "eye.fill"
        case .pushAndReply: return "arrowshape.turn.up.left.fill"
        }
    }
}

/// The colors of what the window shows.
enum ComposerColors {
    static let newSession = Color(red: 0.20, green: 0.68, blue: 0.42)
    static let task = Color(red: 0.40, green: 0.42, blue: 0.95)
    /// The Copilot app's sessions, as their page's tile.
    static let appSession = Color(red: 0.86, green: 0.30, blue: 0.56)
    static let repository = Color(red: 0.16, green: 0.56, blue: 0.95)
}

/// A symbol, white, on a rounded tile of its color, as the window's sidebar shows its pages; with Quieter Colors, in its
/// color, on a neutral tile.
struct ComposerTile: View {
    enum Fill {
        case tint(Color)
        /// The colors of what a model writes.
        case copilot
    }

    let symbol: String
    var fill: Fill
    var size: CGFloat = 28

    @Environment(\.interfaceOptions) private var options

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            if options.quietAppearance {
                shape.fill(Color.primary.opacity(0.07))
                Image(systemName: symbol)
                    .font(size: size * 0.45, weight: .semibold)
                    .foregroundStyle(quietColor)
            } else {
                shape.fill(background)
                shape.strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
                Image(systemName: symbol)
                    .font(size: size * 0.45, weight: .semibold)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var background: AnyShapeStyle {
        switch fill {
        case .tint(let color): return AnyShapeStyle(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
        case .copilot: return AnyShapeStyle(BriefContainer<EmptyView>.gradient)
        }
    }

    private var quietColor: Color {
        switch fill {
        case .tint(let color): return color
        case .copilot: return .accentColor
        }
    }
}

/// What it's about: a work item's type, or a pull request, as a glyph on a small circle of its color.
struct ComposerBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 17

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            Image(systemName: symbol)
                .font(size: size * 0.5, weight: .semibold)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A part's heading: "Where It Goes", "Prompt".
struct ComposerSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(size: 13, weight: .semibold)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A row of a card that opens a menu: its tile, what's chosen and what that means, and a menu's chevrons. While it can't
/// be changed, the same, without them.
struct ComposerMenuRow<Tile: View, Items: View>: View {
    let title: String
    var caption: String?
    /// Nothing's chosen yet: the title asks for it, in the accent color.
    var isPlaceholder = false
    /// The caption says what went wrong.
    var isWarning = false
    /// Something's being looked for or checked: a spinner, with what it's doing as its tooltip.
    var progress: String?
    var isEnabled = true
    @ViewBuilder var tile: () -> Tile
    @ViewBuilder var items: () -> Items

    @LocalState private var isHovered = false

    var body: some View {
        if isEnabled {
            Menu {
                items()
            } label: {
                row(showsChevrons: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .onHover { isHovered = $0 }
        } else {
            row(showsChevrons: false)
        }
    }

    private func row(showsChevrons: Bool) -> some View {
        HStack(spacing: 12) {
            tile()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(size: 13, weight: .semibold)
                    .foregroundStyle(isPlaceholder ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let caption {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if isWarning {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(size: 10)
                        }
                        Text(caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(size: 11.5)
                    .foregroundStyle(isWarning ? Color.orange : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let progress {
                ProgressView()
                    .controlSize(.small)
                    .help(progress)
            }
            if showsChevrons {
                Image(systemName: "chevron.up.chevron.down")
                    .font(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovered && showsChevrons ? 0.05 : 0))
        )
        .contentShape(Rectangle())
    }
}

/// One way to send it, beside the other: its symbol, what it does, and whether it's the one chosen.
struct ComposerChoice: View {
    let symbol: String
    let title: String
    let detail: String
    let isSelected: Bool
    /// Still finding out whether it can be chosen.
    var isChecking = false
    let choose: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @LocalState private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: choose) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol)
                    .font(size: 14, weight: .medium)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(size: 12.5, weight: .semibold)
                    Text(detail)
                        .font(size: 11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if isChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(size: 14)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                    }
                }
                .frame(width: 16, height: 16)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(isHovered && isEnabled ? 0.06 : 0.035)))
            .overlay(shape.strokeBorder(isSelected ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled || isSelected ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small menu on the prompt, as a capsule: its symbol, what's chosen, and a chevron.
struct ComposerCapsuleMenu<Items: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var items: () -> Items

    @LocalState private var isHovered = false

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(size: 10.5, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(size: 11.5, weight: .medium)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(size: 8, weight: .bold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(isHovered ? 0.1 : 0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
    }
}

/// Copies the prompt as it stands, your changes included, and says so for a moment. It only copies, so it's there
/// whichever session and way you choose, in the demo too: it sends nothing, and takes none of the comments the prompt
/// quotes off Needs You.
struct ComposerCopyButton: View {
    let text: String

    /// What it copied, while it says so. Any change to the prompt forgets it, so Undo or Reset back to the same text
    /// doesn't bring Copied back without another copy.
    @LocalState private var copied: String?
    /// How many times it copied, so that each time says so for as long.
    @LocalState private var copies = 0

    var body: some View {
        let isCopied = copied == text
        Button(action: copy) {
            // As wide either way, so Reset beside it never moves.
            ZStack(alignment: .trailing) {
                Label("Copied", systemImage: "checkmark")
                    .opacity(isCopied ? 1 : 0)
                Label("Copy", systemImage: "doc.on.doc")
                    .opacity(isCopied ? 0 : 1)
            }
            .labelStyle(.titleAndIcon)
            .animation(.easeOut(duration: 0.15), value: isCopied)
        }
        .buttonStyle(.borderless)
        .font(size: 11.5, weight: .medium)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Copy the prompt as it stands, to paste it where you like")
        .accessibilityLabel("Copy Prompt")
        .onChange(of: text) { copied = nil }
        .task(id: copies) {
            guard copies > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                copied = nil
            } catch {}
        }
    }

    private func copy() {
        // In place of everything there, whatever its type, so nothing you copied before is pasted instead.
        ThisMac.copy(text)
        copied = text
        copies += 1
        AccessibilityNotification.Announcement("Copied the prompt").post()
    }
}

/// A menu item that's checked when it's the one chosen.
struct CheckedMenuLabel: View {
    let title: String
    let isChecked: Bool

    var body: some View {
        if isChecked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
