import BriefBarUI
import SwiftUI

/// Where an item's details go on a page this wide: beside the page's list or board, taking room from it, or over it.
struct DetailsLayout: Equatable {
    /// The narrowest page that has room for the list or board beside the details.
    static let besideWidth: CGFloat = 700
    /// The narrowest the details get beside it.
    static let narrowestPanel: CGFloat = 330

    var isBeside: Bool
    /// The details cover the list or board, which can't be seen, read by VoiceOver or reached with the keyboard meanwhile.
    var coversContent: Bool
    /// How wide the details are beside it: as wide as you made them, where there's room, or 40% of the page, up to 480
    /// points.
    var panelWidth: CGFloat
    /// How wide you can make them on this page: the list or board keeps the room it has on the narrowest page that shows
    /// the details beside it.
    var panelWidths: ClosedRange<CGFloat>

    init(width: CGFloat, showsDetails: Bool, preferredWidth: CGFloat? = nil) {
        isBeside = width >= Self.besideWidth
        coversContent = showsDetails && !isBeside
        let widths = Self.narrowestPanel...max(Self.narrowestPanel, width - (Self.besideWidth - Self.narrowestPanel))
        panelWidths = widths
        let usual = min(max(width * 0.4, Self.narrowestPanel), 480)
        panelWidth = Self.width(nearest: preferredWidth.flatMap { $0.isFinite ? $0 : nil } ?? usual, in: widths)
    }

    /// The width nearest to this one that the details can have on this page.
    func panelWidth(nearest width: CGFloat) -> CGFloat {
        Self.width(nearest: width, in: panelWidths)
    }

    /// How wide the details are with their edge dragged this far: wider to the left, as far as there's room.
    func panelWidth(draggedBy translation: CGFloat) -> CGFloat {
        panelWidth(nearest: panelWidth - translation)
    }

    private static func width(nearest width: CGFloat, in widths: ClosedRange<CGFloat>) -> CGFloat {
        min(max(width, widths.lowerBound), widths.upperBound)
    }
}

/// A page's list or board, and the details of what you clicked in it, in a floating panel: beside it, taking room from
/// it, as wide as you drag them, or over it when the page is narrower than `DetailsLayout.besideWidth`, or while what they
/// show asks for the whole page (`DetailsFillsPageKey`), as a file's diff can. The Sprint page's work items and the Pull
/// Requests page's pull requests show their details this way, each page keeping its own width.
struct DetailsSplit<Content: View, Details: View>: View {
    /// Whether details show.
    let showsDetails: Bool
    /// How wide you made the details beside the list or board, in points; nil for their usual width.
    @Binding var preferredWidth: Double?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var details: () -> Details

    /// How far you're dragging the details' edge, while you do. The width it makes is saved once you let go.
    @GestureState private var resizing: CGFloat? = nil
    /// What shows in the details asks for the whole page, while the page shows them beside the list or board.
    @LocalState private var fillsPage = false
    @Environment(\.isRendering) private var isRendering

    var body: some View {
        // The width the window offers, whatever the list needs: what it needs depends on where the details go.
        GeometryReader { proxy in
            split(DetailsLayout(
                width: proxy.size.width, showsDetails: showsDetails, preferredWidth: preferredWidth.map { CGFloat($0) }
            ))
        }
    }

    private func split(_ layout: DetailsLayout) -> some View {
        let isBeside = layout.isBeside
        // As wide as you're dragging them, while you do.
        let panelWidth = resizing.map(layout.panelWidth(draggedBy:)) ?? layout.panelWidth
        // Over the list or board: in a narrow window, or, beside it, while what they show fills the page.
        let covers = layout.coversContent || showsDetails && isBeside && fillsPage
        let room: DetailsRoom = !isBeside ? .over : covers ? .fillingPage : .beside
        // The details beside the list take room from it; over it, it's out of reach until they close or go back beside
        // it. Before the overlay, so the details aren't.
        return content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, showsDetails && isBeside ? panelWidth + 14 : 0)
            .accessibilityHidden(covers)
            .disabled(covers)
            .overlay(alignment: .topTrailing) {
                if showsDetails {
                    // One place for the details, beside it or over it, so that what they show stays as it is when they
                    // move.
                    ZStack(alignment: .topTrailing) {
                        if covers {
                            WindowBackdrop()
                                .transition(.opacity)
                        }
                        panel
                            // What in them shows more once they're wider, such as long lines of code, can make them so.
                            .environment(\.detailsWidening, covers ? nil : DetailsWidening(width: panelWidth, widest: layout.panelWidths.upperBound) {
                                resize(to: layout.panelWidth(nearest: $0))
                            })
                            .environment(\.detailsRoom, room)
                            .frame(width: covers ? nil : panelWidth)
                            .overlay(alignment: .leading) {
                                if !covers, layout.panelWidths.upperBound > layout.panelWidths.lowerBound {
                                    edge(layout, panelWidth: panelWidth)
                                }
                            }
                            .padding(.leading, covers ? 12 : 0)
                            .padding(.trailing, covers ? 12 : 14)
                            .padding(.bottom, covers ? 12 : 14)
                    }
                    .transition(isBeside ? .move(edge: .trailing).combined(with: .opacity) : .opacity)
                }
            }
            // What shows in them asks for the whole page while it shows, such as a file's diff.
            .onPreferenceChange(DetailsFillsPageKey.self) { fills in
                if fills != fillsPage { withAnimation(isRendering ? nil : .easeOut(duration: 0.2)) { fillsPage = fills } }
            }
    }

    private var panel: some View {
        details()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .floatingPanel(cornerRadius: 18)
    }

    /// The details' left edge, beside the list: dragging it makes them wider or narrower, and a double-click brings back
    /// their usual width.
    private func edge(_ layout: DetailsLayout, panelWidth: CGFloat) -> some View {
        DetailsEdge(isDragging: resizing != nil, panelWidth: panelWidth, panelWidths: layout.panelWidths)
            .offset(x: -DetailsEdge.width / 2)
            // In the window's coordinates, which the edge doesn't move with.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($resizing) { value, state, _ in state = value.translation.width }
                    .onEnded { value in
                        preferredWidth = Double(layout.panelWidth(draggedBy: value.translation.width))
                    }
            )
            .onTapGesture(count: 2) { resize(to: nil) }
            .accessibilityElement()
            .accessibilityLabel("Details Width")
            .accessibilityValue("\(Int(panelWidth.rounded())) points")
            .accessibilityAdjustableAction { direction in
                resize(to: layout.panelWidth(nearest: layout.panelWidth + (direction == .increment ? 60 : -60)))
            }
            .accessibilityAction(named: "Usual Width") { resize(to: nil) }
    }

    /// Makes the details this wide beside the list, or as wide as usual.
    private func resize(to width: CGFloat?) {
        withAnimation(.easeOut(duration: 0.2)) { preferredWidth = width.map { Double($0) } }
    }
}

/// The left edge of the details beside a list or board, to drag: a grip shows while you point at it or drag it, and the
/// pointer says which way it can go.
private struct DetailsEdge: View {
    /// How wide it is to point at: half over the details, half beside them.
    static let width: CGFloat = 10

    let isDragging: Bool
    let panelWidth: CGFloat
    let panelWidths: ClosedRange<CGFloat>

    @LocalState private var isHovered = false

    var body: some View {
        Color.clear
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(isDragging ? Color.accentColor : Color.primary.opacity(0.3))
                    .frame(width: 4, height: 40)
                    .opacity(isHovered || isDragging ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: isHovered || isDragging)
            }
            .onHover { isHovered = $0 }
            .pointerStyle(.columnResize(directions: directions))
            .help("Drag to make the details wider or narrower; double-click for their usual width")
    }

    /// Left while the details can be wider, right while they can be narrower.
    private var directions: HorizontalDirection.Set {
        var directions: HorizontalDirection.Set = []
        if panelWidth < panelWidths.upperBound { directions.insert(.leading) }
        if panelWidth > panelWidths.lowerBound { directions.insert(.trailing) }
        return directions
    }
}

/// The details beside a list or board, for what in them shows more once they're wider: how wide they are, how wide they
/// can be on this page, and making them wider, as dragging their edge does. Nil while they cover the list or board.
struct DetailsWidening {
    var width: CGFloat
    var widest: CGFloat
    var widen: @MainActor (CGFloat) -> Void

    /// Whether they can be wider.
    var canWiden: Bool { width < widest - 1 }
}

private struct DetailsWideningKey: EnvironmentKey {
    static var defaultValue: DetailsWidening? { nil }
}

extension EnvironmentValues {
    var detailsWidening: DetailsWidening? {
        get { self[DetailsWideningKey.self] }
        set { self[DetailsWideningKey.self] = newValue }
    }

    /// Where the details around a view are on their page; nil outside them.
    var detailsRoom: DetailsRoom? {
        get { self[DetailsRoomKey.self] }
        set { self[DetailsRoomKey.self] = newValue }
    }
}

/// Where a page's details are: beside its list or board, over it in a narrow window, or over all of it while what they show
/// fills the page, such as a file's diff.
enum DetailsRoom: Equatable {
    case beside
    case over
    case fillingPage
}

private struct DetailsRoomKey: EnvironmentKey {
    static var defaultValue: DetailsRoom? { nil }
}

/// Whether what shows in a page's details asks for the whole page, beside the list or board: true while any view in them
/// asks for it.
struct DetailsFillsPageKey: PreferenceKey {
    static var defaultValue: Bool { false }

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
