import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// A made-up Microsoft Entra token for a directory, unsigned: only what BriefBar reads from it. A guest's names the
/// directory its account is from in `idp`.
private func madeUpToken(tenant: String, object: String = "robin", guestFrom home: String? = nil) -> String {
    func encoded(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let idp = home.map { #","idp":"https://sts.windows.net/\#($0)/""# } ?? ""
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
        await #expect(throws: AuthError.signedOut("AADSTS50076: Sign in with multi-factor authentication.")) {
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
        await #expect(throws: ADOError.otherDirectory(organization: "fabrikam", tenant: Tenants.other)) {
            try await client.get(url, as: ADOConnectionData.self)
        }
        #expect(server.requests.count == 1)
        // Once the Azure CLI is signed in there, it's read.
        await tokens.signIn(to: Tenants.other)
        #expect(try await client.get(url, as: ADOConnectionData.self).authenticatedUser.id == "ME")
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
        #expect(problem.signInCommand == "az login --tenant \(Tenants.other)")
        #expect(problem.offersSignIn && !problem.needsSignIn)

        let one = PulseProblem.from(.otherDirectory(organization: "fabrikam", tenant: Tenants.other))
        #expect(one.message == "fabrikam is in a directory your Azure CLI isn't signed in to.")
        let locked: [(organization: String, error: ADOError)] = [(organization: "locked", error: ADOError.forbidden)]
        #expect(PulseProblem.organizations(locked) == .someOrganizations("Couldn't read locked (No access to this organization.)."))
        #expect(PulseProblem.organizations([]) == nil)
        #expect(PulseProblem.signedOut("").signInCommand == "az login")
        #expect(PulseProblem.offline.signInCommand == nil)
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
