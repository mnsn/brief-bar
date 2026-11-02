import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI

/// Opening Azure DevOps pages, and signing in to the Azure CLI.
@MainActor
enum AzureDevOps {
    static let installCLIPage = URL(string: "https://learn.microsoft.com/cli/azure/install-azure-cli-macos")!

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// The "My pull requests" page of the first organization.
    static func openPullRequests(organizations: [String]) {
        guard let organization = organizations.first else {
            open(URL(string: "https://dev.azure.com")!)
            return
        }
        open(ADOEndpoint.myPullRequestsPage(organization: organization))
    }

    /// Opens Terminal running `az login`, which signs in through the browser; with `tenant`, in that directory, for the
    /// organizations in it. BriefBar picks the sign-in up on its next refresh.
    static func signIn(azPath: String?, tenant: String? = nil) {
        let script = signInScript(azPath: azPath, tenant: tenant)
        do {
            let directory = UserHome.url.appendingPathComponent("Library/Caches", isDirectory: true)
                .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Sign in to Azure CLI.command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            Log.app.error("Couldn't start az login: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What Terminal runs to sign in: `az login`, and with `tenant`, a directory's ID, `--tenant` with it: an
    /// organization's, or your sign-in's own. Only a GUID is passed on, as Azure DevOps names directories.
    nonisolated static func signInScript(azPath: String?, tenant: String?) -> String {
        let az = azPath.map(quoted) ?? "az"
        let directory = tenant.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
        let login = directory.map { "\(az) login --tenant \(quoted($0))" } ?? "\(az) login"
        let (signingIn, signedIn) = directory == nil
            ? ("Signing in to the Azure CLI for BriefBar.", "BriefBar will refresh within a minute.")
            : ("Signing in to the Azure CLI for BriefBar, in the directory it needs.", "BriefBar picks it up at its next refresh.")
        return """
            #!/bin/zsh -l
            # Opened by BriefBar, which reads your pull requests with the Azure CLI's sign-in.
            echo "\(signingIn) Your browser will open."
            echo
            \(login) --allow-no-subscriptions --output none && echo && echo "Signed in. You can close this window: \(signedIn)"
            """
    }

    /// Quoted for zsh.
    private nonisolated static func quoted(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
