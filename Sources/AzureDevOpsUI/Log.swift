import BriefBarUI
import os

/// Diagnostics: `log show --last 10m --predicate 'subsystem == "com.asaf.BriefBar" && category == "azureDevOps"'`
///
/// Only counts, states and errors. Never titles or comments.
enum Log {
    static let app = Logger(subsystem: AppIdentity.bundleIdentifier, category: "azureDevOps")
}
