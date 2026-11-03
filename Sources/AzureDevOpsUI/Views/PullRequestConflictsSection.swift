import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// A pull request's merge conflicts, in its details, while Azure DevOps says it has some: the files that conflict with its
/// target branch, and how, each saying what each branch did to it, read as the details show it
/// (`PullRequestConflictsStore`). A file opens its changes in the details, as its row in Files does. **Resolve with
/// Copilot**, on your own while Send Work to Copilot is on, has Copilot merge the target branch in and resolve them; ↗
/// opens the pull request in Azure DevOps, to resolve them there.
struct PullRequestConflictsSection: View {
    @ObservedObject var details: PullRequestDetailsStore
    let item: PRSnapshot
    /// The pull request as the list read it last: open, and its merge conflicts.
    let pullRequest: PullRequest

    @EnvironmentObject private var conflicts: PullRequestConflictsStore
    @EnvironmentObject private var code: PullRequestCodeStore
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window

    /// What they're read again for, while they show: a push or another target, and a window showing them on screen again,
    /// after none did.
    private struct Reading: Equatable {
        var visibilityChanges: Int
        var head: PullRequestFilesStore.Head
    }

    /// The window's page it's on: nil outside one, where nothing is read.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestCodeStore.page(section, window: window)
    }

    var body: some View {
        let state = conflicts.state(of: pullRequest.key)
        VStack(alignment: .leading, spacing: 8) {
            header(state)
            switch state {
            case .read(let read)?:
                list(read)
            case .failed(let error)?:
                unreadable(error)
            case .reading?, nil:
                placeholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: Reading(visibilityChanges: code.visibilityChanges, head: PullRequestFilesStore.Head(pullRequest))) {
            // Asked for again every half minute while they show, for what couldn't be read, which the store reads again
            // then.
            while !Task.isCancelled {
                conflicts.show(pullRequest, on: page)
                try? await Task.sleep(for: .seconds(PullRequestCodeStore.retryInterval))
            }
        }
        // Read, and kept, while they show: in the panel's details, or on a pull request's page.
        .task(id: item.key) {
            let hold = code.hold(item.key)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
            }
            code.release(hold)
        }
    }

    // MARK: Header

    private func header(_ state: PullRequestConflictsStore.State?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let count: Int? = if case .read(let read)? = state, !read.files.isEmpty { read.files.count } else { nil }
            PageSectionHeader(title: "Merge Conflicts", count: count)
            Spacer(minLength: 8)
            if canResolve {
                Button {
                    store.composeCopilot(.resolveConflicts, for: item, copilot: copilot)
                } label: {
                    Label("Resolve with Copilot", systemImage: PullRequestAction.resolveConflicts.symbol)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(size: 11.5, weight: .medium)
                .disabled(isCopilotBusy)
                .help(isCopilotBusy
                    ? "Copilot is at work on this pull request already"
                    : "Have Copilot merge \(pullRequest.targetBranch) in and resolve the conflicts: it may commit the merge, but doesn't push")
            }
            Button {
                AzureDevOps.open(item.pageURL())
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(size: 11.5, weight: .medium)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open the pull request in Azure DevOps, to resolve its conflicts there")
            .accessibilityLabel("Resolve in Azure DevOps")
        }
    }

    /// Resolve Conflicts applies: your open pull request with conflicts, and Send Work to Copilot on.
    private var canResolve: Bool {
        guard copilot.isOn, copilot.canSend || copilot.mode == .demo, let record = store.record(for: item.key) else { return false }
        return PullRequestTasks.actions(for: record, canShip: false).contains(.resolveConflicts)
    }

    /// A task of BriefBar's is at work on the pull request: nothing more goes until it's done, as in its Actions menu.
    private var isCopilotBusy: Bool {
        copilot.latest(forPullRequest: item.key)?.status.phase.isActive == true
    }

    // MARK: The list

    @ViewBuilder
    private func list(_ read: MergeConflicts) -> some View {
        if read.files.isEmpty {
            notice(
                "Azure DevOps doesn't list which files conflict yet. It shows them on the pull request, where you can resolve them.",
                symbol: "questionmark.circle", again: nil
            )
        } else {
            Text(summary(read))
                .font(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(read.files.enumerated()), id: \.element.id) { index, conflict in
                    if index > 0 {
                        Divider()
                            .opacity(0.6)
                            .padding(.leading, 32)
                    }
                    ConflictRow(conflict: conflict, item: item, pullRequest: pullRequest) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            details.open(file: conflict.pathInPullRequest, from: .section(.conflicts), scope: .whole)
                        }
                    }
                }
            }
            .padding(.vertical, 3)
            .background(GlassCard(cornerRadius: 12, raised: true))
        }
    }

    /// "3 files conflict with main: each branch changed them since they parted." With some resolved in Azure DevOps, which
    /// hasn't committed them, and more than BriefBar reads, it says so.
    private func summary(_ read: MergeConflicts) -> String {
        let count = read.files.count
        let target = pullRequest.targetBranch.isEmpty ? "the target branch" : pullRequest.targetBranch
        var parts = [count == 1 ? "1 file conflicts with \(target)." : "\(count) files conflict with \(target)."]
        let resolved = count - read.unresolved.count
        if resolved > 0 {
            parts.append(resolved == 1
                ? "1 is resolved in Azure DevOps, which hasn't committed it yet."
                : "\(resolved) are resolved in Azure DevOps, which hasn't committed them yet.")
        }
        if !read.isComplete {
            parts.append("Azure DevOps lists more than BriefBar reads: these are the first \(count).")
        }
        return parts.joined(separator: " ")
    }

    /// Why they can't show, with Try Again when that may help, and ↗ to the pull request in Azure DevOps.
    private func unreadable(_ error: ADOError) -> some View {
        let why = switch error {
        case .notFound: "Azure DevOps doesn't list them for this pull request."
        case .forbidden: "You don't have access to them."
        default: error.description
        }
        return notice(
            "BriefBar can't list the files that conflict. " + why, symbol: "eye.slash",
            again: PullRequestConflictsStore.mayPass(error) ? { conflicts.show(pullRequest, on: page, again: true) } : nil
        )
    }

    /// A sentence with its symbol, and Try Again when that may help.
    private func notice(_ text: String, symbol: String, again: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(size: 10.5, weight: .medium)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let again {
                Button(action: again) {
                    Image(systemName: "arrow.clockwise")
                        .font(size: 11, weight: .medium)
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Read them again")
                .accessibilityLabel("Try Again")
            }
        }
        .font(size: 12)
        .foregroundStyle(.secondary)
    }

    /// A few rows' worth, until they're read.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach([0.5, 0.38], id: \.self) { width in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 12, height: 12)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 260 * width, height: 9)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCard(cornerRadius: 12, raised: true))
        .accessibilityElement()
        .accessibilityLabel("Reading the files that conflict")
    }
}

/// A file that conflicts: its name and folder, and what each branch did to it. A click opens its changes in the details.
private struct ConflictRow: View {
    let conflict: MergeConflict
    let item: PRSnapshot
    let pullRequest: PullRequest
    let open: () -> Void

    @Environment(\.textScale) private var textScale
    @LocalState private var isHovered = false

    /// "Changed on both branches", and, once someone resolved it in Azure DevOps, that it isn't committed.
    private var how: String {
        let how = conflict.how(source: pullRequest.sourceBranch, target: pullRequest.targetBranch)
        return conflict.isResolved ? how + " · resolved in Azure DevOps, not committed yet" : how
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: conflict.isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(size: 11.5, weight: .semibold)
                    .foregroundStyle(conflict.isResolved ? ItemState.done.color : ItemState.failing.color)
                    .frame(width: 14 * textScale)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(conflict.name)
                            .font(size: 12.5, weight: .medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if let folder = conflict.folder {
                            Text(folder)
                                .font(size: 11.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Text(how)
                        .font(size: 11.5)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(size: 9, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
                    .padding(.horizontal, 3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(conflict.path + " · " + how + "\nClick to see what this pull request changed in it")
        .contextMenu {
            Button("Show Its Changes", action: open)
            Button("Open in Azure DevOps") { AzureDevOps.open(Self.filePage(conflict.pathInPullRequest, of: item)) }
            Button("Copy Path") { PullRequestDetailsPanel.copy(conflict.path) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows what this pull request changed in it")
        .accessibilityAddTraits(.isButton)
    }

    /// "OrderService.cs, in src/Orders, changed on both branches".
    private var accessibilityLabel: String {
        [conflict.name, conflict.folder.map { "in \($0)" } ?? "at the top", how].joined(separator: ", ")
    }

    /// The pull request's Files page in Azure DevOps, at a file.
    static func filePage(_ path: String, of item: PRSnapshot) -> URL {
        var components = URLComponents(url: item.pageURL(), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "_a", value: "files"), URLQueryItem(name: "path", value: path)]
        return components?.url ?? item.pageURL()
    }
}
