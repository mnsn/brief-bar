import Foundation
import Testing
@testable import AzureDevOpsCore

/// Made-up timeline records with what investigating a build reads of them.
enum InvestigationFixture {
    static func record(
        _ id: String, _ type: String, _ name: String, parent: String? = nil, order: Int? = nil, state: String = "completed",
        result: String? = "succeeded", identifier: String? = nil, started: Date? = nil, finished: Date? = nil, attempt: Int? = nil,
        log: Int? = nil, errorCount: Int? = nil, warningCount: Int? = nil, issues: [[String: Any]] = []
    ) -> [String: Any] {
        var json = WorkFixture.record(
            id, type, name, parent: parent, order: order, state: state, result: result, identifier: identifier, finished: finished,
            issues: issues
        )
        if let started { json["startTime"] = iso(started) }
        if let attempt { json["attempt"] = attempt }
        if let log { json["log"] = ["id": log, "type": "Container", "url": "https://example.invalid"] }
        if let errorCount { json["errorCount"] = errorCount }
        if let warningCount { json["warningCount"] = warningCount }
        return json
    }

    static func issue(_ type: String, _ message: String, data: [String: Any]? = nil) -> [String: Any] {
        var json: [String: Any] = ["type": type, "category": "General", "message": message]
        if let data { json["data"] = data }
        return json
    }

    static func timeline(_ records: [[String: Any]]) throws -> ADOTimeline {
        try Fixture.decode(ADOTimeline.self, WorkFixture.timeline(records))
    }

    static func run(_ id: Int = 77, status: PipelineRun.Status = .failed, number: String = "20261018.7", branch: String = "!7") -> PipelineRun {
        PipelineRun(
            id: id, organization: Fixture.org, projectName: "Shop", number: number, status: status, trigger: .pullRequest, branch: branch,
            queuedAt: t(-hour), startedAt: t(-hour), finishedAt: t(-50 * minute)
        )
    }

    static let pipeline = PipelineRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", definitionId: 31, name: "shop-web CI")
}

@Suite struct BuildInvestigationTests {
    private typealias F = InvestigationFixture

    @Test func readsWhatTheTimelineSaysOfEachStep() throws {
        let timeline = try F.timeline([
            F.record("task", "Task", "Build", attempt: 2, log: 12, errorCount: 3, warningCount: 1, issues: [
                F.issue("error", "Build failed", data: [
                    "type": "error", "sourcepath": "src\\Cart.cs", "linenumber": 41, "columnnumber": "5", "flag": true,
                    "nested": ["a": 1], "none": NSNull(),
                ]),
                F.issue("warning", "Without data"),
            ]),
            ["id": "bare", "log": "not a log", "attempt": "second"],
        ])
        let records = timeline.records.elements
        #expect(records.count == 2)
        let task = records[0]
        #expect(task.attempt == 2)
        #expect(task.log?.id == 12)
        #expect(task.errorCount == 3)
        #expect(task.warningCount == 1)
        let issues = task.issues?.elements ?? []
        #expect(issues.count == 2)
        let data = try #require(issues.first).data
        #expect(data["sourcepath"] == "src\\Cart.cs")
        // A number is kept as a string, and a key is found whatever its letter case.
        #expect(data["linenumber"] == "41")
        #expect(data["LineNumber"] == "41")
        #expect(data["flag"] == "true")
        #expect(data["nested"] == nil)
        #expect(data["none"] == nil)
        #expect(issues.last?.data.values.isEmpty == true)
        let bare = records[1]
        #expect(bare.attempt == nil)
        #expect(bare.log == nil)
        #expect(bare.errorCount == nil)
        #expect(bare.issues == nil)
    }

    @Test func buildsTheStepsFromStagesToJobsToTasks() throws {
        let timeline = try F.timeline([
            F.record("deploy", "Stage", "Deploy", order: 3, state: "pending", result: nil),
            F.record("build", "Stage", "Build", order: 1, started: t(-10 * minute), finished: t(-8 * minute)),
            F.record("test", "Stage", "Test", order: 2, result: "failed"),
            F.record("build-phase", "Phase", "Build", parent: "build", order: 1),
            F.record("build-job", "Job", "Build", parent: "build-phase", order: 1, log: 3),
            F.record("compile", "Task", "Compile", parent: "build-job", order: 2, log: 5),
            F.record("checkout", "Task", "Checkout", parent: "build-job", order: 1, log: 4),
            F.record("test-phase", "Phase", "Unit tests", parent: "test", order: 1, result: "failed"),
            F.record("linux", "Job", "Unit tests Linux", parent: "test-phase", order: 1, result: "failed", attempt: 2),
            F.record("mac", "Job", "Unit tests macOS", parent: "test-phase", order: 2),
            F.record("run", "Task", "Run tests", parent: "linux", order: 1, result: "failed", errorCount: 4,
                     issues: [F.issue("error", "2 tests failed"), F.issue("warning", "Slow test")]),
            F.record("deploy-phase", "Phase", "Deploy", parent: "deploy", order: 1, state: "pending", result: nil),
            F.record("approval", "Checkpoint", "Checkpoint", parent: "deploy", state: "inProgress", result: nil),
        ])
        let steps = BuildStep.tree(from: timeline, runFinished: false)
        #expect(steps.map(\.name) == ["Build", "Test", "Deploy"])
        #expect(steps.allSatisfy { $0.kind == .stage })
        #expect(steps.map(\.state) == [.succeeded, .failed, .waiting])
        #expect(steps[0].startedAt == t(-10 * minute))
        #expect(steps[0].finishedAt == t(-8 * minute))
        #expect(steps[0].duration(now: t(0)) == 2 * minute)
        // The phase's job, then its tasks, in order.
        #expect(steps[0].steps.map(\.name) == ["Build"])
        #expect(steps[0].steps[0].kind == .job)
        #expect(steps[0].steps[0].logId == 3)
        #expect(steps[0].steps[0].steps.map(\.name) == ["Checkout", "Compile"])
        #expect(steps[0].steps[0].steps.map(\.logId) == [4, 5])
        #expect(steps[0].steps[0].steps.allSatisfy { $0.kind == .task && $0.steps.isEmpty && $0.attempt == 1 })
        // A phase that runs several jobs shows them all.
        #expect(steps[1].steps.map(\.name) == ["Unit tests Linux", "Unit tests macOS"])
        #expect(steps[1].steps.map(\.state) == [.failed, .succeeded])
        #expect(steps[1].steps[0].attempt == 2)
        let run = steps[1].steps[0].steps[0]
        #expect(run.issues.map(\.message) == ["2 tests failed", "Slow test"])
        #expect(run.errorCount == 4)
        #expect(run.warningCount == 1)
        // A phase without jobs yet stands for them.
        #expect(steps[2].steps.map(\.name) == ["Deploy"])
        #expect(steps[2].steps[0].kind == .job)
        #expect(steps[2].steps[0].state == .pending)
        #expect(steps[2].steps[0].steps.isEmpty)
        // Once the run has finished, what never ran was skipped.
        let finished = BuildStep.tree(from: timeline, runFinished: true)
        #expect(finished[2].state == .skipped)
        #expect(finished[2].steps[0].state == .skipped)
    }

    @Test func aPipelineWithoutStagesHasItsJobsAtTheTop() throws {
        let hidden = try F.timeline([
            F.record("default", "Stage", "__default", identifier: "__default"),
            F.record("phase", "Phase", "Job", parent: "default"),
            F.record("job", "Job", "Job", parent: "phase"),
            F.record("task", "Task", "Script", parent: "job"),
        ])
        let steps = BuildStep.tree(from: hidden, runFinished: true)
        #expect(steps.map(\.kind) == [.job])
        #expect(steps[0].steps.map(\.name) == ["Script"])
        let classic = try F.timeline([
            F.record("lone", "Job", "Lone job", order: 2),
            F.record("phase", "Phase", "Agent job 1", order: 1),
            F.record("job", "Job", "Agent job 1", parent: "phase"),
            F.record("task", "Task", "Build solution", parent: "job"),
            ["id": "nameless", "type": "Job", "parentId": NSNull()],
        ])
        #expect(BuildStep.tree(from: classic, runFinished: true).map(\.name) == ["Agent job 1", "Lone job", "Job"])
        #expect(BuildStep.tree(from: try F.timeline([]), runFinished: true).isEmpty)
    }

    @Test func anIssueSaysItsFileAndLine() throws {
        func issue(_ message: String, _ data: [String: Any]? = nil, type: String = "error") throws -> BuildIssue? {
            let record = try #require(try F.timeline([F.record("task", "Task", "Build", issues: [F.issue(type, message, data: data)])])
                .records.elements.first)
            return BuildIssue.issues(of: record).first
        }
        let compiled = try #require(try issue("; expected", [
            "sourcepath": "D:\\a\\1\\s\\src\\Cart.cs", "linenumber": "41", "columnnumber": "5", "code": "CS1002", "logFileLineNumber": "88",
        ]))
        #expect(compiled.kind == .error)
        #expect(compiled.file == "src/Cart.cs")
        #expect(compiled.line == 41)
        #expect(compiled.column == 5)
        #expect(compiled.code == "CS1002")
        #expect(compiled.logLine == 88)
        #expect(compiled.stepId == "task")
        #expect(compiled.step == "Build")
        // 0 is how the agent says it doesn't know.
        let restored = try #require(try issue("Detected package downgrade", [
            "sourcepath": "src\\Shop\\Shop.csproj", "linenumber": "0", "columnnumber": "0", "code": " ",
        ], type: "warning"))
        #expect(restored.kind == .warning)
        #expect(restored.file == "src/Shop/Shop.csproj")
        #expect(restored.line == nil)
        #expect(restored.column == nil)
        #expect(restored.code == nil)
        // The issue's data says where it is before its message does.
        #expect(try issue("other/File.cs(1,1): error X1: no", ["sourcepath": "/home/vsts/work/1/s/src/Cart.cs"])?.file == "src/Cart.cs")

        // Without a file in its data, its message says, as compilers write it.
        func place(_ message: String) throws -> [String] {
            guard let issue = try issue(message) else { return ["no issue"] }
            return [issue.file ?? "-", issue.line.map(String.init) ?? "-", issue.column.map(String.init) ?? "-"]
        }
        #expect(try place("/home/vsts/work/1/s/src/Cart.cs(41,5): error CS1002: ; expected [/home/vsts/work/1/s/src/Shop.csproj]")
            == ["src/Cart.cs", "41", "5"])
        #expect(try place("C:\\a\\1\\s\\src\\Cart.cs(41): warning CS0168: The variable 'e' is declared but never used")
            == ["src/Cart.cs", "41", "-"])
        #expect(try place("3>src/app.ts(12,5,12,9): error TS2322: Type 'string' is not assignable to type 'number'.")
            == ["src/app.ts", "12", "5"])
        #expect(try place("/Users/runner/work/1/s/Sources/Cart.swift:41:5: error: cannot find 'total' in scope")
            == ["Sources/Cart.swift", "41", "5"])
        #expect(try place("src/main.c:7: fatal error: cart.h: No such file or directory") == ["src/main.c", "7", "-"])
        #expect(try place("C:\\a\\1\\s\\src\\Cart.cpp:41:5: error: use of undeclared identifier 'total'") == ["src/Cart.cpp", "41", "5"])
        #expect(try place("D:/a/1/s/src/Cart.cpp:41: warning: unused variable 'e'") == ["src/Cart.cpp", "41", "-"])
        #expect(try place("/usr/share/dotnet/sdk/8.0.100/Microsoft.Common.targets(2,3): warning MSB3277: Conflicts")
            == ["/usr/share/dotnet/sdk/8.0.100/Microsoft.Common.targets", "2", "3"])
        for nowhere in [
            "Bash exited with code '1'.", "Error: The process '/usr/bin/dotnet' failed with exit code 1", "Test Run Failed.",
            "Retrying in 5 seconds (attempt 2): error 503", "error: pathspec 'main' did not match",
        ] {
            #expect(try place(nowhere) == ["-", "-", "-"], "\(nowhere)")
        }

        // Its message is one line, as a terminal shows it, without the log's marker, and not too long.
        #expect(try issue("##[error]Build\n  failed")?.message == "Build failed")
        #expect(try issue("\u{1B}[31m##[error]Plan\u{1B}[0m failed:\r\n\u{1B}[1mresource\u{1B}[0m exists")?.message == "Plan failed: resource exists")
        #expect(try place("\u{1B}[31m/home/vsts/work/1/s/src/Cart.cs(41,5): error CS1002: ; expected\u{1B}[0m") == ["src/Cart.cs", "41", "5"])
        #expect(try issue(String(repeating: "x", count: 5_000))?.message.count == BuildIssue.messageLimit)
        // What's neither an error nor a warning, or says nothing, isn't an issue.
        #expect(try issue("Just so you know", type: "info") == nil)
        #expect(try issue("  ") == nil)
    }

    @Test func outputReadsAsATerminalShowsIt() {
        // Lines end at each line feed, whatever carriage returns come before it.
        #expect(PlainText.terminalLine("Build failed:\r\r\nsee log") == "Build failed: see log")
        #expect(PlainText.terminalLine("Build failed:\r\nsee log\n") == "Build failed: see log")
        #expect(PlainText.terminalLine("first\n\nsecond") == "first second")
        // A carriage return alone writes over the line, and the last that writes something shows.
        #expect(PlainText.terminalLine("Downloading 50%\rDownloading 100%\nDone") == "Downloading 100% Done")
        #expect(PlainText.terminalLine("Uploading\r   \r\u{1B}[K") == "Uploading")
        #expect(PlainText.terminal("text\r\n") == "text")
        #expect(PlainText.terminal("\r") == "")
        #expect(BuildLogLine(raw: "2026-10-18T10:00:00.1Z Restored\r\r", number: 1)?.text == "Restored")
        #expect(PipelineFailure.clean("##[error]Build failed:\r\r\nsee log") == "Build failed: see log")
    }

    @Test func whereARunFailedReadsAsATerminalShowsIt() throws {
        let timeline = try F.timeline([
            F.record("task", "Task", "Plan", result: "failed", finished: t(-minute),
                     issues: [F.issue("error", "\u{1B}[31m##[error]Plan failed:\u{1B}[0m\n  resource exists")]),
        ])
        #expect(PipelineFailure.first(in: timeline)?.message == "Plan failed: resource exists")
        #expect(PipelineFailure.errors(in: timeline) == ["Plan failed: resource exists"])
        #expect(PipelineFailure.clean("##[error]Plain\nmessage") == "Plain message")
    }

    @Test func errorsComeInTheOrderTheirStepsFinishedEachOnce() throws {
        let timeline = try F.timeline([
            F.record("late", "Task", "Late", result: "failed", finished: t(-minute),
                     issues: [F.issue("error", "Late failure"), F.issue("error", "Shared")]),
            F.record("early", "Task", "Early", result: "failed", finished: t(-hour),
                     issues: [F.issue("warning", "Just a warning"), F.issue("error", "Shared"), F.issue("error", "Early failure")]),
            F.record("continued", "Task", "Continued", result: "succeededWithIssues", finished: t(-2 * hour),
                     issues: [F.issue("error", "Logged, but it went on")]),
            F.record("fine", "Task", "Fine", finished: t(-3 * hour), issues: [F.issue("warning", "Only a warning")]),
        ])
        let errors = BuildIssue.errors(in: timeline, limit: 10)
        #expect(errors.map(\.message) == ["Logged, but it went on", "Shared", "Early failure", "Late failure"])
        #expect(errors.map(\.step) == ["Continued", "Early", "Early", "Late"])
        #expect(BuildIssue.errors(in: timeline, limit: 2).map(\.message) == ["Logged, but it went on", "Shared"])
    }

    @Test func aLogLineLosesItsTimestampColorsAndMarker() {
        func line(_ raw: String) -> BuildLogLine? {
            BuildLogLine(raw: raw, number: 7)
        }
        #expect(line("2026-10-18T10:00:00.1234567Z ##[error]Bash exited with code '1'.")
            == BuildLogLine(number: 7, kind: .error, text: "Bash exited with code '1'."))
        #expect(line("\u{FEFF}2026-10-18T10:00:00.1234567Z ##[section]Starting: Build")
            == BuildLogLine(number: 7, kind: .section, text: "Starting: Build"))
        #expect(line("2026-10-18T10:00:00Z ##[command]/usr/bin/dotnet test")
            == BuildLogLine(number: 7, kind: .command, text: "/usr/bin/dotnet test"))
        #expect(line("2026-10-18T10:00:00.1Z ##[group]Run tests")?.kind == .group)
        #expect(line("2026-10-18T10:00:00.1Z ##[endgroup]") == nil)
        #expect(line("##[warning]Deprecated")?.kind == .warning)
        #expect(line("##[debug]Evaluating: succeeded()")?.kind == .debug)
        #expect(line("##[ERROR]Shouting")?.kind == .error)
        #expect(line("##[made-up]Kept as it is") == BuildLogLine(number: 7, text: "##[made-up]Kept as it is"))
        #expect(line("2026-10-18 10:00:00 is when it ran") == BuildLogLine(number: 7, text: "2026-10-18 10:00:00 is when it ran"))
        // Colors, character sets, titles and links go, and so do other control characters, but tabs.
        #expect(line("2026-10-18T10:00:00.1Z \u{1B}[1;31mFailed\u{1B}[0m\tCartTests\u{1B}(B\u{1B}[m")?.text == "Failed\tCartTests")
        #expect(line("\u{1B}]0;title\u{07}Done \u{1B}]8;;https://example.invalid\u{1B}\\link\u{1B}]8;;\u{1B}\\")?.text == "Done link")
        #expect(line("bell\u{07} and \u{1B}7saved\u{1B}8 \u{9B}2Kcleared\u{7F}")?.text == "bell and saved cleared")
        #expect(line("\u{1B}]0;cut short\u{1B}[32mgreen")?.text == "green")
        #expect(line("##[error]\u{1B}[31mRed error\u{1B}[0m") == BuildLogLine(number: 7, kind: .error, text: "Red error"))
        #expect(line("\u{1B}[31m##[error]Colored marker") == BuildLogLine(number: 7, kind: .error, text: "Colored marker"))
        // What a carriage return wrote over doesn't show, and neither do trailing spaces.
        #expect(line("Downloading 10%\rDownloading 55%\rDownloading 100%   \r")?.text == "Downloading 100%")
        #expect(line("")?.text == "")
        let long = line(String(repeating: "x", count: 2_000))?.text ?? ""
        #expect(long.count == BuildLogLine.limit)
        #expect(long.hasSuffix("…"))
    }

    @Test func aLogsEndIsNumberedFromItsLastLine() {
        let raw = (101...300).map { "2026-10-18T10:00:00.0000000Z line \($0)" }
        let log = BuildLog(stepId: "task", logId: 4, lineCount: 300, lines: raw, keep: 200)
        #expect(log.lines.count == 200)
        #expect(log.lines.first == BuildLogLine(number: 101, text: "line 101"))
        #expect(log.lines.last == BuildLogLine(number: 300, text: "line 300"))
        #expect(log.lineCount == 300)
        #expect(log.isCut)
        // An answer with more than was asked for, such as the whole log, keeps its end, numbered the same.
        let whole = BuildLog(stepId: "task", logId: 4, lineCount: 300, lines: (1...300).map { "line \($0)" }, keep: 200)
        #expect(whole.lines == log.lines)
        // A log that grew since its line count was read still ends on its last line.
        #expect(BuildLog(stepId: "task", logId: 4, lineCount: 2, lines: ["a", "b", "c"], keep: 200).lines.map(\.number) == [1, 2, 3])
        // A short log is all there, and the ends of its groups leave gaps in the numbers, even at its start.
        let short = BuildLog(stepId: "task", logId: 4, lineCount: 3, lines: ["##[group]Setup", "##[endgroup]", "done"], keep: 200)
        #expect(short.lines.map(\.number) == [1, 3])
        #expect(!short.isCut)
        let grouped = BuildLog(stepId: "task", logId: 4, lineCount: 2, lines: ["##[endgroup]", "done"], keep: 200)
        #expect(grouped.lines.map(\.number) == [2])
        #expect(grouped.firstLine == 1)
        #expect(!grouped.isCut)
        #expect(BuildLog(stepId: "task", logId: 4, lineCount: 0, lines: [], keep: 200) == BuildLog(stepId: "task", logId: 4, lines: [], lineCount: 0))
    }

    @Test func testsAddUpAcrossTestRuns() throws {
        let runs = try Fixture.decode([ADOTestRun].self, [
            ["id": 1, "name": "Unit", "totalTests": 120, "passedTests": 110, "unanalyzedTests": 99, "runStatistics": [
                ["state": "Completed", "outcome": "Passed", "count": 110], ["state": "Completed", "outcome": "Failed", "count": 7],
                ["state": "Completed", "outcome": "Timeout", "count": 1], ["state": "Completed", "outcome": "NotExecuted", "count": 2],
                ["state": "Completed", "outcome": "failed"], "not a statistic",
            ]],
            // Without statistics, the failures nobody looked into are its failures.
            ["id": 2, "name": "Integration", "totalTests": 30, "passedTests": 28, "unanalyzedTests": 2],
            ["id": 3, "totalTests": "many"],
        ])
        #expect(runs.map { BuildTests.failed(in: $0) } == [8, 2, 0])
        let tests = BuildTests(runs: runs, failures: [])
        #expect(tests.total == 150)
        #expect(tests.passed == 138)
        #expect(tests.failed == 10)
        #expect(tests.other == 2)
        #expect(tests.runs == 3)
        #expect(tests.unlisted == 10)
    }

    @Test func aFailedTestSaysWhatFailed() throws {
        let run = try Fixture.decode(ADOTestRun.self, ["id": 7, "name": "  Unit tests  "])
        func test(_ json: [String: Any]) throws -> FailedTest {
            FailedTest(try Fixture.decode(ADOTestResult.self, json), run: run)
        }
        let failed = try test([
            "id": 100_001, "outcome": "Failed", "testRun": ["id": "7", "name": "Unit tests"],
            "automatedTestName": "Shop.Tests.CartTests.AddsTax(rate: 0.2, region: \"EU.West\")", "automatedTestStorage": "Shop.Tests.dll",
            "errorMessage": "\r\nAssert.Equal() Failure\r\nExpected: 12\r\n\u{1B}[31mActual:   10\u{1B}[0m  \r\n",
            "stackTrace": (1...40).map { "   at Frame\($0)()" }.joined(separator: "\n"), "durationInMs": 1_500.0,
            "failingSince": ["date": iso(t(-day)), "build": ["id": 41, "number": "20261017.2"]],
        ])
        #expect(failed.id == "7/100001")
        #expect(failed.name == "AddsTax(rate: 0.2, region: \"EU.West\")")
        #expect(failed.fullName == "Shop.Tests.CartTests.AddsTax(rate: 0.2, region: \"EU.West\")")
        #expect(failed.container == "Shop.Tests.dll")
        #expect(failed.run == "Unit tests")
        #expect(failed.outcome == "Failed")
        #expect(failed.message == "Assert.Equal() Failure\nExpected: 12\nActual:   10")
        let frames = failed.stackTrace?.split(separator: "\n") ?? []
        #expect(frames.count == FailedTest.stackTraceLines)
        #expect(frames.first == "   at Frame1()")
        #expect(failed.duration == 1.5)
        #expect(failed.failingSince == t(-day))
        #expect(failed.failingSinceBuildId == 41)
        // A title is its name; without anything, it still has one.
        #expect(try test(["id": 2, "testCaseTitle": "Adds tax", "automatedTestName": "Shop.Tests.CartTests.AddsTax"]).name == "Adds tax")
        #expect(try test(["id": 3, "automatedTestName": "AddsTax"]).name == "AddsTax")
        let bare = try test(["id": 4, "errorMessage": " \n ", "durationInMs": -1, "failingSince": ["build": ["id": "41"]]])
        #expect(bare.name == "Test 4")
        #expect(bare.outcome == "Failed")
        #expect(bare.message == nil)
        #expect(bare.stackTrace == nil)
        #expect(bare.duration == nil)
        #expect(bare.failingSince == nil)
        #expect(bare.failingSinceBuildId == nil)
        // Too much is cut.
        #expect(try test(["id": 5, "errorMessage": String(repeating: "x", count: 5_000)]).message?.count == FailedTest.messageLimit)
        #expect(try test(["id": 6, "stackTrace": String(repeating: "x", count: 5_000)]).stackTrace?.count == FailedTest.stackTraceLimit)
    }

    @Test func hintsSayWhetherItsTheChange() {
        let failed = F.run(77, status: .failed)
        let passed = F.run(1, status: .succeeded, number: "20261018.1")
        let failedOnMain = F.run(2, status: .failed, number: "20261018.2", branch: "main")
        let passedOnMain = F.run(3, status: .succeeded, branch: "main")
        let withIssues = F.run(4, status: .partiallySucceeded, branch: "main")
        let canceled = F.run(5, status: .canceled, branch: "main")
        #expect(BuildComparison(revision: .current, targetBranch: "main").hints(for: failed).isEmpty)
        #expect(BuildComparison(revision: .unknown, targetBranch: "main", targetRun: canceled).hints(for: failed).isEmpty)
        let sameCode = BuildComparison.EarlierPass(run: passed, builtTheSame: true)
        let all = BuildComparison(revision: .outdated, targetBranch: "main", targetRun: failedOnMain, earlierPass: sameCode)
        #expect(all.hints(for: failed) == [.olderCommit, .passedBefore(passed), .targetFails(branch: "main", run: failedOnMain)])
        #expect(all.hints(for: failed).map(\.sentence) == [
            "It built an older commit than the pull request's latest.",
            "It passed on the same commit in 20261018.1: it may be flaky.",
            "main's latest run failed too: it may not be this change.",
        ])
        // A pass on the pull request's same commit, merged into main before main changed, built other code: not flaky.
        let beforeMainChanged = BuildComparison(
            revision: .current, targetBranch: "main", targetRun: passedOnMain,
            earlierPass: BuildComparison.EarlierPass(run: passed, builtTheSame: false)
        )
        #expect(beforeMainChanged.hints(for: failed).map(\.sentence) == [
            "It passed on this commit in 20261018.1, before main changed.", "main's latest run passed.",
        ])
        #expect(BuildComparison(revision: .current, targetBranch: "main", targetRun: withIssues).hints(for: failed)
            == [.targetPasses(branch: "main", run: withIssues)])
        // A run that's running again, or passed since, has no failure to explain: only that it built an older commit.
        for now in [F.run(77, status: .running), F.run(77, status: .succeeded), F.run(77, status: .queued)] {
            #expect(all.hints(for: now) == [.olderCommit])
            #expect(beforeMainChanged.hints(for: now).isEmpty)
        }
        let investigation = BuildInvestigation(pipeline: F.pipeline, run: failed, comparison: all, readAt: t(0))
        #expect(investigation.hints == all.hints(for: failed))
    }

    @Test func anEarlierPassIsOnTheSameCommit() throws {
        func build(
            _ id: Int, result: String = "succeeded", queued: Date, source: String? = "abc", merge: String? = "m1", definition: Int = 31,
            branch: String = "refs/pull/7/merge"
        ) throws -> ADOBuild {
            var json = WorkFixture.build(id, definition: definition, result: result, queued: queued, branch: branch, reason: "pullRequest")
            if let source { json["triggerInfo"] = ["pr.sourceSha": source] }
            if let merge { json["sourceVersion"] = merge }
            return try Fixture.decode(ADOBuild.self, json)
        }
        let failed = try build(10, result: "failed", queued: t(-hour))
        func pass(among runs: [ADOBuild]) -> String? {
            BuildComparison.earlierPass(of: failed, among: runs).map { "\($0.build.id)\($0.builtTheSame ? " the same" : " before")" }
        }
        // The latest that built the very same commit, the same merge.
        #expect(try pass(among: [build(5, queued: t(-3 * hour)), build(6, queued: t(-2 * hour)), build(4, queued: t(-4 * hour))])
            == "6 the same")
        #expect(try pass(among: [build(6, queued: t(-2 * hour), source: nil, merge: "M1")]) == "6 the same")
        // Without one, the latest that built the pull request's same commit, merged before the target branch changed.
        #expect(try pass(among: [build(6, queued: t(-2 * hour), source: "ABC", merge: "other")]) == "6 before")
        #expect(try pass(among: [build(7, queued: t(-90 * minute), source: "abc", merge: "other"), build(6, queued: t(-2 * hour))])
            == "6 the same")
        // Not another commit, a later run, one that didn't pass, another pipeline's, another branch's, or itself.
        #expect(try pass(among: [build(6, queued: t(-2 * hour), source: "def", merge: "m2")]) == nil)
        #expect(try pass(among: [build(11, queued: t(-minute))]) == nil)
        #expect(try pass(among: [build(6, result: "failed", queued: t(-2 * hour))]) == nil)
        #expect(try pass(among: [build(6, result: "partiallySucceeded", queued: t(-2 * hour))]) == nil)
        #expect(try pass(among: [build(6, queued: t(-2 * hour), definition: 32)]) == nil)
        #expect(try pass(among: [build(6, queued: t(-2 * hour), branch: "refs/pull/8/merge")]) == nil)
        #expect(pass(among: [failed]) == nil)
        // Queued at the same time, the one with the lower ID came first.
        #expect(try pass(among: [build(9, queued: t(-hour)), build(12, queued: t(-hour))]) == "9 the same")
        // Without its commits, nothing's the same.
        let unknown = try build(12, result: "failed", queued: t(-hour), source: nil, merge: nil)
        #expect(try BuildComparison.earlierPass(of: unknown, among: [build(6, queued: t(-2 * hour), source: nil, merge: nil)]) == nil)
    }

    @Test func findsAStepAndItsLogOnTheRunsPage() throws {
        let timeline = try F.timeline([
            F.record("s1", "Stage", "Test", result: "failed"),
            F.record("p1", "Phase", "Unit tests", parent: "s1"),
            F.record("j1", "Job", "Unit tests", parent: "p1", result: "failed"),
            F.record("t1", "Task", "Run tests", parent: "j1", result: "failed"),
        ])
        let investigation = BuildInvestigation(
            pipeline: F.pipeline, run: F.run(), steps: BuildStep.tree(from: timeline, runFinished: true), failedStepId: "t1",
            comparison: BuildComparison(revision: .current, targetBranch: "main"), readAt: t(0)
        )
        #expect(investigation.failedStep?.name == "Run tests")
        #expect(investigation.path(to: "t1").map(\.id) == ["s1", "j1", "t1"])
        #expect(investigation.allSteps.map(\.id) == ["s1", "j1", "t1"])
        #expect(investigation.step("p1") == nil)
        #expect(investigation.path(to: "nowhere").isEmpty)
        func query(_ url: URL) -> [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
        #expect(investigation.logPage(for: "t1").path == "/contoso/Shop/_build/results")
        #expect(query(investigation.logPage(for: "t1")) == ["buildId": "77", "view": "logs", "j": "j1", "t": "t1"])
        #expect(query(investigation.logPage(for: "j1")) == ["buildId": "77", "view": "logs", "j": "j1"])
        #expect(query(investigation.logPage(for: "s1")) == ["buildId": "77", "view": "logs", "s": "s1"])
        #expect(query(investigation.logPage(for: "nowhere")) == ["buildId": "77", "view": "logs"])
    }
}
