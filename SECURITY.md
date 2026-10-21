# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/mnsn/briefbar/security/advisories/new),
not in a public issue.

Describe what's affected, how to reproduce it and the impact you expect, with made-up data or
`--diagnose` output, never names, messages, titles or IDs from your own chats, pull requests or
sessions. This is a personal project maintained in spare time, so a reply may take a few days.

## Scope

BriefBar can hold Full Disk Access, which macOS grants to the whole app, to read the Teams
notifications in Notification Center's database. It keeps Teams' unread chats on disk, encrypted,
until they're read, and makes summaries on the Mac. Only its Azure DevOps source uses the network,
with the Azure CLI's sign-in. Worth reporting:

- any way it could send anything about your chats, pull requests or sessions anywhere but Azure DevOps
  (and anything but GET requests there), or expose it to other users or apps on the Mac (its saved
  chats, its log, its summaries),
- any way another app could use BriefBar's Full Disk Access: by injecting code into it, through a
  program it starts, or by signing itself with a key that BriefBar's builds are signed with,
- any way a source could read anything, or check its access, while it's off, or turn on without you,
- any way it could change Notification Center's data, the Copilot app's data, or anything in Azure
  DevOps, and
- problems with how the build scripts and workflows here create, sign or check the app.

Vulnerabilities in Microsoft Teams, Azure DevOps or the Azure CLI should go to the
[Microsoft Security Response Center](https://msrc.microsoft.com/report/vulnerability/new), and in the
GitHub Copilot app to [GitHub](https://bounty.github.com).

## Supported versions

Only the latest commit on `main` is supported. There are no releases yet.

## How BriefBar keeps its permissions to itself

- **Sources are off until you turn them on.** macOS asks for Full Disk Access and notifications only
  once for the whole app, so BriefBar's own consent comes first. A source reads nothing, and checks no
  access, while it's off. An update never turns one on, and a source that starts reading more pauses
  until you've looked.
- **Programs it starts are responsible for themselves.** macOS lets a program use the permissions of
  the app that started it. BriefBar starts every program (the Azure CLI, the login shell that finds
  it, `lsappinfo`) with that responsibility disclaimed, so none of them gets its Full Disk Access.
  `scripts/check-boundaries.sh` checks that nothing else in the app starts programs.
- **Only one module uses the network**, `AzureDevOpsCore`, and `scripts/check-boundaries.sh` checks
  that too.

## How the app is signed

macOS ties Full Disk Access to the app's signing certificate. Every build is signed with one, never ad
hoc, so the access survives rebuilds. The project has no Apple Developer ID, so the certificate is
self-signed: it tells macOS that a build comes from the same place as the last, but not who made it,
and the app isn't notarized.

- **The certificate's key.** Anything that can sign with the key could sign itself as BriefBar and
  get its Full Disk Access. So `make signing-identity` imports the key with an access list that trusts
  no app, not even `codesign`: each build asks for your login password. The build refuses to sign
  with a key that some app may use without asking, which is what **Always Allow** would do.
- **The hardened runtime.** Other processes can't inject code into BriefBar with `DYLD_` environment
  variables or a debugger, and use its Full Disk Access that way.
- **Library validation stays on.** The app has no entitlements and embeds no framework, so it loads
  only Apple's libraries and its own code.
- `scripts/check-app.sh` checks each build for these settings, and CI runs it.

## Releases and updates

None yet: while the repository is private, BriefBar is built from source. Releases will come once it's
public, built by GitHub Actions with an attestation. They'll be signed with a certificate of the
project's own and an update signing key, both held only by an approval-gated `release` environment and
the maintainer's password manager, never on a Mac. Whoever held the certificate's key could ship code
that inherits users' Full Disk Access.
