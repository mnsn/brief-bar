import AzureDevOpsCore
import Foundation
import Testing
@testable import AzureDevOpsUI

/// What Sign In runs in Terminal: `az login`, and for an organization in another directory, in that directory; and what
/// the command line and agents say to run instead.
@Suite struct SignInScriptTests {
    /// A made-up directory's ID.
    private static let tenant = "0b0b0b0b-2222-4222-8222-222222222222"

    @Test func signsInToTheAzureCLI() {
        let script = AzureDevOps.signInScript(azPath: nil, tenant: nil)
        #expect(script.hasPrefix("#!/bin/zsh -l\n"))
        #expect(script.contains("\naz login --allow-no-subscriptions --output none && "))
        #expect(script.contains("BriefBar will refresh within a minute."))
    }

    @Test func signsInToAnOrganizationsDirectoryWithItsID() {
        let script = AzureDevOps.signInScript(azPath: "/opt/homebrew/bin/az", tenant: Self.tenant)
        #expect(script.contains("\n'/opt/homebrew/bin/az' login --tenant '\(Self.tenant)' --allow-no-subscriptions --output none && "))
        // What it says names neither the directory nor the organization.
        #expect(script.contains("echo \"Signing in to the Azure CLI for BriefBar, in an organization's directory. Your browser will open.\""))
        #expect(script.components(separatedBy: Self.tenant).count == 2)
    }

    @Test func passesOnOnlyADirectorysID() {
        let script = AzureDevOps.signInScript(azPath: nil, tenant: "x'; rm -rf ~ #")
        #expect(script.contains("\naz login --allow-no-subscriptions --output none && "))
        #expect(!script.contains("rm -rf"))
    }

    /// The command line and agents have no Sign In button: they're told what to run, with the directory's ID, which
    /// signing in there needs.
    @Test func theCommandLineAndAgentsSayWhatToRun() {
        let error = ADOError.otherDirectory(organization: "fabrikam", tenant: Self.tenant)
        let sentence = "fabrikam is in a directory your Azure CLI isn't signed in to."
        #expect(AzureDevOpsCommandLine.describe(error) == "\(sentence) Run az login --tenant \(Self.tenant).")
        #expect(AzureDevOpsReader.describe(error) == "\(sentence) Run az login --tenant \(Self.tenant), then ask again.")
        #expect(AzureDevOpsCommandLine.describe(ADOError.forbidden) == "No access to this organization.")
        #expect(AzureDevOpsCommandLine.text(of: .signedOut("")) == "Sign in to the Azure CLI to see your pull requests. Run az login.")
        // The log gets neither the organization's name nor its directory's ID.
        #expect(!error.description.contains("fabrikam") && !error.description.contains(Self.tenant))
    }
}
