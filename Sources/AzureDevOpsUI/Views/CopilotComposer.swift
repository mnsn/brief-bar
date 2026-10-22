import AppKit
import AzureDevOpsCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// The window that sends a work item to Copilot: the prompt, which you can change, the model, and the repository the
/// change goes in. A window of its own, since popovers and widgets can't hold a sheet.
@MainActor
final class CopilotComposer: NSObject, NSWindowDelegate {
    static let shared = CopilotComposer()
    private var window: NSWindow?

    func show(item: TaskWorkItem, options: CopilotRunOptions, store: CopilotTasksStore) {
        let view = CopilotComposerView(item: item, options: options, template: store.settings.copilotPromptTemplate) { [weak self] in
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
    let item: TaskWorkItem
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

    /// - Parameter template: the prompt, with placeholders, from Settings.
    init(item: TaskWorkItem, options: CopilotRunOptions, template: String, close: @escaping () -> Void) {
        self.item = item
        self.close = close
        let filledIn = PromptTemplate.render(template, item: item)
        _prompt = LocalState(wrappedValue: filledIn)
        _filledIn = LocalState(wrappedValue: filledIn)
        _model = LocalState(wrappedValue: options.model)
        _effort = LocalState(wrappedValue: options.effort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Repository").foregroundStyle(.secondary)
                    repositoryRow
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
            Text("Send to Copilot")
                .font(.system(size: 20, weight: .bold))
            HStack(spacing: 6) {
                Text(verbatim: "\(item.type) \(item.id)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let entry = store.entries.first(where: { $0.workItem.matches(item.reference) }), entry.status.phase.isActive {
                Label("Copilot is already working on this work item.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var repositoryRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(store.knownRepositories, id: \.self) { url in
                    Button(url.lastPathComponent) { check(url) }
                }
                if !store.knownRepositories.isEmpty { Divider() }
                Button("Choose Folder…", action: chooseFolder)
            } label: {
                Label(repository?.name ?? "Choose a Repository", systemImage: "folder")
            }
            .fixedSize()
            if isChecking {
                ProgressView().controlSize(.small)
            } else if let repositoryProblem {
                Label(repositoryProblem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let repository {
                Text("\(UserPath.abbreviate(repository.root.path)), from origin/\(repository.baseBranch)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                    .help("Go back to the prompt in Settings")
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
            Text(store.canSend
                ? "Copilot works on its own on this Mac, in a new worktree, with your tools, MCP servers and instructions. It pushes a branch and opens a pull request, as you."
                : "The demo doesn't send anything.")
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

    private var canSend: Bool {
        store.canSend && repository != nil && !isChecking && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setUp() {
        guard !hasAppeared else { return }
        hasAppeared = true
        if let remembered = store.repository(for: item) ?? store.knownRepositories.first {
            check(remembered)
        }
    }

    /// Checks that a folder is in a git repository, and fills the base branch into a prompt you haven't changed.
    private func check(_ folder: URL) {
        isChecking = true
        repositoryProblem = nil
        Task {
            do {
                let found = try await store.git().repository(at: folder)
                repository = found
                if prompt == filledIn {
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
        panel.message = "Choose the repository that work item \(item.id)'s change goes in."
        if let current = repository?.root { panel.directoryURL = current.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        check(url)
    }

    private func send() {
        guard canSend, let repository else { return }
        store.send(item, prompt: prompt, options: CopilotRunOptions(model: model.trimmingCharacters(in: .whitespaces), effort: effort),
                   repository: repository.root)
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
