import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// A pull request's whole change, in its details: the files it touched, folder by folder, each with what happened to it,
/// how many lines it adds and removes, and how many comment threads are on it, open ones first. A file opens its page,
/// with its diff (`PullRequestFilePage`). It shows all of the change, its latest update against where its branch left its
/// target, as Azure DevOps' Files page does, or, once you've looked at the pull request before, what changed since. The
/// files are read as it comes on screen, and each file's lines are counted as its row does, one file at a time
/// (`PullRequestFilesStore`).
struct PullRequestFilesSection: View {
    @ObservedObject var details: PullRequestDetailsStore
    let item: PRSnapshot
    /// The pull request as the list read it last, whose change it reads; nil when the list has none.
    let pullRequest: PullRequest?
    let threads: PullRequestPanel.Threads
    /// The row the details just came back to, pointed out for a moment.
    let highlighted: PullRequestDetailsStore.Anchor?

    @EnvironmentObject private var files: PullRequestFilesStore
    @EnvironmentObject private var code: PullRequestCodeStore
    @EnvironmentObject private var store: PRStore
    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window
    @LocalState private var isOnScreen = false
    /// The folders you folded.
    @LocalState private var folded: Set<ChangedFiles.Folder.ID> = []

    /// What its files are read again for, while it's on screen: a push, another change to show, and a window showing it on
    /// screen again, after none did.
    private struct Reading: Equatable {
        var isOnScreen: Bool
        var visibilityChanges: Int
        var head: PullRequestFilesStore.Head?
        var scope: ChangeScope
    }

    /// The window's page it's on: nil outside one, where nothing is read.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestCodeStore.page(section, window: window)
    }

    private var whole: ChangedFiles? {
        guard let pullRequest, case .read(let changes)? = files.list(of: pullRequest.key, .whole) else { return nil }
        return changes
    }

    /// The update you'd seen when you last looked, for what changed since; nil when there's nothing new since, or you never
    /// looked.
    private var lastSeen: Int? {
        whole?.lastSeenUpdate(at: details.lastLooked)
    }

    var body: some View {
        let state = pullRequest.flatMap { files.list(of: $0.key, details.scope) }
        VStack(alignment: .leading, spacing: 8) {
            header(state)
            if let pullRequest {
                switch state {
                case .read(let changes)?:
                    list(changes, pullRequest)
                case .failed(let problem)?:
                    unreadable(problem, pullRequest)
                case .reading?, nil:
                    placeholder
                }
            } else {
                Text("BriefBar hasn't read this pull request.")
                    .font(size: 12.5)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { proxy in
            // Outside a scroll view, it's on screen.
            proxy.bounds(of: .scrollView).map { $0.intersects(CGRect(origin: .zero, size: proxy.size)) } ?? true
        } action: { isOnScreen = $0 }
        .task(id: Reading(
            isOnScreen: isOnScreen, visibilityChanges: code.visibilityChanges, head: pullRequest.map(PullRequestFilesStore.Head.init),
            scope: details.scope
        )) {
            guard isOnScreen, let pullRequest else { return }
            // The whole change, which says which updates there are, and the one it shows; asked for again every half
            // minute while it's on screen, for what couldn't be read, which the store reads again then.
            while !Task.isCancelled {
                files.showList(of: pullRequest, scope: .whole, on: page)
                if details.scope != .whole { files.showList(of: pullRequest, scope: details.scope, on: page) }
                try? await Task.sleep(for: .seconds(PullRequestCodeStore.retryInterval))
            }
        }
        // Its files are read, and kept, while it shows: in the panel's details, or on a pull request's page.
        .task(id: item.key) {
            let hold = code.hold(item.key)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
            }
            code.release(hold)
        }
        // A change that isn't there anymore, such as since an update before a force push: all of it.
        .onChange(of: lastSeen) {
            if case .since(let update) = details.scope, update != lastSeen { details.scope = .whole }
        }
    }

    // MARK: Header

    private func header(_ state: PullRequestFilesStore.State<ChangedFiles>?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            let count: Int? = if case .read(let changes)? = state, !changes.files.isEmpty { changes.files.count } else { nil }
            PageSectionHeader(title: "Files", count: count)
            Spacer(minLength: 6)
            if let lastSeen {
                scopeMenu(since: lastSeen)
            }
            Button {
                AzureDevOps.open(Self.filesPage(item))
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(size: 11.5, weight: .medium)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open the pull request's files in Azure DevOps")
            .accessibilityLabel("Open Files in Azure DevOps")
        }
    }

    /// All of the change, or what changed since you last looked.
    private func scopeMenu(since update: Int) -> some View {
        Menu {
            Picker("Show", selection: $details.scope) {
                Text("All Changes").tag(ChangeScope.whole)
                Text(sinceTitle(update)).tag(ChangeScope.since(update))
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(details.scope == .whole ? "All Changes" : "Since You Last Looked")
                .font(size: 11.5, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show all of the change, or only what changed since you last looked")
        .accessibilityLabel("Changes Shown")
        .accessibilityValue(details.scope == .whole ? "All changes" : "Since you last looked")
    }

    /// "Since You Last Looked: 2 Updates".
    private func sinceTitle(_ update: Int) -> String {
        let count = whole?.updates(since: update) ?? 1
        return "Since You Last Looked: " + (count == 1 ? "1 Update" : "\(count) Updates")
    }

    // MARK: The list

    @ViewBuilder
    private func list(_ changes: ChangedFiles, _ pullRequest: PullRequest) -> some View {
        Text(summary(changes))
            .font(size: 12)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if !changes.isComplete {
            Label("The pull request changes more files than BriefBar reads: these are the first 10,000.", systemImage: "exclamationmark.triangle")
                .font(size: 11.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !changes.files.isEmpty {
            // Each file's comments, found once, rather than for each row as it's drawn. When any file has some, each row
            // keeps room for them, so the counts line up.
            let comments = threads.comments(in: changes)
            // One list, so that the details can scroll to a file's row before it's drawn.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries(changes)) { entry in
                    switch entry {
                    case .folder(let folder):
                        FolderHeader(
                            folder: folder, name: folder.path ?? pullRequest.repositoryName, isFolded: folded.contains(folder.id)
                        ) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if folded.remove(folder.id) == nil { folded.insert(folder.id) }
                            }
                        }
                    case .file(let file):
                        ChangedFileRow(
                            file: file, changes: changes, item: item, pullRequest: pullRequest,
                            comments: comments[file.id] ?? PullRequestPanel.FileComments(threads: []),
                            isHighlighted: highlighted == .file(file.id), reservesComments: !comments.isEmpty
                        ) {
                            withAnimation(.easeOut(duration: 0.15)) { details.open(file: file.path) }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .background(GlassCard(cornerRadius: 12, raised: true))
        }
    }

    /// A folder's heading or a file's row.
    private enum Entry: Identifiable {
        case folder(ChangedFiles.Folder)
        case file(FileChange)

        /// A file's is what the details scroll to, coming back from its page.
        var id: AnyHashable {
            switch self {
            case .folder(let folder): AnyHashable(folder.id)
            case .file(let file): AnyHashable(PullRequestDetailsStore.Anchor.file(file.id))
            }
        }
    }

    /// Each folder's heading, and its files' rows unless you folded it.
    private func entries(_ changes: ChangedFiles) -> [Entry] {
        changes.folders.flatMap { folder in
            [Entry.folder(folder)] + (folded.contains(folder.id) ? [] : folder.files.map(Entry.file))
        }
    }

    /// "9 files changed, 128 lines added and 46 removed"; "What the 2 updates since you last looked, 3h ago, changed: 4 files".
    private func summary(_ changes: ChangedFiles) -> String {
        let count = changes.files.count
        let filesText = count == 1 ? "1 file" : "\(count) files"
        let total = count > 0 ? files.totals(of: changes, in: pullRequest?.key ?? item.key) : nil
        let lines = total.map { ", " + $0.spoken.lowercased() } ?? ""
        guard case .since(let update) = changes.scope else {
            return count == 0 ? "No files changed." : "\(filesText) changed\(lines)."
        }
        let updates = changes.updates(since: update)
        let looked = details.lastLooked.map { ", " + WorkItemDetailsPanel.ago($0, now: store.now) } ?? ""
        let since = updates == 1 ? "the update since you last looked\(looked)" : "the \(updates) updates since you last looked\(looked)"
        return count == 0 ? "Nothing changed in \(since)." : "In \(since): \(filesText) changed\(lines)."
    }

    /// Why its files can't show, with Try Again when that may help, and ↗ to them in Azure DevOps.
    private func unreadable(_ problem: ThreadExcerpt.Problem, _ pullRequest: PullRequest) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "eye.slash")
                .font(size: 10.5, weight: .medium)
                .accessibilityHidden(true)
            Text("BriefBar can't list its files. " + (ThreadCode.sentence(for: problem) ?? problem.description))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if ThreadCode.mayPass(problem) {
                Button {
                    files.showList(of: pullRequest, scope: details.scope, on: page, again: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(size: 11, weight: .medium)
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Read its files again")
                .accessibilityLabel("Try Again")
            }
            Button {
                AzureDevOps.open(Self.filesPage(item))
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(size: 11, weight: .medium)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("See its files in Azure DevOps")
            .accessibilityLabel("Open in Azure DevOps")
        }
        .font(size: 12)
        .foregroundStyle(.secondary)
    }

    /// The pull request's Files page in Azure DevOps.
    static func filesPage(_ item: PRSnapshot) -> URL {
        var components = URLComponents(url: item.pageURL(), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "_a", value: "files")]
        return components?.url ?? item.pageURL()
    }

    /// A few rows' worth, until its files are read.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach([0.45, 0.62, 0.38], id: \.self) { width in
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
        .accessibilityLabel("Reading its files")
    }
}

/// A folder's heading among a change's files: its path, from the top of the repository, or the repository's name for the
/// files at its top. A click folds its files away, saying how many there are, or unfolds them.
private struct FolderHeader: View {
    let folder: ChangedFiles.Folder
    let name: String
    let isFolded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(size: 8.5, weight: .bold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                Image(systemName: folder.path == nil ? "shippingbox" : "folder")
                    .font(size: 10.5, weight: .medium)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(size: 11.5, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if isFolded {
                    Text(folder.files.count == 1 ? "1 file" : "\(folder.files.count) files")
                        .font(size: 11)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFolded ? "Show the files in \(name)" : "Hide the files in \(name)")
        .accessibilityLabel("\(name), \(folder.files.count == 1 ? "1 file" : "\(folder.files.count) files")")
        .accessibilityValue(isFolded ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }
}

/// A file of a change: what happened to it, its name, how many lines it adds and removes, counted as its row comes on
/// screen, and how many comment threads are on it. A click opens its page.
private struct ChangedFileRow: View {
    let file: FileChange
    let changes: ChangedFiles
    let item: PRSnapshot
    let pullRequest: PullRequest
    let comments: PullRequestPanel.FileComments
    let isHighlighted: Bool
    /// Keep room for the comments' count, for the counts to line up with other rows'.
    var reservesComments = false
    let open: () -> Void

    /// The room the comments' count takes, up to 99 of them, at the default text size.
    private static let commentsWidth: CGFloat = 30

    @EnvironmentObject private var files: PullRequestFilesStore
    @Environment(\.textScale) private var textScale
    /// VoiceOver goes to it as the details come back to it from its page.
    @AccessibilityFocusState private var isFocused: Bool
    @EnvironmentObject private var code: PullRequestCodeStore
    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window
    @LocalState private var isOnScreen = false
    @LocalState private var isHovered = false
    /// What it tells the store it is, so that the same file's row elsewhere goes on being counted once this one leaves.
    @LocalState private var viewer = UUID()
    /// The version of the file it asked to count last, to let go of once a push changes it.
    @LocalState private var countedVersion: PullRequestFilesStore.Version?

    private var version: PullRequestFilesStore.Version { PullRequestFilesStore.Version(file, in: changes) }

    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestCodeStore.page(section, window: window)
    }

    /// What it's counted again for: coming on screen, a window showing it again, and another version of the file.
    private struct Counting: Equatable {
        var isOnScreen: Bool
        var visibilityChanges: Int
        var version: PullRequestFilesStore.Version
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let kind = FileKindStyle(file.kind)
                Image(systemName: kind.symbol)
                    .font(size: 11.5, weight: .semibold)
                    .foregroundStyle(kind.color)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(size: 12.5, weight: .medium)
                        .strikethrough(file.kind.contains(.delete), color: .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.originalPath != nil {
                        Text(file.what)
                            .font(size: 11)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 6)
                // Whole, however long the name: it's what gives.
                FileCountsText(counts: files.counts(of: version, in: pullRequest.key))
                    .fixedSize()
                if !comments.isEmpty {
                    FileCommentsBadge(comments: comments)
                        .fixedSize()
                        .frame(minWidth: Self.commentsWidth * textScale, alignment: .trailing)
                } else if reservesComments {
                    Color.clear
                        .frame(width: Self.commentsWidth * textScale, height: 1)
                }
                Image(systemName: "chevron.right")
                    .font(size: 9, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(isHighlighted ? 0.14 : isHovered ? 0.06 : 0))
                    .padding(.horizontal, 3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(file.path + " · " + file.what)
        .contextMenu {
            Button("Show Its Changes") { open() }
            Button("Open in Azure DevOps") { AzureDevOps.open(changes.filePageURL(of: file, in: item)) }
            Button("Copy Path") { PullRequestDetailsPanel.copy(file.path) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows its changes")
        .accessibilityAddTraits(.isButton)
        .accessibilityFocused($isFocused)
        // Also as it's made, once the details scrolled to it.
        .onAppear { if isHighlighted { isFocused = true } }
        .onChange(of: isHighlighted) {
            if isHighlighted { isFocused = true }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.bounds(of: .scrollView).map { $0.intersects(CGRect(origin: .zero, size: proxy.size)) } ?? true
        } action: { isOnScreen = $0 }
        .task(id: Counting(isOnScreen: isOnScreen, visibilityChanges: code.visibilityChanges, version: version)) {
            if let countedVersion, countedVersion != version { files.stopCounting(countedVersion, of: pullRequest.key, by: viewer) }
            countedVersion = version
            guard isOnScreen, code.isVisible(page) else {
                files.stopCounting(version, of: pullRequest.key, by: viewer)
                return
            }
            // Not for a row scrolled past.
            try? await Task.sleep(for: .milliseconds(150))
            // Asked again every half minute while it shows, for a count that failed in a way that may pass, which the
            // store tries again then.
            while !Task.isCancelled {
                files.count(file, in: changes, of: pullRequest, by: viewer, on: page)
                try? await Task.sleep(for: .seconds(PullRequestCodeStore.retryInterval))
            }
        }
        .onDisappear { files.stopCounting(countedVersion ?? version, of: pullRequest.key, by: viewer) }
    }

    /// "PaymentsClient.cs, in src, edited, 12 lines added, 3 removed, 2 open comments".
    private var accessibilityLabel: String {
        var parts = [file.name, file.folder.map { "in \($0)" } ?? "at the top", file.what.lowercased()]
        switch files.counts(of: version, in: pullRequest.key) {
        case .success(let counts)?: parts.append(counts.spoken.lowercased())
        case .failure(.binary)?: parts.append("not text")
        case .failure(.tooLarge)?: parts.append("too long to show")
        default: break
        }
        if !comments.isEmpty { parts.append(comments.spoken.lowercased()) }
        return parts.joined(separator: ", ")
    }
}

/// How a file's change looks: a symbol and its color. Added green, deleted red, renamed blue, edited gray.
struct FileKindStyle {
    let symbol: String
    let color: Color

    init(_ kind: FileChange.Kind) {
        if kind.contains(.add) {
            (symbol, color) = ("plus.circle.fill", ItemState.done.textColor)
        } else if kind.contains(.delete) {
            (symbol, color) = ("minus.circle.fill", ItemState.failing.textColor)
        } else if kind.contains(.rename) {
            (symbol, color) = ("arrow.right.circle.fill", ItemState.running.textColor)
        } else {
            (symbol, color) = ("pencil.circle.fill", .secondary)
        }
    }
}

/// How many lines a file adds and removes, "+12 −3", in their colors, "~+12 −3" when that's only about right; or why it
/// can't say, such as a picture's "Binary"; a faint mark while it's counted.
struct FileCountsText: View {
    let counts: Result<LineCounts, ThreadExcerpt.Problem>?

    var body: some View {
        switch counts {
        case .success(let counts)?:
            HStack(spacing: 4) {
                if counts.isApproximate {
                    Text(verbatim: "~")
                        .foregroundStyle(.secondary)
                        .padding(.trailing, -2)
                }
                if counts.added > 0 {
                    Text(verbatim: "+\(counts.added)")
                        .foregroundStyle(ItemState.done.textColor)
                }
                if counts.removed > 0 {
                    Text(verbatim: "−\(counts.removed)")
                        .foregroundStyle(ItemState.failing.textColor)
                }
            }
            .font(size: 11.5, weight: .medium).monospacedDigit()
            .help(counts.isApproximate ? counts.spoken + ": it changed in more places than BriefBar lines up exactly" : counts.spoken)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(counts.spoken)
        case .failure(.binary)?:
            note("Binary", help: "It isn't text, so BriefBar doesn't compare it")
        case .failure(.tooLarge)?:
            note("Too long", help: "It's longer than BriefBar reads: 1 MB")
        case .failure(let problem)?:
            Image(systemName: "exclamationmark.triangle")
                .font(size: 10.5)
                .foregroundStyle(.tertiary)
                .help("BriefBar couldn't count its lines. " + (ThreadCode.sentence(for: problem) ?? problem.description))
        case nil:
            Capsule()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 30, height: 7)
                .help("Counting its lines")
        }
    }

    private func note(_ text: String, help: String) -> some View {
        Text(text)
            .font(size: 11)
            .foregroundStyle(.secondary)
            .help(help)
    }
}

/// How many comment threads are on a file: the open ones, in your color while one waits on you, or else the resolved ones,
/// quieter.
struct FileCommentsBadge: View {
    let comments: PullRequestPanel.FileComments

    var body: some View {
        let isOpen = comments.open > 0
        HStack(spacing: 3) {
            Image(systemName: isOpen ? "bubble.left.fill" : "checkmark.bubble")
                .font(size: 9.5, weight: .semibold)
            Text(verbatim: String(isOpen ? comments.open : comments.resolved))
                .font(size: 11, weight: .semibold).monospacedDigit()
        }
        .foregroundStyle(comments.waitingOnYou > 0 ? AnyShapeStyle(ItemState.needsYou.textColor) : AnyShapeStyle(.secondary))
        .help(comments.spoken)
    }
}

/// Opens a file of the pull request's change in its details, at one of its threads: from their comments, to see a thread
/// with the rest of its file's changes.
struct ChangedFileOpener {
    var open: @MainActor (_ path: String, _ thread: Int?) -> Void
}

private struct ChangedFileOpenerKey: EnvironmentKey {
    static var defaultValue: ChangedFileOpener? { nil }
}

extension EnvironmentValues {
    /// How the details around a view open a file of their pull request's change; nil outside them.
    var changedFileOpener: ChangedFileOpener? {
        get { self[ChangedFileOpenerKey.self] }
        set { self[ChangedFileOpenerKey.self] = newValue }
    }
}
