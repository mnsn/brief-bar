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
/// to make room, as it does for what's at its far end; where it can't fold that far, what doesn't fit goes under it, never
/// over it. A part with nothing to show, such as capsules for a row without links, takes no room; each line's parts are
/// centered on one another.
package struct RowLines: Layout {
    /// Under the reason's line.
    static let lineSpacing: CGFloat = 2
    /// Above the quiet line, and between its lines where it takes more than one.
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
        // far end, its own things folding what they say to make room for the rest. Where they can't fold that far, as a
        // stage's pill and an order's capsule can't, what doesn't fit goes on a line under them rather than over them: what's
        // at the far end first, so that what shows at rest stays where it is; then the capsules too, what's at the far end
        // beside whichever of the two has room for it.
        let chipsOnQuiet = chipsOnReason ? nil : chips
        if quiet != nil || chipsOnQuiet != nil || trailing != nil {
            y += y > 0 ? Self.quietSpacing : 0
            let chipsSize = chipsOnQuiet.map { $0.size(width: min($0.ideal.width, width)) } ?? .zero
            let chipsRoom = chipsOnQuiet == nil ? 0 : chipsSize.width + (quiet == nil ? 0 : Self.spacing)
            // The quiet line's own things, in the room what follows them on their line leaves: nil where they can't fold
            // into it, on one line. Taking more lines to make that room would move what shows at rest, so they take more
            // only with the line to themselves.
            func quietSize(leaving rest: CGFloat) -> CGSize? {
                let size = quiet.map { $0.size(width: width - rest) } ?? .zero
                return size.width + rest <= width + 0.5 && size.height <= (quiet?.ideal.height ?? 0) + 0.5 ? size : nil
            }
            func row(_ items: [(Part?, CGSize)]) -> [(part: Part, size: CGSize)] {
                items.compactMap { part, size in part.map { (part: $0, size: size) } }
            }
            var rows: [[(part: Part, size: CGSize)]]
            var trailingRow = 0
            if let size = quietSize(leaving: chipsRoom + trailingWidth) {
                rows = [row([(quiet, size), (chipsOnQuiet, chipsSize)])]
            } else if trailing != nil, let size = quietSize(leaving: chipsRoom) {
                rows = [row([(quiet, size), (chipsOnQuiet, chipsSize)])]
                trailingRow = 1
            } else {
                let beside = quietSize(leaving: trailingWidth)
                rows = [row([(quiet, beside ?? quiet.map { $0.size(width: width) } ?? .zero)]), row([(chipsOnQuiet, chipsSize)])]
                trailingRow = beside != nil ? 0 : chipsSize.width + trailingWidth <= width + 0.5 ? 1 : 2
            }
            var placed = false
            for index in 0..<max(rows.count, trailing == nil ? 0 : trailingRow + 1) {
                let items = index < rows.count ? rows[index] : []
                let end = index == trailingRow ? trailing : nil
                guard !items.isEmpty || end != nil else { continue }
                y += placed ? Self.quietSpacing : 0
                placed = true
                lineHeight = max(items.map(\.size.height).max() ?? 0, end?.ideal.height ?? 0)
                var x: CGFloat = 0
                for item in items {
                    arranged.frames[item.part.index] = center(item.size, x: x)
                    x += item.size.width > 0 ? item.size.width + Self.spacing : 0
                }
                if let end { arranged.frames[end.index] = center(end.ideal, x: width - end.ideal.width) }
                y += lineHeight
            }
        }
        arranged.size = CGSize(width: width, height: y)
        return arranged
    }
}
