import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// One of a pull request's builds, open under its row in the details: its stages, where it failed, whether it's the
/// change's doing, what to do about it, with Copilot too (`BuildCopilotActions`), its errors, the tests that failed and the
/// end of the failed step's log, as read when it opened (`BuildInvestigationStore`); for one still going, its stages as they
/// are, and what it's doing.
struct BuildInvestigationView: View {
    let line: PullRequestPanel.CheckLine
    let item: PRSnapshot
    let pullRequest: PullRequest
    let buildId: Int
    let look: BuildInvestigationStore.Look?
    let now: Date
    /// The composer in place that's open in the builds and checks, and what you wrote in each.
    @Binding var composing: CopilotComposing?
    let drafts: CopilotDrafts

    @EnvironmentObject private var investigations: BuildInvestigationStore

    var body: some View {
        if let investigation = look?.investigation {
            VStack(alignment: .leading, spacing: 14) {
                summary(investigation)
                let hints = investigation.hints
                if !hints.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                            BuildHintLine(hint: hint)
                        }
                    }
                }
                // What Copilot can do about it, then Open Run and when it was read.
                BuildCopilotActions(
                    line: line, item: item, pullRequest: pullRequest, investigation: investigation, now: now, composing: $composing,
                    drafts: drafts
                ) {
                    BuildActions(investigation: investigation, look: look, now: now, readAgain: readAgain)
                }
                if let unread = investigation.unreadSentence {
                    note(unread, symbol: "exclamationmark.triangle")
                }
                if let failure = look?.failure, look?.isReading != true {
                    if PulseProblem.from(failure).offersSignIn {
                        // Signing in is what reads it again: a way to, above what was read before.
                        BuildReadFailure(error: failure, readAgain: readAgain)
                    } else {
                        note("Couldn't read it again: \(BuildInvestigationStore.message(for: failure))", symbol: "exclamationmark.triangle")
                    }
                }
                if !investigation.errors.isEmpty {
                    BuildErrors(errors: investigation.errors, failedStepId: investigation.failedStepId)
                }
                if let tests = investigation.tests {
                    FailedTests(tests: tests, page: investigation.testsPage)
                }
                if let log = investigation.log {
                    BuildLogTail(log: log, step: investigation.logStep?.name, page: investigation.logPage(for: log.stepId))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let failure = look?.failure, look?.isReading != true {
            BuildReadFailure(error: failure, readAgain: readAgain)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading its run…")
                    .foregroundStyle(.secondary)
            }
            .font(size: 12)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func readAgain() {
        investigations.read(buildId, of: pullRequest, check: line.check, again: true)
    }

    /// Its stages, then where it failed, or what it's doing while it's going.
    @ViewBuilder
    private func summary(_ investigation: BuildInvestigation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let stages = investigation.stages
            if !stages.isEmpty {
                StageFlow(stages: stages, now: now)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Stages")
            }
            let failed = investigation.failurePlace
            if !failed.isEmpty {
                FailureNote(failure: PipelineFailure(stage: nil, step: failed.joined(separator: " › "), message: nil))
            }
            if let progress = investigation.progress {
                // Blue while it runs or waits in the queue, orange while a stage waits for an approval, as on the Pipelines
                // page.
                let (symbol, state): (String, ItemState) = switch progress {
                case .queued: ("clock", .running)
                case .running: (PipelineStage.State.running.symbol, .running)
                case .waiting: (PipelineStage.State.waiting.symbol, .needsYou)
                }
                Label {
                    Text(progress.sentence)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(state.color)
                }
                .font(size: 12, weight: .medium)
                .foregroundStyle(state.textColor)
            }
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
        }
        .font(size: 11.5)
        .foregroundStyle(.secondary)
    }
}

/// A part's title inside an open build: "Errors 2".
private struct BuildPartTitle<Trailing: View>: View {
    let title: String
    var detail: String?
    var detailColor: Color = .secondary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(size: 12, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(size: 11.5, weight: .medium)
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            trailing()
        }
    }
}

extension BuildPartTitle where Trailing == EmptyView {
    init(title: String, detail: String? = nil, detailColor: Color = .secondary) {
        self.init(title: title, detail: detail, detailColor: detailColor) { EmptyView() }
    }
}

/// "↗ Open Log": a page of Azure DevOps', for what BriefBar doesn't show.
private struct OpenLink: View {
    let title: String
    let url: URL
    let help: String

    var body: some View {
        Button {
            AzureDevOps.open(url)
        } label: {
            Label(title, systemImage: "arrow.up.forward.app")
                .font(size: 11.5, weight: .medium)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(help)
    }
}

// MARK: - Is it this change?

/// Something that tells whether the failure is the change's doing, as a sentence in its state's color; one about another
/// run opens it, ↗.
private struct BuildHintLine: View {
    let hint: BuildHint

    var body: some View {
        if let run = hint.run {
            Button {
                AzureDevOps.open(run.webURL)
            } label: {
                content(opens: true)
            }
            .buttonStyle(.plain)
            .help("Open \(run.number) in Azure DevOps")
            .accessibilityHint("Opens \(run.number) in Azure DevOps")
        } else {
            content(opens: false)
        }
    }

    private func content(opens: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: hint.symbol)
                .font(size: 11.5, weight: .semibold)
                .foregroundStyle(hint.state.color)
                .frame(width: 16)
                .accessibilityHidden(true)
            // ↗ after a space that doesn't break, so it never ends up alone on a line.
            (opens ? Text("\(hint.sentence)\u{00A0}\(Text(Image(systemName: "arrow.up.forward")).foregroundStyle(.secondary))") : Text(hint.sentence))
                .font(size: 12)
                .foregroundStyle(hint.state.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hint.sentence)
    }
}

extension BuildHint {
    /// An older commit, a pass before, a pass before the target branch changed, the target branch failing or passing.
    var symbol: String {
        switch self {
        case .olderCommit: "clock.arrow.circlepath"
        case .passedBefore: "arrow.triangle.2.circlepath"
        case .passedBeforeTargetChanged: "arrow.triangle.branch"
        case .targetFails: "xmark.circle.fill"
        case .targetPasses: "checkmark.circle.fill"
        }
    }
}

// MARK: - What to do

/// Opening its run, and when it was read, to read it again: after what Copilot can do about it, in one row
/// (`BuildCopilotActions`).
private struct BuildActions: View {
    let investigation: BuildInvestigation
    let look: BuildInvestigationStore.Look?
    let now: Date
    let readAgain: () -> Void

    var body: some View {
        Button {
            AzureDevOps.open(investigation.run.webURL)
        } label: {
            Label("Open Run", systemImage: "arrow.up.forward.app")
        }
        .glassButtonStyle()
        .help("Open \(investigation.run.number) in Azure DevOps, with its whole log")
        readStatus
    }

    /// "Read 2m ago ↻", or that it's being read again.
    private var readStatus: some View {
        HStack(spacing: 4) {
            if look?.isReading == true {
                ProgressView()
                    .controlSize(.mini)
                Text("Reading…")
            } else {
                Text("Read \(WorkItemDetailsPanel.ago(investigation.readAt, now: now))")
                Button(action: readAgain) {
                    Image(systemName: "arrow.clockwise")
                        .font(size: 10.5, weight: .semibold)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Read it again")
                .accessibilityLabel("Read Again")
            }
        }
        .font(size: 11)
        .foregroundStyle(.secondary)
        .padding(.vertical, 3)
        .fixedSize()
    }
}

// MARK: - Errors

/// Its errors, in the order they came, each once: what each says, and where.
private struct BuildErrors: View {
    let errors: [BuildIssue]
    let failedStepId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            BuildPartTitle(title: "Errors", detail: "\(errors.count)")
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(size: 10)
                        .foregroundStyle(ItemState.failing.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(error.message)
                            .font(size: 11, design: .monospaced)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let context = error.context(besides: failedStepId) {
                            Text(context)
                                .font(size: 10.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Tests

/// How its tests went, and the ones that failed, each with what it said, its first lines until you ask for all of it, and
/// its stack trace when you ask.
private struct FailedTests: View {
    let tests: BuildTests
    let page: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BuildPartTitle(title: "Tests", detail: tests.summary,
                           detailColor: tests.failed > 0 ? ItemState.failing.textColor : .secondary) {
                OpenLink(title: "Open Tests", url: page, help: "Open its tests in Azure DevOps")
            }
            ForEach(tests.failures) { test in
                FailedTestRow(test: test)
            }
            if tests.unlisted > 0 {
                Text(tests.unlisted == 1 ? "1 more failed: Open Tests lists it." : "\(tests.unlisted) more failed: Open Tests lists them.")
                    .font(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FailedTestRow: View {
    let test: FailedTest

    @LocalState private var showsTrace = false
    @LocalState private var showsWholeMessage = false
    @LocalState private var messageHeight: (shown: CGFloat, full: CGFloat) = (0, 0)

    /// How many lines of what it said show, until you ask for all of it.
    static let messageLines = 6

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "xmark.circle.fill")
                .font(size: 10.5)
                .foregroundStyle(ItemState.failing.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(test.name)
                        .font(size: 12, weight: .semibold)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(test.fullName ?? test.name)
                        .textSelection(.enabled)
                    if test.outcome.caseInsensitiveCompare("Failed") != .orderedSame {
                        Chip(text: test.outcome, color: ItemState.failing.textColor)
                    }
                    Spacer(minLength: 4)
                    if let duration = test.durationText {
                        Text(duration)
                            .font(size: 10.5).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if let place = place {
                    Text(place)
                        .font(size: 10.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let message = test.message {
                    // Show More at its end while there's more of it, with or without a stack trace; Show Less once it's all
                    // there.
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(message)
                            .font(size: 11, design: .monospaced)
                            .lineLimit(showsWholeMessage ? nil : Self.messageLines)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { messageHeight.shown = $0 }
                            // All of it, unseen, to tell whether its first lines cut it short.
                            .background(alignment: .topLeading) {
                                Text(message)
                                    .font(size: 11, design: .monospaced)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .hidden()
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { messageHeight.full = $0 }
                            }
                        if showsWholeMessage || messageHeight.full > messageHeight.shown + 1 {
                            Button(showsWholeMessage ? "Show Less" : "Show More") {
                                withAnimation(.easeOut(duration: 0.15)) { showsWholeMessage.toggle() }
                            }
                            .buttonStyle(.borderless)
                            .font(size: 11)
                            .foregroundStyle(.tint)
                            .fixedSize()
                            .help(showsWholeMessage ? "Show only the first lines of what it said" : "Show all of what it said")
                        }
                    }
                }
                if let trace = test.stackTrace {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showsTrace.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(size: 8.5, weight: .bold)
                                .rotationEffect(.degrees(showsTrace ? 90 : 0))
                            Text(showsTrace ? "Hide Stack Trace" : "Show Stack Trace")
                        }
                        .font(size: 11, weight: .medium)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityValue(showsTrace ? "Expanded" : "Collapsed")
                    if showsTrace {
                        ScrollView(.horizontal) {
                            Text(trace)
                                .font(size: 10.5, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "DeliveryEstimateTests · Storefront.Tests.dll".
    private var place: String? {
        let parts = [test.suite, test.container].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - The log

/// The end of the failed step's log, as Azure DevOps shows it: its last lines, numbered, each in its kind's color,
/// sideways when they're long, and all of what was read when you ask; ↗ opens the whole log.
private struct BuildLogTail: View {
    let log: BuildLog
    /// The step whose log it is.
    let step: String?
    let page: URL

    @LocalState private var showsAll = false

    private var shown: Int { showsAll ? log.lines.count : BuildInvestigation.logLinesShown }

    var body: some View {
        let lines = log.last(shown)
        VStack(alignment: .leading, spacing: 6) {
            BuildPartTitle(title: "Log", detail: step) {
                OpenLink(title: "Open Log", url: page, help: "Open the whole log in Azure DevOps")
            }
            Text(log.extent(showing: shown))
                .font(size: 11)
                .foregroundStyle(.secondary)
            if !lines.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(lines.map { String($0.number) }.joined(separator: "\n"))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                            .accessibilityHidden(true)
                        Text(Self.text(of: lines))
                            .textSelection(.enabled)
                    }
                    .font(size: 10.5, design: .monospaced)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Log")
            }
            if log.lines.count > BuildInvestigation.logLinesShown {
                Button(showsAll ? "Show Fewer Lines"
                    : log.isCut ? "Show the Last \(log.linesRead) Lines" : "Show All \(log.lineCount) Lines") {
                    withAnimation(.easeOut(duration: 0.15)) { showsAll.toggle() }
                }
                .buttonStyle(.borderless)
                .font(size: 11, weight: .medium)
                .help(showsAll ? "Show only its last \(BuildInvestigation.logLinesShown) lines"
                    : log.isCut ? "Show every line BriefBar read of its end: Open Log has the rest" : "Show every line of it")
            }
        }
    }

    /// Its lines in one text, to select across them: errors red, warnings orange, the commands it ran blue, and the lines
    /// that start and end a step quieter.
    static func text(of lines: [BuildLogLine]) -> AttributedString {
        var text = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { text += AttributedString("\n") }
            var piece = AttributedString(line.text)
            switch line.kind {
            case .error: piece.foregroundColor = ItemState.failing.textColor
            case .warning: piece.foregroundColor = ItemState.needsYou.textColor
            case .command: piece.foregroundColor = ItemState.running.textColor
            case .section, .debug: piece.foregroundColor = Color.secondary
            case .group: piece.inlinePresentationIntent = .stronglyEmphasized
            case .plain: break
            }
            text += piece
        }
        return text
    }
}

// MARK: - Couldn't be read

/// Why a run couldn't be read, and what to do about it.
private struct BuildReadFailure: View {
    let error: ADOError
    let readAgain: () -> Void

    @EnvironmentObject private var store: PRStore

    var body: some View {
        let problem = PulseProblem.from(error)
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(problem.needsSignIn
                     ? (problem == .cliNotFound ? "BriefBar reads Azure DevOps with the Azure CLI, which isn't installed."
                        : "Sign in to the Azure CLI to read this run.")
                     : BuildInvestigationStore.message(for: error))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: problem.offersSignIn ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(size: 12)
            HStack(spacing: 8) {
                if problem.offersSignIn {
                    Button(problem == .cliNotFound ? "Install the Azure CLI…" : "Sign In…") { store.signIn(for: problem) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Try Again", action: readAgain)
            }
            .controlSize(.small)
            .font(size: 11)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.08)))
    }
}
