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

/// A made-up Azure CLI, signed in as an account from one directory, to some directories, one of them its default, as
/// `az login --tenant` leaves it.
final class FakeAzureCLI: ProcessRunning, Sendable {
    private struct State {
        var defaultTenant: String
        var signedIn: Set<String>
        /// The directory the signed-in account is from: elsewhere, it's a guest.
        var accountTenant: String
        var runs: [[String]] = []
    }

    private let state: Mutex<State>

    init(defaultTenant: String, signedIn: Set<String>, accountFrom accountTenant: String? = nil) {
        state = Mutex(State(defaultTenant: defaultTenant, signedIn: signedIn, accountTenant: accountTenant ?? defaultTenant))
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

    /// Someone else signs in, with an account from `tenant`, to these directories.
    func switchAccount(to tenant: String, signedIn: Set<String>) {
        state.withLock { state in
            state.accountTenant = tenant
            state.signedIn = signedIn
            state.defaultTenant = tenant
        }
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        let (tenant, isSignedIn, accountTenant) = state.withLock { state -> (String, Bool, String) in
            state.runs.append(arguments)
            let tenant = arguments.firstIndex(of: "--tenant").map { arguments[$0 + 1] } ?? state.defaultTenant
            return (tenant, state.signedIn.contains(tenant), state.accountTenant)
        }
        guard isSignedIn else {
            return ProcessResult(status: 1, stderr: Data("ERROR: AADSTS50076: Sign in with multi-factor authentication.\n".utf8))
        }
        let token = tenant == accountTenant
            ? madeUpToken(tenant: tenant) : madeUpToken(tenant: tenant, object: "robin-guest", guestFrom: accountTenant)
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
        // Someone else signs in while yours is kept: a token from fabrikam's directory is theirs.
        cli.switchAccount(to: Tenants.third, signedIn: [Tenants.third, Tenants.other])
        #expect(try await provider.token(tenant: Tenants.other).accountTenant == Tenants.third)
        // It isn't kept, and yours is asked for again, which tells who's signed in now.
        _ = try await provider.token(tenant: Tenants.other)
        #expect(try await provider.token().tenant == Tenants.third)
        #expect(cli.asked == [nil, Tenants.other, Tenants.other, Tenants.home, nil])
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

    @Test func organizationsWaitingOnASignInDontTakeTheReadsOfPullRequestsSentToYou() async throws {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.on("/contoso/_apis/connectionData", json: ["authenticatedUser": ["id": Fixture.me.uppercased()]])
        server.on("/contoso/_apis/git/pullrequests/11", json: Fixture.pullRequest(11, title: "Theirs", author: People.sam))
        server.on("/_apis/policy/evaluations", json: Fixture.list([]))
        server.on("/threads", json: Fixture.list([]))
        // Ten organizations in a directory to sign in to come first, as many as a refresh reads.
        let elsewhere = (1...10).map { "adatum\($0)" }
        for organization in elsewhere { server.put(organization, in: Tenants.other) }
        let engine = PulseEngine(client: server.client(tokens: tokens), configuration: PulseEngine.Configuration(organizations: [])) { _ in }
        await engine.setLinkedPullRequests(Set(elsewhere.map { PRKey($0, 1) } + [PRKey(Fixture.org, 11)]))
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.records.map(\.id) == [PRKey(Fixture.org, 11)])
        // Each was tried once, and is said.
        for organization in elsewhere {
            #expect(server.requests.filter { $0.url?.path.hasPrefix("/\(organization)/") == true }.count == 1)
        }
        #expect(snapshot.problem?.signInTenant == Tenants.other)
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

    // MARK: Finding and adding organizations

    @Test func findsYourPullRequestsInAnotherDirectoryOnceSignedInThere() async {
        let server = StubServer()
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        server.serveOrganization("fabrikam", mine: [Fixture.pullRequest(1)])
        server.put("fabrikam", in: Tenants.other)
        let client = server.client(tokens: tokens)
        // Not signed in there: nothing of yours to show, rather than a failure to try again.
        var probe = await OrganizationDiscovery.probe(["fabrikam"], client: client)
        #expect(probe.withPullRequests.isEmpty)
        #expect(probe.failures.isEmpty)
        await tokens.signIn(to: Tenants.other)
        probe = await OrganizationDiscovery.probe(["fabrikam"], client: client)
        #expect(probe.withPullRequests == ["fabrikam"])
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
