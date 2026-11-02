import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// A made-up Microsoft Entra token for a directory, unsigned: only what BriefBar reads from it. A guest's names where
/// its account is from in `idp`: another directory, or an identity provider such as live.com.
private func madeUpToken(tenant: String, object: String = "robin", guestFrom home: String? = nil) -> String {
    func encoded(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let idp = home.map { UUID(uuidString: $0) == nil ? $0 : "https://sts.windows.net/\($0)/" }.map { #","idp":"\#($0)""# } ?? ""
    return [encoded(#"{"alg":"none"}"#), encoded(#"{"tid":"\#(tenant)","oid":"\#(object)"\#(idp)}"#), "c2ln"].joined(separator: ".")
}

/// Holds one of the Azure CLI's runs for a directory, the first unless said, until let go, with the token it had when
/// asked: someone else may sign in meanwhile.
actor HeldDirectory {
    private let tenant: String
    private let run: Int
    private var runs = 0
    private var held: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false

    init(_ tenant: String, run: Int = 1) {
        self.tenant = tenant
        self.run = run
    }

    func hold(_ asked: String) async {
        guard asked == tenant else { return }
        runs += 1
        guard runs == run else { return }
        isHolding = true
        await withCheckedContinuation { held = $0 }
    }

    func release() {
        held?.resume()
        held = nil
        isHolding = false
    }
}

/// A made-up Azure CLI, signed in as an account from one directory, to some directories, one of them its default, as
/// `az login --tenant` leaves it.
final class FakeAzureCLI: ProcessRunning, Sendable {
    private struct State {
        var defaultTenant: String
        var signedIn: Set<String>
        /// The directory the signed-in account is from: elsewhere, it's a guest.
        var accountTenant: String
        /// Who's signed in, as the tokens' object IDs name them.
        var object = "robin"
        var runs: [[String]] = []
    }

    private let state: Mutex<State>
    private let held: HeldDirectory?

    init(defaultTenant: String, signedIn: Set<String>, accountFrom accountTenant: String? = nil, held: HeldDirectory? = nil) {
        state = Mutex(State(defaultTenant: defaultTenant, signedIn: signedIn, accountTenant: accountTenant ?? defaultTenant))
        self.held = held
    }

    /// The directory each run asked for with `--tenant`: nil for none, the default.
    var asked: [String?] {
        state.withLock { state in
            state.runs.map { arguments in arguments.firstIndex(of: "--tenant").map { arguments[$0 + 1] } }
        }
    }

    /// `az login --tenant`: signed in there too, which becomes the default.
    func signIn(to tenant: String) {
        state.withLock { state in
            state.signedIn.insert(tenant)
            state.defaultTenant = tenant
        }
    }

    /// A directory that wants you to sign in again, such as for multi-factor authentication.
    func expire(_ tenant: String) {
        _ = state.withLock { state in state.signedIn.remove(tenant) }
    }

    /// Someone else signs in, with an account from `tenant`, to these directories: `object` tells two from one directory apart.
    func switchAccount(to tenant: String, signedIn: Set<String>, as object: String = "robin") {
        state.withLock { state in
            state.accountTenant = tenant
            state.signedIn = signedIn
            state.defaultTenant = tenant
            state.object = object
        }
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        let (tenant, isSignedIn, accountTenant, object) = state.withLock { state -> (String, Bool, String, String) in
            state.runs.append(arguments)
            let tenant = arguments.firstIndex(of: "--tenant").map { arguments[$0 + 1] } ?? state.defaultTenant
            return (tenant, state.signedIn.contains(tenant), state.accountTenant, state.object)
        }
        await held?.hold(tenant)
        guard isSignedIn else {
            return ProcessResult(status: 1, stderr: Data("ERROR: AADSTS50076: Sign in with multi-factor authentication.\n".utf8))
        }
        let token = tenant == accountTenant
            ? madeUpToken(tenant: tenant, object: object) : madeUpToken(tenant: tenant, object: "\(object)-guest", guestFrom: accountTenant)
        return ProcessResult(status: 0, stdout: Data(#"{"accessToken": "\#(token)", "expires_on": 4102444800}"#.utf8))
    }
}

/// Organizations in another directory (a Microsoft Entra tenant) than your sign-in's: Azure DevOps reads each one only
/// with a token from its own directory, and names it when it rejects one from another.
@Suite struct DirectoryTests {
    private static let locator = AzureCLILocator(environment: [:], candidates: ["/bin/az"], useLoginShell: false, isExecutable: { _ in true })

    // MARK: Tokens

    @Test func readsWhichDirectoryATokenIsFor() throws {
        let token = madeUpToken(tenant: Tenants.other.uppercased())
        #expect(AccessToken.tenant(inJWT: token) == Tenants.other)
        #expect(AccessToken.tenant(inJWT: "opaque") == nil)
        // A member's account is in the token's directory; a guest's, in the one its `idp` names.
        #expect(AccessToken.accountTenant(inJWT: token) == Tenants.other)
        let guest = madeUpToken(tenant: Tenants.other, object: "robin-guest", guestFrom: Tenants.home.uppercased())
        #expect(AccessToken.accountTenant(inJWT: guest) == Tenants.home)
        // A personal Microsoft account's names its identity provider.
        #expect(AccessToken.accountTenant(inJWT: madeUpToken(tenant: Tenants.other, guestFrom: "live.com")) == "live.com")
        // What the token says counts, over what the Azure CLI says it asked for.
        let parsed = try AzureCLITokenProvider.parseToken(
            Data(#"{"accessToken": "\#(guest)", "tenant": "\#(Tenants.third)", "expires_on": 4102444800}"#.utf8), now: t(0)
        )
        #expect(parsed.tenant == Tenants.other)
        #expect(parsed.accountTenant == Tenants.home)
        #expect(parsed.account == "\(Tenants.other)/robin-guest")
        let opaque = try AzureCLITokenProvider.parseToken(Data(#"{"accessToken": "abc", "tenant": "\#(Tenants.home.uppercased())"}"#.utf8), now: t(0))
        #expect(opaque.tenant == Tenants.home)
        #expect(opaque.accountTenant == nil)
        #expect(AccessToken.tenant(ofAccount: "\(Tenants.home)/robin") == Tenants.home)
        #expect(AccessToken.tenant(ofAccount: "/robin") == nil)
    }

    @Test func asksTheAzureCLIForAnotherDirectorysTokenWithIt() async throws {
        let cli = FakeAzureCLI(defaultTenant: Tenants.home, signedIn: [Tenants.home, Tenants.other])
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        #expect(try await provider.token(tenant: Tenants.other).tenant == Tenants.other)
        // Kept for that directory, however its ID is written, and apart from yours.
        #expect(try await provider.token(tenant: Tenants.other.uppercased()).tenant == Tenants.other)
        #expect(try await provider.token().tenant == Tenants.home)
        #expect(cli.asked == [Tenants.other, nil])
        // Forgetting one directory's token keeps the others'.
        await provider.invalidate(tenant: Tenants.other)
        _ = try await provider.token(tenant: Tenants.other)
        _ = try await provider.token()
        #expect(cli.asked == [Tenants.other, nil, Tenants.other])
    }

    @Test func signingInToAnotherDirectoryDoesntChangeWhoBriefBarReadsAs() async throws {
        let cli = FakeAzureCLI(defaultTenant: Tenants.home, signedIn: [Tenants.home])
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        // Yours, in the Azure CLI's default directory, which BriefBar keeps as yours.
        #expect(try await provider.token().tenant == Tenants.home)
        // Not signed in to fabrikam's directory.
        await #expect(throws: AuthError.signedOut("AADSTS50076: Sign in with multi-factor authentication.")) {
            try await provider.token(tenant: Tenants.other)
        }
        // `az login --tenant` there makes it the Azure CLI's default; yours is still asked for in your directory.
        cli.signIn(to: Tenants.other)
        #expect(try await provider.token(tenant: Tenants.other).tenant == Tenants.other)
        await provider.invalidate()
        let yours = try await provider.token()
        #expect(yours.tenant == Tenants.home)
        #expect(yours.account == "\(Tenants.home)/robin")
        #expect(cli.asked == [nil, Tenants.other, Tenants.other, Tenants.home])
    }

    @Test func yourDirectoryWantingYouToSignInAgainIsntSomeoneElses() async throws {
        let cli = FakeAzureCLI(defaultTenant: Tenants.home, signedIn: [Tenants.home])
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        #expect(try await provider.token().tenant == Tenants.home)
        // You sign in to fabrikam's directory, which becomes the Azure CLI's default; later, yours wants you to sign in
        // again, while fabrikam's still gives your guest account tokens.
        cli.signIn(to: Tenants.other)
        cli.expire(Tenants.home)
        await provider.invalidate()
        // Signing in again there is what fixes it.
        await #expect(throws: AuthError.signedOut("AADSTS50076: Sign in with multi-factor authentication.", tenant: Tenants.home)) {
            try await provider.token()
        }
        // Signed in to yours again, BriefBar reads as you there, not as your guest account in fabrikam's.
        cli.signIn(to: Tenants.home)
        let yours = try await provider.token()
        #expect(yours.tenant == Tenants.home)
        #expect(yours.account == "\(Tenants.home)/robin")
        #expect(cli.asked == [nil, Tenants.home, nil, Tenants.home])
    }

    @Test func someoneElseSignedInItFollowsTheAzureCLIsDefault() async throws {
        // BriefBar last read as you, in your directory; the Azure CLI is signed in as someone else now, from another.
        let cli = FakeAzureCLI(defaultTenant: Tenants.other, signedIn: [Tenants.other])
        let provider = AzureCLITokenProvider(homeTenant: Tenants.home.uppercased(), locator: Self.locator, runner: cli)
        #expect(try await provider.token().tenant == Tenants.other)
        #expect(cli.asked == [Tenants.home, nil])
        // Their directory is the one tokens are asked for in from then on.
        await provider.invalidate()
        #expect(try await provider.token().tenant == Tenants.other)
        #expect(cli.asked == [Tenants.home, nil, Tenants.other])
    }

    @Test func yourGuestDirectoryWantingYouToSignInAgainIsntSomeoneElses() async throws {
        // The Azure CLI's default was a directory your account is a guest in, from yours.
        let cli = FakeAzureCLI(defaultTenant: Tenants.other, signedIn: [Tenants.other], accountFrom: Tenants.home)
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        #expect(try await provider.token().tenant == Tenants.other)
        // You sign in to a third one, a guest there too; then the first wants you to sign in again.
        cli.signIn(to: Tenants.third)
        cli.expire(Tenants.other)
        await provider.invalidate()
        // There: a plain `az login` may sign in to another directory, without what this one asks for.
        await #expect(throws: AuthError.signedOut("AADSTS50076: Sign in with multi-factor authentication.", tenant: Tenants.other)) {
            try await provider.token()
        }
        #expect(cli.asked == [nil, Tenants.other, nil])
    }

    @Test func afterARestartYourGuestDirectoryWantingYouToSignInAgainIsntSomeoneElses() async throws {
        // BriefBar last read as your guest account in fabrikam's directory, from yours, and kept where it's from. Since the
        // restart, the Azure CLI's default is a third directory you're a guest in too, and fabrikam's wants a sign-in.
        let cli = FakeAzureCLI(defaultTenant: Tenants.third, signedIn: [Tenants.third], accountFrom: Tenants.home)
        let provider = AzureCLITokenProvider(
            homeTenant: Tenants.other, homeAccountTenant: Tenants.home.uppercased(), locator: Self.locator, runner: cli
        )
        // It's still you: fabrikam's directory wants you to sign in again, there, rather than BriefBar reading as you there.
        await #expect(throws: AuthError.signedOut("AADSTS50076: Sign in with multi-factor authentication.", tenant: Tenants.other)) {
            try await provider.token()
        }
        // Signed in there again, yours comes from there, as before the restart, and your account is still from your directory.
        cli.signIn(to: Tenants.other)
        let token = try await provider.token()
        #expect(token.tenant == Tenants.other)
        let account = try #require(token.account)
        #expect(await provider.accountTenant(of: account) == Tenants.home)
        // Nothing is said of anyone else's.
        #expect(await provider.accountTenant(of: "someone-else") == nil)
        #expect(cli.asked == [Tenants.other, nil, Tenants.other])
    }

    @Test func aPersonalAccountsDirectoryWantingYouToSignInAgainIsntSomeoneElses() async throws {
        // A personal Microsoft account, a guest in each directory: its tokens name live.com, not a directory.
        let cli = FakeAzureCLI(defaultTenant: Tenants.home, signedIn: [Tenants.home], accountFrom: "live.com")
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        #expect(try await provider.token().accountTenant == "live.com")
        cli.signIn(to: Tenants.other)
        cli.expire(Tenants.home)
        await provider.invalidate()
        await #expect(throws: AuthError.signedOut("AADSTS50076: Sign in with multi-factor authentication.", tenant: Tenants.home)) {
            try await provider.token()
        }
        #expect(cli.asked == [nil, Tenants.home, nil])
    }

    @Test func someoneElsesSignInDropsTheLastAccountsTokens() async throws {
        let cli = FakeAzureCLI(defaultTenant: Tenants.home, signedIn: [Tenants.home, Tenants.other])
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        _ = try await provider.token()
        #expect(try await provider.token(tenant: Tenants.other).accountTenant == Tenants.home)
        // Someone from the third directory signs in, a guest in fabrikam's too.
        cli.switchAccount(to: Tenants.third, signedIn: [Tenants.third, Tenants.other])
        await provider.invalidate()
        #expect(try await provider.token().tenant == Tenants.third)
        // fabrikam's token was the last account's: it's asked for again, as theirs.
        #expect(try await provider.token(tenant: Tenants.other).accountTenant == Tenants.third)
        #expect(cli.asked == [nil, Tenants.other, Tenants.home, nil, Tenants.other])
    }

    @Test func anotherDirectorysTokenForSomeoneElseIsntKept() async throws {
        let cli = FakeAzureCLI(defaultTenant: Tenants.home, signedIn: [Tenants.home, Tenants.other])
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        _ = try await provider.token()
        // Someone else signs in while yours is kept: a token from fabrikam's directory is theirs, and no caller gets it.
        cli.switchAccount(to: Tenants.third, signedIn: [Tenants.third, Tenants.other])
        let first = Task { try await provider.token(tenant: Tenants.other) }
        let second = Task { try await provider.token(tenant: Tenants.other) }
        for caller in [first, second] {
            await #expect(throws: AuthError.failed("Someone else signed in to the Azure CLI.")) { try await caller.value }
        }
        // Nor is it kept, and yours is asked for again, which tells who's signed in now.
        await #expect(throws: AuthError.failed("Someone else signed in to the Azure CLI.")) {
            try await provider.token(tenant: Tenants.other)
        }
        #expect(try await provider.token().tenant == Tenants.third)
        #expect(cli.asked.suffix(2) == [Tenants.home, nil])
    }

    @Test func anotherDirectorysTokenOnItsWayWhenSomeoneElseSignsInIsntKept() async throws {
        let held = HeldDirectory(Tenants.other)
        let cli = FakeAzureCLI(defaultTenant: Tenants.home, signedIn: [Tenants.home, Tenants.other], held: held)
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        let yours = try await provider.token()
        // A token from fabrikam's directory is on its way, for you, when someone else from your own directory signs in, as
        // the next token for yours tells: theirs from fabrikam's directory name the same directory as yours.
        let fabrikams = Task { try await provider.token(tenant: Tenants.other) }
        try await waitUntil("the Azure CLI to be asked for fabrikam's directory") { await held.isHolding }
        cli.switchAccount(to: Tenants.home, signedIn: [Tenants.home, Tenants.other], as: "sam")
        await provider.invalidate()
        #expect(try await provider.token().account != yours.account)
        await held.release()
        // It was yours: nobody waiting for it gets it, and it isn't kept for them.
        await #expect(throws: AuthError.failed("Someone else signed in to the Azure CLI.")) { try await fabrikams.value }
        #expect(try await provider.token(tenant: Tenants.other).account == "\(Tenants.other)/sam-guest")
        #expect(cli.asked == [nil, Tenants.other, Tenants.home, Tenants.other])
    }

    @Test func someoneElseFoundThroughAnotherDirectoryDropsEveryTokenKept() async throws {
        let cli = FakeAzureCLI(defaultTenant: Tenants.home, signedIn: [Tenants.home, Tenants.other])
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        _ = try await provider.token()
        let fabrikams = try await provider.token(tenant: Tenants.other)
        // Someone else signs in, from a third directory, a guest in fabrikam's too, and a token from their own directory is
        // the first to tell.
        cli.switchAccount(to: Tenants.third, signedIn: [Tenants.third, Tenants.other], as: "sam")
        await #expect(throws: AuthError.failed("Someone else signed in to the Azure CLI.")) {
            try await provider.token(tenant: Tenants.third)
        }
        // fabrikam's, kept for the last account, goes too: it isn't read as them meanwhile.
        await #expect(throws: AuthError.failed("Someone else signed in to the Azure CLI.")) {
            try await provider.token(tenant: Tenants.other)
        }
        // Once theirs is read, fabrikam's is theirs.
        #expect(try await provider.token().tenant == Tenants.third)
        let theirs = try await provider.token(tenant: Tenants.other)
        #expect(theirs.account == "\(Tenants.other)/sam-guest")
        #expect(theirs.account != fabrikams.account)
        #expect(cli.asked == [nil, Tenants.other, Tenants.third, Tenants.other, Tenants.home, nil, Tenants.other])
    }

    @Test func aTokenOnItsWayForTheLastAccountDoesntDropTheNextAccounts() async throws {
        let held = HeldDirectory(Tenants.other)
        let cli = FakeAzureCLI(defaultTenant: Tenants.home, signedIn: [Tenants.home, Tenants.other], held: held)
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        _ = try await provider.token()
        // fabrikam's token, for you, is on its way when someone else signs in, from a third directory, and BriefBar has read
        // as them since, in their own directory too.
        let fabrikams = Task { try await provider.token(tenant: Tenants.other) }
        try await waitUntil("the Azure CLI to be asked for fabrikam's directory") { await held.isHolding }
        cli.switchAccount(to: Tenants.third, signedIn: [Tenants.third, Tenants.other], as: "sam")
        await provider.invalidate()
        let theirHome = try await provider.token()
        #expect(theirHome.tenant == Tenants.third)
        let theirs = try await provider.token(tenant: Tenants.third)
        await held.release()
        // Yours, the last account's, isn't theirs: nobody gets it, and what's kept for them stays.
        await #expect(throws: AuthError.failed("Someone else signed in to the Azure CLI.")) { try await fabrikams.value }
        #expect(try await provider.token() == theirHome)
        #expect(try await provider.token(tenant: Tenants.third) == theirs)
        #expect(cli.asked == [nil, Tenants.other, Tenants.home, nil, Tenants.third])
    }

    @Test func yourTokenOnItsWayWhenSomeoneElseIsFoundIsntKept() async throws {
        let held = HeldDirectory(Tenants.home, run: 2)
        let cli = FakeAzureCLI(defaultTenant: Tenants.home, signedIn: [Tenants.home, Tenants.other], held: held)
        let provider = AzureCLITokenProvider(locator: Self.locator, runner: cli)
        _ = try await provider.token()
        // Yours is asked for again, and is on its way when someone else signs in, from a third directory, a guest in
        // fabrikam's, as a token from fabrikam's directory tells meanwhile.
        await provider.invalidate()
        let yours = Task { try await provider.token() }
        try await waitUntil("the Azure CLI to be asked for your directory again") { await held.isHolding }
        cli.switchAccount(to: Tenants.third, signedIn: [Tenants.third, Tenants.other], as: "sam")
        await #expect(throws: AuthError.failed("Someone else signed in to the Azure CLI.")) {
            try await provider.token(tenant: Tenants.other)
        }
        await held.release()
        // It was the last account's: nobody waiting for it gets it, nor is it kept, and the next one is theirs.
        await #expect(throws: AuthError.failed("Someone else signed in to the Azure CLI.")) { try await yours.value }
        #expect(try await provider.token().tenant == Tenants.third)
        #expect(cli.asked == [nil, Tenants.home, Tenants.other, Tenants.home, nil])
    }

    @Test func whatTheAzureCLISaysKeepsNoIDsOrNames() {
        let output = """
            WARNING: something
            ERROR: AADSTS50020: User account 'robin@contoso.example' from identity provider 'live.com' does not exist in tenant 'Fabrikam Example' and cannot access the application '\(AzureCLITokenProvider.azureDevOpsResource)'. Trace ID: 0d0d0d0d-4444-4444-8444-444444444444 Correlation ID: 0e0e0e0e-5555-4555-8555-555555555555
            Interactive authentication is needed. Please run:
            az login --tenant "\(Tenants.other)"
            """
        #expect(AzureCLITokenProvider.error(fromOutput: output) == .signedOut(
            "AADSTS50020: User account '<account>' from identity provider 'live.com' does not exist in tenant '<name>' and cannot access the application '<id>'. Trace ID: <id> Correlation ID: <id>"
        ))
        // A directory's ID where it says to sign in, and one it would cut short: neither is left, nor any part of one.
        #expect(AzureCLITokenProvider.error(fromOutput: "ERROR: Please run 'az login --tenant \"\(Tenants.other)\"' to setup account.")
            == .signedOut("Please run 'az login --tenant \"<id>\"' to setup account."))
        let long = AzureCLITokenProvider.error(fromOutput: "ERROR: Please run 'az login'. " + String(repeating: "x", count: 266) + " " + Tenants.other)
        #expect(!long.description.contains(String(Tenants.other.prefix(8))))
        #expect(long.description.hasSuffix(" <id>"))
    }

    // MARK: Requests

    @Test func readsAnOrganizationInAnotherDirectoryWithATokenFromThere() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        server.on("/_apis/connectionData", json: ["authenticatedUser": ["id": "ME"]])
        server.put("fabrikam", in: Tenants.other)
        let client = server.client(tokens: tokens)
        #expect(try await client.get(ADOEndpoint.connectionData(organization: "fabrikam"), as: ADOConnectionData.self).authenticatedUser.id == "ME")
        // Rejected with a token from your directory, which isn't fabrikam's, then read with one from fabrikam's.
        #expect(server.requests.map(\.tenant) == [Tenants.home, Tenants.other])
        // From then on, with one from there right away, however its name is spelled.
        _ = try await client.get(ADOEndpoint.connectionData(organization: "Fabrikam"), as: ADOConnectionData.self)
        #expect(server.requests.map(\.tenant) == [Tenants.home, Tenants.other, Tenants.other])
        #expect(await tokens.asked == [nil, Tenants.other, Tenants.other])
        #expect(await tokens.invalidations == 0)
    }

    @Test func saysWhenTheAzureCLIIsntSignedInToAnOrganizationsDirectory() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.on("/_apis/connectionData", json: ["authenticatedUser": ["id": "ME"]])
        server.put("fabrikam", in: Tenants.other)
        let client = server.client(tokens: tokens)
        let url = ADOEndpoint.connectionData(organization: "fabrikam")
        await #expect(throws: ADOError.otherDirectory(organization: "fabrikam", tenant: Tenants.other)) {
            try await client.get(url, as: ADOConnectionData.self)
        }
        // Not a sign-in a fresh token of yours fixes: nothing more is sent once the Azure CLI can't give one from there.
        #expect(server.requests.count == 1)
        #expect(await tokens.invalidations == 0)
        // Until it can, each try asks Azure DevOps where it is, which may have changed, once.
        await #expect(throws: ADOError.otherDirectory(organization: "fabrikam", tenant: Tenants.other)) {
            try await client.get(url, as: ADOConnectionData.self)
        }
        #expect(server.requests.count == 2)
        // Once the Azure CLI is signed in there, it's read.
        await tokens.signIn(to: Tenants.other)
        #expect(try await client.get(url, as: ADOConnectionData.self).authenticatedUser.id == "ME")
    }

    @Test func followsAnOrganizationThatMovesToAnotherDirectory() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        await tokens.signIn(to: Tenants.third)
        server.on("/_apis/connectionData", json: ["authenticatedUser": ["id": "ME"]])
        server.put("fabrikam", in: Tenants.other)
        let client = server.client(tokens: tokens)
        let url = ADOEndpoint.connectionData(organization: "fabrikam")
        _ = try await client.get(url, as: ADOConnectionData.self)
        // It moves to the third directory, and the Azure CLI signs out of the one it was in.
        server.put("fabrikam", in: Tenants.third)
        await tokens.signOut(of: Tenants.other)
        _ = try await client.get(url, as: ADOConnectionData.self)
        #expect(server.requests.map(\.tenant) == [Tenants.home, Tenants.other, Tenants.home, Tenants.third])
        // Still signed in to the one it was in, it's followed all the same.
        server.put("fabrikam", in: Tenants.other)
        await tokens.signIn(to: Tenants.other)
        _ = try await client.get(url, as: ADOConnectionData.self)
        #expect(server.requests.map(\.tenant).suffix(2) == [Tenants.third, Tenants.other])
    }

    @Test func aTokenRejectedByItsOwnDirectoryIsStillUnauthorized() async {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        // Azure DevOps names the token's own directory: you're not a member, or the token is stale.
        server.on("/_apis/connectionData") { _ in .status(401, headers: ["X-VSS-ResourceTenant": Tenants.home.uppercased()]) }
        await #expect(throws: ADOError.unauthorized) {
            try await server.client(tokens: tokens).get(ADOEndpoint.connectionData(organization: "contoso"), as: ADOConnectionData.self)
        }
        #expect(await tokens.asked == [nil, nil])
        #expect(await tokens.invalidations == 1)
    }

    @Test func eachDirectorysTokenIsRefreshedOnceWhenRejected() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        // Your token is rejected, then the fresh one is told the organization is in fabrikam's directory, whose kept token
        // is rejected too, being stale; a fresh one from there works.
        let calls = Locked(0)
        server.on("/fabrikam/_apis/connectionData") { _ in
            calls.set(calls.value + 1)
            switch calls.value {
            case 1: return .status(401)
            case 2, 3: return .status(401, headers: ["X-VSS-ResourceTenant": Tenants.other])
            default: return .json(["authenticatedUser": ["id": "ME"]])
            }
        }
        let read = try await server.client(tokens: tokens).get(ADOEndpoint.connectionData(organization: "fabrikam"), as: ADOConnectionData.self)
        #expect(read.authenticatedUser.id == "ME")
        #expect(await tokens.asked == [nil, nil, Tenants.other, Tenants.other])
        #expect(await tokens.invalidations == 2)
        #expect(calls.value == 4)
    }

    @Test func onlyTenantIDsNameDirectories() throws {
        func response(_ header: String) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(
                url: ADOEndpoint.connectionData(organization: "contoso"), statusCode: 401, httpVersion: "HTTP/1.1",
                headerFields: ["X-VSS-ResourceTenant": header]
            ))
        }
        let two = try response("\(Tenants.other.uppercased()), \(Tenants.third)")
        let empty = try response("00000000-0000-0000-0000-000000000000")
        let odd = try response("contoso; rm -rf ~")
        let blank = try response("")
        #expect(ADOClient.resourceTenants(two) == [Tenants.other, Tenants.third])
        #expect(ADOClient.resourceTenants(empty).isEmpty)
        // Nothing else goes on to `az login --tenant`.
        #expect(ADOClient.resourceTenants(odd).isEmpty)
        #expect(ADOClient.resourceTenants(blank).isEmpty)

        let elsewhere = try response(Tenants.other)
        let yours = AccessToken(value: "t", expiresOn: .distantFuture, tenant: Tenants.home)
        let theirs = AccessToken(value: "t", expiresOn: .distantFuture, tenant: Tenants.other)
        #expect(ADOClient.otherDirectory(of: elsewhere, token: yours) == Tenants.other)
        #expect(ADOClient.otherDirectory(of: elsewhere, token: theirs) == nil)
        // A token that doesn't say its directory can't be told from the organization's.
        #expect(ADOClient.otherDirectory(of: elsewhere, token: AccessToken(value: "t", expiresOn: .distantFuture)) == nil)
    }

    @Test func tellsWhichOrganizationARequestReads() {
        #expect(ADOClient.organization(of: ADOEndpoint.connectionData(organization: "fabrikam")) == "fabrikam")
        #expect(ADOClient.organization(of: ADOEndpoint.threads(organization: "contoso", projectId: "p1", repositoryId: "r1", pullRequestId: 7))
            == "contoso")
        #expect(ADOClient.organization(of: ADOEndpoint.profile) == nil)
        #expect(ADOClient.organization(of: ADOEndpoint.accounts(memberId: "alias")) == nil)
    }

    // MARK: What's wrong

    @Test func namesTheOrganizationsInADirectoryToSignInTo() throws {
        let failures: [(organization: String, error: ADOError)] = [
            (organization: "fabrikam", error: ADOError.otherDirectory(organization: "fabrikam", tenant: Tenants.other)),
            (organization: "locked", error: ADOError.forbidden),
            (organization: "northwind", error: ADOError.otherDirectory(organization: "northwind", tenant: Tenants.other)),
            (organization: "tailspin", error: ADOError.otherDirectory(organization: "tailspin", tenant: Tenants.third)),
        ]
        let problem = try #require(PulseProblem.organizations(failures))
        let others = "Couldn't read locked (No access to this organization.), "
            + "tailspin (The organization is in a directory your Azure CLI isn't signed in to.)."
        #expect(problem == .otherDirectory(organizations: ["fabrikam", "northwind"], tenant: Tenants.other, others: others))
        #expect(problem.message == "fabrikam and northwind are in a directory your Azure CLI isn't signed in to. " + others)
        // A directory's ID only goes where signing in needs it.
        #expect(!problem.message.contains(Tenants.other) && !problem.message.contains(Tenants.third))
        #expect(problem.signInTenant == Tenants.other)
        #expect(problem.signInCommand == "az login --tenant \(Tenants.other) --allow-no-subscriptions")
        #expect(problem.offersSignIn && !problem.needsSignIn)

        let one = PulseProblem.from(.otherDirectory(organization: "fabrikam", tenant: Tenants.other))
        #expect(one.message == "fabrikam is in a directory your Azure CLI isn't signed in to.")
        let locked: [(organization: String, error: ADOError)] = [(organization: "locked", error: ADOError.forbidden)]
        #expect(PulseProblem.organizations(locked) == .someOrganizations("Couldn't read locked (No access to this organization.)."))
        // One reason for each organization, however it's spelled, as when several of its pipelines couldn't be read.
        let twice: [(organization: String, error: ADOError)] = [
            (organization: "fabrikam", error: ADOError.otherDirectory(organization: "fabrikam", tenant: Tenants.other)),
            (organization: "Fabrikam", error: ADOError.otherDirectory(organization: "Fabrikam", tenant: Tenants.other)),
        ]
        #expect(PulseProblem.organizations(twice)?.message == "fabrikam is in a directory your Azure CLI isn't signed in to.")
        #expect(PulseProblem.organizations([]) == nil)
        #expect(PulseProblem.signedOut("").signInCommand == "az login --allow-no-subscriptions")
        #expect(PulseProblem.offline.signInCommand == nil)
    }

    @Test func signsInAgainInYourDirectoryWhenItWantsYouTo() {
        // Your directory wants you to sign in again, there, while the Azure CLI is still signed in to you in another.
        let again = PulseProblem.from(.auth(.signedOut("AADSTS50076: Sign in with multi-factor authentication.", tenant: Tenants.home)))
        #expect(again == .signedOut("AADSTS50076: Sign in with multi-factor authentication.", tenant: Tenants.home))
        #expect(again.needsSignIn)
        #expect(again.signInTenant == Tenants.home)
        #expect(again.signInCommand == "az login --tenant \(Tenants.home) --allow-no-subscriptions")
        #expect(again.message == "Sign in to the Azure CLI to see your pull requests.")
        // Signed out altogether, anyone may sign in, wherever their account is.
        let signedOut = PulseProblem.from(.auth(.signedOut("Run az login")))
        #expect(signedOut.signInTenant == nil)
        #expect(signedOut.signInCommand == "az login --allow-no-subscriptions")
    }

    @Test func anOrganizationInADirectoryToSignInToSaysSoWhateverElseFailedThere() {
        // One of fabrikam's projects failed otherwise first, as one of its pinned pipelines' can.
        let failures: [(organization: String, error: ADOError)] = [
            (organization: "fabrikam", error: ADOError.http(500)),
            (organization: "Fabrikam", error: ADOError.otherDirectory(organization: "Fabrikam", tenant: Tenants.other)),
            (organization: "northwind", error: ADOError.forbidden),
        ]
        #expect(PulseProblem.organizations(failures) == .otherDirectory(
            organizations: ["fabrikam"], tenant: Tenants.other, others: "Couldn't read northwind (No access to this organization.)."
        ))
    }

    @Test func anOrganizationInAnotherDirectoryDoesntHideTheOthers() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.serveOrganization(mine: [Fixture.pullRequest(1, title: "Yours in contoso")])
        server.serveOrganization("fabrikam", mine: [Fixture.pullRequest(2, title: "Yours in fabrikam")])
        server.put("fabrikam", in: Tenants.other)
        let engine = PulseEngine(
            client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: [Fixture.org, "fabrikam"])
        ) { _ in }
        await engine.refreshNow()
        var snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id) == [PRKey(Fixture.org, 1)])
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
        #expect(snapshot.problem?.needsSignIn == false)

        // Once the Azure CLI is signed in to fabrikam's directory too, it's read with the rest.
        await tokens.signIn(to: Tenants.other)
        await engine.refreshNow()
        snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id) == [PRKey(Fixture.org, 1), PRKey("fabrikam", 2)])
        #expect(snapshot.problem == nil)
    }

    @Test func whenNothingCanBeReadItSaysWhichDirectoryToSignInTo() async {
        let server = StubServer()
        server.serveOrganization("fabrikam")
        server.put("fabrikam", in: Tenants.other)
        server.on("/northwind/_apis/connectionData") { _ in .status(500) }
        let snapshot = await PulseEngine.loadOnce(
            client: server.client(tokens: FakeTokens(server.id, tenant: Tenants.home)),
            configuration: PulseEngine.Configuration(organizations: ["fabrikam", "northwind"])
        )
        #expect(snapshot.problem == .otherDirectory(
            organizations: ["fabrikam"], tenant: Tenants.other, others: "Couldn't read northwind (Azure DevOps answered with HTTP 500.)."
        ))
    }

    @Test func aPullRequestYouWatchInAnotherDirectorySaysSoAndIsReadOnceSignedInThere() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.serveOrganization(mine: [Fixture.pullRequest(1)])
        server.on("/fabrikam/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/fabrikam/_apis/git/pullrequests/9", json: Fixture.pullRequest(9, title: "Theirs", author: People.sam))
        server.put("fabrikam", in: Tenants.other)
        let engine = PulseEngine(
            client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: [Fixture.org])
        ) { _ in }
        await engine.setLinkedPullRequests([PRKey("fabrikam", 9)])
        await engine.refreshNow()
        var snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id) == [PRKey(Fixture.org, 1)])
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
        // Signed in there, it's read at the next refresh, rather than an hour later.
        await tokens.signIn(to: Tenants.other)
        await engine.refreshNow()
        snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id) == [PRKey(Fixture.org, 1), PRKey("fabrikam", 9)])
        #expect(snapshot.problem == nil)
    }

    @Test func pullRequestsYouWatchInAnotherDirectoryDontKeepTheOthersWaiting() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.on("/contoso/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/contoso/_apis/git/pullrequests/11", json: Fixture.pullRequest(11, title: "Theirs", author: People.sam))
        server.on("/_apis/policy/evaluations", json: Fixture.list([]))
        server.on("/threads", json: Fixture.list([]))
        // adatum's ten come first, more than a refresh reads.
        server.put("adatum", in: Tenants.other)
        let engine = PulseEngine(client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: [])) { _ in }
        await engine.setLinkedPullRequests(Set((1...10).map { PRKey("adatum", $0) } + [PRKey(Fixture.org, 11)]))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id) == [PRKey(Fixture.org, 11)])
        #expect(snapshot.problem == .otherDirectory(organizations: ["adatum"], tenant: Tenants.other, others: nil))
        // One of adatum's was tried; the rest waited without taking contoso's turn.
        #expect(server.requests.filter { $0.url?.path.hasPrefix("/adatum/") == true }.count == 1)
    }

    @Test func organizationsWaitingOnASignInTakeTurnsWithPullRequestsSentToYou() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.on("/contoso/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/contoso/_apis/git/pullrequests/11", json: Fixture.pullRequest(11, title: "Theirs", author: People.sam))
        server.on("/_apis/policy/evaluations", json: Fixture.list([]))
        server.on("/threads", json: Fixture.list([]))
        // Twelve organizations in a directory to sign in to come first, more than a refresh reads.
        let elsewhere = (1...12).map { "adatum" + ($0 < 10 ? "0\($0)" : "\($0)") }
        for organization in elsewhere { server.put(organization, in: Tenants.other) }
        let engine = PulseEngine(client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: [])) { _ in }
        await engine.setLinkedPullRequests(Set(elsewhere.map { PRKey($0, 1) } + [PRKey(Fixture.org, 11)]))
        func asked() -> Int { server.requests.filter { $0.url?.path.hasPrefix("/adatum") == true }.count }

        // Ten reads a refresh, theirs among them: ten are tried, a request each, and said.
        await engine.refreshNow()
        #expect(asked() == 10)
        #expect(await engine.currentSnapshot().problem
            == .otherDirectory(organizations: Array(elsewhere.prefix(10)), tenant: Tenants.other, others: nil))

        // Then the two not tried yet, and contoso's, come before those tried, seven of which are tried again: and all
        // twelve are said, tried this time or not.
        await engine.refreshNow()
        #expect(asked() == 19)
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id) == [PRKey(Fixture.org, 11)])
        #expect(snapshot.problem == .otherDirectory(organizations: elsewhere, tenant: Tenants.other, others: nil))

        // Once none is sent to you from there, none is said.
        await engine.setLinkedPullRequests([PRKey(Fixture.org, 11)])
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().problem == nil)
    }

    @Test func anOrganizationThatAnswersOtherwiseNoLongerWaitsOnASignIn() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.put("fabrikam", in: Tenants.other)
        // Signed in there, it answers that you aren't one of its members: no access, rather than a sign-in to make.
        server.on("/fabrikam/_apis/connectionData") { _ in .status(401) }
        let engine = PulseEngine(client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: [])) { _ in }
        await engine.setLinkedPullRequests([PRKey("fabrikam", 9)])
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
        await tokens.signIn(to: Tenants.other)
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().problem == nil)
    }

    @Test func pullRequestsSentToYouAreReadWhileEveryOrganizationYouWatchWaitsOnASignIn() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.serveOrganization("fabrikam", mine: [Fixture.pullRequest(1, title: "Yours in fabrikam")])
        server.put("fabrikam", in: Tenants.other)
        server.on("/contoso/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/contoso/_apis/git/pullrequests/11", json: Fixture.pullRequest(11, title: "Theirs", author: People.sam))
        let engine = PulseEngine(
            client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: ["fabrikam"], interval: 300)
        ) { _ in }
        await engine.setLinkedPullRequests([PRKey(Fixture.org, 11)])
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        // fabrikam, the one you watch, waits on a sign-in to its directory; the one sent to you from contoso is read.
        #expect(snapshot.records.map(\.id) == [PRKey(Fixture.org, 11)])
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
        // Something was read: the next refresh comes as often as usual.
        #expect(await engine.nextDelay() == 300)
    }

    @Test func askingToSlowDownComesBeforeADirectoryToSignInTo() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.put("fabrikam", in: Tenants.other)
        server.on("/northwind/_apis/connectionData") { _ in .status(429, headers: ["Retry-After": "120"]) }
        let engine = PulseEngine(
            client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: ["fabrikam", "northwind"])
        ) { _ in }
        await engine.refreshNow()
        // Nothing goes out until then, and nothing can be read either, signed in there or not.
        let problem = await engine.currentSnapshot().problem
        var throttled = false
        if case .throttled? = problem { throttled = true }
        #expect(throttled)
        #expect(await engine.nextDelay() > 100)
    }

    @Test func askingToSlowDownComesFirstWhileOtherOrganizationsAreRead() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.serveOrganization()
        server.serveOrganization("northwind")
        let slowDown = Locked(false)
        server.on("/northwind/_apis/git/pullrequests") { _ in
            slowDown.value ? .status(429, headers: ["Retry-After": "120"]) : .json(Fixture.list([]))
        }
        server.put("fabrikam", in: Tenants.other)
        let engine = PulseEngine(
            client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: [Fixture.org, "fabrikam", "northwind"])
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().problem?.signInTenant == Tenants.other)
        // contoso's lists are read; northwind's are asked to wait: that comes first, over fabrikam's directory.
        slowDown.set(true)
        await engine.refreshNow()
        let problem = await engine.currentSnapshot().problem
        var throttled = false
        if case .throttled? = problem { throttled = true }
        #expect(throttled)
        #expect(await engine.nextDelay() > 100)
    }

    @Test func askingToSlowDownForAPullRequestSentToYouComesFirstToo() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.put("fabrikam", in: Tenants.other)
        server.on("/contoso/_apis/connectionData") { _ in .status(429, headers: ["Retry-After": "120"]) }
        let engine = PulseEngine(
            client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: ["fabrikam"])
        ) { _ in }
        await engine.setLinkedPullRequests([PRKey(Fixture.org, 11)])
        await engine.refreshNow()
        let problem = await engine.currentSnapshot().problem
        var throttled = false
        if case .throttled? = problem { throttled = true }
        #expect(throttled)
        #expect(await engine.nextDelay() > 100)
    }

    @Test func organizationsWaitingOnASignInArentAskedForMore() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        server.serveOrganization("fabrikam", mine: [Fixture.pullRequest(1, title: "Yours in fabrikam")])
        server.put("fabrikam", in: Tenants.other)
        let clock = Locked(t(0))
        let engine = PulseEngine(
            client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: ["fabrikam"]),
            now: { clock.value }
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().records.map(\.id) == [PRKey("fabrikam", 1)])

        // An hour later, the Azure CLI signed out of fabrikam's directory: its pull request stays as it was read, and its
        // details, due again, aren't asked for.
        await tokens.signOut(of: Tenants.other)
        clock.set(t(hour))
        let before = server.requests.count
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().records.map(\.id) == [PRKey("fabrikam", 1)])
        let details = server.requests.dropFirst(before).filter {
            let path = $0.url?.path ?? ""
            return path.contains("/_apis/policy/evaluations") || path.contains("/threads")
        }
        #expect(details.isEmpty)
    }

    @Test func askingToSlowDownLookingUpAPullRequestThatLeftYourListsComesFirstToo() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.serveOrganization()
        let gone = Locked(false)
        server.on("/contoso/_apis/git/pullrequests", query: ["searchCriteria.creatorId": Fixture.me, "searchCriteria.status": "active"]) { _ in
            .json(Fixture.list(gone.value ? [] : [Fixture.pullRequest(1, title: "Yours")]))
        }
        server.on("/contoso/_apis/git/pullrequests/1") { _ in .status(429, headers: ["Retry-After": "120"]) }
        server.put("fabrikam", in: Tenants.other)
        let engine = PulseEngine(
            client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: [Fixture.org, "fabrikam"])
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().records.map(\.id) == [PRKey(Fixture.org, 1)])

        // Your pull request leaves your lists, and looking it up is asked to wait: that comes first, over fabrikam's
        // directory, though nothing else is read after it.
        gone.set(true)
        await engine.refreshNow()
        let problem = await engine.currentSnapshot().problem
        var throttled = false
        if case .throttled? = problem { throttled = true }
        #expect(throttled)
    }

    @Test func pullRequestsSentToYouThatCantBeReadAgainAreLookedAtWithinAMinute() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        server.on("/fabrikam/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/fabrikam/_apis/git/pullrequests/9", json: Fixture.pullRequest(9, title: "Theirs", author: People.sam))
        server.on("/_apis/policy/evaluations", json: Fixture.list([]))
        server.on("/threads", json: Fixture.list([]))
        server.put("fabrikam", in: Tenants.other)
        let engine = PulseEngine(
            client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: [], interval: 300)
        ) { _ in }
        await engine.setLinkedPullRequests([PRKey("fabrikam", 9)])
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().records.map(\.id) == [PRKey("fabrikam", 9)])
        #expect(await engine.nextDelay() == 300)

        // The Azure CLI signs out of fabrikam's directory: the pull request stays as it was last read, but nothing was.
        await tokens.signOut(of: Tenants.other)
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id) == [PRKey("fabrikam", 9)])
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
        #expect(await engine.nextDelay() == 60)
    }

    @Test func theLogDoesntNameOrganizationsInAnotherDirectory() throws {
        // One sent to you comes from a link in a chat: in the second directory here, it's among the others.
        let failures: [(organization: String, error: ADOError)] = [
            (organization: "fabrikam", error: ADOError.otherDirectory(organization: "fabrikam", tenant: Tenants.other)),
            (organization: "northwind", error: ADOError.otherDirectory(organization: "northwind", tenant: Tenants.other)),
            (organization: "tailspin", error: ADOError.otherDirectory(organization: "tailspin", tenant: Tenants.third)),
            (organization: "contoso", error: ADOError.notFound),
        ]
        let problem = try #require(PulseProblem.organizations(failures))
        #expect(problem.message.contains("tailspin"))
        #expect(problem.logMessage == "2 organizations are in a directory your Azure CLI isn't signed in to. Others couldn't be read.")
        for name in ["fabrikam", "northwind", "tailspin", "contoso", Tenants.other, Tenants.third] {
            #expect(!problem.logMessage.contains(name))
        }
        let one = PulseProblem.from(.otherDirectory(organization: "fabrikam", tenant: Tenants.other))
        #expect(one.logMessage == "An organization is in a directory your Azure CLI isn't signed in to.")
        #expect(PulseProblem.offline.logMessage == PulseProblem.offline.message)
    }

    @Test func pinnedPipelinesInAnotherDirectorySayWhichOrganization() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        let contoso = PipelineRef(organization: "contoso", projectId: "p1", projectName: "Shop", definitionId: 31, name: "web CI")
        let fabrikam = PipelineRef(organization: "fabrikam", projectId: "p1", projectName: "Shop", definitionId: 31, name: "web CI")
        let northwind = PipelineRef(organization: "northwind", projectId: "p1", projectName: "Shop", definitionId: 7, name: "deploy")
        server.on("/contoso/p1/_apis/build/builds", json: Fixture.list([WorkFixture.build(42, definition: 31, queued: t(-hour))]))
        server.on("/_apis/build/builds/42/timeline", json: WorkFixture.timeline([WorkFixture.record("s", "Stage", "Build", order: 1)]))
        server.put("fabrikam", in: Tenants.other)
        server.on("/northwind/p1/_apis/build/builds") { _ in .status(500) }
        let others = "Couldn't read northwind (Azure DevOps answered with HTTP 500.)."
        let engine = PipelinesEngine(
            client: server.client(tokens: tokens), configuration: PipelinesEngine.Configuration(pipelines: [contoso, fabrikam, northwind])
        ) { _ in }
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        // contoso's still show; signing in to fabrikam's directory comes first, then why northwind's don't.
        #expect(snapshot.statuses.first { $0.pipeline.organization == "contoso" }?.runs.map(\.id) == [42])
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: others))

        // With none read, one that failed before it doesn't hide it.
        let failing = StubServer()
        failing.on("/contoso/p1/_apis/build/builds") { _ in .status(500) }
        failing.put("fabrikam", in: Tenants.other)
        let none = await PipelinesEngine.loadOnce(
            client: failing.client(tokens: FakeTokens(failing.id, tenant: Tenants.home)),
            configuration: PipelinesEngine.Configuration(pipelines: [contoso, fabrikam])
        )
        #expect(none.problem == .otherDirectory(
            organizations: ["fabrikam"], tenant: Tenants.other, others: "Couldn't read contoso (Azure DevOps answered with HTTP 500.)."
        ))
    }

    @Test func anOrganizationInAnotherDirectoryIsAskedOnceARefreshForItsPinnedPipelines() async throws {
        let server = StubServer()
        let web = PipelineRef(organization: "fabrikam", projectId: "p1", projectName: "Shop", definitionId: 31, name: "web CI")
        let api = PipelineRef(organization: "fabrikam", projectId: "p2", projectName: "Other", definitionId: 40, name: "api CI")
        server.put("fabrikam", in: Tenants.other)
        let snapshot = await PipelinesEngine.loadOnce(
            client: server.client(tokens: FakeTokens(server.id, tenant: Tenants.home)),
            configuration: PipelinesEngine.Configuration(pipelines: [web, api])
        )
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
        // Its first project's pipelines say where it is; its other project's aren't asked for, this refresh.
        #expect(server.requests.count == 1)
    }

    @Test func aRunsStagesWaitingOnASignInSaySoAndAreTriedAgainAtEachRefresh() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        let web = PipelineRef(organization: "fabrikam", projectId: "p1", projectName: "Shop", definitionId: 31, name: "web CI")
        // fabrikam's runs are read, but its run's stages answer that they're in a directory to sign in to, as when that
        // sign-in has just run out.
        server.on("/fabrikam/p1/_apis/build/builds", json: Fixture.list([
            WorkFixture.build(42, definition: 31, status: "inProgress", result: nil, queued: t(-hour)),
        ]))
        server.on("/fabrikam/p1/_apis/build/builds/42/timeline") { _ in .status(401, headers: ["X-VSS-ResourceTenant": Tenants.other]) }
        let clock = Locked(t(0))
        let engine = PipelinesEngine(
            client: server.client(tokens: tokens), configuration: PipelinesEngine.Configuration(pipelines: [web]), now: { clock.value }
        ) { _ in }
        func timelines() -> Int { server.requests.compactMap(\.url?.path).filter { $0.hasSuffix("/timeline") }.count }

        await engine.refreshNow()
        var snapshot = await engine.currentSnapshot()
        #expect(snapshot.statuses.first?.runs.map(\.id) == [42])
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
        // Not a timeline that keeps failing, waited on longer and longer: it's tried again at each refresh.
        clock.set(t(60))
        await engine.refreshNow()
        clock.set(t(61))
        await engine.refreshNow()
        #expect(timelines() == 3)
        // So signing in there reads it at the next one.
        await tokens.signIn(to: Tenants.other)
        server.on("/fabrikam/p1/_apis/build/builds/42/timeline", json: WorkFixture.timeline([
            WorkFixture.record("s", "Stage", "Build", order: 1, state: "inProgress", result: nil),
        ]))
        clock.set(t(62))
        await engine.refreshNow()
        snapshot = await engine.currentSnapshot()
        #expect(snapshot.statuses.first?.stages.map(\.name) == ["Build"])
        #expect(snapshot.problem == nil)
    }

    @Test func runsWaitingOnASignInTakeTheirTurnsBehindTheOthers() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        // Six of fabrikam's pipelines come first, a refresh's worth, with runs read whose stages wait on a sign-in to its
        // directory; northwind's comes after them.
        let fabrikam = (1...6).map {
            PipelineRef(organization: "fabrikam", projectId: "p1", projectName: "Shop", definitionId: $0, name: "CI \($0)")
        }
        let northwind = PipelineRef(organization: "northwind", projectId: "p1", projectName: "Shop", definitionId: 7, name: "deploy")
        server.on("/fabrikam/p1/_apis/build/builds", json: Fixture.list((1...6).map {
            WorkFixture.build(100 + $0, definition: $0, status: "inProgress", result: nil, queued: t(-hour))
        }))
        for build in 101...106 {
            server.on("/fabrikam/p1/_apis/build/builds/\(build)/timeline") { _ in .status(401, headers: ["X-VSS-ResourceTenant": Tenants.other]) }
        }
        server.on("/northwind/p1/_apis/build/builds", json: Fixture.list([
            WorkFixture.build(207, definition: 7, status: "inProgress", result: nil, queued: t(-hour)),
        ]))
        server.on("/northwind/p1/_apis/build/builds/207/timeline", json: WorkFixture.timeline([
            WorkFixture.record("s", "Stage", "Deploy", order: 1, state: "inProgress", result: nil),
        ]))
        let clock = Locked(t(0))
        let engine = PipelinesEngine(
            client: server.client(tokens: tokens), configuration: PipelinesEngine.Configuration(pipelines: fabrikam + [northwind]),
            now: { clock.value }
        ) { _ in }
        func northwindStages() async -> [String]? {
            await engine.currentSnapshot().statuses.first { $0.pipeline.organization == "northwind" }?.stages.map(\.name)
        }
        await engine.refreshNow()
        #expect(await northwindStages() == [])
        // fabrikam's go behind it, though they aren't timelines that keep failing: northwind's stages are read next.
        clock.set(t(60))
        await engine.refreshNow()
        #expect(await northwindStages() == ["Deploy"])
        #expect(await engine.currentSnapshot().problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
    }

    @Test func theSprintSaysWhichOrganizationsTeamsAreInAnotherDirectory() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")])
        server.put("fabrikam", in: Tenants.other)
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam"], team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        // Your team's sprint shows, and fabrikam's teams, which may have yours, say what to do.
        #expect(snapshot.board?.sprint.name == "Sprint 7")
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
    }

    @Test func aTeamYouChoseIsReadWhileTheTeamsOfTheOrganizationsYouWatchWaitOnASignIn() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")])
        server.put("fabrikam", in: Tenants.other)
        // You chose contoso's team, and watch only fabrikam now, whose teams are in a directory to sign in to.
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: ["fabrikam"], team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.sprint.name == "Sprint 7")
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
    }

    @Test func theSprintNamesEveryOrganizationToSignInToWhenNoTeamsCanBeRead() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.put("fabrikam", in: Tenants.other)
        server.put("northwind", in: Tenants.other)
        server.on("/tailspin/_apis/teams") { _ in .status(500) }
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: ["fabrikam", "northwind", "tailspin"], interval: 300),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().problem == .otherDirectory(
            organizations: ["fabrikam", "northwind"], tenant: Tenants.other,
            others: "Couldn't read tailspin (Azure DevOps answered with HTTP 500.)."
        ))
        // Nothing could be read: a sign-in there is picked up within a minute.
        #expect(await engine.nextDelay() == 60)
    }

    @Test func aTeamFoundWhileSomeTeamsWaitOnASignInIsKeptOnlyOnceItsComparedWithThem() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        let web = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "Web Team")
        WorkFixture.serve(
            server, sprints: [WorkFixture.team.id: [WorkFixture.iteration()], web.id: [WorkFixture.iteration("i9", name: "Sprint 9")]],
            relations: ["i1": WorkFixture.relations([1]), "i9": WorkFixture.relations([5])],
            items: [WorkFixture.workItem(1, "User Story"), WorkFixture.workItem(5, "Task", "Yours", assignee: People.me)]
        )
        server.on("/fabrikam/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/fabrikam/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(web)]))
        server.put("fabrikam", in: Tenants.other)
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam"]),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        var snapshot = await engine.currentSnapshot()
        // contoso's team's sprint shows, but isn't one for the app to keep: fabrikam's teams may have more of your work.
        #expect(snapshot.board?.team.id == WorkFixture.team.id)
        #expect(snapshot.foundTeam == nil)
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))

        // Signed in there, the team with the most of your work is found among them all, and is the one to keep.
        await tokens.signIn(to: Tenants.other)
        await engine.refreshNow()
        snapshot = await engine.currentSnapshot()
        #expect(snapshot.foundTeam == web)
        #expect(snapshot.board?.team.id == web.id)
        #expect(snapshot.problem == nil)
    }

    @Test func aTeamFoundWhileSomeTeamsWaitOnASignInIsLookedForAgainAsEachDirectoryIsSignedInTo() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        let web = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "Web Team")
        WorkFixture.serve(
            server, sprints: [WorkFixture.team.id: [WorkFixture.iteration()], web.id: [WorkFixture.iteration("i9", name: "Sprint 9")]],
            relations: ["i1": WorkFixture.relations([1]), "i9": WorkFixture.relations([5])],
            items: [WorkFixture.workItem(1, "User Story"), WorkFixture.workItem(5, "Task", "Yours", assignee: People.me)]
        )
        server.on("/fabrikam/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/fabrikam/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(web)]))
        server.put("fabrikam", in: Tenants.other)
        server.put("northwind", in: Tenants.third)
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam", "northwind"]),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().board?.team.id == WorkFixture.team.id)

        // Signed in to fabrikam's directory, its team, with more of your work, is found; northwind's teams still wait on a
        // sign-in, so it isn't kept yet.
        await tokens.signIn(to: Tenants.other)
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.team.id == web.id)
        #expect(snapshot.foundTeam == nil)
        #expect(snapshot.problem == .otherDirectory(organizations: ["northwind"], tenant: Tenants.third, others: nil))
    }

    @Test func aTeamWhoseSprintWaitsOnASignInIsSaidAndWhatsFoundMeanwhileIsntKept() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        let web = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "Web Team")
        WorkFixture.serve(
            server, sprints: [WorkFixture.team.id: [WorkFixture.iteration()], web.id: [WorkFixture.iteration("i9", name: "Sprint 9")]],
            relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")]
        )
        server.on("/fabrikam/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/fabrikam/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(web)]))
        server.put("fabrikam", in: Tenants.other)
        // Your teams are read with the team you chose.
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam"], team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().teams.map(\.id) == [WorkFixture.team.id, web.id])

        // BriefBar then looks for one, once the Azure CLI has signed out of fabrikam's directory: its team's sprint can't
        // be read, so it's said, and the team found meanwhile isn't kept.
        await tokens.signOut(of: Tenants.other)
        await engine.setConfiguration(SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam"]))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.team.id == WorkFixture.team.id)
        #expect(snapshot.foundTeam == nil)
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
    }

    @Test func whenNoTeamsSprintCanBeReadForWantOfASignInItsLookedAtAgainWithinAMinute() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        let web = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "Web Team")
        WorkFixture.serve(
            server, sprints: [WorkFixture.team.id: [WorkFixture.iteration()], web.id: [WorkFixture.iteration("i9", name: "Sprint 9")]],
            relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")]
        )
        server.on("/fabrikam/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(web)]))
        server.put("fabrikam", in: Tenants.other)
        // fabrikam's teams are read while contoso's team, which you chose, shows.
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: ["fabrikam"], team: WorkFixture.team, interval: 300),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()

        // BriefBar then looks for one of your teams, once the Azure CLI has signed out of fabrikam's directory.
        await tokens.signOut(of: Tenants.other)
        await engine.setConfiguration(SprintEngine.Configuration(organizations: ["fabrikam"], interval: 300))
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
        #expect(await engine.nextDelay() == 60)
    }

    @Test func theSprintWaitsAsAzureDevOpsAsksBeforeAnySignIn() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.put("fabrikam", in: Tenants.other)
        server.on("/northwind/_apis/teams") { _ in .status(429, headers: ["Retry-After": "120"]) }
        let engine = SprintEngine(
            client: server.client(tokens: tokens), configuration: SprintEngine.Configuration(organizations: ["fabrikam", "northwind"]),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        let problem = await engine.currentSnapshot().problem
        var throttled = false
        if case .throttled? = problem { throttled = true }
        #expect(throttled)
    }

    @Test func theSprintSaysWhyOtherOrganizationsTeamsCouldntBeReadWithADirectoryToSignInTo() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")])
        server.put("fabrikam", in: Tenants.other)
        server.on("/northwind/_apis/teams") { _ in .status(500) }
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam", "northwind"], team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.sprint.name == "Sprint 7")
        #expect(snapshot.problem == .otherDirectory(
            organizations: ["fabrikam"], tenant: Tenants.other, others: "Couldn't read northwind (Azure DevOps answered with HTTP 500.)."
        ))
    }

    @Test func theSprintSaysWhyItsTeamCouldntBeReadWithADirectoryToSignInTo() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        WorkFixture.serve(server)
        server.on("/iterations/i1/workitems") { _ in .status(500) }
        server.put("fabrikam", in: Tenants.other)
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam"], team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        // Signing in to fabrikam's directory is still offered, with why your team's sprint couldn't be read.
        #expect(await engine.currentSnapshot().problem == .otherDirectory(
            organizations: ["fabrikam"], tenant: Tenants.other, others: "Couldn't read contoso (Azure DevOps answered with HTTP 500.)."
        ))
    }

    @Test func aTeamFoundWhileSomeTeamsWaitOnASignInStaysUnkeptUntilTheirTeamsAreRead() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")])
        server.on("/fabrikam/_apis/teams") { _ in .status(500) }
        server.put("fabrikam", in: Tenants.other)
        let engine = SprintEngine(
            client: server.client(tokens: tokens), configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam"]),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().foundTeam == nil)

        // Signed in to fabrikam's directory, its teams can't be read for another reason: they still haven't been compared.
        await tokens.signIn(to: Tenants.other)
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.team.id == WorkFixture.team.id)
        #expect(snapshot.foundTeam == nil)
    }

    @Test func aTeamFoundWhileSomeTeamsWaitOnASignInIsComparedAgainWhenAnotherDirectoryComesBack() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.third)
        let shipping = TeamRef(organization: "northwind", projectId: "p8", projectName: "Ship", id: "t8", name: "Ship Team")
        // northwind's team has no sprint at first. (Before the fixture's routes, so its work items' route comes first.)
        let hasSprint = Locked(false)
        server.on("/t8/_apis/work/teamsettings/iterations") { _ in
            .json(Fixture.list(hasSprint.value ? [WorkFixture.iteration("i8", name: "Sprint 8")] : []))
        }
        WorkFixture.serve(
            server, relations: ["i1": WorkFixture.relations([1]), "i8": WorkFixture.relations([5])],
            items: [WorkFixture.workItem(1, "User Story"), WorkFixture.workItem(5, "Task", "Yours", assignee: People.me)]
        )
        server.on("/northwind/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/northwind/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(shipping)]))
        server.put("fabrikam", in: Tenants.other)
        server.put("northwind", in: Tenants.third)
        let clock = Locked(t(0))
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam", "northwind"]),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        // contoso's team is found while fabrikam's teams wait on a sign-in.
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().board?.team.id == WorkFixture.team.id)

        // Hours later, northwind's directory wants a sign-in too; signed in there again later, its team has a sprint with
        // your work, and it's compared, though fabrikam's teams still wait.
        await tokens.signOut(of: Tenants.third)
        clock.set(t(SprintEngine.teamsLifetime + 60))
        await engine.refreshNow()
        await tokens.signIn(to: Tenants.third)
        hasSprint.set(true)
        clock.set(t(2 * SprintEngine.teamsLifetime + 120))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.team.id == shipping.id)
        #expect(snapshot.foundTeam == nil)
    }

    @Test func whenEveryTeamReadBeforeWaitsOnASignInItsLookedAtAgainWithinAMinute() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        let web = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "Web Team")
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")])
        server.on("/fabrikam/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(web)]))
        server.put("fabrikam", in: Tenants.other)
        let clock = Locked(t(0))
        // fabrikam's teams are read while contoso's team, which you chose, shows.
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: ["fabrikam"], team: WorkFixture.team, interval: 300),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()

        // Hours later, BriefBar looks for one of your teams, and the Azure CLI has signed out of fabrikam's directory: the
        // teams read before wait on that sign-in, and nothing else can be read.
        await tokens.signOut(of: Tenants.other)
        await engine.setConfiguration(SprintEngine.Configuration(organizations: ["fabrikam"], interval: 300))
        clock.set(t(SprintEngine.teamsLifetime + 60))
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
        #expect(await engine.nextDelay() == 60)
    }

    @Test func teamsOfManyOrganizationsWaitingOnASignInDontUseUpTheTeamsTried() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        // As many organizations as teams are tried in a refresh, a team each, before contoso.
        let elsewhere = (1...SprintEngine.teamsToTry).map { "adatum\($0)" }
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")])
        for (index, organization) in elsewhere.enumerated() {
            let team = TeamRef(organization: organization, projectId: "p\(index)", projectName: "Web", id: "w\(index)", name: "Web")
            server.on("/\(organization)/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(team)]))
            server.put(organization, in: Tenants.other)
        }
        let organizations = elsewhere + [Fixture.org]
        // Your teams are read with the team you chose.
        let engine = SprintEngine(
            client: server.client(tokens: tokens), configuration: SprintEngine.Configuration(organizations: organizations, team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().teams.count == SprintEngine.teamsToTry + 1)

        // BriefBar then looks for one, once the Azure CLI has signed out of their directory: contoso's is tried after them.
        await tokens.signOut(of: Tenants.other)
        await engine.setConfiguration(SprintEngine.Configuration(organizations: organizations))
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().board?.team.id == WorkFixture.team.id)
    }

    @Test func aTeamFoundWhileAnOrganizationWaitsOnASignInStaysUnkeptWhenItsTeamsThenFailOtherwise() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        let web = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "Web Team")
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")])
        let failing = Locked(false)
        server.on("/fabrikam/_apis/teams") { _ in failing.value ? .status(500) : .json(Fixture.list([WorkFixture.teamJSON(web)])) }
        server.put("fabrikam", in: Tenants.other)
        let organizations = [Fixture.org, "fabrikam"]
        let clock = Locked(t(0))
        // Your teams are read with the team you chose.
        let engine = SprintEngine(
            client: server.client(tokens: tokens), configuration: SprintEngine.Configuration(organizations: organizations, team: WorkFixture.team),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()

        // Hours later, BriefBar looks for one while fabrikam's directory wants a sign-in: contoso's is found, but not kept.
        await tokens.signOut(of: Tenants.other)
        await engine.setConfiguration(SprintEngine.Configuration(organizations: organizations))
        clock.set(t(SprintEngine.teamsLifetime + 60))
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().foundTeam == nil)

        // Signed in there, fabrikam's teams fail otherwise: they still haven't been compared, so it's still not kept.
        await tokens.signIn(to: Tenants.other)
        failing.set(true)
        clock.set(t(2 * SprintEngine.teamsLifetime + 120))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.team.id == WorkFixture.team.id)
        #expect(snapshot.foundTeam == nil)
    }

    @Test func aTeamFoundWhoseOrganizationThenWaitsOnASignInIsntShownForAnother() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        let web = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "Web Team")
        WorkFixture.serve(
            server, sprints: [WorkFixture.team.id: [WorkFixture.iteration()], web.id: [WorkFixture.iteration("i9", name: "Sprint 9")]],
            relations: ["i1": WorkFixture.relations([1]), "i9": WorkFixture.relations([5])],
            items: [WorkFixture.workItem(1, "User Story"), WorkFixture.workItem(5, "Task", "Yours", assignee: People.me)]
        )
        server.on("/fabrikam/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/fabrikam/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(web)]))
        server.put("fabrikam", in: Tenants.other)
        server.put("northwind", in: Tenants.third)
        let clock = Locked(t(0))
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam", "northwind"]),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        // fabrikam's team has more of your work; northwind's teams wait on a sign-in, so it isn't kept yet.
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().board?.team.id == web.id)

        // Hours later, the Azure CLI has signed out of fabrikam's directory: its teams wait on a sign-in too, and
        // contoso's team shows instead.
        await tokens.signOut(of: Tenants.other)
        clock.set(t(SprintEngine.teamsLifetime + 60))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.team.id == WorkFixture.team.id)
        #expect(snapshot.foundTeam == nil)
        #expect(snapshot.problem?.signInTenant == Tenants.other)
    }

    @Test func aTeamFoundWhoseBoardThenWaitsOnASignInIsntShownNorKept() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        let web = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "Web Team")
        WorkFixture.serve(
            server, sprints: [WorkFixture.team.id: [WorkFixture.iteration()], web.id: [WorkFixture.iteration("i9", name: "Sprint 9")]],
            relations: ["i1": WorkFixture.relations([1]), "i9": WorkFixture.relations([5])],
            items: [WorkFixture.workItem(1, "User Story"), WorkFixture.workItem(5, "Task", "Yours", assignee: People.me)]
        )
        server.on("/fabrikam/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/fabrikam/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(web)]))
        server.put("fabrikam", in: Tenants.other)
        let clock = Locked(t(0))
        let engine = SprintEngine(
            client: server.client(tokens: tokens), configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam"]),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        // fabrikam's team has more of your work: it's found, and kept.
        await engine.refreshNow()
        var snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.team.id == web.id)
        #expect(snapshot.foundTeam == web)

        // A minute later, the Azure CLI has signed out of fabrikam's directory, which only its board's next read tells, its
        // teams and sprint being known: fabrikam waits on a sign-in, and contoso's team shows instead, not kept.
        await tokens.signOut(of: Tenants.other)
        clock.set(t(60))
        await engine.refreshNow()
        snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.team.id == WorkFixture.team.id)
        #expect(snapshot.foundTeam == nil)
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
    }

    /// A team found for you is set aside once its organization waits on a sign-in: when its board is read, or your teams
    /// are read again. If the team looked at instead can't be read, its board isn't shown meanwhile.
    @Test(arguments: [60, SprintEngine.teamsLifetime + 60])
    func aTeamSetAsideForASignInIsntShownWhenTheNextCantBeRead(after gap: TimeInterval) async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        let web = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "Web Team")
        WorkFixture.serve(
            server, sprints: [WorkFixture.team.id: [WorkFixture.iteration()], web.id: [WorkFixture.iteration("i9", name: "Sprint 9")]],
            relations: ["i9": WorkFixture.relations([5])],
            items: [WorkFixture.workItem(1, "User Story"), WorkFixture.workItem(5, "Task", "Yours", assignee: People.me)]
        )
        // contoso's sprint's work can be read at first, and not later.
        let failing = Locked(false)
        server.on("/iterations/i1/workitems") { _ in failing.value ? .status(500) : .json(WorkFixture.relations([1])) }
        server.on("/fabrikam/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/fabrikam/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(web)]))
        server.put("fabrikam", in: Tenants.other)
        let clock = Locked(t(0))
        let engine = SprintEngine(
            client: server.client(tokens: tokens), configuration: SprintEngine.Configuration(organizations: [Fixture.org, "fabrikam"]),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().board?.team.id == web.id)

        // Later, fabrikam waits on a sign-in, and contoso's team, looked at instead, can't be read: fabrikam's board doesn't
        // stay shown meanwhile.
        await tokens.signOut(of: Tenants.other)
        failing.set(true)
        clock.set(t(gap))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board == nil)
        #expect(snapshot.foundTeam == nil)
        #expect(snapshot.problem == .otherDirectory(
            organizations: ["fabrikam"], tenant: Tenants.other, others: "Couldn't read contoso (Azure DevOps answered with HTTP 500.)."
        ))
    }

    @Test func aTeamWhoseOrganizationThenWaitsOnASignInIsntFoundOnItsOwn() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        let first = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "A Team")
        let second = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t10", name: "B Team")
        // B Team's sprint can't be read at first. (Before the fixture's routes, which have none of B Team's.)
        server.on("/t10/_apis/work/teamsettings/iterations") { _ in .status(500) }
        WorkFixture.serve(
            server, sprints: [first.id: [WorkFixture.iteration("i9", name: "Sprint 9")]],
            relations: ["i9": WorkFixture.relations([5])], items: [WorkFixture.workItem(5, "Task", "Yours", assignee: People.me)]
        )
        server.on("/fabrikam/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/fabrikam/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(first), WorkFixture.teamJSON(second)]))
        server.put("fabrikam", in: Tenants.other)
        let clock = Locked(t(0))
        let engine = SprintEngine(
            client: server.client(tokens: tokens), configuration: SprintEngine.Configuration(organizations: ["fabrikam"]),
            now: { clock.value }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().board?.team.id == first.id)
        func boardReads() -> Int { server.requests.filter { $0.url?.path.contains("/iterations/i9/workitems") == true }.count }
        let before = boardReads()

        // A minute later, signed out of fabrikam's directory, BriefBar looks for your team again, as you now watch contoso
        // too: A Team's sprint is still known, and B Team's tells that fabrikam waits on a sign-in. A Team isn't found on
        // its own then, nor its board asked for. (contoso's team has no sprint.)
        await tokens.signOut(of: Tenants.other)
        clock.set(t(60))
        await engine.setConfiguration(SprintEngine.Configuration(organizations: ["fabrikam", Fixture.org]))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(boardReads() == before)
        #expect(snapshot.board == nil)
        #expect(snapshot.foundTeam == nil)
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
    }

    @Test func theSprintSaysWhyOtherOrganizationsTeamsCouldntBeReadBesideATeamYouChose() async throws {
        let server = StubServer()
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")])
        server.on("/northwind/_apis/teams") { _ in .status(500) }
        let engine = SprintEngine(
            client: server.client(),
            configuration: SprintEngine.Configuration(organizations: [Fixture.org, "northwind"], team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        // Your team's sprint shows, and why northwind's teams, which the team picker lacks, couldn't be read.
        #expect(snapshot.board?.sprint.name == "Sprint 7")
        #expect(snapshot.problem == .someOrganizations("Couldn't read northwind (Azure DevOps answered with HTTP 500.)."))
    }

    @Test func teamsWaitingOnASignInDontTakeTheTurnsOfOthers() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        // More of fabrikam's teams than are tried in a refresh, before contoso's.
        let many = (1...SprintEngine.teamsToTry).map {
            TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "w\($0)", name: "Web \($0)")
        }
        WorkFixture.serve(server, relations: ["i1": WorkFixture.relations([1])], items: [WorkFixture.workItem(1, "User Story")])
        server.on("/fabrikam/_apis/teams", json: Fixture.list(many.map(WorkFixture.teamJSON)))
        server.put("fabrikam", in: Tenants.other)
        // Your teams are read with the team you chose.
        let engine = SprintEngine(
            client: server.client(tokens: tokens),
            configuration: SprintEngine.Configuration(organizations: ["fabrikam", Fixture.org], team: WorkFixture.team),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().teams.count == SprintEngine.teamsToTry + 1)

        // BriefBar then looks for one, once the Azure CLI has signed out of fabrikam's directory: after the first of
        // fabrikam's, contoso's is tried.
        await tokens.signOut(of: Tenants.other)
        await engine.setConfiguration(SprintEngine.Configuration(organizations: ["fabrikam", Fixture.org]))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.team.id == WorkFixture.team.id)
        #expect(snapshot.problem?.signInTenant == Tenants.other)
    }

    @Test func aTeamWhoseWorkCantBeComparedForWantOfASignInIsLeftOut() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        await tokens.signIn(to: Tenants.other)
        let web = TeamRef(organization: "fabrikam", projectId: "p9", projectName: "Web", id: "t9", name: "Web Team")
        WorkFixture.serve(
            server, sprints: [WorkFixture.team.id: [WorkFixture.iteration()], web.id: [WorkFixture.iteration("i9", name: "Sprint 9")]],
            relations: ["i1": WorkFixture.relations([1]), "i9": WorkFixture.relations([5])],
            items: [WorkFixture.workItem(1, "User Story"), WorkFixture.workItem(5, "Task", "Yours", assignee: People.me)]
        )
        server.on("/fabrikam/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/fabrikam/_apis/teams", json: Fixture.list([WorkFixture.teamJSON(web)]))
        server.put("fabrikam", in: Tenants.other)
        let organizations = [Fixture.org, "fabrikam"]
        let engine = SprintEngine(
            client: server.client(tokens: tokens), configuration: SprintEngine.Configuration(organizations: organizations),
            now: { t(0) }, calendar: WorkFixture.utc
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().board?.team.id == web.id)

        // You choose contoso's team, then let BriefBar look again, once the Azure CLI has signed out of fabrikam's
        // directory: both teams' sprints are known, but fabrikam's work can't be read to compare.
        await engine.setConfiguration(SprintEngine.Configuration(organizations: organizations, team: WorkFixture.team))
        await engine.setConfiguration(SprintEngine.Configuration(organizations: organizations))
        await tokens.signOut(of: Tenants.other)
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.board?.team.id == WorkFixture.team.id)
        #expect(snapshot.foundTeam == nil)
        #expect(snapshot.problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
    }

    // MARK: Finding and adding organizations

    @Test func findsYourPullRequestsInAnotherDirectoryOnceSignedInThere() async {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.serveOrganization("fabrikam", mine: [Fixture.pullRequest(1)])
        server.put("fabrikam", in: Tenants.other)
        let client = server.client(tokens: tokens)
        // Not signed in there: neither a failure to try again soon, nor one without pull requests of yours, but one to look
        // in again once signed in there.
        var probe = await OrganizationDiscovery.probe(["fabrikam"], client: client)
        #expect(probe.withPullRequests.isEmpty)
        #expect(probe.failures.isEmpty)
        #expect(probe.elsewhere == ["fabrikam"])
        await tokens.signIn(to: Tenants.other)
        probe = await OrganizationDiscovery.probe(["fabrikam"], client: client)
        #expect(probe.withPullRequests == ["fabrikam"])
        #expect(probe.elsewhere.isEmpty)
    }

    @Test func checksAnOrganizationAsYouAddIt() async {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.on("/_apis/profile/profiles/me", json: ["id": "profile-id", "publicAlias": "alias"])
        server.on("/_apis/accounts", query: ["memberId": "alias"], json: Fixture.list([["accountName": "contoso"], ["accountName": "Locked"]]))
        server.on("/contoso/_apis/connectionData", json: ["authenticatedUser": ["id": "ME"]])
        server.on("/locked/_apis/connectionData") { _ in .status(403) }
        // Another organization in your directory, which isn't yours: a project's name, perhaps.
        server.on("/web/_apis/connectionData") { _ in .status(401) }
        server.on("/offline/_apis/connectionData") { _ in .failure(.notConnectedToInternet) }
        server.put("fabrikam", in: Tenants.other)
        // A project's name, entered as an organization's, which is another organization's, in another directory.
        server.put("shop", in: Tenants.third)
        let client = server.client(tokens: tokens)

        #expect(await OrganizationDiscovery.access(to: "contoso", client: client) == .readable)
        #expect(await OrganizationDiscovery.access(to: "fabrikam", client: client) == .otherDirectory(tenant: Tenants.other))
        #expect(await OrganizationDiscovery.access(to: "shop", client: client) == .otherDirectory(tenant: Tenants.third))
        #expect(await OrganizationDiscovery.access(to: "web", client: client) == .notYours)
        // Azure DevOps has none by that name.
        #expect(await OrganizationDiscovery.access(to: "nowhere", client: client) == .notYours)
        #expect(await OrganizationDiscovery.access(to: "locked", client: client) == .unreadable(.forbidden))
        #expect(await OrganizationDiscovery.access(to: "offline", client: client) == .unchecked(.offline))
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func anOrganizationThatCantBeToldYoursIsWatched() async {
        let server = StubServer()
        server.on("/_apis/profile/profiles/me") { _ in .failure(.notConnectedToInternet) }
        server.on("/locked/_apis/connectionData") { _ in .status(403) }
        // Its list says why it can't be read, once it's watched.
        let access = await OrganizationDiscovery.access(to: "locked", client: server.client(tokens: FakeTokens(server.id, tenant: Tenants.home)))
        #expect(access == .unchecked(.offline))
        #expect(access.watches)
    }

    @Test func saysWhyAnOrganizationIsntAddedAndWhereAProjectsOrganizationIs() throws {
        let hint = "If shop is a project, its organization is the first part of its link: dev.azure.com/organization/shop."
        let elsewhere = OrganizationDiscovery.Access.otherDirectory(tenant: Tenants.third)
        let inAnotherDirectory = try #require(elsewhere.explanation(for: "shop"))
        #expect(inAnotherDirectory.title == "shop is in a directory your Azure CLI isn't signed in to")
        #expect(inAnotherDirectory.detail == "Sign in to it, and BriefBar reads shop with your other organizations. " + hint)
        #expect(!inAnotherDirectory.title.contains(Tenants.third) && !inAnotherDirectory.detail.contains(Tenants.third))
        #expect(elsewhere.watches)
        #expect(elsewhere.signInTenant == Tenants.third)

        let notYours = try #require(OrganizationDiscovery.Access.notYours.explanation(for: "shop"))
        #expect(notYours.title == "shop isn't one of your organizations")
        #expect(notYours.detail == "BriefBar didn't add it. " + hint)
        #expect(!OrganizationDiscovery.Access.notYours.watches)

        let unreadable = try #require(OrganizationDiscovery.Access.unreadable(.forbidden).explanation(for: "locked"))
        #expect(unreadable.title == "Your sign-in can't read locked")
        #expect(unreadable.detail == "BriefBar didn't add it. No access to this organization.")
        #expect(!OrganizationDiscovery.Access.unreadable(.forbidden).watches)

        // Readable, or not checked for now: it's watched without a word, and its list says what's wrong.
        #expect(OrganizationDiscovery.Access.readable.explanation(for: "contoso")?.title == nil)
        #expect(OrganizationDiscovery.Access.unchecked(.offline).explanation(for: "contoso")?.title == nil)
        #expect(OrganizationDiscovery.Access.unchecked(.offline).watches)
        #expect(OrganizationDiscovery.Access.readable.signInTenant == nil)
    }
}
