# Contributing to BriefBar

Bug reports, ideas and pull requests are welcome.

## Getting started

You need macOS 15 or later and Swift 6. Xcode works, and so do just the Command Line Tools.

```sh
git clone https://github.com/mnsn/brief-bar.git
cd brief-bar
make test    # run the tests
make demo    # run the app with made-up data for every source (Ctrl-C to quit)
```

`make demo` writes made-up Teams notifications in Notification Center's layout to `build/demo/teams`
and a made-up Copilot data directory to `build/demo/copilot`, and starts the app with `--demo`, which
turns every source on in preferences kept in memory. Azure DevOps makes up its own pull requests,
links sent in chats, sprint and pipelines, and never runs `az`, reaches Azure DevOps or reads
Notification Center. Use it to work on the UI and to take screenshots without
showing your own chats, pull requests or sessions. `make demo ARGS=--window` also opens the window.

Other targets:

```sh
make build              # debug build
make demo-check         # check that each source's made-up data lands in the expected groups and states
make check-boundaries   # check that only AzureDevOpsCore uses the network, and only BriefBarCore starts programs
make signing-key-check  # check what keeps signing keys safe, in throwaway keychains (it asks nothing)
make updater-check      # check, on a copy of build/BriefBar.app, that its updater can't use its permissions
make update-rehearsal   # install an update through the updater, in copies of build/BriefBar.app
make render             # draw the menu bar, lists, widgets, window and Settings from your own data into render/
make screenshots        # render the README's pictures from the demo data
make app                # build BriefBar.app into ./build, signed ad hoc
make install            # build the app, copy it to ~/Applications and open it
make signing-identity   # optional: a certificate that builds are then signed with, to keep Full Disk Access
make pppc-profile       # a configuration profile that grants the built app Full Disk Access, for MDM
make package            # what a release ships: the universal app, checked and zipped, in build/release
make icon               # regenerate Resources/AppIcon.icns
```

Builds are signed ad hoc, so each one needs Full Disk Access again: turning BriefBar off and on in the
list keeps the old build's signature, so run `tccutil reset SystemPolicyAllFiles com.asaf.BriefBar`
(or remove it with −) and add it again with +. [Signing](#signing) has the optional certificate that
keeps the access, and what `make package` needs.

These read your own data, for the sources that are on in the installed app, or the ones `--source`
names. They run only from a shell, such as Terminal's: started as an app (`open`), BriefBar refuses
them. Teams' modes read Notification Center with Terminal's Full Disk Access, never the unread chats
the app saved, so they count as unread only what arrived since the app last read Notification Center:

```sh
make run                          # the app, from a debug build, with its own preferences
make dump ARGS="--source copilot" # what a source shows
make watch                        # changes as they happen
make diagnose                     # Teams: the structure only, without names, messages or IDs
```

`BriefBar --chats` lists the pull request links in every app's notifications, as **Pull Requests Sent
in Chats** finds them, with Terminal's Full Disk Access. The other modes leave pull requests sent in
chats out: only the app has them, in memory. `--teams`, `--sprint` (`--team <name>`,
`--mine`) and `--pipelines` (`--search <text> --project <name>` to find more) print what the Sprint
and Pipelines sections show. They read the app's settings but never change them.

[How it works](docs/how-it-works.md) explains the sources, the permissions, the menu bar, the signing
and the updates.

## Project layout

```text
Sources/BriefBarCore/          shared, with no UI: file watching (FSEvents, kqueue), read-only SQLite,
                               timestamps, ProcessRunner (every program BriefBar starts), and the models
                               of the sources you turned on and of where sections show
Sources/NotificationCenterDB/  Notification Center's database: the records of the apps a source asks for
Sources/TeamsCore/             Teams' notifications, the unread rules, the encrypted unread chats
Sources/AzureDevOpsCore/       Azure DevOps: sign-in with the Azure CLI, the client (the only networking),
                               the engines (pull requests, sprint, pipelines), groups, notifications, the
                               brief, and the links people send you in chats
Sources/CopilotCore/           the Copilot app's database and event logs, and session statuses
Sources/BriefBarUI/            shared app code: the source protocol, menu-bar drawing, desktop widgets,
                               the windows' look, the notifier, Full Disk Access, the on-device model,
                               Launch at Login
Sources/TeamsUI/               each source's app code: its lists, settings, widget and command-line
Sources/AzureDevOpsUI/         modes, and its BriefBarSource
Sources/CopilotUI/
Sources/BriefBar/              the app: sources and consent, menu-bar items, widgets, windows, Settings,
                               starting the updater, the command line and --render
Sources/BriefBarUpdater/       the updater: Sparkle, in a helper app inside BriefBar.app, with library
                               validation off and none of BriefBar's permissions
Tests/                         Swift Testing suites for the shared code, each source's core and some of
                               its app code, with made-up data
scripts/                       app bundling, signing and checks, the optional signing certificate,
                               releases (their keys, signing and appcast), the boundary and demo checks,
                               the demo data, the MDM profile and the icon
.github/workflows/             CI and releases
```

Each source's code came from its Pulse app (Teams Pulse, ADO Pulse, Copilot Pulse) and keeps its
names, such as `ConversationStore` and `PRStore`, so changes there can be brought over.

## Debugging

The app binary doubles as a command-line tool (`BriefBar --help`). These variables point a source at
other data:

| Variable | For |
|---|---|
| `BRIEFBAR_TEAMS_DB`, `BRIEFBAR_TEAMS_STATE_DIR` | Another Notification Center database, such as `build/demo/teams/db2/db`, and its state. With another database, BriefBar keeps the key of the unread chats in a file next to that state instead of the keychain |
| `BRIEFBAR_COPILOT_DIR` | Another Copilot data directory, such as `build/demo/copilot` |
| `BRIEFBAR_AZ` | Another `az` |
| `BRIEFBAR_CHAT_LINKS_DB` | Another Notification Center database for Azure DevOps' pull requests sent in chats, such as one the tests make, which needs no Full Disk Access |
| `BRIEFBAR_RENDER_SUMMARIES=1` | `--render` summarizes Teams' unread chats first, and words the brief across sources, with the on-device model |

With `--demo`, Teams and Copilot read only what these variables name, never your own data. Chats from
Notification Center's own database are only ever saved by the installed app, with the key in the
keychain, and only the running app reads them back: the command line and `--render` never use that
key, even run from the installed app, since any program can run its binary. With another database,
they use its key file.

BriefBar reads these variables, and runs its command-line modes and `--render`, only with the
permissions of the app that started it, such as Terminal. Started as an app (Finder, a login item,
`open`), or by a program that disclaimed it, it has its own Full Disk Access, so it ignores the
variables that point a source at other data, and refuses those modes ([Ground rules](#ground-rules)).
Run `make demo`, `make demo-check` and the rest from a shell, as the Makefile does.

Diagnostics go to the system log, each source under its own category:

```sh
log show --last 10m --info --predicate 'subsystem == "com.asaf.BriefBar"' --style compact
```

## Building with only the Command Line Tools

- `make test` passes Swift Testing's macro plugin folder to the compiler explicitly. Without it,
  `swift test` sometimes fails with "plugin for module 'TestingMacros' not found".
- The `@State`, `@Entry` and `#Preview` SwiftUI macros aren't available without Xcode, so the views
  use a small `@LocalState` property wrapper instead of `@State`, and environment values are written
  out by hand.
- Liquid Glass (`glassEffect`, the glass button style) is in the macOS 26 SDK only: use it inside
  `#if compiler(>=6.2)` and `if #available(macOS 26.0, *)`, so CI's macOS 15 build still compiles.
  `--render` can't draw glass or materials, so views draw a stand-in when `isRendering` is set
  (`Sources/BriefBarUI/WindowStyle.swift`).

## Ground rules

- **Every source is off until you turn it on.** Nothing turns one on by itself: not an update, not a
  new source, not a migration. While a source is off, don't read its data or check its access.
- **Say what a source reads.** When a source starts reading something new, update its
  `SourceDescription` and raise its `version`, so whoever turned it on sees the change before it reads
  more.
- **Only Azure DevOps uses the network**, and only Azure DevOps: every request a GET, never a write.
  Teams and Copilot make no network requests, and neither does anything else but the updater,
  Sparkle, which fetches only this project's releases, and only if you allow it. Networking code goes
  in `AzureDevOpsCore`, and `make check-boundaries` fails if any other module uses networking APIs.
- **Start programs only through `ProcessRunner`**, which keeps them from using BriefBar's privacy
  permissions. `make check-boundaries` fails if any other module starts one.
- **Whoever starts BriefBar as an app chooses its arguments and environment, and can read its
  output.** Started by LaunchServices (`open --env … --stdout … --args …`), or by a program that
  disclaimed it, BriefBar has its own Full Disk Access (`Attribution.itself`). So nothing a caller
  chooses may decide what it reads with that access, or carry what it read anywhere the caller can
  read: no command-line mode or `--render` runs (`CommandLineAccess`), only `--help` and
  `--check-updater`, which read nothing of yours; `-key value` arguments don't reach its preferences,
  its standard output and error go to `/dev/null`, and the variables that point it at other data are
  read only through `Attribution.environment`, which is empty then. A test fails if code reads the
  environment anywhere else, until it's checked and listed with its reason. Variables that move where
  macOS keeps your files, such as `HOME`, which chooses the keychain, are put back first thing
  (`LaunchEnvironment`): add any other you find there. Keychain items go in the login keychain by its
  file (`KeychainKeyStore`), never the default keychain, which any program running as you can change.
  Find files in your home folder through `UserHome`, never FileManager's home folder, its search paths
  or `~`; a test checks.
- **Keep library validation on in BriefBar.** It links only Apple's libraries and has no entitlements.
  Code that needs other libraries, or library validation off, belongs in the updater or another helper
  app that holds no permissions, started as a `RunningProgram`. `scripts/check-app.sh` fails
  otherwise.
- **Never change what a source reads.** Open Notification Center's database and the Copilot app's
  database read-only, keep reads short, and never run SQL that writes, including `PRAGMA` settings
  and checkpoints. Never copy them.
- **Only unread chats touch the disk**, encrypted, and only until they're read. Summaries, read chats
  and anything else about chats stay in memory.
- **Nothing from Notification Center goes to the preferences**, which any program running as you can
  read with `defaults read`: the links people send in chats, and which of the pull requests listed
  only because of them you've seen, stay in memory. `ChatLinkSettingsTests` checks that the
  preferences hold none of it.
- **Summaries stay on the Mac.** Use `SystemLanguageModel.default`, through `OnDeviceModel`, never
  Private Cloud Compute or any other model. A brief across sources says a chat's text only while Teams
  shows message previews, and asks the model only as each source's settings allow.
- **No content in logs.** Log counts, states and errors, never names, messages, titles or IDs.
- **Use made-up data.** Real chats, pull requests and sessions are private, and often confidential.
  Don't put them in tests, screenshots, issues or pull requests. `--diagnose` output is safe to share,
  and so are the pictures from `--demo --render`; the other modes' output isn't, and neither are the
  pictures `--render` draws from your own data.
- **Logic goes in the core modules**, free of UI code and covered by tests. A source's app code shows
  what its core publishes, and keeps some of your data, such as which pull requests you've seen, in
  its preferences, or Teams' saved chats: test what it keeps, and who can read it, in its own tests
  (`Tests/AzureDevOpsUITests`, `Tests/TeamsUITests`).
- **Tests leave nothing behind.** They write only to temporary directories, and keep settings in
  `MemorySettings`, or `MemoryDefaults` where code takes a `UserDefaults`: a UserDefaults suite leaves
  a file in `~/Library/Preferences`, even once removed.
- **The formats are undocumented.** When you rely on a new field, handle its absence and add a test
  with a small made-up sample.

## Pull requests

- Keep each pull request focused, and describe the change users will see.
- Run `make test`, `make check-boundaries` and `make demo-check` first. CI runs them on macOS 15 (with
  Xcode 16, so without summaries) and macOS 26, checks the signing keys' protection, packages the app,
  checks its updater, and runs it on Apple silicon and Intel.
- Update the README, or [How it works](docs/how-it-works.md), when behavior or settings change.
- For UI changes, include before and after screenshots from `make screenshots`, never of your own data.

## Signing

Builds from source are signed ad hoc, so there's no key on your Mac that anything could sign as
BriefBar with, but each build needs Full Disk Access again (see above). To keep it across rebuilds,
`make signing-identity` creates **BriefBar Signing** in your login keychain, with a key that no app may
use without asking and that can't be exported. Each build then asks for your login password twice,
for the updater and the app: click **Allow** only while your build is signing, never **Always Allow**
([why](README.md#keeping-full-disk-access-across-rebuilds)). `make app` refuses to sign with a key
that some app may use without asking, signs with the certificate's SHA-1 rather than its name, and
checks the signature's certificate afterwards. `scripts/make-signing-identity.sh --check` reads the
key's protection, `--replace` makes a new certificate and `--delete` goes back to ad hoc.
`make signing-key-check` tests all of that in throwaway keychains, without asking anything.

`make package` signs with a certificate, as a release does. CI uses a throwaway one in a throwaway
keychain (`scripts/ci-signing-identity.sh`), whose key `codesign` may use without asking. You can
package with one too, without a certificate of your own, but don't give such a build Full Disk Access:

```sh
export BRIEFBAR_SIGNING_KEYCHAIN="$(scripts/ci-signing-identity.sh)"
make package
security delete-keychain "$BRIEFBAR_SIGNING_KEYCHAIN" && rmdir "$(dirname "$BRIEFBAR_SIGNING_KEYCHAIN")"
```

[How it works](docs/how-it-works.md#signing) explains why.

## CI

`.github/workflows/ci.yml` runs on every push to `main` that changes more than docs, on pull requests,
and when started by hand:

- It builds and tests on macOS 15, whose Xcode 16 SDK has no FoundationModels, and on macOS 26. Each
  runs the boundary and demo checks and `make signing-key-check`, packages the universal app with a
  throwaway certificate, signs its update with a throwaway key, the way a release does
  (`scripts/appcast-dry-run.sh`), checks that its updater can't use BriefBar's permissions
  (`scripts/test-updater-isolation.sh`), and installs an update through it
  (`scripts/update-rehearsal.sh`).
- The macOS 26 job uploads the package as the `BriefBar` artifact, and the next jobs run it on
  macOS 15, on Apple silicon and on Intel, with the updater check too.

## Releasing

Releases are built and signed by GitHub Actions, not on a maintainer's Mac.

1. Set the new version as `CFBundleShortVersionString` in `Resources/Info.plist`, as three numbers
   such as `0.2.0`. The build sets `CFBundleVersion` to the same value. Sparkle compares it to decide
   whether a release is newer, so a release fails unless its version is higher than every earlier
   tag.
2. Add a section for it at the top of `CHANGELOG.md`, with the date, such as
   `## 0.2.0 - 2026-11-30`. It becomes the release notes, on GitHub and in the app's update window, so
   write it for users.
3. Push to `main` and wait for CI. If no runner picks a job up, start the workflow again from
   **Actions** with **Run workflow**.
4. Tag the commit and push the tag:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

5. Approve the release: in the run under **Actions**, click **Review deployments**, select `release`
   and click **Approve and deploy**.

The tag starts the [release workflow](.github/workflows/release.yml). Its first job checks the
version and the changelog, then builds and tests the universal app on macOS 26, signed with a
throwaway certificate. After your approval, the second job signs the app again with the release
certificate (`scripts/sign-release.sh`), checks that it's the certificate in
`Resources/ReleaseRequirement.txt` and deletes it from the runner. It then signs the zip and writes
`appcast.xml` (`scripts/make-appcast.sh`), checks the signatures with the public key
(`scripts/verify-appcast.swift`), attests both files, and publishes the release with `BriefBar.zip`,
its SHA-256, `appcast.xml` and the changelog section.

### The release keys

A release needs two private keys, which only the `release` environment and the maintainer's password
manager hold. `scripts/make-release-keys.sh` makes both, once, in memory, and copies them one at a
time to the clipboard for the environment's secrets. They're never written to a file or stored in a
keychain, so no program on the maintainer's Mac can use them. The clipboard keeps them on that Mac:
Universal Clipboard doesn't offer them to other devices, and clipboard managers skip them.

- **The release certificate**, **BriefBar Release**, signs the app. macOS ties Full Disk Access to
  it, so every release must be signed with the same one, or every user loses the access. It's a
  certificate of its own, never one in a keychain like **BriefBar Signing**: anything that could sign
  with it could sign itself as a release and inherit BriefBar's Full Disk Access on every Mac, so it
  exists only where it's needed. That's also why builds from source don't share Full Disk Access with
  the releases. Secrets: `RELEASE_CERTIFICATE_P12` and `RELEASE_CERTIFICATE_PASSWORD`.
  `Resources/ReleaseRequirement.txt` holds the designated requirement it gives the app, and the
  release workflow refuses to publish an app that doesn't have it.
- **The update signing key** signs each update and the appcast. Installed apps accept only updates
  signed with the key that matches `SUPublicEDKey` in `Resources/Info.plist`. It's an Ed25519 key in
  the form Sparkle's `generate_keys -x` exports, but kept out of the keychain, where any program could
  export it with `generate_keys`. Secret: `SPARKLE_PRIVATE_KEY`.

To set up a repository:

1. In its **Settings › Environments**, create an environment named `release`. Under
   **Deployment protection rules**, turn on **Required reviewers** and add the maintainers. Under
   **Deployment branches and tags**, choose **Selected branches and tags** and add a rule for the tag
   pattern `v*`.
2. Run `scripts/make-release-keys.sh` in Terminal. For each secret it copies, click
   **Add environment secret** in the environment, paste the value, and name it as the script says.
   Paste each into your password manager too: it keeps the only other copy. The script writes the
   public halves only once you've copied all three, and refuses to run again after that.
3. Commit the public halves it wrote, `Resources/Info.plist` and `Resources/ReleaseRequirement.txt`,
   and push.

Never put either private key anywhere else: in a file you keep, a keychain, a command-line argument
or a log. Don't change `SUPublicEDKey` or the release certificate either, unless one leaks or is
lost, and then never both in one release: Sparkle accepts an update with a new certificate or a new
update signing key, not both.

- If the update signing key leaks, run `scripts/make-release-keys.sh --new-update-key`. It sets the
  new public key in `Info.plist` and copies the new private key for your password manager, but the
  next release must still be signed with the old key, which installed apps know: keep the old
  `SPARKLE_PRIVATE_KEY` until it's out. `scripts/make-appcast.sh` refuses that mismatch, so sign that
  release by hand with Sparkle's `sign_update`. Then replace the secret, and later releases are
  signed with the new key. If the key is lost, the installed apps can't be updated anymore: publish
  a release with a new key and ask users to download it by hand once.
- If the release certificate leaks or is lost, run `scripts/make-release-keys.sh --new-certificate`
  and replace the two certificate secrets. Users lose Full Disk Access with the next update and have
  to grant it again, so say so in its release notes.

## License

BriefBar is licensed under the GNU General Public License, version 3 or later. By contributing, you
agree that your contributions are licensed under the same terms.
