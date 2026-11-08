#!/bin/bash
# Tests scripts/prepare-release.sh, which a release's version commit runs, in repositories of its own in a temporary
# folder. Two pull requests' notes, merged in another order than they were written, one of them changing two sources'
# descriptions, then the last pull request's, which changes one of them again, become the release's section of
# CHANGELOG.md in the order they merged, ending with After this update; each description's version rises once, with
# a doc line; Info.plist gets the version; and the notes go. It refuses, changing nothing, notes it can't read, a
# version or a date it can't use, a description's version that a pull request changed, a changelog section of
# Unreleased, and a history it can't order the notes by. --check reads the same notes, and with --fetch, the last
# release's tag from origin. CI runs it (make release-notes-check).
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/scripts/prepare-release.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-prepare-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Git as it is anywhere, without this Mac's settings, such as signing commits.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 LC_ALL=C
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
fail() {
    echo "test-prepare-release failed: $*" >&2
    exit 1
}

REPO="$WORK/repo"
in_repo() { git -C "$REPO" "$@"; }
# write <path> <text>: a file of the repository.
write() {
    mkdir -p "$(dirname "$REPO/$1")"
    printf '%s\n' "$2" > "$REPO/$1"
}
# commit <message> <time>: everything, at that time, which orders notes only here.
commit() {
    in_repo add --all
    GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" in_repo commit --quiet --message "$1"
}
# notes <branch> <time> <notes>: a pull request's branch, from main, with its notes in changes/<branch>.md.
notes() {
    in_repo checkout --quiet -b "$1" main
    write "changes/$1-20260101-000000.md" "$3"
    commit "Add $1" "$2"
    in_repo checkout --quiet main
}
# merge <branch> <time>: into main, as GitHub merges a pull request.
merge() {
    GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" in_repo merge --quiet --no-ff --message "Merge $1" "$1"
}
# prepare <arguments>: the script under test, in the repository, into $WORK/out and $WORK/err.
prepare() { "$REPO/scripts/prepare-release.sh" "$@" > "$WORK/out" 2> "$WORK/err"; }
# What a run changes, to tell that a refused one changed nothing.
state() {
    in_repo status --porcelain --untracked-files=all
    in_repo diff HEAD | cksum
}
# refuses <what's said> <arguments>: the script fails, says so, and changes nothing.
refuses() {
    local said="$1" before
    shift
    before="$(state)"
    if prepare "$@"; then fail "it didn't refuse ($*), and said: $(cat "$WORK/out")"; fi
    grep -qF -- "$said" "$WORK/err" || fail "refusing ($*), it didn't say \"$said\", but: $(cat "$WORK/err")"
    [[ "$(state)" == "$before" ]] || fail "refusing ($*), it changed something: $(in_repo status --short)"
}
# check_refuses <what's said>: --check fails and says so. It never changes anything.
check_refuses() {
    if prepare --check; then fail "--check didn't refuse, and said: $(cat "$WORK/out")"; fi
    grep -qF -- "$1" "$WORK/err" || fail "refusing, --check didn't say \"$1\", but: $(cat "$WORK/err")"
}
# expect <path> <text>: the file is exactly that.
expect() {
    [[ "$(cat "$REPO/$1")" == "$2" ]] || fail "$1 isn't what it should be. It's:
$(cat "$REPO/$1")
$(diff <(printf '%s\n' "$2") "$REPO/$1" || true)"
}
# says <text>: CHANGELOG.md says it, however its lines wrap.
says() {
    tr '\n' ' ' < "$REPO/CHANGELOG.md" | sed 's/   */ /g' | grep -qF -e "$1" ||
        fail "CHANGELOG.md doesn't say \"$1\". It's:
$(cat "$REPO/CHANGELOG.md")"
}

PLIST_1_0_0='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>BriefBar</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
</dict>
</plist>'
CHANGELOG_1_0_0='# Changelog

## 1.0.0 - 2026-01-01

- **The first version.** Everything is new.'
TEAMS='package final class TeamsSource {
    nonisolated package static let descriptionVersion = 2
}'
AZURE_DEVOPS='package final class AzureDevOpsSource {
    /// 2: the sprint.
    /// 3: what a pull request'"'"'s details read, which takes more than one line to say, so that this one goes on to
    /// another.
    nonisolated package static let descriptionVersion = 3

    package let name = "Azure DevOps"
}'
COPILOT='package final class CopilotSource {
    /// 2: Show Links.
    nonisolated package static let descriptionVersion = 2
}'
GITHUB='package final class GitHubSource {
    nonisolated package static let descriptionVersion = 1
}'
AGENTS='public enum AgentAccess {
    /// What agents get.
    public static let version = 5
}'

# make_repo: a repository laid out as BriefBar's, released as 1.0.0, with the tag v1.0.0, on main: a copy of one made
# once.
TEMPLATE="$WORK/template"
make_repo() {
    rm -rf "$REPO"
    if [[ -d "$TEMPLATE" ]]; then
        cp -R "$TEMPLATE" "$REPO"
        return
    fi
    git init --quiet --initial-branch=main "$REPO"
    mkdir -p "$REPO/scripts"
    cp "$SCRIPT" "$REPO/scripts/"
    write CHANGELOG.md "$CHANGELOG_1_0_0"
    write Resources/Info.plist "$PLIST_1_0_0"
    write Sources/TeamsUI/TeamsSource.swift "$TEAMS"
    write Sources/AzureDevOpsUI/AzureDevOpsSource.swift "$AZURE_DEVOPS"
    write Sources/CopilotUI/CopilotSource.swift "$COPILOT"
    write Sources/GitHubUI/GitHubSource.swift "$GITHUB"
    write Sources/BriefBarCore/AgentAccess.swift "$AGENTS"
    write changes/README.md "# Release notes, until a release gathers them"
    commit "Prepare BriefBar 1.0.0" 2026-01-01T09:00:00
    in_repo tag v1.0.0
    cp -R "$REPO" "$TEMPLATE"
}

# A release of three pull requests' notes. Stages was written first and merged second, missions written second and
# merged first; edits, the last of the batch, wrote its notes before both merged, then merged main, and the release
# is prepared on it, as its version commit is.
make_repo
prepare --check || fail "--check refused no notes: $(cat "$WORK/err")"
grep -qF "No release notes in changes/. The descriptions' versions, and CHANGELOG.md, are v1.0.0's." "$WORK/out" ||
    fail "--check said, of no notes: $(cat "$WORK/out")"
notes stages 2026-01-10T10:00:00 "- **See each pull request's stage.** With Pull Request Order on, each pull request shows where it is in its
  flow, and a click changes it.
- **Spell checking as you write.** Your replies underline the words your Mac doesn't know.

## Descriptions

Azure DevOps: with Pull Request Order on, each pull request's stage, worked out from what it reads already, and the
stages you set, kept for each account.

Copilot: with Pull Request Order on, which session works on each pull request's stage.

After this update: Azure DevOps keeps the stages you set, and Copilot reads which session works on each pull
request's stage."
notes missions 2026-01-10T12:00:00 "- **Change a mission yourself.** A pull request's menu has **Mission**."
in_repo checkout --quiet -b edits main
write changes/edits-20260101-000000.md "- **Edit your comments.** With **Make Changes in Azure DevOps** on, your own comments have **Edit**.

## Descriptions

Azure DevOps: with Make Changes in Azure DevOps, your own comments edited, when you click Edit.

After this update: with Make Changes in Azure DevOps on, Azure DevOps edits your own comments when you click Edit."
commit "Add edits" 2026-01-10T08:00:00
in_repo checkout --quiet main
merge missions 2026-01-11T09:00:00
merge stages 2026-01-11T10:00:00
in_repo checkout --quiet edits
merge main 2026-01-11T11:00:00

prepare --check || fail "--check refused good notes: $(cat "$WORK/err")"
grep -qF "The release notes in changes/ are fine, from 3 pull requests." "$WORK/out" || fail "--check said: $(cat "$WORK/out")"

refuses "the version, 1.1, isn't like 1.2.3." --main main 1.1 2026-02-01
refuses "the date, 2026-02-30, isn't a day like 2026-11-30." --main main 1.1.0 2026-02-30
refuses "the date, 01/02/2026, isn't a day like 2026-11-30." --main main 1.1.0 01/02/2026
refuses "1.0.0 already: it's prepared." --main main 1.0.0 2026-02-01
refuses "0.9.0 isn't higher than the last release in CHANGELOG.md, 1.0.0." --main main 0.9.0 2026-02-01
refuses "there's no origin/main" 1.1.0 2026-02-01
refuses "Usage:" --main main 1.1.0 2026-02-01 extra
refuses "Usage:" --main main --fetch 1.1.0 2026-02-01

prepare --main main 1.1.0 2026-02-01 || fail "it refused the release: $(cat "$WORK/err")"
expect CHANGELOG.md "# Changelog

## 1.1.0 - 2026-02-01

- **Change a mission yourself.** A pull request's menu has **Mission**.
- **See each pull request's stage.** With Pull Request Order on, each pull request shows where it is in its
  flow, and a click changes it.
- **Spell checking as you write.** Your replies underline the words your Mac doesn't know.
- **Edit your comments.** With **Make Changes in Azure DevOps** on, your own comments have **Edit**.
- **After this update, Azure DevOps and Copilot ask you once to look at what they read, and wait until you have.** Azure
  DevOps keeps the stages you set, and Copilot reads which session works on each pull request's stage. With Make Changes
  in Azure DevOps on, Azure DevOps edits your own comments when you click Edit.

## 1.0.0 - 2026-01-01

- **The first version.** Everything is new."
expect Sources/AzureDevOpsUI/AzureDevOpsSource.swift "package final class AzureDevOpsSource {
    /// 2: the sprint.
    /// 3: what a pull request's details read, which takes more than one line to say, so that this one goes on to
    /// another.
    /// 4: with Pull Request Order on, each pull request's stage, worked out from what it reads already, and the stages
    /// you set, kept for each account. With Make Changes in Azure DevOps, your own comments edited, when you click
    /// Edit.
    nonisolated package static let descriptionVersion = 4

    package let name = \"Azure DevOps\"
}"
expect Sources/CopilotUI/CopilotSource.swift "package final class CopilotSource {
    /// 2: Show Links.
    /// 3: with Pull Request Order on, which session works on each pull request's stage.
    nonisolated package static let descriptionVersion = 3
}"
expect Sources/TeamsUI/TeamsSource.swift "$TEAMS"
expect Sources/GitHubUI/GitHubSource.swift "$GITHUB"
expect Sources/BriefBarCore/AgentAccess.swift "$AGENTS"
expect Resources/Info.plist "${PLIST_1_0_0/1.0.0/1.1.0}"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO/Resources/Info.plist")" == 1.1.0 ]] ||
    fail "Info.plist doesn't read as version 1.1.0."
[[ "$(cd "$REPO" && ls changes)" == README.md ]] || fail "the notes aren't all gone, or README.md is: $(ls "$REPO/changes")"
grep -qF "  changes/missions-20260101-000000.md
  changes/stages-20260101-000000.md
  changes/edits-20260101-000000.md" "$WORK/out" || fail "it didn't say the order it found: $(cat "$WORK/out")"
in_repo commit --quiet --all --message "Prepare BriefBar 1.1.0"
in_repo tag v1.1.0
prepare --check || fail "--check refused a release: $(cat "$WORK/err")"
refuses "1.1.0 already: it's prepared." --main main 1.1.0 2026-02-01
refuses "there are no release notes in changes/." --main edits 1.2.0 2026-02-02
# A pull request that merged after the release was prepared, before the release did, isn't in it: as the release
# workflow's make test checks a tag, the release's own commit is fine, and so is main after it, but not a tag on the
# commit that merged the release, which has that pull request's change and notes.
notes late 2026-01-12T10:00:00 "- **Late.** Merged after the release was prepared."
merge late 2026-01-12T11:00:00
merge edits 2026-01-12T12:00:00
in_repo checkout --quiet v1.1.0
prepare --check || fail "--check refused the release's tag: $(cat "$WORK/err")"
write changes/next-20260101-000000.md "- **Next.** Written on a branch that starts at the tag, not committed yet."
prepare --check || fail "--check refused, at the tag, notes not committed yet: $(cat "$WORK/err")"
rm "$REPO/changes/next-20260101-000000.md"
in_repo checkout --quiet main
prepare --check || fail "--check refused, on main after a release, the notes of the next: $(cat "$WORK/err")"
PREPARED_COMMIT="$(in_repo rev-parse --short v1.1.0)"
in_repo tag --force v1.1.0 main > /dev/null
check_refuses "v1.1.0 is tagged on a commit with notes that its section of CHANGELOG.md doesn't have: changes/late-20260101-000000.md."
grep -qF "Tag the release's own commit instead, $PREPARED_COMMIT (\"Prepare BriefBar 1.1.0\")" "$WORK/err" ||
    fail "refusing the tag, --check didn't name the release's own commit: $(cat "$WORK/err")"

# The sentence that starts After this update names the sources in the app's order, and agents last.
# release <notes>: a release 1.1.0 of one pull request with those notes, merged.
release() {
    make_repo
    notes one 2026-01-10T10:00:00 "$1"
    merge one 2026-01-11T10:00:00
    prepare --main main 1.1.0 2026-02-01 || fail "it refused the release of $1: $(cat "$WORK/err")"
}
release "## Descriptions

Agents: the tool \`stage\`.

After this update: agents get the tool \`stage\`."
expect CHANGELOG.md "# Changelog

## 1.1.0 - 2026-02-01

- **After this update, agents ask you once to look at what they get, and wait until you have.** Agents get the tool
  \`stage\`.

${CHANGELOG_1_0_0#*

}"
expect Sources/BriefBarCore/AgentAccess.swift "public enum AgentAccess {
    /// What agents get.
    /// 6: the tool \`stage\`.
    public static let version = 6
}"
release "- **Teams' chats in order.** Newest first.

## Descriptions

Teams: the order of your chats.

After this update: Teams reads the order of your chats."
says "- **Teams' chats in order.** Newest first. - **After this update, Teams asks you once to look at what it reads, and \
waits until you have.** Teams reads the order of your chats. ## 1.0.0"
expect Sources/TeamsUI/TeamsSource.swift "package final class TeamsSource {
    /// 3: the order of your chats.
    nonisolated package static let descriptionVersion = 3
}"
release "## Descriptions

GitHub: drafts.

Agents: drafts.

Teams: drafts.

After this update: drafts show."
says "- **After this update, Teams, GitHub and agents ask you once to look at what they read and get, and wait until you \
have.** Drafts show. ## 1.0.0"

# Two notes that one merge brings go by name; a note renamed on main counts from its rename, as the one added there.
make_repo
in_repo checkout --quiet -b stack main
write changes/b-second-20260101-000000.md "- **Second.** By name."
write changes/a-first-20260101-000000.md "- **First.** By name."
commit "Add both" 2026-01-10T10:00:00
in_repo checkout --quiet main
merge stack 2026-01-11T10:00:00
notes later 2026-01-09T10:00:00 "- **Third.** Merged last."
merge later 2026-01-12T10:00:00
in_repo mv changes/b-second-20260101-000000.md changes/b-renamed-20260101-000000.md
commit "Rename a note" 2026-01-13T10:00:00
prepare --main main 1.1.0 2026-02-01 || fail "it refused notes merged together: $(cat "$WORK/err")"
expect CHANGELOG.md "# Changelog

## 1.1.0 - 2026-02-01

- **First.** By name.
- **Third.** Merged last.
- **Second.** By name.

${CHANGELOG_1_0_0#*

}"

# Notes only on the release's branch, which merged other branches, go in the order they merged into it, whenever they
# were written.
make_repo
notes on-main 2026-01-10T10:00:00 "- **On main.** Merged first."
merge on-main 2026-01-11T10:00:00
in_repo checkout --quiet -b batch main
in_repo checkout --quiet -b written-first batch
write changes/written-first-20260101-000000.md "- **Written first.** Into the batch."
commit "Add written-first" 2026-01-12T10:00:00
in_repo checkout --quiet -b written-second batch
write changes/written-second-20260101-000000.md "- **Written second.** Into the batch."
commit "Add written-second" 2026-01-12T11:00:00
in_repo checkout --quiet batch
merge written-second 2026-01-13T10:00:00
merge written-first 2026-01-13T11:00:00
prepare --main main 1.1.0 2026-02-01 || fail "it refused the batch: $(cat "$WORK/err")"
expect CHANGELOG.md "# Changelog

## 1.1.0 - 2026-02-01

- **On main.** Merged first.
- **Written second.** Into the batch.
- **Written first.** Into the batch.

${CHANGELOG_1_0_0#*

}"

# A later pull request from a branch whose notes file a release gathered already, which adds to that file rather than
# writing a new one: the release's deletion conflicts with its change, and keeping the file would release the first
# pull request's bullets again. Whether the release came first, or was still in flight, --check refuses them.
# keep_in_merge <branch> <file>: merges that branch, which deleted the file that this one changed, keeping the file.
keep_in_merge() {
    if in_repo merge --quiet --no-ff -m "Merge $1" "$1" > /dev/null 2>&1; then fail "merging $1 didn't conflict over $2."; fi
    in_repo add "$2"
    in_repo commit --quiet --no-edit
}
REUSED=changes/reused-20260101-000000.md
make_repo
notes reused 2026-01-10T10:00:00 "- **First.** From the branch's first pull request."
merge reused 2026-01-11T10:00:00
prepare --main main 1.1.0 2026-02-01 || fail "it refused the release: $(cat "$WORK/err")"
commit "Prepare BriefBar 1.1.0" 2026-01-12T10:00:00
in_repo tag v1.1.0
in_repo checkout --quiet reused
printf '%s\n' "- **Second.** From its second." >> "$REPO/$REUSED"
commit "Add to the notes" 2026-01-13T10:00:00
keep_in_merge main "$REUSED"
check_refuses "$REUSED:1: has the bullet **First.**, but it's already in CHANGELOG.md: write a new file for new notes"

make_repo
notes reused 2026-01-10T10:00:00 "- **First.** From the branch's first pull request."
merge reused 2026-01-11T10:00:00
in_repo checkout --quiet -b release main
prepare --main main 1.1.0 2026-02-01 || fail "it refused the release: $(cat "$WORK/err")"
commit "Prepare BriefBar 1.1.0" 2026-01-12T10:00:00
in_repo checkout --quiet reused
printf '%s\n' "- **Second.** From its second." >> "$REPO/$REUSED"
commit "Add to the notes" 2026-01-12T11:00:00
in_repo checkout --quiet main
merge reused 2026-01-12T12:00:00
in_repo checkout --quiet release
keep_in_merge main "$REUSED"
check_refuses "$REUSED:1: has the bullet **First.**, but it's already in CHANGELOG.md: write a new file for new notes"

# What it refuses, changing nothing.
make_repo
notes good 2026-01-10T10:00:00 "- **Good.** Notes."
merge good 2026-01-11T10:00:00
# refuses_notes <what's said> <notes>: a pull request's notes, which --check doesn't accept, nor would a release.
refuses_notes() {
    write changes/bad-20260101-000000.md "$2"
    check_refuses "changes/bad-20260101-000000.md:$1"
    rm "$REPO/changes/bad-20260101-000000.md"
}
refuses_notes "1: has a heading other than ## Descriptions" "# Edit your comments

- **Edit.** Them."
refuses_notes "1: has a bullet without a bold lead" "- Edit your comments."
refuses_notes "1: has a bullet whose bold lead doesn't close" "- **Edit your comments. And more,
  on another line."
refuses_notes "3: continues no bullet" "- **Edit.** Them.

  And more."
refuses_notes "1: isn't a bullet" "Edit your comments."
refuses_notes "1: has an After this update bullet" "- **After this update, Azure DevOps asks you once.** It reads more."
refuses_notes "3: doesn't start with \"Teams:\", \"Azure DevOps:\", \"Copilot:\", \"GitHub:\", \"Agents:\" or \"After this update:\"" \
    "## Descriptions

GitHub Copilot: sessions.

After this update: more."
refuses_notes "4: starts \"Teams:\" with no blank line before it" "## Descriptions

Azure DevOps: what it reads from
Teams: its notifications.

After this update: Azure DevOps reads more."
refuses_notes "1: needs an After this update" "## Descriptions

Copilot: sessions."
refuses_notes "3: numbers Copilot's doc line" "## Descriptions

Copilot: 3: sessions.

After this update: Copilot reads sessions."
refuses_notes "3: doesn't end Copilot's doc line with a full stop" "## Descriptions

Copilot: sessions

After this update: Copilot reads sessions."
refuses_notes "5: repeats \"After this update\"" "## Descriptions

Copilot: sessions.

After this update: After this update, Copilot asks you once."
refuses_notes "5: names Copilot twice" "## Descriptions

Copilot: sessions.

Copilot: more.

After this update: Copilot reads sessions."
refuses_notes "1: has a ## Descriptions that names no source" "## Descriptions

After this update: nothing changed."
refuses_notes "1: has no notes" ""
refuses_notes "1: has a tab" "- **Edit.**	Them."
write changes/notes.txt "Not a note."
check_refuses "changes/notes.txt isn't named like a notes file"
rm "$REPO/changes/notes.txt"
write changes/my-branch.md "- **Unstamped.** Named after its branch alone, which another pull request could use too."
check_refuses "changes/my-branch.md isn't named like a notes file: its branch, then the UTC date and time it was made"
rm "$REPO/changes/my-branch.md"

in_repo checkout --quiet -b bad main
write changes/bad-20260101-000000.md "- **Bad.** A note.
And not."
commit "Add bad notes" 2026-01-12T10:00:00
refuses "changes/bad-20260101-000000.md:2: isn't a bullet" --main main 1.1.0 2026-02-01
in_repo checkout --quiet main

in_repo checkout --quiet -b raised main
write Sources/CopilotUI/CopilotSource.swift "${COPILOT/descriptionVersion = 2/descriptionVersion = 3}"
commit "Raise Copilot's version" 2026-01-12T10:00:00
refuses "Sources/CopilotUI/CopilotSource.swift's descriptionVersion is 3, but 2 in v1.0.0: only a release changes it." \
    --main main 1.1.0 2026-02-01
check_refuses "Sources/CopilotUI/CopilotSource.swift's descriptionVersion is 3, but 2 in v1.0.0"
in_repo checkout --quiet main

in_repo checkout --quiet -b documented main
write Sources/CopilotUI/CopilotSource.swift "${COPILOT/    nonisolated/    /// 3: sessions.
    nonisolated}"
commit "Add a doc line for a version" 2026-01-12T10:00:00
refuses "Sources/CopilotUI/CopilotSource.swift has a doc line for descriptionVersion 3, past its version, 2" \
    --main main 1.1.0 2026-02-01
check_refuses "Sources/CopilotUI/CopilotSource.swift has a doc line for descriptionVersion 3, past its version, 2"
in_repo checkout --quiet main

# A numbered doc line changed in place, here with the next version's entry on it, is refused against the last
# release's tag, whose doc lines say what each version was; the doc text above them can change.
in_repo checkout --quiet -b inline main
write Sources/AzureDevOpsUI/AzureDevOpsSource.swift "${AZURE_DEVOPS/the sprint./the sprint. 4: more.}"
commit "Add an entry to a numbered doc line" 2026-01-12T10:00:00
refuses "Sources/AzureDevOpsUI/AzureDevOpsSource.swift's numbered doc lines above descriptionVersion aren't as v1.0.0" \
    --main main 1.1.0 2026-02-01
check_refuses "Sources/AzureDevOpsUI/AzureDevOpsSource.swift's numbered doc lines above descriptionVersion aren't as"
in_repo checkout --quiet main
in_repo checkout --quiet -b preface main
write Sources/BriefBarCore/AgentAccess.swift "${AGENTS/What agents get./What agents get, and when the release raises it.}"
commit "Say more above a version" 2026-01-12T10:00:00
prepare --check || fail "--check refused a change to the doc text above a version: $(cat "$WORK/err")"
in_repo checkout --quiet main

in_repo checkout --quiet -b edited main
write CHANGELOG.md "$CHANGELOG_1_0_0
- **Added later.** To a release that's out."
commit "Write in a released section" 2026-01-12T10:00:00
refuses "CHANGELOG.md isn't as v1.0.0 left it: only a release changes it." --main main 1.1.0 2026-02-01
check_refuses "CHANGELOG.md isn't as v1.0.0 left it: only a release changes it."
in_repo checkout --quiet main

in_repo checkout --quiet -b described main
write changes/described-20260101-000000.md "## Descriptions

Copilot: sessions.

After this update: Copilot reads sessions."
commit "Add described" 2026-01-12T10:00:00
chmod a-w "$REPO/Sources/CopilotUI/CopilotSource.swift"
refuses "can't write Sources/CopilotUI/CopilotSource.swift." --main main 1.1.0 2026-02-01
chmod u+w "$REPO/Sources/CopilotUI/CopilotSource.swift"
in_repo checkout --quiet main

in_repo checkout --quiet -b unreleased main
write CHANGELOG.md "# Changelog

## Unreleased

- **Old.** As pull requests wrote notes before.

${CHANGELOG_1_0_0#*

}"
commit "Write in CHANGELOG.md" 2026-01-12T10:00:00
refuses "CHANGELOG.md has an Unreleased section." --main main 1.1.0 2026-02-01
check_refuses "CHANGELOG.md has an Unreleased section."
in_repo checkout --quiet main

in_repo checkout --quiet -b behind v1.0.0
refuses "HEAD doesn't have all of main" --main main 1.1.0 2026-02-01
in_repo checkout --quiet main

write changes/untracked-20260101-000000.md "- **Untracked.** Not committed."
refuses "?? changes/untracked-20260101-000000.md" --main main 1.1.0 2026-02-01
rm "$REPO/changes/untracked-20260101-000000.md"
printf '<!-- Not committed. -->\n' >> "$REPO/Resources/Info.plist"
refuses " M Resources/Info.plist" --main main 1.1.0 2026-02-01
in_repo checkout --quiet -- Resources/Info.plist
in_repo tag -d v1.0.0 > /dev/null
refuses "there's no tag v1.0.0" --main main 1.1.0 2026-02-01
prepare --check || fail "--check refused, without the tag: $(cat "$WORK/err")"
grep -qF "aren't compared with v1.0.0's, which isn't here" "$WORK/out" || fail "--check said, without the tag: $(cat "$WORK/out")"

# --check --fetch, in a shallow clone of the last commit alone, as CI's: it fetches the last release's tag, and finds a
# version that a pull request raised; and when the release isn't tagged yet, as on its own pull request, it says so.
make_repo
notes good 2026-01-10T10:00:00 "- **Good.** Notes."
merge good 2026-01-11T10:00:00
CLONE="$WORK/clone"
shallow_clone() {
    rm -rf "$CLONE"
    git clone --quiet --no-tags --depth 1 --branch "$1" "file://$REPO" "$CLONE"
}
shallow_clone main
"$CLONE/scripts/prepare-release.sh" --check --fetch > "$WORK/out" || fail "--check --fetch refused: $(cat "$WORK/out")"
grep -qF "fine, from 1 pull request. The descriptions' versions, and CHANGELOG.md, are v1.0.0's." "$WORK/out" ||
    fail "--check --fetch said: $(cat "$WORK/out")"
in_repo checkout --quiet -b raised main
write Sources/GitHubUI/GitHubSource.swift "${GITHUB/descriptionVersion = 1/descriptionVersion = 2}"
commit "Raise GitHub's version" 2026-01-12T10:00:00
shallow_clone raised
if "$CLONE/scripts/prepare-release.sh" --check --fetch > "$WORK/out" 2> "$WORK/err"; then
    fail "--check --fetch didn't find GitHub's version raised."
fi
grep -qF "descriptionVersion is 2, but 1 in v1.0.0" "$WORK/err" || fail "--check --fetch said: $(cat "$WORK/err")"
in_repo checkout --quiet main
prepare --main main 1.1.0 2026-02-01 || fail "it refused the release: $(cat "$WORK/err")"
commit "Prepare BriefBar 1.1.0" 2026-01-13T10:00:00
shallow_clone main
"$CLONE/scripts/prepare-release.sh" --check --fetch > "$WORK/out" || fail "--check --fetch refused a release's own pull request."
grep -qF "v1.1.0 isn't tagged yet" "$WORK/out" || fail "--check --fetch said, of an untagged release: $(cat "$WORK/out")"

echo "scripts/prepare-release.sh passed its tests."
