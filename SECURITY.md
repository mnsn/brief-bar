# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/mnsn/brief-bar/security/advisories/new),
not in a public issue.

Describe what's affected, how to reproduce it and the impact you expect, with made-up data or
`--diagnose` output, never names, messages, titles or IDs from your own chats, pull requests or
sessions. This is a personal project maintained in spare time, so a reply may take a few days.

## Scope

BriefBar can hold Full Disk Access, which macOS grants to the whole app, to read notifications in
Notification Center's database: Teams', and, only if you turn on Azure DevOps' Pull Requests Sent in
Chats, every app's, for links to pull requests. It keeps Teams' unread chats on disk, encrypted,
until they're read; keeps the links it finds in other apps' notifications in memory only; and makes
summaries on the Mac. Nothing else it reads in Notification Center is kept anywhere other programs
running as you can read it, such as its preferences or a temporary file: what its queries sort stays
in memory. Only its Azure DevOps and GitHub sources use the network for what they show, with the
Azure CLI's and the GitHub CLI's sign-ins. BriefBar's own requests are for its updates, from this
project's GitHub releases. Worth reporting:

- any way it could send anything about your chats, pull requests, work items, pipelines or sessions
  anywhere but Azure DevOps (and anything but GET requests there) and GitHub (and anything but its one
  read-only GraphQL query there), or expose it to other users or apps
  on the Mac (its saved chats, the links it finds in chats, its preferences, its log, its summaries),
  other than the work items you send to Copilot yourself, with Send Work to Copilot,
- any way another app could use BriefBar's Full Disk Access: by injecting code into it or into a copy
  of it, through a program it starts, its updater included, by starting it (with its command-line
  modes, arguments, environment or output), or by signing itself with a key that BriefBar's builds
  are signed with,
- any way a source could read anything, or check its access, while it's off, or turn on without you,
- any way it could change Notification Center's data, the Copilot app's data, or anything in Azure
  DevOps, or start Copilot, which changes your code and opens pull requests, without you sending it a
  work item,
- any way to make it install an update that the release workflow here didn't sign, and
- problems with how the build scripts and workflows here create, sign, check or publish the app.

Vulnerabilities in Microsoft Teams, Azure DevOps or the Azure CLI should go to the
[Microsoft Security Response Center](https://msrc.microsoft.com/report/vulnerability/new), and in the
GitHub Copilot app to [GitHub](https://bounty.github.com).

## Supported versions

Only the latest release, and the latest commit on `main`, are supported.

## How BriefBar keeps its permissions to itself

- **Sources are off until you turn them on.** macOS asks for Full Disk Access and notifications only
  once for the whole app, so BriefBar's own consent comes first. A source reads nothing, and checks no
  access, while it's off. An update never turns one on, and a source that starts reading more pauses
  until you've looked. Any program running as you can still turn a source on, or Pull Requests Sent
  in Chats, by changing BriefBar's preferences with `defaults write`, but that only makes BriefBar
  itself show what it reads: it keeps nothing it reads with Full Disk Access where such a program
  could read it ([How it works](docs/how-it-works.md#programs-that-start-briefbar)). Turning on Send
  Work to Copilot that way only adds its buttons: nothing is sent until you send it, and the tasks it
  keeps there can't point it at other files ([How it works](docs/how-it-works.md#send-work-to-copilot)).
- **Programs it starts are responsible for themselves.** macOS lets a program use the permissions of
  the app that started it. BriefBar starts every program (its updater, the Azure CLI, the GitHub CLI,
  the login shell that finds them, `lsappinfo`, and the Copilot CLI and git, for Send Work to
  Copilot) with that responsibility disclaimed, so none of them gets its Full Disk Access, and the
  updater and Copilot run only once macOS confirms it. `scripts/check-boundaries.sh` checks that
  nothing else in the app starts programs. Sparkle, in the updater, starts none either: it hands its
  installer to launchd.
- **Only two modules use the network**, `AzureDevOpsCore` and `GitHubCore`, and
  `scripts/check-boundaries.sh` checks that too. The other requests are Sparkle's, for this project's
  releases. GitHub's GraphQL API takes reads and writes alike as POST requests, so `GitHubCore` sends
  only one fixed query, which a test checks has no mutation, and keeps the GitHub CLI's token in memory.
- **What it reads with Full Disk Access stays with it.** Teams' unread chats are on disk only
  encrypted, with a key in your login keychain that the command line never uses. BriefBar names that
  keychain by its file, in your home folder as the user database names it, rather than using the
  default keychain and the search list, which any program running as you can change. The links it
  finds in other apps' notifications, and which of those pull requests you've seen, stay in memory.
  Its preferences, which any program running as you can read and change, hold its settings, which of
  your own pull requests you've seen, which Copilot sessions you've cleared and which work items you
  sent to Copilot, but nothing from Notification Center.

## How the app is signed

macOS ties Full Disk Access to the app's signing certificate, so every release is signed with the
same one, and updates keep the access. The project has no Apple Developer ID, so the certificate is
self-signed: it tells macOS that a new version comes from the same place as the last, but not who made
it, and the app isn't notarized.

- The app runs with the hardened runtime, so other processes can't inject code into it with `DYLD_`
  environment variables or a debugger, and use its Full Disk Access that way. That takes System
  Integrity Protection, which is on unless you turn it off: with it off, macOS doesn't stop programs
  from loading code into BriefBar, or into any other app, and BriefBar can't prevent that.
- It has no entitlements, so library validation is on: macOS loads into it only libraries that Apple
  signed, and it links only Apple's. macOS recognizes the app by its own executable's signature, so
  with library validation off, software running as you could copy the app anywhere, put its own code
  in one of the copy's frameworks, and run that code with BriefBar's Full Disk Access.
- Sparkle is in an app of its own inside BriefBar, `Contents/Helpers/BriefBar Updater.app`, the only
  part with library validation off (`com.apple.security.cs.disable-library-validation`, its only
  entitlement). With it on, macOS loads only libraries signed by Apple or by the app's own team, and a
  self-signed certificate has no team, so macOS would refuse even the updater's own copy of Sparkle.
  Code put in that copy runs as the updater, which has none of BriefBar's permissions: it has an
  identity of its own (`com.asaf.BriefBar.Updater`), and BriefBar starts it responsible for itself,
  and ends it if macOS says otherwise. A Developer ID would let Sparkle load with library validation
  on.
- Software running as you can also start BriefBar itself, unchanged, through LaunchServices (`open`)
  or with its responsibility disclaimed, and BriefBar then has its own Full Disk Access. That software
  chooses its arguments and environment, and can read its output (`open --stdout`). So then BriefBar
  runs none of its command-line modes or `--render`, only `--help` and `--check-updater`, which read
  nothing of yours; it ignores the variables that point it at other data and the preferences in its
  arguments, puts back `HOME` and `TMPDIR` and drops the variables that would move your keychain, your
  home folder, your temporary folders or SQLite's files, keeps the key to Teams' saved chats in your
  login keychain whatever they say, and sends its output to `/dev/null`
  ([How it works](docs/how-it-works.md#programs-that-start-briefbar)).
- `scripts/check-app.sh` checks each build for these settings, and CI runs it.
  `scripts/test-updater-isolation.sh` shows, on a copy of a build that macOS opens, that the updater
  is responsible for itself, and that an ad-hoc library put in place of Sparkle never runs as
  BriefBar; CI runs it too.
- Anything that can sign with the certificate's key can sign itself as BriefBar and inherit its Full
  Disk Access. So the release certificate, **BriefBar Release**, is on no Mac: it's made in memory,
  once, and kept only in the `release` environment's secrets and the maintainer's password manager.
- Builds from source are signed ad hoc, so there's no key on the Mac that could sign as them. The
  optional certificate that keeps their Full Disk Access across rebuilds (`make signing-identity`)
  trusts no app to use its key, not even `codesign`, which asks for the password every time, and its
  key can't be exported. `make app` refuses to sign with a key that some app may use without asking,
  signs with the certificate's SHA-1 rather than its name, and checks the signature afterwards.

## How updates are verified

The app updates itself with [Sparkle](https://sparkle-project.org), in its updater. It reads the
appcast, a small file that describes the latest release, from
`https://github.com/mnsn/brief-bar/releases/latest/download/appcast.xml`, and downloads the update
from the same release.

- The release workflow signs both the update's zip and the appcast with an EdDSA (Ed25519) key. The
  app has the public key in its `Info.plist` (`SUPublicEDKey`).
- The app rejects an appcast whose signature doesn't match (`SURequireSignedFeed`), with no fallback
  after a while (`SUSignedFeedFailureExpirationInterval` is 0). It checks the zip's signature before
  it even unpacks it (`SUVerifyUpdateBeforeExtraction`).
- The EdDSA signature is the main protection. The certificate is what keeps Full Disk Access.

The private keys of both exist only in the maintainer's password manager and in the secrets of the
`release` environment in GitHub Actions: `RELEASE_CERTIFICATE_P12` and `RELEASE_CERTIFICATE_PASSWORD`
for the certificate, and `SPARKLE_PRIVATE_KEY` for the update signing key.
`scripts/make-release-keys.sh` makes them in memory, so they're never written to a file or a keychain,
where any program running as the maintainer could use them. Only the job that signs a release can
read the secrets, and the environment waits for a maintainer to approve each release. That job
deletes its copy of the certificate right after signing. Before publishing, it checks that the
certificate is the one every release uses (`Resources/ReleaseRequirement.txt`) and that the
signatures match the public key in `Info.plist`.

If the update signing key were lost, users would have to download a new version by hand once,
because the app can't accept an update signed with a different key. If the certificate were lost, a
release signed with a new one would lose Full Disk Access, and users would have to grant it again.

## Verifying a download

Releases are built and published by the
[release workflow](https://github.com/mnsn/brief-bar/blob/main/.github/workflows/release.yml) from the
tagged source, with a build provenance attestation. To check that a `BriefBar.zip` you downloaded came
from it, use the [GitHub CLI](https://cli.github.com):

```sh
gh attestation verify BriefBar.zip --repo mnsn/brief-bar
```

The release's `appcast.xml` has an attestation too. Each release also lists the zip's SHA-256, which
`shasum -a 256 BriefBar.zip` prints.
