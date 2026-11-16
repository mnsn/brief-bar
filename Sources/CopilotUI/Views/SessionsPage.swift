import BriefBarCore
import BriefBarUI
import CopilotCore
import SwiftUI

/// The Sessions section's page in a window, as Azure DevOps' and GitHub's pages show theirs: every session by what it
/// needs from you, each group in a card under its heading, then the idle ones, folded. A click opens a session in the
/// Copilot app, or shows what a task BriefBar sent is for, in this window wherever it can.
struct SessionsPage: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.interfaceOptions) private var options
    @Environment(\.textScale) private var textScale

    @LocalState private var showIdle = false

    /// The groups with a card each, in the popover's order: Idle folds below them.
    static let shownPhases: [DisplayPhase] = [.needsYou, .running, .done, .stopped]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Sessions", subtitle: Self.subtitle(store.counts, hasLoaded: store.hasLoaded)) {
                if store.appInstalled {
                    Button {
                        CopilotApp.activate()
                    } label: {
                        ControlLabel("Open Copilot", systemImage: "arrow.up.forward.app")
                    }
                    .glassButtonStyle()
                    .help("Open GitHub Copilot")
                }
            }
            PageScroll {
                VStack(alignment: .leading, spacing: 18) {
                    notices
                    ForEach(Self.shownPhases, id: \.self) { phase in
                        let sessions = store.sessions(in: phase)
                        if !sessions.isEmpty {
                            section(phase, sessions)
                        }
                    }
                    idle
                }
            }
        }
    }

    /// "3 need you · 6 running · 2 finished · 1 stopped": the groups with a card, as the menu bar counts them.
    static func subtitle(_ counts: PhaseCounts, hasLoaded: Bool) -> String {
        let parts = shownPhases.filter { counts[$0] > 0 }.map { "\(counts[$0]) \($0.countLabel(counts[$0]))" }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return hasLoaded ? "Nothing needs you" : "Your GitHub Copilot sessions, and which ones need you"
    }

    @ViewBuilder
    private var notices: some View {
        if let problem = store.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        if store.hasLoaded, store.activeSessions.isEmpty {
            QuietView(idleCount: store.counts.idle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if !store.hasLoaded, store.problem == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your sessions…")
                    .font(style: .body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    private func section(_ phase: DisplayPhase, _ sessions: [SessionSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeading(symbol: phase.symbol, color: phase.color, title: phase.title, count: sessions.count) {
                ClearButton(phase: phase)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    // A session nested under the one that started it stays with it, without a line between them.
                    if index > 0, session.depth == 0 {
                        Divider().padding(.leading, dividerInset).padding(.trailing, 12)
                    }
                    SessionRow(session: session)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
            }
            .padding(.vertical, 4)
            .background(GlassCard(cornerRadius: 18))
        }
    }

    /// Where a row's name starts, for the line between rows: the card's and the row's padding, its symbol, and the space
    /// after it.
    private var dividerInset: CGFloat {
        6 + 8 + options.rowIconWidth * textScale + options.rowIconSpacing
    }

    /// Sessions that need nothing and show nothing new, on a line each, folded until you open them, as in the popover.
    @ViewBuilder
    private var idle: some View {
        let idle = store.sessions(in: .idle)
        if !idle.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FoldingSectionHeading(title: DisplayPhase.idle.title, count: idle.count, isExpanded: $showIdle)
                    .padding(.horizontal, 4)
                if showIdle {
                    VStack(spacing: 0) {
                        ForEach(idle) { session in
                            SessionRowView(session: session, now: store.now, compact: true) {
                                store.open(session, inWindow: true)
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(GlassCard(cornerRadius: 18))
                }
            }
        }
    }
}
