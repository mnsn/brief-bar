import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// A work item's details, beside the sprint: what it is and where it stands, what it's about, its tasks and the work items
/// it links to, its attachments and its discussion, read from Azure DevOps when you open it. Open in Azure DevOps opens it
/// there, to change it.
struct WorkItemDetailsPanel: View {
    @EnvironmentObject private var details: WorkItemDetailsStore
    @EnvironmentObject private var sprint: SprintStore
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        if let item = details.selected {
            VStack(spacing: 0) {
                topBar(item)
                Divider()
                    .opacity(0.6)
                ScrollView {
                    content(item)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                // Each work item from the top.
                .id(item.key)
            }
            .onAppear { details.refreshIfStale() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Details of \(item.type) \(item.id)")
        }
    }

    private var me: String { sprint.board?.me ?? "" }

    // MARK: Top

    private func topBar(_ item: WorkItem) -> some View {
        HStack(spacing: 8) {
            if let previous = details.history.last {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { details.back() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Back to \(previous.type) \(previous.id): \(previous.title)")
                .accessibilityLabel("Back")
            }
            TypeBadge(item: item, size: 20)
            Text(item.type + " " + String(item.id))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            if details.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 22, height: 22)
                    .help("Reading it from Azure DevOps")
            } else if details.mode == .live {
                Button {
                    details.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Read it again")
            }
            Menu {
                menuItems(item)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            Button {
                withAnimation(.easeOut(duration: 0.2)) { details.close() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .accessibilityLabel("Close Details")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 44)
    }

    @ViewBuilder
    private func menuItems(_ item: WorkItem) -> some View {
        Button("Open in Azure DevOps") { details.openInAzureDevOps() }
        Button("Copy Link") { Self.copy(item.webURL.absoluteString) }
        Button("Copy ID and Title") { Self.copy("\(item.id) \(item.title)") }
        if copilot.isOn {
            Divider()
            CopilotSendMenuItems(item: item)
        }
        LinkMenuItems(item.linkRef)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ item: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(item)
            if let read = details.details {
                if let failure = details.failure {
                    Label("Couldn't read it again: \(WorkItemDetailsStore.message(for: failure))", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                properties(item, read)
                texts(read)
                children(read)
                related(read)
                resources(read)
                discussion(read)
                footer(item, read)
            } else if let failure = details.failure {
                FailureView(error: failure)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading its details…")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
        }
    }

    private func heading(_ item: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title)
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            FlowLayout(spacing: 6) {
                Chip(text: item.state, color: item.stateColor, symbol: item.stateSymbol)
                if let reason = details.details?.reason, reason.caseInsensitiveCompare(item.state) != .orderedSame {
                    Text(reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                WorkItemLinks(item: item)
            }
            actions(item)
        }
    }

    private func actions(_ item: WorkItem) -> some View {
        ViewThatFits(in: .horizontal) {
            actionButtons(item, compact: false)
            actionButtons(item, compact: true)
        }
    }

    private func actionButtons(_ item: WorkItem, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                details.openInAzureDevOps()
            } label: {
                Label("Open in Azure DevOps", systemImage: "arrow.up.forward.app")
            }
            .glassButtonStyle()
            .help("Open it in Azure DevOps, to change it there")
            if copilot.isOn {
                if let entry = copilot.latest(for: item) {
                    CopilotRunBadge(entry: entry)
                } else {
                    Button {
                        copilot.compose(item)
                    } label: {
                        if compact {
                            Image(systemName: "paperplane")
                        } else {
                            Label("Send to Copilot…", systemImage: "paperplane")
                        }
                    }
                    .glassButtonStyle()
                    .help("Send to Copilot…")
                    .accessibilityLabel("Send to Copilot")
                }
            }
        }
        .controlSize(.small)
        .fixedSize()
    }

    // MARK: Fields

    private func properties(_ item: WorkItem, _ read: WorkItemDetails) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 9) {
            property("Assigned To") {
                HStack(spacing: 6) {
                    Avatar(name: item.assignedTo?.name, size: 18, isMe: item.isAssigned(to: me))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(item.assignedTo?.name ?? "Unassigned")
                        .foregroundStyle(item.assignedTo == nil ? .secondary : .primary)
                }
            }
            if let parent = read.parent {
                property("Parent") {
                    LinkedItemRow(link: parent, item: shown(parent), project: item.project, me: me, compact: true) { follow($0) }
                        .padding(.horizontal, -6)
                }
            }
            if let size = read.size {
                property(read.sizeTitle ?? "Size") { Text(Self.number(size)) }
            }
            if let work = workText(item, read) {
                property("Work") { Text(work) }
            }
            if let priority = read.priority {
                property("Priority") { Text(String(priority)) }
            }
            if let severity = read.severity {
                property("Severity") { Text(severity) }
            }
            if let activity = read.activity {
                property("Activity") { Text(activity) }
            }
            if let area = read.areaPath {
                property("Area") {
                    Text(Self.path(area))
                        .help(area)
                }
            }
            if let iteration = read.iterationPath {
                property("Iteration") {
                    Text(Self.lastPart(of: iteration))
                        .help(iteration)
                }
            }
            if !read.item.tags.isEmpty {
                property("Tags") {
                    FlowLayout(spacing: 5) {
                        ForEach(Array(read.item.tags.enumerated()), id: \.offset) { _, tag in
                            Chip(text: tag, color: .secondary)
                        }
                    }
                }
            }
        }
        .font(.system(size: 12.5))
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCard(cornerRadius: 12, raised: true))
    }

    private func property<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
                .lineLimit(1)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "3 h left · 5 h estimated · 2 h done", for what tracks hours.
    private func workText(_ item: WorkItem, _ read: WorkItemDetails) -> String? {
        var parts: [String] = []
        if let remaining = item.remainingWork, !item.isDone { parts.append("\(Hours.text(remaining)) left") }
        if let estimate = read.originalEstimate, estimate > 0 { parts.append("\(Hours.text(estimate)) estimated") }
        if let completed = read.completedWork, completed > 0 { parts.append("\(Hours.text(completed)) done") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Text

    @ViewBuilder
    private func texts(_ read: WorkItemDetails) -> some View {
        if read.texts.isEmpty {
            section("Description") {
                Text("No description")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            }
        } else {
            ForEach(read.texts) { field in
                section(field.title) {
                    RichTextView(text: field.text)
                }
            }
        }
    }

    // MARK: Links

    @ViewBuilder
    private func children(_ read: WorkItemDetails) -> some View {
        let links = read.children
        if !links.isEmpty {
            let readable = links.compactMap(shown)
            let ordered = SprintBoard.Row(parent: nil, tasks: readable).tasksInWorkOrder
            let byId = Dictionary(links.map { ($0.workItemId, $0) }, uniquingKeysWith: { first, _ in first })
            let unreadable = links.filter { shown($0) == nil }
            let allTasks = readable.allSatisfy { $0.type.caseInsensitiveCompare("Task") == .orderedSame }
            section(allTasks && unreadable.isEmpty ? "Tasks" : "Child Work Items", count: links.count) {
                if !readable.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        SegmentedProgress(
                            done: readable.filter { $0.category.column == .done }.count,
                            inProgress: readable.filter { $0.category.column == .inProgress }.count,
                            toDo: readable.filter { ($0.category.column ?? .toDo) == .toDo }.count
                        )
                        let done = readable.filter(\.isDone).count
                        Text("\(done) of \(readable.count) done")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 2)
                }
                VStack(spacing: 1) {
                    ForEach(ordered) { child in
                        if let link = byId[child.id] {
                            LinkedItemRow(link: link, item: child, project: details.selected?.project ?? "", me: me) { follow($0) }
                        }
                    }
                    ForEach(unreadable) { link in
                        LinkedItemRow(link: link, item: nil, project: details.selected?.project ?? "", me: me) { follow($0) }
                    }
                }
                .padding(.horizontal, -6)
            }
        }
    }

    @ViewBuilder
    private func related(_ read: WorkItemDetails) -> some View {
        let links = read.otherLinks
        if !links.isEmpty {
            section("Related Work", count: links.count) {
                VStack(spacing: 1) {
                    ForEach(links) { link in
                        LinkedItemRow(
                            link: link, item: shown(link), project: details.selected?.project ?? "", me: me, showsLinkName: true
                        ) { follow($0) }
                    }
                }
                .padding(.horizontal, -6)
            }
        }
    }

    /// A linked work item: the newest of what the sprint knows of it and what was read with the details.
    private func shown(_ link: WorkItemDetails.Link) -> WorkItem? {
        details.linked(link)
    }

    private func follow(_ item: WorkItem) {
        withAnimation(.easeOut(duration: 0.15)) { details.follow(item) }
    }

    @ViewBuilder
    private func resources(_ read: WorkItemDetails) -> some View {
        if !read.resources.isEmpty {
            let attachments = read.resources.filter { $0.kind == .attachment }.count
            section(attachments == read.resources.count ? "Attachments" : attachments == 0 ? "Links" : "Attachments and Links",
                    count: read.resources.count) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(read.resources) { resource in
                        Link(destination: resource.url) {
                            Label(resource.name, systemImage: resource.kind == .attachment ? "paperclip" : "link")
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .help("Open \(resource.kind == .attachment ? "the file" : "the page") in your browser")
                        .contextMenu {
                            Button("Copy Link") { Self.copy(resource.url.absoluteString) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Discussion

    private func discussion(_ read: WorkItemDetails) -> some View {
        section("Discussion", count: read.commentCount > 0 ? read.commentCount : nil) {
            if let problem = read.commentsProblem {
                Label("Couldn't read its comments. \(problem)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if read.comments.isEmpty {
                Text("No comments yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(read.comments) { comment in
                        CommentView(comment: comment, now: store.now, isMine: comment.author.map { !me.isEmpty && $0.id == me } ?? false)
                    }
                    if read.commentCount > read.comments.count {
                        Button("See all \(read.commentCount) comments in Azure DevOps") { details.openInAzureDevOps() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11.5))
                    }
                }
            }
        }
    }

    private func footer(_ item: WorkItem, _ read: WorkItemDetails) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let created = read.createdAt {
                Text("Created \(Self.day(created, now: store.now))" + (read.createdBy.map { " by \($0.name)" } ?? ""))
                    .help(created.formatted(date: .complete, time: .shortened))
            }
            if let changed = item.changedAt {
                Text("Updated \(Self.ago(changed, now: store.now))" + (read.changedBy.map { " by \($0.name)" } ?? ""))
                    .help(changed.formatted(date: .complete, time: .shortened))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, count: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let count {
                    Text(String(count))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "5", "2.5", whatever the value.
    static func number(_ value: Double) -> String {
        Int(exactly: value).map(String.init) ?? String(format: "%.1f", value)
    }

    /// "Storefront › Checkout", from `Storefront\Checkout`.
    static func path(_ path: String) -> String {
        path.split(separator: "\\").joined(separator: " › ")
    }

    static func lastPart(of path: String) -> String {
        path.split(separator: "\\").last.map(String.init) ?? path
    }

    /// "Oct 12", or "Oct 12, 2025" in another year.
    static func day(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    /// "just now", "5m ago".
    static func ago(_ date: Date, now: Date) -> String {
        let elapsed = Elapsed.short(since: date, now: now)
        return elapsed == "now" ? "just now" : "\(elapsed) ago"
    }
}

/// Why a work item's details couldn't be read, and what to do about it.
private struct FailureView: View {
    let error: ADOError

    @EnvironmentObject private var details: WorkItemDetailsStore
    @EnvironmentObject private var store: PRStore

    var body: some View {
        let problem = PulseProblem.from(error)
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(problem.needsSignIn
                     ? (problem == .cliNotFound ? "BriefBar reads Azure DevOps with the Azure CLI, which isn't installed."
                        : "Sign in to the Azure CLI to read this work item.")
                     : WorkItemDetailsStore.message(for: error))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: problem.needsSignIn ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.system(size: 12))
            HStack(spacing: 8) {
                if problem.needsSignIn {
                    Button(problem == .cliNotFound ? "Install the Azure CLI…" : "Sign In…") { store.signIn() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Try Again") { details.reload() }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
    }
}

/// A work item the details link to: where it stands, what it is, the hours left and who has it. A click shows its details.
private struct LinkedItemRow: View {
    let link: WorkItemDetails.Link
    /// What it is, when it could be read.
    let item: WorkItem?
    /// The project of the work item that links to it: one that can't be read opens through it.
    let project: String
    let me: String
    var compact = false
    var showsLinkName = false
    let open: (WorkItem) -> Void

    @EnvironmentObject private var details: WorkItemDetailsStore
    @LocalState private var isHovered = false

    /// What opens: what was read, or just its ID when it couldn't be.
    private var target: WorkItem {
        item ?? WorkItem(
            id: link.workItemId, organization: details.selected?.organization ?? "", project: project, type: "Work Item",
            title: "Work item \(link.workItemId)", state: "", category: .proposed
        )
    }

    var body: some View {
        Button {
            open(target)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item?.stateSymbol ?? "circle.dashed")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(item?.stateColor ?? .secondary)
                    .frame(width: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                if let item, item.type.caseInsensitiveCompare("Task") != .orderedSame {
                    Image(systemName: item.typeSymbol)
                        .font(.system(size: 10))
                        .foregroundStyle(item.typeColor)
                        .help(item.type)
                }
                Text(item?.title ?? "Work item \(link.workItemId)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(item == nil || item?.isDone == true ? .secondary : .primary)
                    .strikethrough(item?.isDone == true && !compact, color: .secondary.opacity(0.6))
                    .multilineTextAlignment(.leading)
                    .lineLimit(compact ? 1 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsLinkName {
                    Text(link.name)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if !compact, let remaining = item?.remainingText {
                    Text(remaining)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !compact, let item {
                    Avatar(name: item.assignedTo?.name, size: 16, isMe: item.isAssigned(to: me))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .contextMenu {
            Button("Show Details") { open(target) }
            Button("Open in Azure DevOps") { AzureDevOps.open(target.webURL) }
        }
        .accessibilityLabel(item.map { "\($0.type) \($0.id): \($0.title), \($0.state)" } ?? "Work item \(link.workItemId)")
    }

    private var help: String {
        guard let item else { return "Work item \(link.workItemId)\nClick to see its details" }
        return "\(item.type) \(item.id): \(item.title)\n\(item.state) · \(item.assignedTo?.name ?? "Unassigned")\nClick to see its details"
    }
}

/// One of a work item's comments: who wrote it and when, and what they wrote.
private struct CommentView: View {
    let comment: WorkItemDetails.Comment
    let now: Date
    let isMine: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Avatar(name: comment.author?.name, size: 22, isMe: isMine)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(comment.author?.name ?? "Someone")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let created = comment.createdAt {
                        Text(WorkItemDetailsPanel.ago(created, now: now) + (comment.isEdited ? " · edited" : ""))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(created.formatted(date: .complete, time: .shortened))
                    }
                }
                RichTextView(text: comment.text)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// Views side by side, on as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + lineHeight))
    }
}
