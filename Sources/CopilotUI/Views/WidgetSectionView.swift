import BriefBarCore
import BriefBarUI
import CopilotCore
import SwiftUI

/// Sessions' part of a desktop widget: those that need attention first, then the most recent idle ones to fill
/// the space.
struct WidgetSectionView: View {
    @EnvironmentObject private var store: SessionStore
    let rows: Int
    @Environment(\.interfaceOptions) private var options

    private static let headerHeight: CGFloat = 36

    var body: some View {
        let active = store.activeSessions
        // Reserve the last row for the "+N more" line when everything doesn't fit.
        let visible = active.count > rows ? Array(active.prefix(rows - 1)) : active
        let hidden = active.count - visible.count
        let recent = hidden > 0 ? [] : Array(store.sessions(in: .idle).prefix(rows - visible.count))

        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .frame(height: Self.headerHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            if visible.isEmpty && recent.isEmpty {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(visible) { row($0) }
                    if hidden > 0 {
                        WidgetMore(hidden: hidden, total: active.count, section: .copilotSessions)
                    }
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, session in
                        row(session)
                            .overlay(alignment: .top) {
                                if index == 0 && !visible.isEmpty {
                                    Rectangle()
                                        .fill(.separator)
                                        .frame(height: 1)
                                        .padding(.horizontal, 8)
                                }
                            }
                    }
                }
                .padding(.horizontal, 6)
                Spacer(minLength: 0)
            }
        }
        .frame(height: Self.height(rows: rows, options: options))
    }

    private func row(_ session: SessionSnapshot) -> some View {
        SessionRowView(session: session, now: store.now, compact: true) { store.open(session) }
            .frame(height: options.compactRowHeight)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(options.quietAppearance ? Color.secondary : store.counts.needsYou > 0 ? Color.orange : Color.accentColor)
            Text("Copilot")
                .font(.system(size: 13, weight: .semibold))
            if let problem = store.problem {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(problem)
            }
            Spacer()
            if store.hasLoaded && store.counts.active == 0 {
                Text("All quiet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                CountChips(counts: store.counts)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let problem = store.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
        } else if store.hasLoaded {
            QuietView(idleCount: store.counts.idle)
        }
    }

    static func height(rows: Int, options: InterfaceOptions = InterfaceOptions()) -> CGFloat {
        headerHeight + CGFloat(rows) * options.compactRowHeight
    }
}
