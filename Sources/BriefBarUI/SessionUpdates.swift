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
    /// What it took of each `--mcp`'s requests to read again: nothing is taken twice, and nothing asked before it started
    /// reading them, as the app reads everything as it starts.
    private var taken: RereadRequests.Taken = [:]

    /// - Parameters:
    ///   - isDemo: the demo has it on, with what its sessions told in memory (`tellDemo`).
    ///   - now: the time, in tests.
    package init(defaults: UserDefaults, isDemo: Bool, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.isDemo = isDemo
        self.now = now
        isOn = isDemo || SessionUpdatesSetting.isOn(in: defaults)
        if isOn {
            taken = RereadRequests.taken(in: defaults)
            load()
        }
    }

    /// Updates from Copilot Sessions, on the Agents page. Either way, what sessions told before is forgotten.
    package func setOn(_ on: Bool) {
        guard on != isOn else { return }
        defaults.set(on, forKey: SessionUpdatesSetting.defaultsKey)
        Log.app.info("Updates from Copilot Sessions \(on ? "on" : "off", privacy: .public)")
        isOn = on
        SessionReports.forgetAll(in: defaults)
        taken = [:]
        if on {
            load()
        } else {
            agentChanges = nil
            reports = SessionReports()
        }
    }

    private func load() {
        if !isDemo { SessionReports.prune(in: defaults, now: now()) }
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
        SessionReports.prune(in: defaults, now: date)
        let loaded = SessionReports.load(from: defaults, now: date)
        if loaded != reports { reports = loaded }
        let (requests, taken) = RereadRequests.take(since: taken, from: defaults, now: date)
        self.taken = taken
        var refs: [ItemRef] = []
        for request in requests where !refs.contains(request.ref) {
            refs.append(request.ref)
        }
        guard !refs.isEmpty else { return }
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
