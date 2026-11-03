import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// Made-up directories' IDs: yours, and another you're a guest in.
private enum Directories {
    static let yours = "0a0a0a0a-1111-4111-8111-111111111111"
    static let other = "0b0b0b0b-2222-4222-8222-222222222222"
}

/// A made-up Azure CLI, signed in as you, from your directory, there and in another one, the default of which `az login
/// --tenant` changes. Its tokens are unsigned, with only what BriefBar reads from them.
private final class FakeCLI: ProcessRunning, Sendable {
    private let defaultTenant: Mutex<String>
    private let runs = Mutex<[[String]]>([])

    init(defaultTenant: String) {
        self.defaultTenant = Mutex(defaultTenant)
    }

    /// The directory each run asked for with `--tenant`: nil for none, the default.
    var asked: [String?] {
        runs.withLock { $0.map { arguments in arguments.firstIndex(of: "--tenant").map { arguments[$0 + 1] } } }
    }

    func signIn(to tenant: String) {
        defaultTenant.withLock { $0 = tenant }
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        runs.withLock { $0.append(arguments) }
        let tenant = arguments.firstIndex(of: "--tenant").map { arguments[$0 + 1] } ?? defaultTenant.withLock { $0 }
        // You, from your directory: elsewhere, your guest account, which names yours.
        let claims = tenant == Directories.yours
            ? #"{"tid":"\#(tenant)","oid":"robin"}"#
            : #"{"tid":"\#(tenant)","oid":"robin-guest","idp":"https://sts.windows.net/\#(Directories.yours)/"}"#
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = ["e30", payload, "c2ln"].joined(separator: ".")
        return ProcessResult(status: 0, stdout: Data(#"{"accessToken": "\#(token)", "expires_on": 4102444800}"#.utf8))
    }
}

/// Your sign-in's directory, and where the account BriefBar reads with is from, kept for after a restart: whichever section
/// read with your sign-in's token, and gone with what that account has seen when Azure DevOps is turned off.
@MainActor
@Suite struct AccountOriginTests {
    private static let tenant = Directories.yours
    private static let other = Directories.other
    private static let locator = AzureCLILocator(environment: [:], candidates: ["/bin/az"], useLoginShell: false, isExecutable: { _ in true })

    @Test func turningAzureDevOpsOffForgetsWhereYourAccountIsFrom() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.accountOrigin = Self.tenant
        settings.accountDirectory = Self.tenant
        #expect(defaults.string(forKey: SettingsKey.accountOrigin) == Self.tenant)
        #expect(defaults.string(forKey: SettingsKey.accountDirectory) == Self.tenant)
        settings.forgetSeen()
        #expect(settings.accountOrigin == nil)
        #expect(settings.accountDirectory == nil)
        #expect(defaults.string(forKey: SettingsKey.accountOrigin) == nil)
        #expect(defaults.string(forKey: SettingsKey.accountDirectory) == nil)
    }

    @Test func aReadArrivingAfterAzureDevOpsIsTurnedOffSavesNothing() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = PRStore(settings: settings, mode: .live)
        // Turned off: the source stops the store, then deletes what was saved.
        store.stop()
        settings.forgetSeen()
        // The engine's last read, queued before it stopped, arrives after, with who's signed in.
        store.receive(PulseSnapshot(account: "\(Self.tenant)/robin", hasLoaded: true))
        #expect(settings.seen.account == nil)
        #expect(defaults.data(forKey: SettingsKey.seen) == nil)
        #expect(defaults.string(forKey: SettingsKey.accountOrigin) == nil)
    }

    @Test func yourDirectoryIsKeptWhicheverSectionReadAndPinnedAfterARestart() async throws {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        let cli = FakeCLI(defaultTenant: Self.tenant)
        let tokens = AzureDevOpsCommandLine.tokens(defaults, runner: cli, locator: Self.locator)
        let store = PRStore(settings: settings, mode: .live, tokens: tokens)
        // Only the pipelines or the sprint read, with your sign-in's token: no pull requests, so nothing they've seen.
        #expect(try await tokens.token().tenant == Self.tenant)
        await store.keepSignIn()
        #expect(settings.seen.account == nil)
        #expect(settings.accountDirectory == Self.tenant)
        #expect(settings.accountOrigin == Self.tenant)

        // You sign in to another directory for an organization there, which makes it the Azure CLI's default, and BriefBar
        // restarts: it still asks for your tokens in yours, rather than reading as your guest account there.
        cli.signIn(to: Self.other)
        store.stop()
        #expect(settings.pinnedDirectory == Self.tenant)
        let restarted = AzureDevOpsCommandLine.tokens(defaults, runner: cli, locator: Self.locator)
        #expect(try await restarted.token().tenant == Self.tenant)
        #expect(cli.asked == [nil, Self.tenant])
    }
}
