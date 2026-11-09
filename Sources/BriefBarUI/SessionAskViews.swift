import AppKit
import BriefBarCore
import SwiftUI

// Ask… on a Copilot session: in its page's heading, beside ✨ Summarize; in its row's menus in Copilot's list; and in a pull
// request's Copilot line ⌄, which opens its page to ask it there. Its field, and what it answers, show under its page's
// heading and under its row, as Explain's answer shows under what it's about. Only while it can ask (`SessionAsks`); never
// in a widget.

private struct OffersAsksKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether Ask… and what sessions answered it show: not in a desktop widget.
    package var offersAsks: Bool {
        get { self[OffersAsksKey.self] }
        set { self[OffersAsksKey.self] = newValue }
    }
}

/// Whether a composer in place is open, which takes Esc from the details it's in: they close once it's closed.
package struct InlineComposerOpen: PreferenceKey {
    package static let defaultValue = false

    package static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Where Ask… shows what a session was asked and answered, and its field: under its page's heading, or under its row in
/// Copilot's list, which shows less of a long answer at first.
package enum SessionAskPlace: Sendable {
    case page
    case row
}

/// What Ask…'s views share: their symbol, and how they name a session.
enum SessionAskViews {
    static let symbol = "bubble.left.and.text.bubble.right"
    /// The most characters of a session's name its sentences show.
    static let nameLimit = 48

    /// A session as a sentence names it: "‘Retry backoff’", or a task of BriefBar's, "the ‘Fix the build’ task"; its name
    /// cut short in its middle when it's long; "the session" when it has none.
    static func quoted(_ name: String, isTask: Bool) -> String {
        let name = short(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !name.isEmpty else { return isTask ? "the task" : "the session" }
        return isTask ? "the ‘\(name)’ task" : "‘\(name)’"
    }

    /// A name cut short in its middle past `nameLimit` characters.
    static func short(_ name: String) -> String {
        guard name.count > nameLimit else { return name }
        let half = (nameLimit - 1) / 2
        return String(name.prefix(half)).trimmingCharacters(in: .whitespaces) + "…"
            + String(name.suffix(half)).trimmingCharacters(in: .whitespaces)
    }

    /// About how many lines of a long answer show until you ask for all of it, and how many it has at most to show whole,
    /// so that one only a few lines longer doesn't hide them behind Show More: as Explain's on a page, fewer under a row.
    static func lines(in place: SessionAskPlace) -> (shown: CGFloat, whole: CGFloat) {
        switch place {
        case .page: (12, 16)
        case .row: (6, 8)
        }
    }

    /// How many blocks start in what shows of a long answer, from where each starts, by its index: the last of them may be
    /// cut, and those after it aren't there at all, for the keyboard's focus or VoiceOver to reach. At least the first.
    static func shown(of tops: [Int: CGFloat], in height: CGFloat) -> Int {
        max(1, tops.values.filter { $0 < height }.count)
    }

    /// "just now", "2 minutes ago", as VoiceOver says how long ago.
    static func spokenAgo(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : Elapsed.spoken(since: date, now: now) + " ago"
    }
}

// MARK: - Ask… in a page's heading

/// Ask…, in a Copilot session's page heading, beside ✨ Summarize: opens the field under it. Only while it can ask, and
/// while nothing's asked of the session and its field is closed: then what shows under the heading has what's next, such as
/// Ask More under its answer.
package struct SessionAskButton: View {
    private let ref: ItemRef

    @EnvironmentObject private var services: AppServices
    @Environment(\.offersAsks) private var offersAsks

    package init(ref: ItemRef) {
        self.ref = ref
    }

    package var body: some View {
        if offersAsks {
            Content(ref: ref, asks: services.sessionAsks)
        }
    }

    private struct Content: View {
        let ref: ItemRef
        @ObservedObject var asks: SessionAsks

        var body: some View {
            if asks.offers(ref), asks.question(for: ref) == nil, !asks.isFieldOpen(for: ref) {
                Button {
                    asks.openField(for: ref)
                } label: {
                    ControlLabel("Ask…", systemImage: SessionAskViews.symbol)
                        .fixedSize()
                }
                .glassButtonStyle()
                .help("Ask the session where it stands, or anything about its work, aside: nothing in it changes")
            }
        }
    }
}

// MARK: - Ask… in menus

/// Ask… in a session's row's menus, in a group of its own: to ask it; while it's asked, to stop; once it answered, to ask
/// more, or dismiss the answer; when it couldn't, to try again, or to ask something else. Not to ask while its field is
/// open already. Each says it's Ask…'s, as Try Asking Again does beside a failed summary's Try Again, in the same menus
/// and VoiceOver's actions, which have no lines between them.
package struct SessionAskMenuItems: View {
    private let ref: ItemRef?
    private let divided: Bool

    @EnvironmentObject private var services: AppServices
    @Environment(\.offersAsks) private var offersAsks

    /// - Parameter divided: whether a line sets them apart, in a menu; not among accessibility actions.
    package init(_ ref: ItemRef?, divided: Bool = true) {
        self.ref = ref
        self.divided = divided
    }

    package var body: some View {
        if offersAsks, let ref {
            Content(ref: ref, divided: divided, asks: services.sessionAsks)
        }
    }

    private struct Content: View {
        let ref: ItemRef
        let divided: Bool
        @ObservedObject var asks: SessionAsks

        var body: some View {
            if asks.offers(ref) {
                let isFieldOpen = asks.isFieldOpen(for: ref)
                if divided { Divider() }
                switch asks.question(for: ref)?.state {
                case nil:
                    if !isFieldOpen { Button("Ask…") { asks.openField(for: ref) } }
                case .asking:
                    Button("Stop Asking") { asks.dismiss(ref) }
                case .answered:
                    if !isFieldOpen { Button("Ask More…") { asks.openField(for: ref) } }
                    Button("Dismiss Answer") { asks.dismiss(ref) }
                case .failed:
                    Button("Try Asking Again") { asks.tryAgain(ref) }
                    if !isFieldOpen { Button("Ask…") { asks.openField(for: ref) } }
                }
                if divided { Divider() }
            }
        }
    }
}

/// Ask…, where a session's page opens, such as a pull request's Copilot line ⌄: opens its field, then its page, where it
/// shows under the heading; Ask More… once it answered. While it's being asked, Stop Asking, as its row's menus have it:
/// asking it again there would stop that question for another. Only while it can ask.
package struct SessionAskPageItem: View {
    private let ref: ItemRef
    private let openPage: () -> Void

    @EnvironmentObject private var services: AppServices
    @Environment(\.offersAsks) private var offersAsks

    /// - Parameter openPage: opens the session's page.
    package init(_ ref: ItemRef, openPage: @escaping () -> Void) {
        self.ref = ref
        self.openPage = openPage
    }

    package var body: some View {
        if offersAsks {
            Content(ref: ref, openPage: openPage, asks: services.sessionAsks)
        }
    }

    private struct Content: View {
        let ref: ItemRef
        let openPage: () -> Void
        @ObservedObject var asks: SessionAsks

        var body: some View {
            if asks.offers(ref) {
                if asks.question(for: ref)?.isAsking == true {
                    Button("Stop Asking") { asks.dismiss(ref) }
                } else {
                    Button(asks.question(for: ref)?.answer != nil ? "Ask More…" : "Ask…") {
                        asks.openField(for: ref)
                        openPage()
                    }
                }
            }
        }
    }
}

// MARK: - What was asked, and the field

/// What was asked of a Copilot session with Ask…, and its field, under its page's heading or its row: while it's asked,
/// that it is, with Stop; once it answered, the answer, as Explain's shows, with Ask More; when it couldn't, why, with Try
/// Again; and, while it's open, the field to ask it, under them. Nothing while nothing's asked and its field is closed.
package struct SessionAskPart: View {
    private let ref: ItemRef?
    private let name: String
    private let isTask: Bool
    private let place: SessionAskPlace
    private let open: (perform: () -> Void, help: String)?

    @EnvironmentObject private var services: AppServices
    @Environment(\.offersAsks) private var offersAsks

    /// - Parameters:
    ///   - name: the session's name, as its row or its page shows it.
    ///   - isTask: it's a task BriefBar sent, which sentences call one: "the ‘Fix the build’ task".
    ///   - open: what ↗ on its answer does, and its tooltip, such as opening the session in GitHub Copilot.
    package init(
        ref: ItemRef?, name: String, isTask: Bool = false, place: SessionAskPlace, open: (perform: () -> Void, help: String)? = nil
    ) {
        self.ref = ref
        self.name = name
        self.isTask = isTask
        self.place = place
        self.open = open
    }

    package var body: some View {
        if offersAsks, let ref, ref.kind == .session {
            SessionAskContent(
                ref: ref, name: SessionAskViews.quoted(name, isTask: isTask), place: place, open: open, isDemo: services.isDemo,
                asks: services.sessionAsks
            )
        }
    }
}

private struct SessionAskContent: View {
    let ref: ItemRef
    /// "‘Retry backoff’", "the ‘Fix the build’ task".
    let name: String
    let place: SessionAskPlace
    let open: (perform: () -> Void, help: String)?
    let isDemo: Bool
    @ObservedObject var asks: SessionAsks

    var body: some View {
        let question = asks.question(for: ref)
        let isFieldOpen = asks.isFieldOpen(for: ref)
        if asks.canAsk, question != nil || isFieldOpen {
            VStack(alignment: .leading, spacing: 8) {
                if let question {
                    questionView(question)
                }
                if isFieldOpen {
                    SessionAskField(ref: ref, name: name, isFollowUp: question?.answer != nil, isDemo: isDemo, asks: asks)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // VoiceOver hears it once it ends, once, though it shows in more than one place, such as a page and a row.
            .onChange(of: question?.endedAt) { announce() }
        }
    }

    @ViewBuilder
    private func questionView(_ question: SessionAsks.Question) -> some View {
        switch question.state {
        case .asking:
            SessionAskingLine(question: question, name: name) { asks.dismiss(ref) }
        case .answered(let answer):
            SessionAnswerCard(
                answer: answer, question: question.shownQuestion, name: name, answeredAt: question.endedAt ?? question.askedAt,
                place: place, open: open, askMore: asks.isFieldOpen(for: ref) ? nil : { asks.openField(for: ref) }
            ) {
                asks.dismiss(ref)
            }
            // Each answer anew, from its beginning.
            .id(question.askedAt)
        case .failed(let problem):
            SessionAskFailureLine(problem: problem, name: name, endedAt: question.endedAt ?? question.askedAt) {
                asks.tryAgain(ref)
            } dismiss: {
                asks.dismiss(ref)
            }
        }
    }

    private func announce() {
        guard let question = asks.question(for: ref), question.endedAt != nil, asks.announcesOnce(ref) else { return }
        let name = SpokenText.unquoted(name)
        switch question.state {
        case .answered: SpokenText.announce("Answer from \(name)")
        case .failed(let problem): SpokenText.announce("Couldn't ask \(name). \(problem.message)")
        case .asking: break
        }
    }
}

/// That a session is being asked, in the running color, with what you asked and since when, and Stop, which stops it and
/// deletes its copy of the session.
private struct SessionAskingLine: View {
    let question: SessionAsks.Question
    let name: String
    let stop: () -> Void

    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TimelineView(.periodic(from: question.askedAt, by: 60)) { context in
                SessionAskLineLabel(
                    symbol: SessionAskViews.symbol, state: .running, text: "Asking \(name)", detail: "You asked: \(question.shownQuestion)",
                    detailLines: 1, since: question.askedAt, now: context.date,
                    spoken: "Asking \(SpokenText.unquoted(name)), for \(Elapsed.spoken(since: question.askedAt, now: context.date)), you asked: \(question.shownQuestion)"
                )
            }
            Button("Stop", action: stop)
                .buttonStyle(.borderless)
                .font(size: 11.5, weight: .medium)
                .fixedSize()
                .help("Stop asking: nothing changes in the session")
                .accessibilityLabel("Stop Asking")
        }
        .modifier(SessionAskLineBackground(state: .running))
    }
}

/// Why a session couldn't answer, in the failing color, with what the Copilot CLI said, when that says more, Try Again and
/// ✕.
private struct SessionAskFailureLine: View {
    let problem: SessionAsks.Problem
    let name: String
    let endedAt: Date
    let tryAgain: () -> Void
    let dismiss: () -> Void

    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TimelineView(.periodic(from: endedAt, by: 60)) { context in
                SessionAskLineLabel(
                    symbol: "exclamationmark.triangle.fill", state: .failing, text: "Couldn't ask \(name): \(problem.message)",
                    detail: problem.detail, detailLines: 3, since: endedAt, now: context.date,
                    spoken: "Couldn't ask \(SpokenText.unquoted(name)): \(problem.message)"
                        + (problem.detail.map { ", " + $0 } ?? "") + ", " + SessionAskViews.spokenAgo(endedAt, now: context.date)
                )
            }
            Button("Try Again", action: tryAgain)
                .buttonStyle(.borderless)
                .font(size: 11.5, weight: .medium)
                .fixedSize()
                .help("Ask it again, as before")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(size: 9.5, weight: .semibold)
                    .frame(width: 18 * textScale, height: 18 * textScale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .modifier(SessionAskLineBackground(state: .failing))
    }
}

/// A line's symbol, sentence and what's under it, and its time, as Explain's lines have them: one element for VoiceOver.
private struct SessionAskLineLabel: View {
    let symbol: String
    let state: ItemState
    let text: String
    let detail: String?
    let detailLines: Int
    let since: Date
    let now: Date
    let spoken: String

    @Environment(\.textScale) private var textScale

    var body: some View {
        // Read here, not in the alignment's closure, which runs apart from the view.
        let scale = textScale
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(size: 11, weight: .semibold)
                .foregroundStyle(state.color)
                .frame(width: 14 * scale)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 * scale }
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(size: 11.5, weight: .medium)
                    .foregroundStyle(state.textColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(detailLines)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: detailLines > 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Elapsed.short(since: since, now: now))
                .font(size: 11, weight: .medium).monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .help([text, detail].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// A line's tinted background, in its state's color, as Explain's lines have it.
private struct SessionAskLineBackground: ViewModifier {
    let state: ItemState

    func body(content: Content) -> some View {
        content
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(state.color.opacity(0.08)))
            .accessibilityElement(children: .contain)
    }
}

/// What a session answered, as Explain's answer shows: from whom and when, Copy, ↗ and ✕; what you asked; the answer, its
/// beginning while it's long, fading out, with Show More; that it was asked aside; and Ask More.
private struct SessionAnswerCard: View {
    let answer: String
    /// What you asked, as it shows: your words, or "Where do you stand?".
    let question: String
    /// "‘Retry backoff’".
    let name: String
    let answeredAt: Date
    let place: SessionAskPlace
    let open: (perform: () -> Void, help: String)?
    /// Opens the field to ask more, unless it's open.
    let askMore: (() -> Void)?
    let dismiss: () -> Void

    @Environment(\.textScale) private var textScale
    @Environment(\.interfaceOptions) private var options
    /// All of a long answer shows, rather than its beginning.
    @LocalState private var showsAll = false
    /// How tall all of the answer is, to tell whether it's long; and where each of its blocks starts, to tell which show.
    @LocalState private var answerHeight: CGFloat = 0
    @LocalState private var blockTops: [Int: CGFloat] = [:]

    /// Its text's size: a little smaller under a row, as a row's words are.
    private var textSize: CGFloat { place == .page ? 12.5 : 12 }
    /// A line of the answer, at the text size on windows' pages.
    private var lineHeight: CGFloat { 16 * textScale }
    private var shownHeight: CGFloat { SessionAskViews.lines(in: place).shown * lineHeight }

    /// It's long: it shows its beginning, then Show More.
    private var isLong: Bool { answerHeight > SessionAskViews.lines(in: place).whole * lineHeight }
    private var isCut: Bool { isLong && !showsAll }

    /// While it's cut, how many of its blocks are there: those that start in what shows.
    private var shownBlocks: Int? {
        guard isCut, !blockTops.isEmpty else { return nil }
        return SessionAskViews.shown(of: blockTops, in: shownHeight)
    }

    var body: some View {
        let colorful = !options.quietAppearance
        let blocks = AnswerMarkdown.blocks(answer)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient) : AnyShapeStyle(Color.secondary))
                    .accessibilityHidden(true)
                // Whole, wrapping beside the buttons when it must, the time never cut short.
                TimelineView(.periodic(from: answeredAt, by: 60)) { context in
                    Text("Answer from \(name) · \(StoryTime.ago(answeredAt, now: context.date))")
                        .font(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Answer from \(SpokenText.unquoted(name)), \(SessionAskViews.spokenAgo(answeredAt, now: context.date))")
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 4)
                iconButton("doc.on.doc", help: "Copy the answer", label: "Copy the Answer") {
                    ThisMac.copy(answer)
                    SpokenText.announce("Copied the answer")
                }
                if let open {
                    iconButton("arrow.up.forward.app", help: open.help, label: "Open the Session", action: open.perform)
                }
                iconButton("xmark", size: 9.5, weight: .semibold, help: "Dismiss the answer", label: "Dismiss the Answer", action: dismiss)
            }
            .frame(minHeight: 18 * textScale)
            Text("You asked: \(question)")
                .font(size: 11.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A long one shows its beginning, fading out, with Show More under it, and Show Less once it's all there: only its
            // blocks that start in what shows are there, and what shows of the last of them takes no clicks below it.
            AnswerText(blocks: blocks, size: textSize, shownBlocks: shownBlocks)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: isCut ? shownHeight : nil, alignment: .top)
                .clipped()
                .contentShape(Rectangle())
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Rectangle()
                        if isCut {
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 28 * textScale)
                        }
                    }
                }
                // All of it, unseen, out of reach of the keyboard and VoiceOver: how tall it is, and where its blocks start.
                .background(alignment: .topLeading) {
                    AnswerText(blocks: blocks, size: textSize, reportsBlockTops: true)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .disabled(true)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
                        .onPreferenceChange(AnswerBlockTops.self) { blockTops = $0 }
                        .transformPreference(AnswerBlockTops.self) { $0 = [:] }
                }
            if isLong {
                Button(showsAll ? "Show Less" : "Show More") {
                    withAnimation(.easeOut(duration: 0.15)) { showsAll.toggle() }
                }
                .buttonStyle(.borderless)
                .font(size: 11)
                // In the tint, as a summary's is.
                .foregroundStyle(.tint)
                .fixedSize()
                .help(showsAll ? "Show only the beginning of the answer" : "Show all of the answer")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Asked aside: the session's history didn't change.")
                    .font(size: 10.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let askMore {
                    Button("Ask More", action: askMore)
                        .buttonStyle(.borderless)
                        .font(size: 11, weight: .medium)
                        .foregroundStyle(.tint)
                        .fixedSize()
                        .help("Ask it more, following up on its answer, aside as before")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient.opacity(0.07)) : AnyShapeStyle(Color.primary.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient.opacity(0.28)) : AnyShapeStyle(Color.primary.opacity(0.1)),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .contain)
    }

    private func iconButton(
        _ symbol: String, size: CGFloat = 10.5, weight: Font.Weight = .medium, help: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(size: size, weight: weight)
                .frame(width: 18 * textScale, height: 18 * textScale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The field that asks a session, in a box of its own: "Ask ‘Retry backoff’", or "Ask More" once it answered; what you want
/// to know, which Return or Ask asks, empty for where it stands; and what asking does. ✕ or Esc closes it.
private struct SessionAskField: View {
    let ref: ItemRef
    /// "‘Retry backoff’".
    let name: String
    /// It follows up on the answer that shows.
    let isFollowUp: Bool
    let isDemo: Bool
    @ObservedObject var asks: SessionAsks

    @FocusState private var isFocused: Bool
    @Environment(\.isRendering) private var isRendering
    @Environment(\.textScale) private var textScale

    private var title: String { isFollowUp ? "Ask More" : "Ask \(name)" }
    /// What it asks while it's empty.
    private var placeholder: String { isFollowUp ? SessionAskPrompt.whereItStandsNow : SessionAskPrompt.whereItStands }

    /// What asking does: as Explain's composer says it.
    private var note: String {
        if isDemo, !isRendering { return "The demo makes its answer up, and runs nothing." }
        return "Asks a copy of \(name) that's deleted after, so nothing changes, and sends its conversation to GitHub Copilot: one premium request."
    }

    private var words: Binding<String> {
        Binding { asks.words(for: ref) } set: { asks.setWords($0, for: ref) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: SessionAskViews.symbol)
                    .font(size: 11.5, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(size: 12.5, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                Button {
                    asks.closeField(for: ref)
                } label: {
                    Image(systemName: "xmark")
                        .font(size: 10, weight: .semibold)
                        .frame(width: 18 * textScale, height: 18 * textScale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .accessibilityLabel("Close \(SpokenText.unquoted(title))")
            }
            TextField(placeholder, text: words, axis: .vertical)
                .textFieldStyle(.plain)
                .font(size: 12.5)
                .lineLimit(1...5)
                .focused($isFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(isFocused ? 0.6 : 0.2), lineWidth: isFocused ? 1.5 : 1)
                )
                // Return asks, empty too: then where it stands.
                .onSubmit(ask)
                .accessibilityLabel(isFollowUp ? "Your Next Question" : "Your Question")
                .accessibilityHint("Empty, it asks: \(placeholder)")
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(size: 10)
                        .accessibilityHidden(true)
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(size: 11)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: ask) {
                    ControlLabel("Ask")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .help(isFollowUp ? "Ask it, following up on its answer" : "Ask it: empty, where it stands")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1))
        // Esc closes it, not the details it's in.
        .preference(key: InlineComposerOpen.self, value: true)
        .onAppear {
            guard !isRendering else { return }
            isFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SpokenText.unquoted(title))
    }

    private func ask() {
        asks.ask(ref, question: asks.words(for: ref))
    }
}
