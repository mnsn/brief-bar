# Contributing to BriefBar

Bug reports, ideas and pull requests are welcome.

## Getting started

You need macOS 15 or later and Swift 6. Xcode works, and so do just the Command Line Tools.

```sh
git clone https://github.com/mnsn/briefbar.git
cd briefbar
make test    # run the tests
make demo    # run the app with made-up data for every source (Ctrl-C to quit)
```

`make demo` writes made-up Teams notifications in Notification Center's layout to `build/demo/teams`
and a made-up Copilot data directory to `build/demo/copilot`, and starts the app with `--demo`, which
turns every source on in a throwaway set of preferences. Azure DevOps makes up its own pull requests,
and never runs `az` or reaches Azure DevOps. Use it to work on the UI and to take screenshots without
showing your own chats, pull requests or sessions.

Other targets:

```sh
make build              # debug build
make demo-check         # check that each source's made-up data lands in the expected groups
make check-boundaries   # check that only AzureDevOpsCore uses the network, and only BriefBarCore starts programs
make render             # draw the menu bar, lists, widgets and Settings from your own data into render/
make screenshots        # render the README's pictures from the demo data
make signing-identity   # once per Mac: create the certificate every build is signed with
make app                # build BriefBar.app into ./build, signed with it
make package            # the universal app, checked and zipped, in build/release
make install            # build the app, copy it to ~/Applications and open it
make pppc-profile       # a configuration profile that grants the built app Full Disk Access, for MDM
make icon               # regenerate Resources/AppIcon.icns
```

These read your own data, for the sources that are on in the installed app, or the ones `--source`
names. Teams' modes read Notification Center with Terminal's Full Disk Access:

```sh
make run                          # the app, from a debug build, with its own preferences
make dump ARGS="--source copilot" # what a source shows
make watch                        # changes as they happen
make diagnose                     # Teams: the structure only, without names, messages or IDs
```

[How it works](docs/how-it-works.md) explains the sources, the permissions, the menu bar and the
signing.

## Project layout

```text
Sources/BriefBarCore/          shared, with no UI: file watching (FSEvents, kqueue), read-only SQLite,
                               timestamps, ProcessRunner (every program BriefBar starts), and the models
                               of the sources you turned on and of the menu-bar layout
Sources/NotificationCenterDB/  Notification Center's database: the records of the apps a source asks for
Sources/TeamsCore/             Teams' notifications, the unread rules, the encrypted unread chats
Sources/AzureDevOpsCore/       Azure DevOps: sign-in with the Azure CLI, the client (the only networking),
                               the engine, groups, notifications and the brief
Sources/CopilotCore/           the Copilot app's database and event logs, and session statuses
Sources/BriefBarUI/            shared app code: the source protocol, menu-bar drawing, desktop widgets,
                               the notifier, Full Disk Access, the on-device model, Launch at Login
Sources/TeamsUI/               each source's app code: its lists, settings, widget and command-line
Sources/AzureDevOpsUI/         modes, and its BriefBarSource
Sources/CopilotUI/
Sources/BriefBar/              the app: sources and consent, menu-bar items, Settings, the command line
                               and --render
Tests/                         Swift Testing suites for the shared code and each source's core, with
                               made-up data
scripts/                       app bundling, signing and checks, the signing certificate, the boundary and
                               demo checks, the demo data, the MDM profile and the icon
.github/workflows/             CI
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
| `BRIEFBAR_RENDER_SUMMARIES=1` | `--render` summarizes Teams' unread chats first, with the on-device model |

With `--demo`, Teams and Copilot read only what these variables name, never your own data. Chats from
Notification Center's own database are only ever saved by the installed app, with the key in the
keychain.

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

## Ground rules

- **Every source is off until you turn it on.** Nothing turns one on by itself: not an update, not a
  new source, not a migration. While a source is off, don't read its data or check its access.
- **Say what a source reads.** When a source starts reading something new, update its
  `SourceDescription` and raise its `version`, so whoever turned it on sees the change before it reads
  more.
- **Only Azure DevOps uses the network**, and only Azure DevOps: every request a GET, never a write.
  Teams and Copilot make no network requests, and neither does anything else. Networking code goes in
  `AzureDevOpsCore`, and `make check-boundaries` fails if any other module uses networking APIs.
- **Start programs only through `ProcessRunner`**, which keeps them from using BriefBar's privacy
  permissions. `make check-boundaries` fails if any other module starts one.
- **Never change what a source reads.** Open Notification Center's database and the Copilot app's
  database read-only, keep reads short, and never run SQL that writes, including `PRAGMA` settings
  and checkpoints. Never copy them.
- **Only unread chats touch the disk**, encrypted, and only until they're read. Summaries, read chats
  and anything else about chats stay in memory.
- **Summaries stay on the Mac.** Use `SystemLanguageModel.default`, through `OnDeviceModel`, never
  Private Cloud Compute or any other model.
- **No content in logs.** Log counts, states and errors, never names, messages, titles or IDs.
- **Use made-up data.** Real chats, pull requests and sessions are private, and often confidential.
  Don't put them in tests, screenshots, issues or pull requests. `--diagnose` output is safe to share;
  `--dump`, `--watch` and `--json` output isn't.
- **Logic goes in the core modules**, free of UI code and covered by tests.
- **The formats are undocumented.** When you rely on a new field, handle its absence and add a test
  with a small made-up sample.

## Pull requests

- Keep each pull request focused, and describe the change users will see.
- Run `make test`, `make check-boundaries` and `make demo-check` first. CI runs them, then builds and
  checks the app.
- Update the README, or [How it works](docs/how-it-works.md), when behavior or settings change.
- For UI changes, include before and after screenshots from `make screenshots`, never of your own data.

## Signing

Every build is signed with a certificate, never ad hoc, so Full Disk Access and Teams' keychain item
survive rebuilds. `make signing-identity` creates **BriefBar Signing** in your login keychain, with a
key that no app may use without asking. Each build asks for your login password: click **Allow**,
never **Always Allow**. [How it works](docs/how-it-works.md#signing) explains why.

CI signs with a throwaway certificate in a throwaway keychain (`scripts/ci-signing-identity.sh`), whose
key `codesign` may use without asking. You can build with one too, without your own certificate, but
don't give such a build Full Disk Access:

```sh
export BRIEFBAR_SIGNING_KEYCHAIN="$(scripts/ci-signing-identity.sh)"
make package
security delete-keychain "$BRIEFBAR_SIGNING_KEYCHAIN"
```

## CI

`.github/workflows/ci.yml` reads the repository's visibility, so nothing needs editing when it changes:

- **While the repository is private**, where macOS minutes count ten times, one macOS 26 job runs on
  every push to `main` that changes more than docs, on pull requests and when started by hand. It
  runs the tests, the boundary and demo checks, then packages the universal app and checks it.
- **Once it's public**, the same workflow also builds on macOS 15, whose Xcode 16 SDK has no
  FoundationModels. It then runs the packaged app on macOS 15, on Apple silicon and on Intel.

## Releasing

There are no releases yet: while the repository is private, nobody could download them or their
update feed, so BriefBar is built from source. Once it's public, releases will follow Teams Pulse's
process:

- a tag, built and attested by GitHub Actions,
- signed with a certificate of the project's own, **BriefBar Release**, and an update signing key,
  both held only by an approval-gated `release` environment and the maintainer's password manager,
  never on a Mac,
- delivered by Sparkle.

## License

BriefBar is licensed under the GNU General Public License, version 3 or later. By contributing, you
agree that your contributions are licensed under the same terms.
