import Foundation

/// A made-up investigation of the demo's failed builds, for `--demo` and the screenshots. Times are relative to `now`.
extension DemoData {
    /// What the demo's failed builds show when you open them: shop-web CI's run that failed in two of its delivery
    /// estimate tests, on `!4088`, as its check says, and on the pull requests the Pipelines page shows, as their runs
    /// say. It built the latest commit, unless the Pipelines page says it's outdated, and the pipeline's latest run on main
    /// failed the same way, as the Pipelines page shows it. Nil for another build, or a pull request that isn't the demo's.
    public static func buildInvestigation(buildId: Int, of pullRequest: PullRequest, now: Date = Date()) -> BuildInvestigation? {
        guard pullRequest.key.organization.caseInsensitiveCompare(organization) == .orderedSame,
              let shopWeb = pipelines(now: now).first(where: { $0.pipeline.name == "shop-web CI" }),
              let onMain = shopWeb.latest, onMain.status == .failed
        else { return nil }
        // The run the Pipelines page shows for the pull request, or the one its check failed with.
        let isPipelinesRun = buildId == pullRequest.key.number * 1_000 + shopWeb.pipeline.definitionId
        let isCheckRun = records(now: now).first { $0.id == pullRequest.key }?.details?.checks
            .contains { $0.kind == .build && $0.state == .failed && $0.buildId == buildId } == true
        guard isPipelinesRun || isCheckRun else { return nil }
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        // Whether it built the latest commit, as the Pipelines page says of its pull requests' runs.
        let revision = pipelinesPullRequests(now: now).first { $0.pullRequest.key == pullRequest.key }?.revisions[buildId] ?? .current
        var run = onMain
        run.id = buildId
        run.branch = "!\(pullRequest.key.number)"
        run.trigger = .pullRequest

        var nextLog = 0
        /// Tasks one after the other from `start`, each `(name, seconds, state, issues)`.
        func tasks(_ job: String, from start: Date, _ list: [(String, Double, PipelineStage.State, [BuildIssue])]) -> [BuildStep] {
            var at = start
            return list.enumerated().map { index, task in
                let (name, seconds, state, issues) = task
                let started = state == .skipped ? nil : at
                if state != .skipped { at = at.addingTimeInterval(seconds) }
                nextLog += 1
                return BuildStep(
                    id: "\(job)-task-\(index + 1)", kind: .task, name: name, state: state, startedAt: started,
                    finishedAt: started.map { $0.addingTimeInterval(seconds) }, issues: issues, logId: state == .skipped ? nil : nextLog
                )
            }
        }
        let checkout = "Checkout \(pullRequest.repositoryName)@\(pullRequest.sourceBranch) to s"
        let warning = BuildIssue(
            kind: .warning,
            message: "Non-nullable property 'Carrier' must contain a non-null value when exiting constructor. Consider declaring "
                + "the property as nullable.",
            file: "src/Storefront/Delivery/DeliveryEstimate.cs", line: 18, column: 23, code: "CS8618", logLine: 57,
            stepId: "build-task-5", step: "Build"
        )
        let errors = [
            BuildIssue(kind: .error, message: "2 tests failed in DeliveryEstimateTests.", logLine: 37, stepId: "test-task-4",
                       step: "Run unit tests"),
            BuildIssue(kind: .error, message: "Dotnet command failed with non-zero exit code on the following projects: "
                + "tests/Storefront.Tests/Storefront.Tests.csproj", logLine: 38, stepId: "test-task-4", step: "Run unit tests"),
        ]
        let buildTasks = tasks("build", from: ago(71), [
            ("Initialize job", 3, .succeeded, []), (checkout, 6, .succeeded, []), ("Use .NET SDK 8.0.x", 9, .succeeded, []),
            ("Restore", 31, .succeeded, []), ("Build", 82, .warning, [warning]), ("Post-job: Checkout", 1, .succeeded, []),
            ("Finalize Job", 1, .succeeded, []),
        ])
        let testTasks = tasks("test", from: ago(68.6), [
            ("Initialize job", 3, .succeeded, []), (checkout, 6, .succeeded, []), ("Use .NET SDK 8.0.x", 8, .succeeded, []),
            ("Run unit tests", 182, .failed, errors), ("Publish test results", 6, .succeeded, []),
            ("Post-job: Checkout", 1, .succeeded, []), ("Finalize Job", 1, .succeeded, []),
        ])
        func job(_ id: String, _ name: String, _ state: PipelineStage.State, _ tasks: [BuildStep]) -> BuildStep {
            var logId: Int?
            if !tasks.isEmpty {
                nextLog += 1
                logId = nextLog
            }
            return BuildStep(
                id: "\(id)-job", kind: .job, name: name, state: state, startedAt: tasks.first?.startedAt,
                finishedAt: tasks.last?.finishedAt, logId: logId, steps: tasks
            )
        }
        func stage(_ id: String, _ name: String, _ state: PipelineStage.State, _ jobs: [BuildStep]) -> BuildStep {
            BuildStep(
                id: "\(id)-stage", kind: .stage, name: name, state: state, startedAt: jobs.first?.startedAt, finishedAt: jobs.last?.finishedAt,
                steps: jobs
            )
        }
        let steps = [
            stage("build", "Build", .succeeded, [job("build", "Build", .succeeded, buildTasks)]),
            stage("test", "Test", .failed, [job("test", "Unit tests", .failed, testTasks)]),
            stage("publish", "Publish", .skipped, [job("publish", "Publish packages", .skipped, [])]),
        ]
        let failedTask = testTasks[3]
        return BuildInvestigation(
            pipeline: shopWeb.pipeline, run: run, steps: steps,
            failure: PipelineFailure(stage: "Test", step: failedTask.name, message: errors[0].message),
            failedStepId: failedTask.id, errors: errors,
            log: BuildLog(stepId: failedTask.id, logId: failedTask.logId ?? 0, lines: unitTestLog, lineCount: unitTestLog.count),
            tests: BuildTests(total: 320, passed: 318, failed: 2, runs: 1, failures: failedTests),
            comparison: BuildComparison(revision: revision, targetBranch: pullRequest.targetBranch, targetRun: onMain),
            readAt: now
        )
    }

    /// The Pipelines page's pull requests, as the app lists them: yours that are open, the newest first, as `PRStore` does.
    private static func pipelinesPullRequests(now: Date) -> [PullRequestPipelines] {
        let authored = records(now: now).filter { $0.role == .author && $0.pullRequest.status == .active }.map(\.pullRequest)
            .sorted { ($0.createdAt, $0.key) > ($1.createdAt, $1.key) }
        return pullRequestPipelines(authored, now: now)
    }

    /// The made-up log of the step that failed, `dotnet test`'s.
    private static var unitTestLog: [BuildLogLine] {
        let lines: [(BuildLogLine.Kind, String)] = [
            (.section, "Starting: Run unit tests"),
            (.plain, "=============================================================================="),
            (.plain, "Task         : .NET Core"),
            (.plain, "Description  : Build, test, package, or publish a dotnet application, or run a custom dotnet command"),
            (.plain, "Version      : 2.247.1"),
            (.plain, "Author       : Microsoft Corporation"),
            (.plain, "Help         : https://docs.microsoft.com/azure/devops/pipelines/tasks/build/dotnet-core-cli"),
            (.plain, "=============================================================================="),
            (.command, "\"/usr/bin/dotnet\" test /home/vsts/work/1/s/tests/Storefront.Tests/Storefront.Tests.csproj --logger trx "
                + "--results-directory /home/vsts/work/_temp --configuration Release --no-build"),
            (.plain, "Test run for /home/vsts/work/1/s/tests/Storefront.Tests/bin/Release/net8.0/Storefront.Tests.dll (.NETCoreApp,Version=v8.0)"),
            (.plain, "VSTest version 17.11.1 (x64)"),
            (.plain, ""),
            (.plain, "Starting test execution, please wait..."),
            (.plain, "A total of 1 test files matched the specified pattern."),
            (.plain, "  Failed Storefront.Tests.Delivery.DeliveryEstimateTests.EstimateSkipsWeekends [14 ms]"),
            (.plain, "  Error Message:"),
            (.plain, "   Assert.Equal() Failure: Values differ"),
            (.plain, "Expected: Monday"),
            (.plain, "Actual:   Saturday"),
            (.plain, "  Stack Trace:"),
            (.plain, "     at Storefront.Tests.Delivery.DeliveryEstimateTests.EstimateSkipsWeekends() in "
                + "/home/vsts/work/1/s/tests/Storefront.Tests/Delivery/DeliveryEstimateTests.cs:line 41"),
            (.plain, "   at System.RuntimeMethodHandle.InvokeMethod(Object target, Void** arguments, Signature sig, Boolean isConstructor)"),
            (.plain, "  Failed Storefront.Tests.Delivery.DeliveryEstimateTests.EstimateUsesTheWarehouseTimeZone [6 ms]"),
            (.plain, "  Error Message:"),
            (.plain, "   Assert.Equal() Failure: Values differ"),
            (.plain, "Expected: 2 days"),
            (.plain, "Actual:   3 days"),
            (.plain, "  Stack Trace:"),
            (.plain, "     at Storefront.Tests.Delivery.DeliveryEstimateTests.EstimateUsesTheWarehouseTimeZone() in "
                + "/home/vsts/work/1/s/tests/Storefront.Tests/Delivery/DeliveryEstimateTests.cs:line 67"),
            (.plain, "   at System.RuntimeMethodHandle.InvokeMethod(Object target, Void** arguments, Signature sig, Boolean isConstructor)"),
            (.plain, "Results File: /home/vsts/work/_temp/Storefront.Tests.trx"),
            (.plain, ""),
            (.plain, "Failed!  - Failed:     2, Passed:   318, Skipped:     0, Total:   320, Duration: 9 s - Storefront.Tests.dll (net8.0)"),
            (.plain, "Result Attachments will be stored in LogStore"),
            (.plain, "Run Attachments will be stored in LogStore"),
            (.plain, ""),
            (.error, "2 tests failed in DeliveryEstimateTests."),
            (.error, "Dotnet command failed with non-zero exit code on the following projects: tests/Storefront.Tests/Storefront.Tests.csproj"),
            (.section, "Finishing: Run unit tests"),
        ]
        return lines.enumerated().map { BuildLogLine(number: $0 + 1, kind: $1.0, text: $1.1) }
    }

    /// The two tests that failed.
    private static var failedTests: [FailedTest] {
        let testRun = 9_301
        func test(_ id: Int, _ name: String, expected: String, actual: String, line: Int, milliseconds: Double) -> FailedTest {
            let fullName = "Storefront.Tests.Delivery.DeliveryEstimateTests.\(name)"
            return FailedTest(
                id: "\(testRun)/\(id)", name: name, fullName: fullName, container: "Storefront.Tests.dll", run: "Storefront.Tests",
                message: "Assert.Equal() Failure: Values differ\nExpected: \(expected)\nActual:   \(actual)",
                stackTrace: "at \(fullName)() in /home/vsts/work/1/s/tests/Storefront.Tests/Delivery/DeliveryEstimateTests.cs:line \(line)",
                duration: milliseconds / 1_000
            )
        }
        return [
            test(100_117, "EstimateSkipsWeekends", expected: "Monday", actual: "Saturday", line: 41, milliseconds: 14),
            test(100_118, "EstimateUsesTheWarehouseTimeZone", expected: "2 days", actual: "3 days", line: 67, milliseconds: 6),
        ]
    }
}
