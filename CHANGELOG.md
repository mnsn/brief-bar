# Changelog

## Unreleased

- **Library validation is back on in BriefBar.** Sparkle, the updater, needs it off, so it now runs in
  an app of its own inside BriefBar, `Contents/Helpers/BriefBar Updater.app`, with none of BriefBar's
  permissions: BriefBar starts it responsible for itself, and ends it if macOS says otherwise. A copy of
  BriefBar with other code in place of Sparkle can no longer run that code with BriefBar's Full Disk
  Access. Updates look and work as before, and keep the access.
- **Your sprint and pipelines**, as ADO Pulse fixed them: they start over when you sign in to the Azure
  CLI as someone else, and a refresh stops once nothing shows them. A retried run's stages are read
  again, runs in different organizations no longer mix, and a timeline that keeps failing doesn't hold
  up the rest.
- `BriefBar --check-updater` shows how macOS treats the updater. `make updater-check` checks it in a
  copy of a build that macOS opens, with other code in place of Sparkle, and `make update-rehearsal`
  installs an update through it, from a feed on the Mac.

## 0.1.0 - Unreleased

The first version: Teams Pulse, ADO Pulse and Copilot Pulse in one menu-bar app.

- **Three sources, each off until you turn it on.** Microsoft Teams (unread chats), Azure DevOps (pull
  requests) and GitHub Copilot (app sessions) work as their Pulse apps did. Each first says what it
  reads, where it connects and what it needs. Turning one off deletes what it saved.
- **Azure DevOps as ADO Pulse has it now:** an **Answered** group for what you've taken care of in
  Azure DevOps, until you've seen it; **Pull Requests Sent in Chats**, off until you turn it on, which
  lists a pull request when someone sends you a link to it, from the notifications every app posts,
  keeping only the links, in memory, as it does which of those pull requests you've seen; and what
  you've seen of your own pull requests, kept for each Azure CLI account.
- **Your sprint and pipelines**, from ADO Pulse's window: your team's current sprint as a task board,
  with **Just Mine**, and the pipelines you pin, stage by stage. Each is a section of its own, a page
  in BriefBar's window to start with, and reads Azure DevOps only while something shows it.
- **Permissions once.** Full Disk Access and notifications are BriefBar's, granted once, and used only
  by the sources you turn on. An update never turns a source on, and one that starts reading more
  pauses until you've looked.
- **Menu bar, widgets and windows, arranged as you like.** Each section (Teams' Chats and Group
  Chats, pull requests, the sprint, pipelines, sessions) can share a menu-bar item, a desktop widget or a window with
  others, have one of its own, or be hidden from any of them. Settings › Menu Bar, Widgets and
  Windows also put everything in one, or give each its own.
- **A window** with a page for each section, and a sidebar with their counts. BriefBar shows a Dock
  icon only while it's open.
- **Widgets for every source**, each with its own position and size. Teams' start hidden.
- **Settings in a window of their own**, and in each list's gear menu.
- **Programs it starts can't use its permissions:** the Azure CLI and the login shell that finds it
  run responsible for themselves.
- **Started by another program with its own permissions, BriefBar takes your keychain and home
  folder from the user database, not from it.** Such a program chooses BriefBar's environment, and
  `HOME` chooses the keychain macOS uses: in a keychain that program made, BriefBar would seal the
  Teams chats it read with a new key there, where they're saved for any program to read. So BriefBar
  puts back `HOME` from the user database, and drops `CFFIXED_USER_HOME`, `DIRHELPER_USER_DIR_SUFFIX`
  and SQLite's variables, before anything reads them. And the key to Teams' saved chats always goes
  in your login keychain, by its file, whatever the default keychain and the search list say.
- **Releases with in-app updates.** Each release is built from its tagged source by GitHub Actions,
  with an attestation, and signed with the project's own certificate, so updates keep Full Disk
  Access. BriefBar checks for updates only if you allow it, and installs only updates signed with the
  project's key.
- **Builds from source are signed ad hoc**, so no key on your Mac can sign as BriefBar. An optional
  certificate keeps their Full Disk Access across rebuilds: no app may use its key without asking, and
  it can't be exported.
- **The hardened runtime**, with library validation off only so that the app can load Sparkle, its
  updater.
