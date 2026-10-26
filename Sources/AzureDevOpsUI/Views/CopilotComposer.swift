import AppKit
import AzureDevOpsCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// The window that sends a work item, or a pull request's comments, build or conflicts, to Copilot: the prompt, which
/// you can change, the model, and the repository the change goes in, or the session it goes on with. A window of its own,
/// since popovers and widgets can't hold a sheet.
@MainActor
final class CopilotComposer: NSObject, NSWindowDelegate {
    static let shared = CopilotComposer()
    private var window: NSWindow?

    func show(item: TaskWorkItem, options: CopilotRunOptions, store: CopilotTasksStore) {
        show(subject: .workItem(item), prompt: nil, options: options, continuing: nil, store: store)
    }

    /// - Parameters:
    ///   - prompt: a pull request's, written for it; nil for a work item's, from the template in Settings.
    ///   - continuing: an earlier run whose session it goes on with, unless you choose a new one.
    ///   - handOff: what a pull request's prompt takes off Needs You once it's sent, as it was written.
    func show(
        subject: TaskSubject, prompt: String?, options: CopilotRunOptions, continuing: CopilotRun?, handOff: CommentHandOff? = nil,
        store: CopilotTasksStore
    ) {
        let view = CopilotComposerView(
            subject: subject, options: options, template: store.settings.copilotPromptTemplate, prompt: prompt, continuing: continuing,
            handOff: handOff
        ) { [weak self] in
            self?.window?.close()
        }
        .environmentObject(store)
        .environmentObject(store.settings)
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
        window.title = "Send to Copilot"
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { window = nil }
    }
}

struct CopilotComposerView: View {
    let subject: TaskSubject
    /// The run it can go on with.
    let continuing: CopilotRun?
    /// What the prompt takes off Needs You once it's sent: the comments it quoted when it was written, in the threads it
    /// still quotes when you send it.
    let handOff: CommentHandOff?
    let close: () -> Void

    @EnvironmentObject private var store: CopilotTasksStore
    @EnvironmentObject private var settings: AppSettings

    @LocalState private var prompt: String
    /// The prompt as it was last filled in, to tell whether you changed it.
    @LocalState private var filledIn: String
    @LocalState private var model: String
    @LocalState private var effort: String?
    @LocalState private var repository: GitRepository?
    @LocalState private var repositoryProblem: String?
    @LocalState private var isChecking = false
    @LocalState private var hasAppeared = false
    /// Goes on with the earlier run's session, in its worktree.
    @LocalState private var continueSession: Bool

    /// - Parameters:
    ///   - template: the prompt, with placeholders, from Settings, for a work item.
    ///   - prompt: a pull request's prompt, written for it.
    init(
        subject: TaskSubject, options: CopilotRunOptions, template: String, prompt: String? = nil, continuing: CopilotRun? = nil,
        handOff: CommentHandOff? = nil, close: @escaping () -> Void
    ) {
        self.subject = subject
        self.continuing = continuing
        self.handOff = handOff
        self.close = close
        let filledIn: String
        switch subject {
        case .workItem(let item): filledIn = prompt ?? PromptTemplate.render(template, item: item)
        case .pullRequest: filledIn = prompt ?? ""
        }
        _prompt = LocalState(wrappedValue: filledIn)
        _filledIn = LocalState(wrappedValue: filledIn)
        _model = LocalState(wrappedValue: options.model)
        _effort = LocalState(wrappedValue: options.effort)
        _continueSession = LocalState(wrappedValue: continuing != nil)
    }

    init(item: TaskWorkItem, options: CopilotRunOptions, template: String, close: @escaping () -> Void) {
        self.init(subject: .workItem(item), options: options, template: template, close: close)
    }

    private var workItem: TaskWorkItem? {
        if case .workItem(let item) = subject { return item }
        return nil
    }

    private var pullRequest: (TaskPullRequest, PullRequestAction)? {
        if case .pullRequest(let pullRequest, let action) = subject { return (pullRequest, action) }
        return nil
    }

    /// Push & Reply ships what an earlier run changed: only in its session, and its worktree.
    private var mustContinue: Bool { pullRequest?.1 == .pushAndReply }

    private var isContinuing: Bool { continuing != nil && (continueSession || mustContinue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if let continuing {
                    GridRow {
                        Text("Session").foregroundStyle(.secondary)
                        Picker("Session", selection: $continueSession) {
                            Text("Go On with Its Last Session").tag(true)
                            Text("Start a New One").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(mustContinue)
                        .help("Its last session goes on in its worktree, \(UserPath.abbreviate(continuing.worktree.path)), with what it changed")
                    }
                }
                if let (pullRequest, _) = pullRequest {
                    GridRow {
                        Text("Repository").foregroundStyle(.secondary)
                        Text("\(pullRequest.organization) / \(pullRequest.project) / \(pullRequest.repository)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if !isContinuing {
                    GridRow {
                        Text(pullRequest == nil ? "Repository" : "Local Clone").foregroundStyle(.secondary)
                        repositoryRow
                    }
                }
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        CopilotModelMenu(model: $model)
                        CopilotEffortPicker(effort: $effort)
                    }
                }
            }
            promptEditor
            footer
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: setUp)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pullRequest.map { "\($0.1.title) with Copilot" } ?? "Send to Copilot")
                .font(.system(size: 20, weight: .bold))
            HStack(spacing: 6) {
                Text(verbatim: workItem.map { "\($0.type) \($0.id)" } ?? pullRequest.map { "!\($0.0.id)" } ?? "")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(workItem?.title ?? pullRequest?.0.title ?? "")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if isBusy {
                Label("Copilot is already working on this \(workItem != nil ? "work item" : "pull request").", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Copilot works on it already.
    private var isBusy: Bool {
        if let workItem {
            return store.entries.first { $0.workItem?.matches(workItem.reference) == true }?.status.phase.isActive == true
        }
        if let (pullRequest, _) = self.pullRequest {
            return store.latest(forPullRequest: PRKey(pullRequest.organization, pullRequest.id))?.status.phase.isActive == true
        }
        return false
    }

    private var repositoryRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(store.knownRepositories, id: \.self) { url in
                    Button(url.lastPathComponent) { check(url) }
                }
                if !store.knownRepositories.isEmpty { Divider() }
                Button(pullRequest == nil ? "Choose Folder…" : "Choose Local Clone…", action: chooseFolder)
            } label: {
                Label(repository?.name ?? (pullRequest == nil ? "Choose a Repository" : "Choose Local Clone…"), systemImage: "folder")
            }
            .fixedSize()
            .disabled(isChecking || !store.canSend || !store.isOn)
            if isChecking {
                ProgressView().controlSize(.small)
            } else if let repositoryProblem {
                Label(repositoryProblem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let repository {
                Text("\(UserPath.abbreviate(repository.root.path)), from origin/\(pullRequest?.0.sourceBranch ?? repository.baseBranch)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if pullRequest != nil {
                Text("Choose its folder on this Mac once. BriefBar will remember it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prompt").font(.headline)
                Spacer()
                Button("Reset") { prompt = filledIn }
                    .buttonStyle(.borderless)
                    .disabled(prompt == filledIn)
                    .help(workItem != nil ? "Go back to the prompt in Settings" : "Go back to the prompt BriefBar wrote")
            }
            TextEditor(text: $prompt)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 250)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text(store.canSend ? footnote : "The demo doesn't send anything.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
            Button("Send", action: send)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSend)
        }
    }

    /// What Copilot does, on its own, as you.
    private var footnote: String {
        let place = isContinuing ? "in the same session and worktree as before" : "in a new worktree"
        switch pullRequest?.1 {
        case nil:
            return "Copilot works on its own on this Mac, in a new worktree, with your tools, MCP servers and instructions. It pushes a branch and opens a pull request, as you."
        case .pushAndReply?:
            return "Copilot works on its own on this Mac, \(place), with your tools, MCP servers and instructions. It commits, pushes the pull request's branch, and replies on its threads, as you."
        case .review?:
            return "Copilot works on its own on this Mac, \(place), at the pull request's latest commit, with your tools, MCP servers and instructions. It changes nothing, and posts nothing."
        case .some:
            return "Copilot works on its own on this Mac, \(place), at the pull request's latest commit, with your tools, MCP servers and instructions. It doesn't push or reply: check its changes, then choose Push & Reply."
        }
    }

    private var canSend: Bool {
        store.canSend && store.isOn && !isBusy && (repository != nil || isContinuing) && (!mustContinue || isContinuing)
            && !isChecking && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setUp() {
        guard !hasAppeared, store.canSend, store.isOn else { return }
        hasAppeared = true
        switch subject {
        case .workItem(let item):
            if let folder = store.repository(for: item) ?? store.knownRepositories.first { check(folder) }
        case .pullRequest(let pullRequest, _):
            if let continuing {
                check(continuing.repository)
            } else {
                isChecking = true
                Task {
                    do {
                        repository = try await store.repository(for: pullRequest, using: store.git())
                    } catch {
                        repositoryProblem = String(describing: error)
                    }
                    isChecking = false
                }
            }
        }
    }

    /// Checks that a folder is in a git repository, and fills the base branch into a prompt you haven't changed.
    private func check(_ folder: URL) {
        guard store.canSend, store.isOn, !isChecking else { return }
        isChecking = true
        repositoryProblem = nil
        Task {
            do {
                let git = await store.git()
                let found: GitRepository
                if let (pullRequest, _) = pullRequest {
                    found = try await store.checkRepository(at: folder, for: pullRequest, using: git)
                } else {
                    found = try await git.repository(at: folder)
                }
                repository = found
                if prompt == filledIn, let item = workItem {
                    filledIn = PromptTemplate.render(settings.copilotPromptTemplate, item: item, baseBranch: found.baseBranch)
                    prompt = filledIn
                }
            } catch {
                repository = nil
                repositoryProblem = String(describing: error)
            }
            isChecking = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = workItem.map { "Choose the repository that work item \($0.id)'s change goes in." }
            ?? pullRequest.map {
                "Choose your local clone of \($0.0.organization)/\($0.0.project)/\($0.0.repository). BriefBar will remember it for this repository's pull requests."
            } ?? ""
        if let current = repository?.root { panel.directoryURL = current.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        check(url)
    }

    private func send() {
        let continuing = isContinuing ? self.continuing : nil
        guard canSend, let folder = continuing?.repository ?? repository?.root else { return }
        store.send(subject, prompt: prompt, options: CopilotRunOptions(model: model.trimmingCharacters(in: .whitespaces), effort: effort),
                   repository: folder, continuing: continuing, handOff: handOff)
        close()
    }
}

/// The model: one of the suggestions, or any other your plan offers, by its ID.
struct CopilotModelMenu: View {
    @Binding var model: String

    var body: some View {
        Menu {
            ForEach(CopilotModel.suggestions) { choice in
                Button {
                    model = choice.id
                } label: {
                    if choice.id == model {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
            if !model.isEmpty, !CopilotModel.suggestions.contains(where: { $0.id == model }) {
                Divider()
                Button {} label: { Label(model, systemImage: "checkmark") }
            }
            Divider()
            Button("Other Model…") {
                if let other = Self.askForModel(current: model) { model = other }
            }
        } label: {
            Text(model.isEmpty ? "Choose a Model" : CopilotModel.name(of: model))
        }
        .fixedSize()
    }

    private static func askForModel(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Use Another Model"
        alert.informativeText = "Enter the model's ID, as the Copilot CLI's /model command lists it, such as gpt-6-luna."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let model = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }
}

/// How hard the model thinks; Default leaves it to the model.
struct CopilotEffortPicker: View {
    @Binding var effort: String?

    var body: some View {
        Picker("Effort", selection: $effort) {
            Text("Default Effort").tag(String?.none)
            ForEach(CopilotModel.efforts, id: \.self) { effort in
                Text(CopilotModel.effortName(effort)).tag(Optional(effort))
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Reasoning effort: how hard the model thinks. Not every model takes every one.")
    }
}
