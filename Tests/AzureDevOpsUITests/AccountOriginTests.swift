import AzureDevOpsCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Where the account BriefBar reads your pull requests with is from, kept for after a restart: it goes with what that
/// account has seen when Azure DevOps is turned off.
@MainActor
@Suite struct AccountOriginTests {
    /// A made-up directory's ID.
    private static let tenant = "0a0a0a0a-1111-4111-8111-111111111111"

    @Test func turningAzureDevOpsOffForgetsWhereYourAccountIsFrom() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.accountOrigin = Self.tenant
        #expect(defaults.string(forKey: SettingsKey.accountOrigin) == Self.tenant)
        settings.forgetSeen()
        #expect(settings.accountOrigin == nil)
        #expect(defaults.string(forKey: SettingsKey.accountOrigin) == nil)
    }
}
