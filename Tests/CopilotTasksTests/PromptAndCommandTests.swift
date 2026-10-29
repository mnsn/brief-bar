import Foundation
import Testing
@testable import CopilotTasks

@Suite struct PromptTemplateTests {
    @Test func fillsInTheWorkItem() {
        let prompt = PromptTemplate.render("Fix {type} {id}: {title} ({url}) in {organization}/{project}", item: sampleItem)
        #expect(prompt == "Fix Task 4217: Show the order total in the cart (https://dev.azure.com/contoso/Storefront/_workitems/edit/4217) in contoso/Storefront")
    }

    /// The composer shows the prompt before the repository says which branch the work starts from.
    @Test func leavesTheBaseBranchUntilTheRepositorySays() {
        let shown = PromptTemplate.render("{id} into {baseBranch}", item: sampleItem)
        #expect(shown == "4217 into {baseBranch}")
        #expect(PromptTemplate.render(shown, baseBranch: "main") == "4217 into main")
        #expect(PromptTemplate.render("{id} into {baseBranch}", item: sampleItem, baseBranch: "develop") == "4217 into develop")
    }

    /// A title is filled in once, as it is: its braces aren't placeholders.
    @Test func keepsBracesInValuesAndUnknownPlaceholders() {
        var item = sampleItem
        item.title = "Rename {id} to {key}"
        #expect(PromptTemplate.render("{title} {nope} {", item: item) == "Rename {id} to {key} {nope} {")
    }

    @Test func theStandardPromptAsksForAPublishedPullRequestLinkedToTheWorkItem() {
        let prompt = PromptTemplate.render(PromptTemplate.standard, item: sampleItem, baseBranch: "main")
        #expect(prompt.hasPrefix("Fix Azure DevOps Task 4217: Show the order total in the cart\nhttps://dev.azure.com/"))
        #expect(prompt.contains("detached at origin/main"))
        #expect(prompt.contains("published, ready for review, and linked to work item 4217"))
        #expect(!prompt.contains("{"))
    }
}

@Suite struct CopilotCommandTests {
    @Test func runsOnItsOwnWithTheChosenModelAndSession() {
        let arguments = CopilotCommand.arguments(
            prompt: "Fix it", options: CopilotRunOptions(model: "claude-opus-5.5", effort: "max"), sessionId: "abc",
            name: "Task 1: Fix it", directory: URL(fileURLWithPath: "/tmp/wt")
        )
        #expect(arguments == [
            "-p", "Fix it", "--model", "claude-opus-5.5", "--reasoning-effort", "max",
            "--autopilot", "--allow-all-tools", "--no-ask-user",
            "--session-id", "abc", "--name", "Task 1: Fix it", "-C", "/tmp/wt", "--silent",
        ])
    }

    @Test func leavesTheEffortToTheModel() {
        let arguments = CopilotCommand.arguments(
            prompt: "p", options: CopilotRunOptions(model: "auto", effort: nil), sessionId: "s", name: "n",
            directory: URL(fileURLWithPath: "/w")
        )
        #expect(!arguments.contains("--reasoning-effort"))
    }

    /// The CLI refuses `--trust-folder` with `--session-id`, which every run has, and won't start.
    @Test func neverAsksToTrustTheFolder() {
        let arguments = CopilotCommand.arguments(
            prompt: "p", options: CopilotModel.standard, sessionId: "s", name: nil, directory: URL(fileURLWithPath: "/w"),
            denied: ["shell(git push)"]
        )
        #expect(arguments.contains("--session-id"))
        #expect(!arguments.contains("--trust-folder"))
    }

    @Test func namesTheSessionAfterTheWorkItemShortly() {
        #expect(CopilotCommand.sessionName(for: sampleItem) == "Task 4217: Show the order total in the cart")
        var long = sampleItem
        long.title = String(repeating: "a", count: 200)
        let name = CopilotCommand.sessionName(for: long)
        #expect(name.count == 80)
        #expect(name.hasSuffix("…"))
    }

    @Test func resumesInTerminalWithEveryPathQuoted() {
        let script = CopilotCommand.resumeScript(
            copilot: URL(fileURLWithPath: "/opt/homebrew/bin/copilot"), sessionId: "abc",
            directory: URL(fileURLWithPath: "/Users/robin/Robin's Repos/wi-1"), workItem: 1
        )
        #expect(script.hasPrefix("#!/bin/zsh -l\n"))
        #expect(script.hasSuffix("cd '/Users/robin/Robin'\\''s Repos/wi-1' && exec '/opt/homebrew/bin/copilot' --resume 'abc'"))
        #expect(script.contains("# Opened by BriefBar: Copilot's session for work item 1, to go on with it.\n"))

        let own = CopilotCommand.resumeScript(
            copilot: URL(fileURLWithPath: "/opt/homebrew/bin/copilot"), sessionId: "abc", directory: URL(fileURLWithPath: "/Users/robin/shop"),
            home: URL(fileURLWithPath: "/Users/robin/.copilot"), file: URL(fileURLWithPath: "/Users/robin/Library/Caches/x/Copilot session abc.command")
        )
        #expect(own == """
            #!/bin/zsh -l
            # Opened by BriefBar: a Copilot CLI session, to go on with it.
            /bin/rm -f -- '/Users/robin/Library/Caches/x/Copilot session abc.command'
            cd '/Users/robin/shop' && COPILOT_HOME='/Users/robin/.copilot' exec '/opt/homebrew/bin/copilot' --resume 'abc'
            """)
    }

    @Test func titlesOptionsByTheirNames() {
        #expect(CopilotModel.standard.title == "Claude Opus 5.5 · Max")
        #expect(CopilotRunOptions(model: "gpt-6.1-sol", effort: "xhigh").title == "GPT-6.1 Sol · Extra High")
        #expect(CopilotRunOptions(model: "my-model", effort: nil).title == "my-model")
    }
}
