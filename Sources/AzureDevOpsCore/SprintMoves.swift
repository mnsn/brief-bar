import Foundation

// Moving one of your work items to another sprint, on My Work, with Make Changes in Azure DevOps on: into your team's
// current sprint, or its next, which BriefBar finds in the team's sprints, read only as you ask for it (`TeamSprints`). The
// change itself is `ADOWrite.setIteration`. What it moved shows where it went at once (`SprintBoard.removing`,
// `OutsideWork.placing`), until the sprint and your work outside it are read again.

extension ADOEndpoint {
    /// A team's sprints, past, current and future, each with its dates: only as you move a work item of yours to the team's
    /// next sprint.
    public static func teamIterations(team: TeamRef) -> URL {
        url("https://dev.azure.com", [team.organization, team.projectId, team.id, "_apis", "work", "teamsettings", "iterations"],
            [("api-version", apiVersion)])
    }
}

/// A team's sprints, as Azure DevOps lists them for it, for the one after its current sprint: read with one GET, only as you
/// move a work item to the next sprint.
public enum TeamSprints {
    /// The team's sprint after `current`, as Azure DevOps lists its sprints now (`Sprint.next(after:in:now:calendar:)`); nil
    /// when it has none.
    public static func next(
        of team: TeamRef, after current: Sprint?, client: ADOClient, now: Date = Date(), calendar: Calendar = .current
    ) async throws -> Sprint? {
        let list = try await client.get(ADOEndpoint.teamIterations(team: team), as: ADOList<ADOIteration>.self)
        return Sprint.next(after: current, in: list.value, now: now, calendar: calendar)
    }
}

extension Sprint {
    /// A team's sprint after `current`, of its sprints as Azure DevOps lists them: the one that starts first after it does;
    /// with no current sprint, the first that starts after today. Without dates, Azure DevOps calls a sprint the team hasn't
    /// reached yet future: the first of those, as it lists them, when none after it has dates. Nil when there's none.
    public static func next(after current: Sprint?, in iterations: [ADOIteration], now: Date, calendar: Calendar = .current) -> Sprint? {
        let sprints = iterations.filter { iteration in
            guard let current else { return true }
            return iteration.id != current.id && iteration.path != current.path
        }
        let after: Int? = if let current {
            SprintDay.number(current.start)
        } else {
            SprintDay.today(now, calendar: calendar)
        }
        let dated = sprints.compactMap { iteration -> (sprint: Sprint, day: Int)? in
            guard let day = SprintDay.number(iteration.attributes?.startDate) else { return nil }
            if let after, day <= after { return nil }
            if after == nil, iteration.attributes?.timeFrame?.lowercased() != "future" { return nil }
            return (Sprint(iteration), day)
        }
        if let first = dated.min(by: { $0.day < $1.day }) { return first.sprint }
        let undated = sprints.first { $0.attributes?.startDate == nil && $0.attributes?.timeFrame?.lowercased() == "future" }
        return undated.map(Sprint.init)
    }
}

extension WorkItem {
    /// As Azure DevOps answered a change that moved it to the iteration at `path`: there, as its answer says, and changed
    /// when it says, or at `date` when it says nothing, so that what shows of it, such as its details, follows.
    public func moved(to path: String, answer: ADOWorkItem?, at date: Date) -> WorkItem {
        var item = self
        item.iteration = answer?.fields.iterationPath ?? path
        item.changedAt = answer?.fields.changedDate ?? date
        return item
    }
}

extension SprintBoard {
    /// As it is once BriefBar moved one of its work items: without it, when it went to another sprint, until the sprint is
    /// read again (`removing`).
    public func moving(_ item: WorkItem) -> SprintBoard {
        guard self.item(item.key) != nil, item.iteration != nil, !OutsideWork.isSamePath(item.iteration, sprint.path) else {
            return self
        }
        return removing(item.key)
    }

    /// Without a work item BriefBar moved to another sprint, until the sprint is read again: a story's or bug's row goes, and
    /// its tasks, which stay in the sprint, go with those whose story isn't in it.
    public func removing(_ key: WorkItemKey) -> SprintBoard {
        var board = self
        var orphans: [WorkItem] = []
        var rows: [Row] = []
        for row in self.rows {
            if row.parent?.key == key {
                orphans += row.tasks
                continue
            }
            var kept = row
            kept.tasks.removeAll { $0.key == key }
            rows.append(kept)
        }
        if !orphans.isEmpty {
            if let index = rows.firstIndex(where: { $0.parent == nil }) {
                rows[index].tasks = (rows[index].tasks + orphans).sorted(by: WorkItem.ordered)
            } else {
                rows.append(Row(parent: nil, tasks: orphans.sorted(by: WorkItem.ordered)))
            }
        }
        board.rows = rows.filter { $0.parent != nil || !$0.tasks.isEmpty }
        return board
    }
}

extension OutsideWork {
    /// With a work item of yours where BriefBar just moved it, until your work is read again: in its new iteration, in order,
    /// as a read would have it; or added, as one that left the sprint's board for another sprint. One moved into the sprint's
    /// own iteration stays, without a place to say, until the sprint's board, read again, has it.
    public func placing(_ item: WorkItem, board: SprintBoard?) -> OutsideWork {
        var work = self
        work.items = Self.yours(items.filter { $0.key != item.key } + [item], board: board, taskTypes: taskTypes)
        return work
    }
}
