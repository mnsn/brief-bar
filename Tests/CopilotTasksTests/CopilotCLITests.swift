import BriefBarCore
import Foundation
import Testing
@testable import CopilotTasks

@Suite struct LoginEnvironmentTests {
    /// Startup files can print anything before the environment; values can hold newlines and equals signs.
    @Test func readsTheVariablesAfterWhatStartupFilesPrint() {
        let output = Data("Welcome back!\n\0\(LoginEnvironment.marker)\0PATH=/opt/homebrew/bin:/usr/bin\0NOTE=a\nb=c\0=bad\0".utf8)
        #expect(LoginEnvironment.parse(output) == ["PATH": "/opt/homebrew/bin:/usr/bin", "NOTE": "a\nb=c"])
        #expect(LoginEnvironment.parse(Data("PATH=/usr/bin\0".utf8)) == nil)
    }

    @Test func asksAnInteractiveLoginShell() async {
        let runner = FakeRunner { _ in .ok("\0\(LoginEnvironment.marker)\0PATH=/custom/bin\0HOME=/Users/robin\0") }
        let environment = await LoginEnvironment.load(runner: runner, base: ["SHELL": "/bin/bash", "PATH": "/usr/bin"])
        #expect(environment == ["PATH": "/custom/bin", "HOME": "/Users/robin"])
        #expect(runner.arguments.first?.prefix(3) == ["-i", "-l", "-c"])
    }

    /// When the shell can't say, BriefBar's own environment, with the usual places on PATH.
    @Test func fallsBackToTheUsualPlaces() async {
        let runner = FakeRunner { _ in .failure("zsh: something broke", status: 1) }
        let environment = await LoginEnvironment.load(runner: runner, base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/robin"])
        #expect(environment["HOME"] == "/Users/robin")
        #expect(environment["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin")
    }

    /// When BriefBar is started as an app, whoever started it chose its environment: it doesn't get to steer Copilot.
    @Test func leavesOutCopilotsVariablesFromWhoeverStartedBriefBar() {
        let environment = ["PATH": "/usr/bin", "COPILOT_HOME": "/elsewhere", "COPILOT_ALLOW_ALL": "true", "HOME": "/Users/robin"]
        #expect(LoginEnvironment.base(environment, attribution: .itself) == ["PATH": "/usr/bin", "HOME": "/Users/robin"])
        #expect(LoginEnvironment.base(environment, attribution: .caller) == environment)
    }

    @Test func findsProgramsOnPathInOrder() {
        let home = URL(fileURLWithPath: "/Users/robin")
        let executables: Set<String> = ["/second/copilot", "/Users/robin/.dotnet/tools/copilot"]
        let environment = ["PATH": "/first:/second:~/.dotnet/tools"]
        #expect(LoginEnvironment.which("copilot", in: environment, home: home) { executables.contains($0) }?.path == "/second/copilot")
        #expect(LoginEnvironment.which("copilot", in: ["PATH": "~/.dotnet/tools"], home: home) { executables.contains($0) }?.path
                == "/Users/robin/.dotnet/tools/copilot")
        #expect(LoginEnvironment.which("git", in: environment, home: home) { executables.contains($0) } == nil)
    }

    /// Your home folder as the user database names it, never one that whoever starts BriefBar chose.
    @Test func expandsAndAbbreviatesYourHomeFolder() {
        let home = URL(fileURLWithPath: "/Users/robin")
        #expect(UserPath.expand("~", home: home) == "/Users/robin")
        #expect(UserPath.expand("~/dev/repos", home: home) == "/Users/robin/dev/repos")
        #expect(UserPath.expand("~sam/dev", home: home) == "~sam/dev")
        #expect(UserPath.expand("/opt/homebrew/bin", home: home) == "/opt/homebrew/bin")
        #expect(UserPath.abbreviate("/Users/robin/dev/repos", home: home) == "~/dev/repos")
        #expect(UserPath.abbreviate("/Users/robin", home: home) == "~")
        #expect(UserPath.abbreviate("/Users/robinson/dev", home: home) == "/Users/robinson/dev")
    }
}

@Suite struct CopilotCLITests {
    let home = URL(fileURLWithPath: "/Users/robin")

    @Test func prefersTheOverrideThenPathThenTheUsualPlacesThenTheApps() {
        let app = "/Users/robin/Library/Caches/github-copilot-sdk/cli"
        var executables: Set<String> = [
            "/custom/copilot", "/path/copilot", "/opt/homebrew/bin/copilot", "\(app)/1.0.99-2/copilot", "\(app)/1.0.100-0/copilot",
        ]
        func locate(_ overrides: [String: String] = [:]) -> String? {
            CopilotCLI.locate(
                environment: ["PATH": "/path"], overrides: overrides, home: home, isExecutable: { executables.contains($0) },
                appVersions: { $0.path == app ? ["1.0.99-2", "1.0.100-0", "notes.txt"] : [] }
            )?.path
        }
        #expect(locate([CopilotCLI.overrideVariable: "/custom/copilot"]) == "/custom/copilot")
        #expect(locate() == "/path/copilot")
        executables.remove("/path/copilot")
        #expect(locate() == "/opt/homebrew/bin/copilot")
        executables.remove("/opt/homebrew/bin/copilot")
        #expect(locate() == "\(app)/1.0.100-0/copilot")
        executables = []
        #expect(locate() == nil)
    }

    @Test func keepsItsSessionsInCopilotHome() {
        #expect(CopilotCLI.home(environment: [:], userHome: home).path == "/Users/robin/.copilot")
        #expect(CopilotCLI.home(environment: ["COPILOT_HOME": "/data/copilot"], userHome: home).path == "/data/copilot")
    }

    /// Copilot's config allows comments.
    @Test func readsTrustedFoldersFromItsConfig() {
        let config = Data("""
            // User settings belong in settings.json.
            {
              "trustedFolders": ["~/dev/repos", "/work"],
              "theme": "dark"
            }
            """.utf8)
        #expect(CopilotCLI.trustedFolders(config: config) == ["~/dev/repos", "/work"])
        #expect(CopilotCLI.trustedFolders(config: Data("not json".utf8)) == [])
    }

    @Test func trustsAFolderInsideATrustedOne() {
        let trusted = ["~/dev/repos", "/work/"]
        #expect(CopilotCLI.isTrusted(URL(fileURLWithPath: "/Users/robin/dev/repos/Storefront"), trusted: trusted, home: home))
        #expect(CopilotCLI.isTrusted(URL(fileURLWithPath: "/Users/robin/dev/repos"), trusted: trusted, home: home))
        #expect(CopilotCLI.isTrusted(URL(fileURLWithPath: "/work/web"), trusted: trusted, home: home))
        #expect(!CopilotCLI.isTrusted(URL(fileURLWithPath: "/Users/robin/dev/repos-old/Storefront"), trusted: trusted, home: home))
        #expect(!CopilotCLI.isTrusted(URL(fileURLWithPath: "/Users/robin/dev"), trusted: trusted, home: home))
    }
}
