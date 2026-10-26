import AppKit
import BriefBarCore
import SwiftUI

/// The links on a thing's row: a capsule for its work items, one for its pull requests and one for its Copilot sessions,
/// each in the color of the one that needs you most, with a sessions' state in a word when there's one. Nothing while Show
/// Links is off, or it has no links.
package struct LinkCapsules: View {
    private let ref: ItemRef
    private let excluding: Set<ItemRef>
    private let opensMenu: Bool

    @EnvironmentObject private var services: AppServices

    /// - Parameters:
    ///   - excluding: what the row shows already, such as the task Copilot is doing on it.
    ///   - opensMenu: a click opens the links' menu: only where the row itself isn't a button, which would take the click.
    package init(_ ref: ItemRef, excluding: Set<ItemRef> = [], opensMenu: Bool = false) {
        self.ref = ref
        self.excluding = excluding
        self.opensMenu = opensMenu
    }

    package var body: some View {
        Capsules(ref: ref, excluding: excluding, opensMenu: opensMenu, links: services.links)
    }

    private struct Capsules: View {
        let ref: ItemRef
        let excluding: Set<ItemRef>
        let opensMenu: Bool
        @ObservedObject var links: Links

        var body: some View {
            let shown = links.connections(of: ref).filter { !excluding.contains($0.item.ref) }
            if !shown.isEmpty {
                let groups = Dictionary(grouping: shown, by: \.item.ref.kind.family).sorted { $0.key < $1.key }.map(\.value)
                HStack(spacing: 4) {
                    ForEach(groups, id: \.first?.id) { group in
                        if opensMenu {
                            Menu {
                                LinksMenuContent(ref: ref, links: links)
                            } label: {
                                LinkCapsule(connections: group)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        } else {
                            LinkCapsule(connections: group)
                        }
                    }
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// One kind of link, as a capsule: its symbol, then the one linked thing's number, or how many there are; a session's
/// state in a word.
struct LinkCapsule: View {
    let connections: [LinkConnection]

    var body: some View {
        let first = connections[0].item
        HStack(spacing: 3) {
            Image(systemName: first.ref.kind == .session ? "waveform.path.ecg" : first.symbol)
            if connections.count > 1 {
                Text("\(connections.count)").monospacedDigit()
            } else if first.ref.kind == .session {
                if let word = first.stateWord { Text(word) }
            } else {
                Text(first.label).monospacedDigit()
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(first.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(first.color.opacity(0.14)))
        .contentShape(Capsule())
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }

    private var help: String {
        connections.map { connection in
            var line = connection.item.menuTitle
            if let status = connection.item.status { line += " — \(status)" }
            return line + " (\(connection.reason))"
        }
        .joined(separator: "\n")
    }
}

/// A thing's links in its context menu: linking it to more, and its links, to open, unlink, or show again once hidden.
/// Nothing while Show Links is off.
package struct LinkMenuItems: View {
    private let ref: ItemRef

    @EnvironmentObject private var services: AppServices

    package init(_ ref: ItemRef) {
        self.ref = ref
    }

    package var body: some View {
        Items(ref: ref, links: services.links)
    }

    private struct Items: View {
        let ref: ItemRef
        @ObservedObject var links: Links

        var body: some View {
            if links.isOn {
                Divider()
                Button(LinkPickerView.buttonTitle(for: ref.kind)) { links.pick(for: ref) }
                if !links.connections(of: ref, includingHidden: true).isEmpty {
                    Menu("Links") {
                        LinksMenuContent(ref: ref, links: links)
                    }
                }
            }
        }
    }
}

/// A thing's links, each to open (or its own menu), then Link…, Unlink and Show Hidden Links.
struct LinksMenuContent: View {
    let ref: ItemRef
    @ObservedObject var links: Links

    var body: some View {
        let all = links.connections(of: ref, includingHidden: true)
        let shown = all.filter { !$0.isHidden }
        let hidden = all.filter(\.isHidden)
        ForEach(shown) { connection in
            let title = Self.title(connection)
            if let menu = connection.item.menu {
                Menu(title) { menu() }
            } else {
                Button(title) { connection.item.open?() }
                    .disabled(connection.item.open == nil)
            }
        }
        if !shown.isEmpty { Divider() }
        Button(LinkPickerView.buttonTitle(for: ref.kind)) { links.pick(for: ref) }
        if !shown.isEmpty {
            Menu("Unlink") {
                ForEach(shown) { connection in
                    Button(connection.isKnownElsewhere ? "\(connection.item.menuTitle) (Hide Here)" : connection.item.menuTitle) {
                        links.unlink(ref, connection.item.ref)
                    }
                }
            }
        }
        if !hidden.isEmpty {
            Menu("Show Hidden Links") {
                ForEach(hidden) { connection in
                    Button(connection.item.menuTitle) { links.showAgain(ref, connection.item.ref) }
                }
            }
        }
    }

    /// "Work Item 5101 · Save items for later — Active".
    static func title(_ connection: LinkConnection) -> String {
        var title = connection.item.menuTitle
        if let status = connection.item.status { title += " — \(status)" }
        if let via = connection.via { title += " (through \(via.label))" }
        return title
    }
}

// MARK: - The picker

/// The window that links a thing to others: what it's linked to, what likely goes with it, and everything else the
/// sources list, to check or uncheck; or a link you paste. A window of its own, since popovers and widgets can't hold a
/// sheet.
@MainActor
final class LinkPicker: NSObject, NSWindowDelegate {
    static let shared = LinkPicker()
    private var window: NSWindow?

    func show(for ref: ItemRef, links: Links) {
        let view = LinkPickerView(subject: ref, links: links) { [weak self] in
            self?.window?.close()
        }
        let host = NSHostingController(rootView: AnyView(view))
        host.sizingOptions = [.preferredContentSize]
        let window = window ?? {
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            return window
        }()
        window.contentViewController = host
        window.title = "Links"
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { window = nil }
    }
}

package struct LinkPickerView: View {
    let subject: ItemRef
    @ObservedObject var links: Links
    let close: () -> Void

    @LocalState private var search = ""

    package init(subject: ItemRef, links: Links, close: @escaping () -> Void) {
        self.subject = subject
        self.links = links
        self.close = close
    }

    /// "Link Work Items or Sessions…", for the kinds a thing links to.
    static func buttonTitle(for kind: ItemRef.Kind) -> String {
        switch kind {
        case .workItem: return "Link Pull Requests or Sessions…"
        case .pullRequest: return "Link Work Items or Sessions…"
        case .gitHubPullRequest: return "Link Work Items or Sessions…"
        case .session: return "Link Work Items or Pull Requests…"
        }
    }

    package var body: some View {
        let item = links.describe(subject)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(item.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text("Links you add or take away here stay in BriefBar. Azure DevOps, GitHub and Copilot don't see them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("Search, or paste a link", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    sections
                }
                .padding(.vertical, 2)
            }
            .frame(height: 340)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    @ViewBuilder
    private var sections: some View {
        let candidates = links.candidates(for: subject)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let pasted = ItemRef.from(link: query).flatMap { ItemRef.canLink(subject, $0) ? $0 : nil }
        if let pasted {
            section("From the Link", [links.describe(pasted)])
        } else if query.isEmpty {
            let linked = links.connections(of: subject).map(\.item)
            let linkedRefs = Set(linked.map(\.ref))
            let suggested = links.suggestions(for: subject, among: candidates)
                .compactMap { ref in candidates.first { $0.ref == ref } }
            let rest = candidates.filter { !linkedRefs.contains($0.ref) && !suggested.map(\.ref).contains($0.ref) }
            section("Linked", linked)
            section("Suggested", suggested)
            ForEach([0, 1, 2], id: \.self) { family in
                let items = rest.filter { $0.ref.kind.family == family }
                if let kind = items.first?.ref.kind {
                    section(kind.plural.prefix(1).uppercased() + kind.plural.dropFirst(), items)
                }
            }
            if candidates.isEmpty && linked.isEmpty {
                Text("Nothing to link yet: turn on the sources whose things you want to link.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        } else {
            let found = candidates.filter { Self.matches($0, query) }
            section("Found", found)
            if found.isEmpty {
                Text("Nothing matches. Paste a link to a pull request, a work item or a Copilot session to link it.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [LinkedItem]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            ForEach(items, id: \.ref) { item in
                LinkPickerRow(item: item, isLinked: links.isLinked(subject, item.ref)) {
                    if links.isLinked(subject, item.ref) {
                        links.unlink(subject, item.ref)
                    } else {
                        links.link(subject, item.ref)
                    }
                }
            }
        }
    }

    static func matches(_ item: LinkedItem, _ query: String) -> Bool {
        let text = [item.label, item.title, item.place, item.status, item.hint?.branch].compactMap { $0 }.joined(separator: " ")
        return query.split(separator: " ").allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }
}

/// One thing in the picker: checked when it's linked; a click links or unlinks it.
private struct LinkPickerRow: View {
    let item: LinkedItem
    let isLinked: Bool
    let toggle: () -> Void

    @LocalState private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 9) {
                Image(systemName: isLinked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isLinked ? Color.accentColor : .secondary)
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(item.color)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label == item.title ? item.title : "\(item.label)  \(item.title)")
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    let detail = [item.place, item.status].compactMap { $0 }.joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isHovered ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(item.menuTitle)
        .accessibilityValue(isLinked ? "Linked" : "Not linked")
    }
}

// MARK: - The setting

/// Show Links, off by default: in Settings, with what it does and reads.
package struct LinksSetting: View {
    @ObservedObject private var links: Links

    package init(links: Links) {
        self.links = links
    }

    package static let title = "Show Links"
    package static let explanation = """
        Shows which work items, pull requests and Copilot sessions go together, on their rows: the work items linked to \
        your pull requests in Azure DevOps and the pull requests linked to the sprint's work items, the work item or pull \
        request a Copilot session started from or the pull request it opened, a session on a pull request's branch, and \
        the links you add. Right-click a row to link it to more, or to unlink. What you add or take away stays in \
        BriefBar: Azure DevOps, GitHub and Copilot don't see it. For this, Azure DevOps reads the links of your pull \
        requests and of the sprint's work items, and Copilot reads which pull request each session started from or opened.
        """

    package var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(Self.title, isOn: Binding(get: { links.isOn }, set: { links.setOn($0) }))
            Text(Self.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
