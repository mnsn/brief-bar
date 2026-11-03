import AppKit
import AzureDevOpsCore
import BriefBarUI
import SwiftUI

/// Code as a pull request changed it: its line numbers, added and removed lines in their colors and marked with + and −,
/// and the lines a comment is on marked in the accent color. Each line is a row, and long ones scroll sideways rather than
/// wrap. Its text can be selected across lines and copied, without the numbers, and follows the window's text size. A
/// comment thread's card shows the code it's on with it; it's meant for whole files too.
///
/// AppKit draws it, an `NSTextView` beside a gutter, so that every row is exactly as tall as the others, its text
/// selectable across rows, and a long file costs only the rows on screen. VoiceOver reads it a row at a time, from a
/// list of its rows, each with its numbers, how the change left it and whether the comment is on it (`ThreadCode.spoken`),
/// and then the text, as it's copied, to select.
struct CodeView: NSViewRepresentable {
    let rows: [CodeRow]
    /// Whether the gutter numbers each line before the change too, beside its number after it: for code with lines
    /// removed, or a comment on the code before the change. Otherwise each line has its number after the change.
    var showsOldNumbers = true
    /// What VoiceOver says the list of its rows is: "Code of PaymentsClient.cs, lines 85 to 91".
    var label = "Code"
    /// How many digits its gutter has room for, at least: as many as a file's longest number, so that the code of each
    /// part of a file's diff starts in the same place.
    var numberDigits = 2
    /// Told how much wider than the room it has its longest line is, in points, as that changes: 0 once they all fit.
    var onOverflow: ((CGFloat) -> Void)? = nil

    /// The size of its text at the usual text size, in points.
    static let textSize: CGFloat = 11.5

    func makeNSView(context: Context) -> CodeNSView {
        CodeNSView()
    }

    func updateNSView(_ view: CodeNSView, context: Context) {
        view.update(
            rows: rows, metrics: CodeMetrics(scale: context.environment.textScale), showsOldNumbers: showsOldNumbers, label: label,
            numberDigits: numberDigits, onOverflow: onOverflow
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodeNSView, context: Context) -> CGSize? {
        let metrics = CodeMetrics(scale: context.environment.textScale)
        let height = metrics.height(of: rows.count)
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: nsView.idealWidth, height: height)
        }
        return CGSize(width: width, height: height)
    }
}

/// The sizes code is drawn at, for a text size.
struct CodeMetrics: Equatable {
    let font: NSFont
    let numberFont: NSFont
    /// Every row's height.
    let lineHeight: CGFloat
    /// How far the text sits above where a row's height would put it, so it's in the middle of its row.
    let baselineOffset: CGFloat
    let digitWidth: CGFloat
    /// The height of a line of numbers.
    let numberHeight: CGFloat

    private init(size: CGFloat) {
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        numberFont = NSFont.monospacedDigitSystemFont(ofSize: size - 1, weight: .regular)
        let layoutManager = NSLayoutManager()
        let natural = layoutManager.defaultLineHeight(for: font)
        lineHeight = (natural * 1.32).rounded(.up)
        baselineOffset = ((lineHeight - natural) / 2).rounded(.down)
        digitWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        numberHeight = layoutManager.defaultLineHeight(for: numberFont)
    }

    /// At the window's text size, `CodeView.textSize` times `scale`.
    @MainActor
    init(scale: CGFloat) {
        let size = (CodeView.textSize * max(scale, 0.5) * 2).rounded() / 2
        if let known = Self.known[size] {
            self = known
        } else {
            self.init(size: size)
            Self.known[size] = self
        }
    }

    @MainActor private static var known: [CGFloat: CodeMetrics] = [:]

    func height(of rows: Int) -> CGFloat {
        CGFloat(max(rows, 0)) * lineHeight
    }
}

// MARK: - AppKit

/// The gutter beside the code, which scrolls sideways under it.
final class CodeNSView: NSView {
    private let gutter = CodeGutterView()
    private let scrollView = CodeScrollView()
    private let textView: CodeTextView
    private var rows: [CodeRow] = []
    private var metrics = CodeMetrics(scale: 1)
    private var onOverflow: ((CGFloat) -> Void)?
    /// The width of the text's longest line, with the room around it.
    private var contentWidth: CGFloat = 0
    private var lastOverflow: CGFloat = -1

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        textView = CodeTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.textContainerInset = NSSize(width: CodeTextView.leading, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = false

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .automatic
        addSubview(gutter)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// As wide as its longest line, with its gutter.
    var idealWidth: CGFloat { gutter.width + contentWidth }

    /// Its text, as selecting all of it copies it: the code, without the numbers.
    var text: String { textView.string }

    /// What VoiceOver says its text is, after the list of its rows, which says more of each.
    static let textLabel = "The code's text, to select and copy"

    /// Whether two lists of rows are the same, their text byte for byte: Swift's strings are equal when they look the
    /// same, as "é" written in one character and in two, but a diff tells those apart, and so must what's copied.
    static func same(_ lhs: [CodeRow], _ rhs: [CodeRow]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 == $1 && $0.text.utf8.elementsEqual($1.text.utf8) }
    }

    func update(
        rows: [CodeRow], metrics: CodeMetrics, showsOldNumbers: Bool, label: String, numberDigits: Int = 2,
        onOverflow: ((CGFloat) -> Void)?
    ) {
        self.onOverflow = onOverflow
        gutter.setAccessibilityLabel(label)
        textView.setAccessibilityLabel(Self.textLabel)
        guard !Self.same(rows, self.rows) || metrics != self.metrics || showsOldNumbers != gutter.showsOldNumbers
            || numberDigits != gutter.numberDigits
        else { return }
        self.rows = rows
        self.metrics = metrics
        gutter.update(rows: rows, metrics: metrics, showsOldNumbers: showsOldNumbers, numberDigits: numberDigits)
        textView.update(rows: rows, metrics: metrics)
        contentWidth = textView.contentWidth
        lastOverflow = -1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = metrics.height(of: rows.count)
        gutter.frame = NSRect(x: 0, y: 0, width: gutter.width, height: height)
        scrollView.frame = NSRect(x: gutter.width, y: 0, width: max(0, bounds.width - gutter.width), height: height)
        let visible = scrollView.contentSize.width
        textView.frame = NSRect(x: 0, y: 0, width: max(contentWidth, visible), height: height)
        let overflow = max(0, (contentWidth - visible).rounded(.up))
        if overflow != lastOverflow {
            lastOverflow = overflow
            let tell = onOverflow
            // Not while SwiftUI lays it out.
            DispatchQueue.main.async { tell?(overflow) }
        }
    }
}

/// Scrolls the code sideways, and leaves scrolling up and down to the page around it: a gesture that starts more
/// sideways than up or down scrolls the code until it ends, its momentum included; any other scrolls the page.
final class CodeScrollView: NSScrollView {
    /// Which way the gesture under way goes: nil until it has moved.
    private var scrollsSideways: Bool?

    override func scrollWheel(with event: NSEvent) {
        let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if !isGesture || event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            // A mouse's wheel turns each time by itself; a gesture goes the way it starts.
            scrollsSideways = nil
        }
        if scrollsSideways == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            scrollsSideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        let canScroll = (documentView?.frame.width ?? 0) > contentSize.width + 0.5
        if scrollsSideways == true, canScroll {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// The code's text, each row a line, and behind it each row's color, as wide as the text or the room it has.
final class CodeTextView: NSTextView {
    /// The room before the text.
    static let leading: CGFloat = 8
    /// After its longest line.
    static let trailing: CGFloat = 12

    private var rows: [CodeRow] = []
    private var metrics = CodeMetrics(scale: 1)
    private(set) var contentWidth: CGFloat = 0

    func update(rows: [CodeRow], metrics: CodeMetrics) {
        self.rows = rows
        self.metrics = metrics
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = metrics.lineHeight
        paragraph.maximumLineHeight = metrics.lineHeight
        paragraph.lineBreakMode = .byClipping
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * ("0" as NSString).size(withAttributes: [.font: metrics.font]).width
        let line: [NSAttributedString.Key: Any] = [
            .font: metrics.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            .baselineOffset: metrics.baselineOffset,
        ]
        var note = line
        note[.foregroundColor] = NSColor.secondaryLabelColor
        let text = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            let isNote = row.kind == .gap
            // Its text as it is, but for what would break it into more lines than one, such as a form feed or a line
            // separator: a space each, so every row stays beside its number.
            let shown = isNote ? "⋯ " + row.text : Self.oneLine(row.text)
            text.append(NSAttributedString(string: shown + (index < rows.count - 1 ? "\n" : ""), attributes: isNote ? note : line))
        }
        typingAttributes = line
        textStorage?.setAttributedString(text)
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
            contentWidth = (layoutManager.usedRect(for: textContainer).width + Self.leading + Self.trailing).rounded(.up)
        }
        needsDisplay = true
    }

    /// A line's text with each character that starts a new line, as the text system sees it, as a space: a carriage
    /// return, a form feed, a vertical tab, the next-line character, and the line and paragraph separators.
    static func oneLine(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: CharacterSet.newlines.contains) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.newlines.contains($0) ? " " : $0 }))
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !rows.isEmpty, metrics.lineHeight > 0 else { return }
        let first = max(0, Int(rect.minY / metrics.lineHeight))
        let last = min(rows.count - 1, Int(rect.maxY / metrics.lineHeight))
        guard first <= last else { return }
        for index in first...last {
            let row = NSRect(x: rect.minX, y: CGFloat(index) * metrics.lineHeight, width: rect.width, height: metrics.lineHeight)
            CodeColors.fill(row, for: rows[index])
        }
    }
}

/// Each row's numbers, before and after the change, and + or −, in front of its color; and a bar in the accent color
/// beside the lines a comment is on. For VoiceOver, it's the list of the rows, each saying its numbers, how the change left
/// it, whether a comment is on it, and its text (`ThreadCode.spoken`), which the text, as copied, doesn't have.
final class CodeGutterView: NSView {
    private var rows: [CodeRow] = []
    private var metrics = CodeMetrics(scale: 1)
    private(set) var showsOldNumbers = true
    /// The fewest digits it has room for.
    private(set) var numberDigits = 2
    private var digits = 2
    /// The rows, for VoiceOver: made as they're first asked for after the rows change.
    private var rowElements: [CodeRowElement]?

    /// The bar, and the room before the numbers.
    private static let bar: CGFloat = 3
    private static let padding: CGFloat = 6
    private static let spacing: CGFloat = 8

    override var isFlipped: Bool { true }

    var width: CGFloat {
        let column = CGFloat(digits) * metrics.digitWidth
        let numbers = showsOldNumbers ? 2 * column + Self.spacing : column
        // The numbers, then + or −.
        return (Self.bar + Self.padding + numbers + Self.spacing + metrics.digitWidth).rounded(.up)
    }

    func update(rows: [CodeRow], metrics: CodeMetrics, showsOldNumbers: Bool, numberDigits: Int = 2) {
        self.rows = rows
        self.metrics = metrics
        self.showsOldNumbers = showsOldNumbers
        self.numberDigits = numberDigits
        let largest = rows.compactMap { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0
        digits = max(2, numberDigits, String(largest).count)
        needsDisplay = true
        if rowElements != nil {
            rowElements = nil
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .list }

    override func accessibilityChildren() -> [Any]? {
        if rowElements == nil {
            rowElements = rows.indices.map { CodeRowElement(index: $0, label: ThreadCode.spoken(rows[$0]), gutter: self) }
        }
        return rowElements
    }

    /// Where a row is on screen: across the code beside the gutter too.
    func screenFrame(ofRow index: Int) -> NSRect {
        let rect = NSRect(
            x: 0, y: CGFloat(index) * metrics.lineHeight, width: superview?.bounds.width ?? bounds.width, height: metrics.lineHeight
        )
        return NSAccessibility.screenRect(fromView: self, rect: rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty, metrics.lineHeight > 0 else { return }
        let first = max(0, Int(dirtyRect.minY / metrics.lineHeight))
        let last = min(rows.count - 1, Int(dirtyRect.maxY / metrics.lineHeight))
        guard first <= last else { return }
        let column = CGFloat(digits) * metrics.digitWidth
        for index in first...last {
            let row = rows[index]
            let top = CGFloat(index) * metrics.lineHeight
            let rect = NSRect(x: 0, y: top, width: bounds.width, height: metrics.lineHeight)
            CodeColors.fill(rect, for: row)
            if row.isMarked {
                NSColor.controlAccentColor.setFill()
                NSRect(x: 0, y: top, width: Self.bar, height: metrics.lineHeight).fill()
            }
            let color: NSColor = row.isMarked ? .controlAccentColor : .tertiaryLabelColor
            let attributes: [NSAttributedString.Key: Any] = [.font: metrics.numberFont, .foregroundColor: color]
            let y = top + ((metrics.lineHeight - metrics.numberHeight) / 2).rounded(.down)
            var x = Self.bar + Self.padding
            func number(_ value: Int?) {
                if let value {
                    let text = String(value) as NSString
                    let size = text.size(withAttributes: attributes)
                    text.draw(at: NSPoint(x: x + column - size.width, y: y), withAttributes: attributes)
                }
                x += column + Self.spacing
            }
            if showsOldNumbers { number(row.oldNumber) }
            number(row.newNumber)
            let sign: (String, NSColor)? = switch row.kind {
            case .line(.added): ("+", .systemGreen)
            case .line(.removed): ("−", .systemRed)
            case .line(.unchanged), .gap: nil
            }
            if let sign {
                (sign.0 as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: metrics.numberFont, .foregroundColor: sign.1])
            }
        }
    }
}

/// A row of code, for VoiceOver: what `ThreadCode.spoken` says of it, where it is on screen.
final class CodeRowElement: NSAccessibilityElement {
    private let index: Int
    private weak var gutter: CodeGutterView?

    init(index: Int, label: String, gutter: CodeGutterView) {
        self.index = index
        self.gutter = gutter
        super.init()
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
        setAccessibilityParent(gutter)
    }

    /// AppKit asks for it on the main thread, where its gutter is, but not every compiler and SDK says so, so it's said
    /// here, with only what may go there: the gutter, a view, and the row's number, not the element.
    override func accessibilityFrame() -> NSRect {
        let gutter = self.gutter
        let row = index
        return MainActor.assumeIsolated { gutter?.screenFrame(ofRow: row) ?? .zero }
    }
}

/// The colors of the rows, the same in the gutter and behind the text.
enum CodeColors {
    static func fill(_ rect: NSRect, for row: CodeRow) {
        let color: NSColor? = switch row.kind {
        case .line(.added): NSColor.systemGreen.withAlphaComponent(0.15)
        case .line(.removed): NSColor.systemRed.withAlphaComponent(0.13)
        case .line(.unchanged): nil
        case .gap: NSColor.labelColor.withAlphaComponent(0.05)
        }
        if let color {
            color.setFill()
            rect.fill(using: .sourceOver)
        }
        if row.isMarked {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            rect.fill(using: .sourceOver)
        }
    }
}
