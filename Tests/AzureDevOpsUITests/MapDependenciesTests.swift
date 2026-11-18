import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Dependencies between work items linked in Azure DevOps, or taken away, from My Work's Map, with Make Changes in Azure
/// DevOps on: each read first, so that one there already, or gone already, goes nowhere; what goes, only while it's on and
/// as you click, testing the revision read; how it shows at once; Undo; and what the line at the top of the Map says when it
/// stopped. With the demo's made-up sprint, as a sprint that reads Azure DevOps would have it, and a stand-in for Azure
/// DevOps that keeps each work item's links and answers as it does.
@MainActor
@Suite struct MapDependenciesTests {
    /// What the stand-in for Azure DevOps keeps of work items' links, was sent and answers.
    @MainActor
    final class AzureDevOps {
        /// Each work item's predecessors, in its links' order, after a link of another kind first.
        var predecessors: [Int: [Int]] = [:]
        var revisions: [Int: Int] = [:]
        var sent: [ADOWrite] = []
        var reads: [WorkItemKey] = []
        var fails: ADOError?
        /// Fails the read of a work item's links, as when you're offline.
        var readFails: ADOError?

        func read(_ key: WorkItemKey) throws -> ADOWorkItemLinks {
            reads.append(key)
            if let readFails { throw readFails }
            let links: [[String: String]] = [["rel": "System.LinkTypes.Hierarchy-Reverse", "url": address(5101)]]
                + (predecessors[key.id] ?? []).map { ["rel": WorkDependency.predecessor, "url": address($0)] }
            return try ADOJSON.decoder().decode(ADOWorkItemLinks.self, from: JSONSerialization.data(withJSONObject: [
                "id": key.id, "rev": revisions[key.id] ?? 1, "relations": links,
            ] as [String: Any]))
        }

        /// As the client does: nothing goes once `wanted` no longer wants it; and as Azure DevOps does, nothing changes from
        /// a revision that isn't the work item's.
        func send(_ write: ADOWrite, while wanted: (@Sendable () async -> Bool)?) async throws -> ADOWrite.Answer {
            if let wanted, !(await wanted()) { throw CancellationError() }
            sent.append(write)
            if let fails { throw fails }
            let key: WorkItemKey
            switch write {
            case .addDependency(let later, let earlier, let revision):
                guard revision == (revisions[later.id] ?? 1) else { throw ADOError.refused(nil, message: "TF401331") }
                predecessors[later.id, default: []].append(earlier)
                key = later
            case .removeDependency(let later, _, let index, let revision):
                guard revision == (revisions[later.id] ?? 1) else { throw ADOError.refused(nil, message: "TF401331") }
                predecessors[later.id]?.remove(at: index - 1)
                key = later
            default:
                throw ADOError.http(400)
            }
            revisions[key.id] = (revisions[key.id] ?? 1) + 1
            return .workItem(try ADOJSON.decoder().decode(ADOWorkItem.self, from: JSONSerialization.data(withJSONObject: [
                "id": key.id, "rev": revisions[key.id] ?? 1, "fields": ["System.Id": key.id],
            ] as [String: Any])))
        }

        private func address(_ id: Int) -> String {
            "https://dev.azure.com/\(DemoData.organization)/_apis/wit/workItems/\(id)"
        }
    }

    nonisolated static let referenceNow = Date()

    private func key(_ id: Int) -> WorkItemKey { WorkItemKey(DemoData.organization, id) }

    private func dependency(_ before: Int, _ after: Int) -> WorkDependency { WorkDependency(key(before), key(after)) }

    /// A sprint that reads Azure DevOps, with the demo's Sprint 42 read, and what links its work items' dependencies, telling
    /// what it changed as Show Links would hear it.
    private func live(makesChanges: Bool = true) -> (dependencies: MapDependencies, azure: AzureDevOps, told: Box, sprint: SprintStore) {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.makesChanges = makesChanges
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
        let sprint = SprintStore(settings: settings, mode: .live, client: store.client)
        sprint.receive(SprintSnapshot(board: DemoData.sprintBoard(now: Self.referenceNow), hasLoaded: true))
        let dependencies = MapDependencies(sprint: sprint, settings: settings, client: store.client)
        let azure = AzureDevOps()
        let told = Box()
        dependencies.send = { write, _, wanted in try await azure.send(write, while: wanted) }
        dependencies.read = { key in try azure.read(key) }
        dependencies.changed = { dependency, linked in told.changes.append((dependency, linked)) }
        return (dependencies, azure, told, sprint)
    }

    /// What it told Show Links, in order.
    @MainActor
    final class Box {
        var changes: [(WorkDependency, Bool)] = []
    }

    /// Off, nothing goes, and the Map's buttons say how to turn it on; on, a dependency is linked on the later work item, from
    /// the revision read, shows at once, is told to Show Links, and Undo takes it away again, by its index among the links.
    @Test func linksADependencyAndUndoTakesItAway() async {
        let (dependencies, azure, told, sprint) = live(makesChanges: false)
        #expect(dependencies.held == MapDependencyText.turnOn)
        await dependencies.link([dependency(5103, 5104)], words: "Task 5104 waits for Task 5103")
        #expect(azure.sent.isEmpty && azure.reads.isEmpty && dependencies.line == nil)

        dependencies.settings.makesChanges = true
        #expect(dependencies.held == nil)
        azure.revisions[5104] = 4
        await dependencies.link([dependency(5103, 5104)], words: "Task 5104 waits for Task 5103")
        #expect(azure.reads == [key(5104)])
        #expect(azure.sent == [.addDependency(key(5104), waitsFor: 5103, revision: 4)])
        #expect(dependencies.known == [dependency(5103, 5104)])
        #expect(told.changes.map { $0.1 } == [true])
        guard case .changed(let change, let written)? = dependencies.line else {
            Issue.record("Expected it linked, got \(String(describing: dependencies.line))")
            return
        }
        #expect(written == [dependency(5103, 5104)])
        #expect(MapDependencyText.changed(change, wrote: true) == "Linked in Azure DevOps: Task 5104 waits for Task 5103.")
        #expect(dependencies.undoable == change.back(written))
        #expect(dependencies.undoable?.unlinks == true && dependencies.undoable?.words == change.words)

        await dependencies.undo()
        #expect(azure.sent.last == .removeDependency(key(5104), waitsFor: 5103, index: 1, revision: 5))
        #expect(azure.predecessors[5104] == [])
        #expect(dependencies.known.isEmpty)
        #expect(dependencies.undoable == nil)
        #expect(told.changes.map { $0.1 } == [true, false])
        withExtendedLifetime(sprint) {}
    }

    /// One Azure DevOps links already, or doesn't, as someone did meanwhile, needs nothing sent: it shows as it is, and Undo
    /// takes back only what BriefBar changed, never what was there before; where it changed nothing, there's no Undo.
    @Test func whatsThereAlreadyGoesNowhereAndUndoLeavesIt() async {
        let (dependencies, azure, _, sprint) = live()
        azure.predecessors[5104] = [5103]
        await dependencies.link([dependency(5103, 5104)], words: "Task 5104 waits for Task 5103")
        #expect(azure.sent.isEmpty && dependencies.undoable == nil)
        if case .changed(let change, let written)? = dependencies.line {
            #expect(written.isEmpty)
            #expect(MapDependencyText.changed(change, wrote: false) == "Azure DevOps has it already: Task 5104 waits for Task 5103.")
        } else {
            Issue.record("Expected it there already, got \(String(describing: dependencies.line))")
        }
        await dependencies.unlink([dependency(5102, 5104)], words: "Task 5104 waits for Task 5102")
        #expect(azure.reads == [key(5104), key(5104)])
        #expect(azure.sent.isEmpty && dependencies.undoable == nil)
        #expect(dependencies.known == [dependency(5103, 5104)])

        await dependencies.link([dependency(5103, 5104), dependency(5104, 5105)], words: "2 dependencies")
        #expect(azure.sent == [.addDependency(key(5105), waitsFor: 5104, revision: 1)])
        #expect(dependencies.undoable?.dependencies == [dependency(5104, 5105)])
        #expect(dependencies.undoable?.words == "1 dependency")
        await dependencies.undo()
        #expect(azure.predecessors[5104] == [5103] && azure.predecessors[5105] == [])
        #expect(dependencies.known == [dependency(5103, 5104)])
        withExtendedLifetime(sprint) {}
    }

    /// Several at once, one after another; where one fails, the rest wait, and the line says how many went and why, with Try
    /// Again for the rest, where it may help; where Azure DevOps refused it, not.
    @Test func linkingSeveralStopsAtOneThatFailsAndTryAgainSendsTheRest() async {
        let (dependencies, azure, _, sprint) = live()
        let all = [dependency(5103, 5104), dependency(5104, 5105), dependency(5104, 5106)]
        azure.revisions[5105] = 2
        dependencies.read = { key in
            if key.id == 5105 { azure.readFails = .offline }
            defer { azure.readFails = nil }
            return try azure.read(key)
        }
        await dependencies.link(all, words: "3 dependencies")
        guard case .failed(let change, let problem, let done, let written)? = dependencies.line else {
            Issue.record("Expected it stopped, got \(String(describing: dependencies.line))")
            return
        }
        #expect(done == 1 && problem == .offline && change.dependencies == all && written == [dependency(5103, 5104)])
        #expect(azure.sent.count == 1)
        #expect(dependencies.known == [dependency(5103, 5104)])
        #expect(MapDependencyText.done(done, of: all.count) == "1 of 3 went.")

        // Try Again sends the rest; Undo then takes back all three, as the line says.
        dependencies.read = { key in try azure.read(key) }
        await dependencies.retry()
        #expect(azure.sent.count == 3)
        #expect(dependencies.known == Set(all))
        #expect(azure.predecessors[5105] == [5104])
        #expect(dependencies.line == .changed(change, written: all))
        #expect(dependencies.undoable == change.back(all))
        await dependencies.undo()
        #expect(azure.sent.count == 6 && dependencies.known.isEmpty)
        #expect(azure.predecessors[5104] == [] && azure.predecessors[5105] == [] && azure.predecessors[5106] == [])

        azure.fails = .refused(nil, message: "TF401331")
        await dependencies.link([dependency(5104, 5105)], words: "Task 5105 waits for Task 5104")
        guard case .failed(_, let refused, _, _)? = dependencies.line else {
            Issue.record("Expected it refused, got \(String(describing: dependencies.line))")
            return
        }
        #expect(!MapDependencies.retries(refused))
        withExtendedLifetime(sprint) {}
    }

    /// Someone else signing in as a change goes: what went shows nothing, as it was the last one's, and nothing more is read
    /// or sent, as them.
    @Test func someoneElseSigningInStopsItAndWhatWentShowsNothing() async {
        let (dependencies, azure, told, sprint) = live()
        dependencies.accountChanged("me@contoso.com")
        dependencies.send = { write, _, wanted in
            let answer = try await azure.send(write, while: wanted)
            dependencies.accountChanged("someone-else@contoso.com")
            return answer
        }
        await dependencies.link([dependency(5103, 5104), dependency(5104, 5105)], words: "2 dependencies")
        #expect(azure.sent == [.addDependency(key(5104), waitsFor: 5103, revision: 1)])
        #expect(azure.reads == [key(5104)])
        #expect(dependencies.known.isEmpty && told.changes.isEmpty)
        #expect(dependencies.line == nil && dependencies.undoable == nil)
        withExtendedLifetime(sprint) {}
    }

    /// Turned off while it waits to go, nothing goes, and the line says nothing more.
    @Test func turnedOffBeforeItGoesNothingGoes() async {
        let (dependencies, azure, _, sprint) = live()
        dependencies.read = { key in
            dependencies.settings.makesChanges = false
            return try azure.read(key)
        }
        await dependencies.link([dependency(5103, 5104)], words: "Task 5104 waits for Task 5103")
        #expect(azure.sent.isEmpty)
        #expect(dependencies.line == nil)
        #expect(dependencies.known.isEmpty)
        withExtendedLifetime(sprint) {}
    }
}
