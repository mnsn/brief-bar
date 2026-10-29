import BriefBarCore
import BriefBarUI
import GitHubCore
import SwiftUI

/// Pull requests' part of a desktop widget, in the list's order.
struct WidgetSectionView: View {
    @EnvironmentObject private var store: GitHubStore
    let rows: Int
    @Environment(\.interfaceOptions) private var options

    private static let headerHeight: CGFloat = 36

    var body: some View {
        let items = store.items
        // Reserve the last row for the "+N more" line when everything doesn't fit.
        let visible = items.count > rows ? Array(items.prefix(rows - 1)) : items
        let hidden = items.count - visible.count

        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .frame(height: Self.headerHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            if visible.isEmpty {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(visible) { item in
                        PRRowView(item: item, now: store.now, compact: true) { store.open(item) }
                            .frame(height: options.compactRowHeight)
                    }
                    if hidden > 0 {
                        WidgetMore(hidden: hidden, total: items.count, section: .githubPullRequests)
                    }
                }
                .padding(.horizontal, 6)
                Spacer(minLength: 0)
            }
        }
        .frame(height: Self.height(rows: rows, options: options))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.merge")
                .font(size: 12, weight: .semibold)
                .foregroundStyle(options.quietAppearance ? Color.secondary : store.counts.needsYou > 0 ? Color.orange : Color.accentColor)
            Text("GitHub")
                .font(size: 13, weight: .semibold)
            if let problem = store.problem, !problem.needsSignIn {
                Image(systemName: "exclamationmark.triangle")
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                    .help(problem.message)
            }
            Spacer()
            if store.hasLoaded && store.problem?.needsSignIn != true && store.counts.total == 0 {
                Text("All quiet")
                    .font(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            } else {
                CountChips(counts: store.counts)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let problem = store.problem {
            VStack(spacing: 6) {
                Label(problem.message, systemImage: problem.needsSignIn ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle")
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                if problem.needsSignIn {
                    Button(problem == .cliNotFound ? "Install the GitHub CLI…" : "Sign In…") { store.signIn() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
        } else if store.hasLoaded {
            QuietView()
        }
    }

    static func height(rows: Int, options: InterfaceOptions = InterfaceOptions()) -> CGFloat {
        headerHeight + CGFloat(rows) * options.compactRowHeight
    }
}
