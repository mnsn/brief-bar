import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

/// BriefBar's Settings window: General, where sections show, then a page for each source.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show(_ destination: SettingsDestination) {
        navigation.destination = destination
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model, navigation: navigation)
                .environmentObject(model.services)
                .environmentObject(model.services.loginItem))
            let window = NSWindow(contentViewController: host)
            window.title = "BriefBar Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("BriefBarSettings")
            if !window.setFrameUsingName("BriefBarSettings") {
                window.center()
            }
            self.window = window
        }
        model.services.loginItem.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var destination: SettingsDestination? = .general
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $navigation.destination) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsDestination.general)
                ForEach(Surface.allCases, id: \.self) { surface in
                    Label(surface.title, systemImage: surface.symbol)
                        .tag(SettingsDestination.layout(surface))
                }
                Section("Sources") {
                    ForEach(model.sources.map(\.id), id: \.self) { id in
                        if let source = model.source(id) {
                            SidebarSourceRow(name: source.name, symbol: source.symbol, state: model.state(of: id))
                                .tag(SettingsDestination.source(id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            ScrollView {
                detail
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 740, height: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.destination ?? .general {
        case .general:
            GeneralPage(model: model) { navigation.destination = $0 }
        case .source(let id):
            if let source = model.source(id) {
                SourcePage(model: model, source: source)
                    .id(id)
            }
        case .layout(let surface):
            LayoutPage(model: model, surface: surface)
                .id(surface)
        }
    }
}

struct SidebarSourceRow: View {
    let name: String
    let symbol: String
    let state: SourceState

    var body: some View {
        HStack {
            Label(name, systemImage: symbol)
            Spacer()
            switch state {
            case .on:
                Text("On")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .needsReview:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help("Waiting for you to look at what it reads now")
            case .off:
                EmptyView()
            }
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var loginItem: LoginItem
    var go: (SettingsDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppIconView(isBundled: AppIdentity.isBundled, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BriefBar")
                        .font(.title.weight(.semibold))
                    Text("What needs you, from the apps you choose, in the menu bar")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Every source is off until you turn it on. Each one first says what it reads, where it connects and what it needs, and turning it on is your consent: macOS asks for some permissions only once for all of BriefBar, and BriefBar never turns a source on by itself.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { Divider() }
                    SourceSummaryRow(source: source, state: model.state(of: source.id)) {
                        go(.source(source.id))
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if loginItem.isAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Launch BriefBar at Login", isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    ))
                    if loginItem.needsApproval {
                        Button("Allow in Login Items Settings…") { loginItem.openSystemSettings() }
                    } else if let error = loginItem.lastError {
                        Text("Launch at Login failed: \(error)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            UpdateSettings(updates: model.services.updates)

            HStack {
                Text("Version \(AppIdentity.version)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit BriefBar") { NSApp.terminate(nil) }
            }
        }
    }
}

/// Whether BriefBar checks for updates by itself, and a way to check now, when it updates itself.
struct UpdateSettings: View {
    @ObservedObject var updates: UpdateStatus

    var body: some View {
        if updates.isAvailable {
            HStack {
                Toggle("Check for Updates Automatically", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.setAutomaticallyChecks($0) }
                ))
                Spacer()
                Button("Check for Updates…") { updates.check() }
                    .disabled(!updates.canCheck)
            }
        }
    }
}

struct SourceSummaryRow: View {
    let source: any BriefBarSource
    let state: SourceState
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.symbol)
                .font(.title2)
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.headline)
                Text(source.description.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .on:
                Label("On", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Settings…", action: open)
            case .needsReview:
                Label("Paused", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Button("Review…", action: open)
            case .off:
                Button("Turn On…", action: open)
            }
        }
    }
}

// MARK: - A source

struct SourcePage: View {
    @ObservedObject var model: AppModel
    let source: any BriefBarSource

    @LocalState private var confirmingTurnOff = false
    @LocalState private var offeringToRemoveAccess = false

    private var state: SourceState { model.state(of: source.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: source.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name)
                        .font(.title2.weight(.semibold))
                    Text(source.description.summary)
                        .foregroundStyle(.secondary)
                }
            }

            switch state {
            case .off:
                DescriptionBox(description: source.description)
                turnOnButton(title: "Turn On \(source.name)")
                Text("You can turn it off at any time. Turning it off deletes what BriefBar saved for it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .needsReview:
                Label("\(source.name) is paused: since you turned it on, an update changed what it reads. Here's what it reads now.", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                DescriptionBox(description: source.description)
                HStack {
                    turnOnButton(title: "Keep It On")
                    Button("Turn It Off") { model.turnOff(source.id) }
                }
            case .on:
                if let status = source.statusView() {
                    status
                }
                Form {
                    source.settingsView()
                }
                .environment(\.inSettingsForm, true)
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("What it reads") {
                    DescriptionBox(description: source.description)
                        .padding(.top, 6)
                }
                Button("Turn Off \(source.name)…") { confirmingTurnOff = true }
            }
        }
        .alert("Turn off \(source.name)?", isPresented: $confirmingTurnOff) {
            Button("Turn Off", role: .destructive) { turnOff() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BriefBar stops reading it, removes it from the menu bar and deletes what it saved for it. Its settings stay.")
        }
        .alert(FullDiskAccess.removalTitle, isPresented: $offeringToRemoveAccess) {
            Button("Open Privacy Settings") { FullDiskAccess.openPrivacySettingsPane() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(FullDiskAccess.removalMessage)
        }
    }

    private func turnOnButton(title: String) -> some View {
        Button(title) { model.turnOn(source.id) }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
    }

    private func turnOff() {
        // Whether it needs the access now, rather than whether it can: Azure DevOps only does for pull requests
        // sent in chats.
        let access = model.services.fullDiskAccess
        let neededAccess = access.isRequested(by: source.id)
        model.turnOff(source.id)
        if neededAccess && !access.isNeeded {
            offeringToRemoveAccess = true
        }
    }
}

/// What a source reads, where it connects and what it needs.
struct DescriptionBox: View {
    let description: SourceDescription

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            entry("What BriefBar reads", description.reads, symbol: "doc.text.magnifyingglass")
            entry("Network", description.network, symbol: "network")
            entry("What it needs", description.needs, symbol: "lock.shield")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func entry(_ title: String, _ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
