import AzureDevOpsCore
import BriefBarCore
import Foundation

/// `--sprint`, `--teams` and `--pipelines`: what the Sprint and Pipelines sections show, as text. They read the
/// app's settings (which team, which pipelines) but never change them.
enum WorkCLI {
    // MARK: Sprint

    static func sprint(_ options: AzureDevOpsCommandLine.Options) -> Int32 {
        let now = Date()
        if options.demo {
            let board = DemoData.sprintBoard(now: now)
            printBoard(options.mine ? board.justMine() : board, whole: board, now: now)
            return 0
        }
        let client = ADOClient(tokens: AzureCLITokenProvider())
        let organizations = AzureDevOpsCommandLine.organizations(options)
        var team = AzureDevOpsCommandLine.appDefaults?.data(forKey: SettingsKey.sprintTeam).flatMap { try? JSONDecoder().decode(TeamRef.self, from: $0) }
        if let name = options.team {
            switch findTeam(name, in: organizations, client: client) {
            case .success(let found): team = found
            case .failure(let message):
                fputs("\(message)\n", stderr)
                return 1
            }
        }
        if team == nil {
            fputs("No team chosen in the app yet: looking for yours with a sprint going on today…\n", stderr)
        }
        let configuration = SprintEngine.Configuration(organizations: organizations, team: team)
        let snapshot = AzureDevOpsCommandLine.wait { await SprintEngine.loadOnce(client: client, configuration: configuration, now: now) }
        if let problem = snapshot.problem {
            print("! \(problem.message)")
        }
        guard let board = snapshot.board else {
            if snapshot.problem == nil {
                print(team.map { "\($0.name) has no sprint going on today." } ?? "None of your teams has a sprint going on today.")
            }
            return snapshot.problem == nil ? 0 : 1
        }
        printBoard(options.mine ? board.justMine() : board, whole: board, now: now)
        return 0
    }

    private static func findTeam(_ name: String, in organizations: [String], client: ADOClient) -> Result<TeamRef, ErrorMessage> {
        let found: Result<[TeamRef], ErrorMessage> = AzureDevOpsCommandLine.wait {
            var teams: [TeamRef] = []
            for organization in organizations {
                do {
                    let list = try await client.get(ADOEndpoint.myTeams(organization: organization), as: ADOList<ADOTeam>.self)
                    teams += list.value.compactMap { TeamRef(organization: organization, $0) }
                } catch {
                    return .failure(ErrorMessage("Can't read your teams in \(organization): \((error as? ADOError)?.description ?? error.localizedDescription)"))
                }
            }
            return .success(teams)
        }
        return found.flatMap { teams in
            let wanted = name.lowercased()
            if let team = teams.first(where: { $0.name.lowercased() == wanted || "\($0.projectName)/\($0.name)".lowercased() == wanted }) {
                return .success(team)
            }
            return .failure(ErrorMessage("You're not on a team named \(name). Run --teams to list yours."))
        }
    }

    struct ErrorMessage: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    static func printBoard(_ board: SprintBoard, whole: SprintBoard, now: Date) {
        boardLines(board, whole: whole, now: now).forEach { print($0) }
    }

    /// The board as `--sprint` prints it, and the `sprint` tool of `--mcp` gives agents.
    static func boardLines(_ board: SprintBoard, whole: SprintBoard, now: Date) -> [String] {
        var lines: [String] = []
        let sprint = board.sprint
        var header = "\(sprint.name) · \(board.team.name) (\(board.team.projectName))"
        if let start = sprint.start, let finish = sprint.finish {
            header += " · \(SprintDates.range(start, finish))"
        }
        if let left = sprint.daysLeft(now: now), let day = sprint.day(now: now), let length = sprint.length {
            header += " · \(left == 1 ? "last day" : "\(left) days left") (day \(day) of \(length))"
        }
        lines.append(header)
        let mine = whole.myWork
        let hours = board.remainingWork
        lines.append("Tasks: \(board.count(in: .done)) done, \(board.count(in: .inProgress)) in progress, \(board.count(in: .toDo)) to do"
            + (hours > 0 ? " · \(Hours.text(hours)) left" : "")
            + " · yours: \(mine.filter { $0.category.column == .inProgress }.count) in progress, "
            + "\(mine.filter { $0.category.column == .toDo }.count) to do, \(whole.myDoneCount) done")

        let stories = board.rows.filter { $0.parent != nil }
        let sections: [(String, [SprintBoard.Row])] = [
            ("IN PROGRESS", stories.filter { $0.progress == .inProgress }),
            ("NOT STARTED", stories.filter { $0.progress == .toDo }),
            ("NOT IN A STORY", board.rows.filter { $0.parent == nil }),
            ("DONE", stories.filter { $0.progress == .done }),
        ]
        for (title, rows) in sections where !rows.isEmpty {
            lines.append("")
            lines.append(title)
            for row in rows {
                if let parent = row.parent {
                    let progress = row.tasks.isEmpty ? "no tasks" : "\(row.doneCount)/\(row.tasks.count) done"
                    lines.append("  \(symbol(parent)) \(parent.id) \(parent.type): \(parent.title)  [\(parent.state) · \(parent.assignedTo?.name ?? "Unassigned")]  \(progress)")
                }
                for task in row.tasksInWorkOrder {
                    lines.append("      " + taskLine(task, me: board.me))
                }
            }
        }
        return lines
    }

    /// "◐ 5112 Show saved items  [Active · Sam Rivera (you)]  3 h", as `--sprint` prints a task.
    static func taskLine(_ task: WorkItem, me: String?) -> String {
        let mark = me.map { task.isAssigned(to: $0) } == true ? " (you)" : ""
        let hours = task.remainingText.map { "  \($0)" } ?? ""
        return "\(symbol(task)) \(task.id) \(task.title)  [\(task.state) · \(task.assignedTo?.name ?? "Unassigned")\(mark)]\(hours)"
    }

    private static func symbol(_ item: WorkItem) -> String {
        switch item.category.column {
        case .done?: return "✓"
        case .inProgress?: return "◐"
        default: return "○"
        }
    }

    // MARK: Teams

    static func teams(_ options: AzureDevOpsCommandLine.Options) -> Int32 {
        if options.demo {
            let sprint = DemoData.sprint()
            print("Your teams; * has a sprint going on today; + is the app's choice")
            print("*+ \(DemoData.team.name) (\(DemoData.team.projectName)): \(sprint.name)")
            print("   \(DemoData.otherTeam.name) (\(DemoData.otherTeam.projectName)): no sprint today")
            return 0
        }
        let client = ADOClient(tokens: AzureCLITokenProvider())
        let organizations = AzureDevOpsCommandLine.organizations(options)
        let chosen = AzureDevOpsCommandLine.appDefaults?.data(forKey: SettingsKey.sprintTeam).flatMap { try? JSONDecoder().decode(TeamRef.self, from: $0) }
        let now = Date()
        let lines: Result<[String], ErrorMessage> = AzureDevOpsCommandLine.wait {
            var lines: [String] = []
            for organization in organizations {
                let teams: [TeamRef]
                do {
                    teams = try await client.get(ADOEndpoint.myTeams(organization: organization), as: ADOList<ADOTeam>.self)
                        .value.compactMap { TeamRef(organization: organization, $0) }
                        .sorted { ($0.projectName.lowercased(), $0.name.lowercased()) < ($1.projectName.lowercased(), $1.name.lowercased()) }
                } catch {
                    return .failure(ErrorMessage("Can't read your teams in \(organization): \((error as? ADOError)?.description ?? error.localizedDescription)"))
                }
                for team in teams {
                    let current = try? await client.get(ADOEndpoint.currentIteration(team: team), as: ADOList<ADOIteration>.self)
                        .value.map(Sprint.init).first { $0.isCurrent(now: now) }
                    let marks = (current == nil ? " " : "*") + (team.id == chosen?.id ? "+" : " ")
                    lines.append("\(marks) \(team.name) (\(team.projectName), \(organization)): \(current?.name ?? "no sprint today")")
                }
            }
            return .success(lines)
        }
        switch lines {
        case .success(let lines):
            print("Your teams; * has a sprint going on today; + is the app's choice")
            lines.forEach { print($0) }
            return 0
        case .failure(let message):
            fputs("\(message)\n", stderr)
            return 1
        }
    }

    // MARK: Pipelines

    static func pipelines(_ options: AzureDevOpsCommandLine.Options) -> Int32 {
        let now = Date()
        if options.demo {
            DemoData.pipelines(now: now).forEach { printPipeline($0, now: now) }
            return 0
        }
        let pinned = AzureDevOpsCommandLine.appDefaults?.data(forKey: SettingsKey.pinnedPipelines)
            .flatMap { try? JSONDecoder().decode([PipelineRef].self, from: $0) } ?? []
        guard !pinned.isEmpty else {
            print("No pipelines pinned in the app yet. Find some with --pipelines --search <text> --project <name>.")
            return 0
        }
        let client = ADOClient(tokens: AzureCLITokenProvider())
        let snapshot = AzureDevOpsCommandLine.wait { await PipelinesEngine.loadOnce(client: client, configuration: PipelinesEngine.Configuration(pipelines: pinned)) }
        if let problem = snapshot.problem { print("! \(problem.message)") }
        snapshot.statuses.forEach { printPipeline($0, now: now) }
        return snapshot.problem == nil ? 0 : 1
    }

    static func printPipeline(_ status: PipelineStatus, now: Date) {
        pipelineLines(status, now: now).forEach { print($0) }
    }

    /// A pipeline as `--pipelines` prints it, and the `pipelines` tool of `--mcp` gives agents.
    static func pipelineLines(_ status: PipelineStatus, now: Date) -> [String] {
        var lines: [String] = []
        let folder = status.pipeline.folder.isEmpty ? "" : " (\(status.pipeline.folder.replacingOccurrences(of: "\\", with: " › ")))"
        var line = "\(status.pipeline.name)\(folder)  \(status.headline)"
        if let run = status.latest {
            var parts = [run.number]
            if !run.branch.isEmpty { parts.append(run.branch) }
            if let who = run.requestedFor { parts.append(who) }
            if let at = run.changedAt { parts.append("\(Elapsed.short(since: at, now: now)) ago") }
            if let duration = run.duration(now: now) { parts.append(RunDuration.short(duration)) }
            line += " · " + parts.joined(separator: " · ")
        }
        if let branch = status.pipeline.branch { line += "  [runs of \(branch) only]" }
        lines.append(line)
        if !status.stages.isEmpty {
            lines.append("  stages: " + status.stages.map { stage in
                let duration = stage.startedAt.map { RunDuration.short((stage.finishedAt ?? now).timeIntervalSince($0)) }
                return "\(symbol(stage.state)) \(stage.name)" + (duration.map { " \($0)" } ?? "")
            }.joined(separator: " → "))
        }
        if let failure = status.failure, status.latest?.status == .failed {
            lines.append("  failed: \([failure.stage, failure.step].compactMap { $0 }.joined(separator: " › "))" + (failure.message.map { ": \($0)" } ?? ""))
        }
        if !status.runs.isEmpty {
            lines.append("  runs (oldest to newest): " + status.runs.prefix(12).reversed().map { symbol($0.status) }.joined())
        }
        return lines
    }

    private static func symbol(_ state: PipelineStage.State) -> String {
        switch state {
        case .succeeded: return "✓"
        case .warning: return "!"
        case .failed: return "✕"
        case .running: return "▶"
        case .waiting: return "⏸"
        case .pending: return "○"
        case .canceled, .skipped: return "–"
        }
    }

    private static func symbol(_ status: PipelineRun.Status) -> String {
        switch status {
        case .succeeded: return "✓"
        case .partiallySucceeded: return "!"
        case .failed: return "✕"
        case .running: return "▶"
        case .queued: return "○"
        case .canceled: return "–"
        }
    }

    /// `--pipelines --search <text> --project <name>`: the pipelines you could pin, by name or number.
    static func searchPipelines(_ options: AzureDevOpsCommandLine.Options) -> Int32 {
        let text = options.search ?? ""
        if options.demo {
            for pipeline in PipelineSearch.pipelines(DemoData.pipelines().map(\.pipeline) + DemoData.morePipelines, containing: text) {
                print("\(pipeline.definitionId)  \(pipeline.name)  (\(pipeline.folder.replacingOccurrences(of: "\\", with: " › ")))")
            }
            return 0
        }
        guard let project = options.project, let organization = AzureDevOpsCommandLine.organizations(options).first else {
            fputs("Say which project to search in with --project <name> (and --org <name> if it isn't the app's first).\n", stderr)
            return 2
        }
        let client = ADOClient(tokens: AzureCLITokenProvider())
        let result: Result<[PipelineRef], ADOError> = AzureDevOpsCommandLine.wait {
            do {
                return .success(try await PipelineSearch.pipelines(containing: text, organization: organization, projectId: project, client: client))
            } catch {
                return .failure((error as? ADOError) ?? .network(error.localizedDescription))
            }
        }
        switch result {
        case .success(let found) where options.status:
            // How the first few are doing, as the Pipelines page would show them pinned.
            let pipelines = Array(found.prefix(5))
            let snapshot = AzureDevOpsCommandLine.wait { await PipelinesEngine.loadOnce(client: client, configuration: PipelinesEngine.Configuration(pipelines: pipelines)) }
            if let problem = snapshot.problem { print("! \(problem.message)") }
            let now = Date()
            snapshot.statuses.forEach { printPipeline($0, now: now) }
            return snapshot.problem == nil ? 0 : 1
        case .success(let found):
            let like = PipelineSearch.number(in: text) == nil ? "named like" : "numbered or named like"
            print("\(found.count) pipelines in \(project) \(like) “\(text)” (the first 50)")
            for pipeline in found {
                print("\(pipeline.definitionId)  \(pipeline.name)  (\(pipeline.folder.replacingOccurrences(of: "\\", with: " › ")))")
            }
            return 0
        case .failure(let error):
            fputs("\(error.description)\n", stderr)
            return 1
        }
    }
}
