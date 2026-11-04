import BriefBarCore
import Combine
import Foundation

/// Updates from Copilot Sessions: what Copilot sessions told BriefBar through its agents' tools, which `--mcp` keeps in
/// BriefBar's preferences and tells the app it changed (`AgentChanges`): what each session works on and the pull requests
/// it opened, for the Copilot source to show (`reports`), and what agents changed in Azure DevOps, for the Azure DevOps
/// source to read again sooner (`rereads`). It's off until you turn it on (`SessionUpdatesSetting`): until then it reads
/// nothing. Turning it off or on forgets what sessions told before, which nothing would have kept current meanwhile.
@MainActor
package final class SessionUpdates: ObservableObject {
    @Published package private(set) var isOn: Bool
    /// What sessions told: nothing while it's off.
    @Published package private(set) var reports = SessionReports()
    /// What agents said they just changed in Azure DevOps, as each change arrives, for its source to read again.
    package let rereads = PassthroughSubject<[ItemRef], Never>()

    private let defaults: UserDefaults
    private let isDemo: Bool
    private let now: () -> Date
    /// Hears about what agents tell through `--mcp`, while it's on.
    private var agentChanges: AnyObject?
    /// When the last request to read again that it took was made: nothing older is taken, and nothing made before the app
    /// started, which reads everything as it starts.
    private var takenUpTo: Date

    /// - Parameters:
    ///   - isDemo: the demo has it on, with what its sessions told in memory (`tellDemo`).
    ///   - now: the time, in tests.
    package init(defaults: UserDefaults, isDemo: Bool, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.isDemo = isDemo
        self.now = now
        takenUpTo = now()
        isOn = isDemo || SessionUpdatesSetting.isOn(in: defaults)
        if isOn { load() }
    }

    /// Updates from Copilot Sessions, on the Agents page. Either way, what sessions told before is forgotten.
    package func setOn(_ on: Bool) {
        guard on != isOn else { return }
        defaults.set(on, forKey: SessionUpdatesSetting.defaultsKey)
        Log.app.info("Updates from Copilot Sessions \(on ? "on" : "off", privacy: .public)")
        isOn = on
        SessionReports.forgetAll(in: defaults)
        takenUpTo = now()
        if on {
            load()
        } else {
            agentChanges = nil
            reports = SessionReports()
        }
    }

    private func load() {
        reports = SessionReports.load(from: defaults, now: now())
        // The demo's agents keep what they're told in their own memory.
        if !isDemo, agentChanges == nil {
            agentChanges = AgentChanges.observe { [weak self] in self?.agentChanged() }
        }
    }

    /// An agent told something through `--mcp`: reads what sessions told again, and passes on what's new to read again.
    package func agentChanged() {
        guard isOn else { return }
        let date = now()
        let loaded = SessionReports.load(from: defaults, now: date)
        if loaded != reports { reports = loaded }
        let taken = RereadRequests.take(after: takenUpTo, from: defaults, now: date)
        guard let latest = taken.map(\.at).max() else { return }
        takenUpTo = max(takenUpTo, latest)
        var refs: [ItemRef] = []
        for request in taken where !refs.contains(request.ref) {
            refs.append(request.ref)
        }
        rereads.send(refs)
    }

    /// Forgets a source's things when you turn it off, whether this is on or not: every session's report with Copilot's,
    /// the work items and pull requests of the others.
    package func forget(_ source: SourceID) {
        if source == .copilot {
            SessionReports.forgetAll(in: defaults)
        } else {
            let kinds = ItemRef.Kind.of(source)
            guard !kinds.isEmpty else { return }
            SessionReports.forget(kinds, in: defaults, now: now())
        }
        guard isOn else { return }
        var reports = SessionReports.load(from: defaults, now: now())
        // The demo's are in memory only.
        if isDemo {
            reports = self.reports
            reports.forget(source == .copilot ? Set(ItemRef.Kind.allCases) : ItemRef.Kind.of(source))
        }
        if reports != self.reports { self.reports = reports }
    }

    /// What the demo's sessions told, as if they had, kept in memory.
    package func tellDemo(_ reports: [SessionReport]) {
        guard isDemo, isOn else { return }
        self.reports = SessionReports(reports)
    }
}
