import AzureDevOpsCore
import BriefBarUI
import SwiftUI

/// Formatted text from Azure DevOps, such as a description or a comment, drawn by BriefBar: its text can be selected, and
/// its links open in the browser. Nothing it links to or embeds is loaded here; an image is a link to it.
struct RichTextView: View {
    let text: RichText
    var size: CGFloat = 12.5
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.blocks.enumerated()), id: \.offset) { _, block in
                view(of: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(of block: RichText.Block) -> some View {
        switch block {
        case .paragraph(let runs):
            lines(runs)
        case .heading(let level, let runs):
            lines(runs, size: size + max(0, 4 - CGFloat(level)), weight: .semibold)
                .padding(.top, 3)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let depth, let runs):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ListMarkerView(marker: marker, size: size)
                lines(runs)
            }
            .padding(.leading, 4 + CGFloat(min(depth, 6)) * 16)
        case .quote(let runs):
            lines(runs)
                .foregroundStyle(.secondary)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 3)
                }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(size: size - 1, design: .monospaced)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        case .table(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Divider()
                    }
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            lines(cell)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        case .image(let alt, let url):
            ImageLink(alt: alt, url: url, size: size)
        case .rule:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func lines(_ runs: [RichText.Run], size: CGFloat? = nil, weight: Font.Weight = .regular) -> some View {
        // Its fonts are the text's own, so they follow the text size here.
        Text(Self.attributed(runs, size: (size ?? self.size) * scale, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ runs: [RichText.Run], size: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            let isCode = run.style.contains(.code)
            var font = Font.system(
                size: isCode ? size - 1 : size, weight: run.style.contains(.bold) ? .semibold : weight,
                design: isCode ? .monospaced : .default
            )
            if run.style.contains(.italic) { font = font.italic() }
            piece.font = font
            if run.style.contains(.underline) { piece.underlineStyle = .single }
            if run.style.contains(.strikethrough) { piece.strikethroughStyle = .single }
            if isCode { piece.backgroundColor = Color.primary.opacity(0.07) }
            if let link = run.link { piece.link = link }
            result += piece
        }
        return result
    }
}

private struct ListMarkerView: View {
    let marker: RichText.ListMarker
    let size: CGFloat

    var body: some View {
        switch marker {
        case .bullet:
            Text("•")
                .font(size: size, weight: .bold)
                .foregroundStyle(.secondary)
        case .number(let number):
            Text(String(number) + ".")
                .font(size: size).monospacedDigit()
                .foregroundStyle(.secondary)
        case .checkbox(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(size: size)
                .foregroundStyle(checked ? Color.accentColor : .secondary)
                .accessibilityLabel(checked ? "Done" : "Not done")
        }
    }
}

/// An image in the text, which isn't loaded: what it is, which opens it in the browser.
private struct ImageLink: View {
    let alt: String
    let url: URL?
    let size: CGFloat

    var body: some View {
        let label = Label(alt, systemImage: "photo")
            .font(size: size - 0.5)
            .lineLimit(1)
            .truncationMode(.middle)
        if let url {
            Link(destination: url) { label }
                .help("Open the image in your browser")
        } else {
            label.foregroundStyle(.secondary)
        }
    }
}
