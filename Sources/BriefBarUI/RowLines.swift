import SwiftUI

/// The parts of what a row says under its title, as `RowLines` lays them out.
package enum RowLinePart: Sendable {
    /// Why it's here, in its first words, which stay whole longest: "Sam Rivera replied".
    case reason
    /// Where, after them, cut short first where the row is narrow: " · payments-api".
    case place
    /// Its capsules: its links, a Copilot task's, a session's ↳ tag. At the end of its reason where they fit, or else at the
    /// end of its quiet line: never left out, as a session's capsule is what says that it waits for you.
    case chips
    /// What someone wrote, under its reason.
    case detail
    /// Its quiet line's own things, such as a pull request's stage, its order and what's left.
    case quiet
    /// At its quiet line's far end, such as Finished My Review.
    case trailing
}

private struct RowLinePartKey: LayoutValueKey {
    static let defaultValue = RowLinePart.detail
}

extension View {
    /// Which part of what a row says under its title this is (`RowLines`).
    package func rowLine(_ part: RowLinePart) -> some View {
        layoutValue(key: RowLinePartKey.self, value: part)
    }
}

/// What a row says under its title: its reason and where, with its capsules at its end; what someone wrote; and its quiet
/// line, with what's at its far end. Where the reason's line is too narrow for its capsules, where it is gets cut short
/// first, down to a few letters; where they still don't fit, they go to the end of the quiet line, which folds what it says
/// to make room, as it does for what's at its far end. A part with nothing to show, such as capsules for a row without
/// links, takes no room; each line's parts are centered on one another.
package struct RowLines: Layout {
    /// Under the reason's line.
    static let lineSpacing: CGFloat = 2
    /// Above the quiet line.
    static let quietSpacing: CGFloat = 4
    /// Before the capsules, and between what's on the quiet line.
    static let spacing: CGFloat = 6
    /// Before what's at the quiet line's far end, at least.
    static let trailingSpacing: CGFloat = 8
    /// How much of where it is shows, at least, while the capsules stay beside the reason: its line's height, three times.
    static let placeFloor: CGFloat = 3
    /// Too little room for where it is shows none of it, rather than a lone "…": its line's height, once and a half.
    static let placeShown: CGFloat = 1.5

    package init() {}

    package func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width, subviews).size
    }

    package func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(bounds.width, subviews)
        for index in subviews.indices {
            let frame = arranged.frames[index] ?? .zero
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private struct Part {
        let index: Int
        let subview: LayoutSubview
        let ideal: CGSize

        func size(width: CGFloat) -> CGSize {
            subview.sizeThatFits(ProposedViewSize(width: max(width, 0), height: nil))
        }
    }

    /// Where each part goes, by its index, and how big they come to.
    private struct Arrangement {
        var frames: [Int: CGRect] = [:]
        var size: CGSize = .zero
    }

    /// - Parameter proposedWidth: nil, or infinite, for each part as wide as it would be.
    private func arrange(_ proposedWidth: CGFloat?, _ subviews: Subviews) -> Arrangement {
        func part(_ kind: RowLinePart) -> Part? {
            guard let index = subviews.indices.first(where: { subviews[$0][RowLinePartKey.self] == kind }) else { return nil }
            let ideal = subviews[index].sizeThatFits(.unspecified)
            guard ideal.width > 0, ideal.height > 0 else { return nil }
            return Part(index: index, subview: subviews[index], ideal: ideal)
        }
        let reason = part(.reason), place = part(.place), chips = part(.chips), detail = part(.detail)
        let quiet = part(.quiet), trailing = part(.trailing)

        let chipsWidth = chips.map { $0.ideal.width + Self.spacing } ?? 0
        let trailingWidth = trailing.map { $0.ideal.width + Self.trailingSpacing } ?? 0
        let idealWidth = max(
            (reason?.ideal.width ?? 0) + (place?.ideal.width ?? 0) + chipsWidth, detail?.ideal.width ?? 0,
            (quiet?.ideal.width ?? 0) + trailingWidth
        )
        let width = proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth

        var arranged = Arrangement()
        var y: CGFloat = 0

        // The reason's line, with the capsules at its end while it can keep a few letters of where it is.
        let placeFloor = place.map { min($0.ideal.width, $0.ideal.height * Self.placeFloor) } ?? 0
        let chipsOnReason = chips.map { (reason?.ideal.width ?? 0) + placeFloor + $0.ideal.width + Self.spacing <= width } ?? false
        let textRoom = width - (chipsOnReason ? chipsWidth : 0)
        let reasonSize = reason.map { $0.size(width: min($0.ideal.width, textRoom)) } ?? .zero
        var placeSize = CGSize.zero
        if let place {
            let room = min(place.ideal.width, textRoom - reasonSize.width)
            if room >= min(place.ideal.width, place.ideal.height * Self.placeShown) { placeSize = place.size(width: room) }
        }
        var lineHeight = max(reasonSize.height, placeSize.height)
        if chipsOnReason, let chips { lineHeight = max(lineHeight, chips.ideal.height) }
        func center(_ size: CGSize, x: CGFloat) -> CGRect {
            CGRect(origin: CGPoint(x: x, y: y + (lineHeight - size.height) / 2), size: size)
        }
        if let reason { arranged.frames[reason.index] = center(reasonSize, x: 0) }
        if let place { arranged.frames[place.index] = center(placeSize, x: reasonSize.width) }
        if chipsOnReason, let chips {
            arranged.frames[chips.index] = center(chips.ideal, x: reasonSize.width + placeSize.width + Self.spacing)
        }
        y += lineHeight

        if let detail {
            y += Self.lineSpacing
            let size = detail.size(width: width)
            arranged.frames[detail.index] = CGRect(origin: CGPoint(x: 0, y: y), size: size)
            y += size.height
        }

        // The quiet line: its own things, then the capsules where the reason's line had no room for them, and what's at its
        // far end.
        let chipsOnQuiet = chipsOnReason ? nil : chips
        if quiet != nil || chipsOnQuiet != nil || trailing != nil {
            y += y > 0 ? Self.quietSpacing : 0
            let chipsSize = chipsOnQuiet.map { $0.size(width: min($0.ideal.width, width - trailingWidth)) } ?? .zero
            let room = width - trailingWidth - (chipsOnQuiet == nil ? 0 : chipsSize.width + (quiet == nil ? 0 : Self.spacing))
            let quietSize = quiet.map { $0.size(width: room) } ?? .zero
            lineHeight = max(quietSize.height, chipsSize.height, trailing?.ideal.height ?? 0)
            if let quiet { arranged.frames[quiet.index] = center(quietSize, x: 0) }
            if let chipsOnQuiet {
                arranged.frames[chipsOnQuiet.index] = center(chipsSize, x: quietSize.width > 0 ? quietSize.width + Self.spacing : 0)
            }
            if let trailing { arranged.frames[trailing.index] = center(trailing.ideal, x: width - trailing.ideal.width) }
            y += lineHeight
        }
        arranged.size = CGSize(width: width, height: y)
        return arranged
    }
}
