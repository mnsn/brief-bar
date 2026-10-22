#!/bin/bash
# Checks that every source's made-up data lands in the expected groups: the counts that
# `BriefBar --demo --json` prints for each source, by its own groups and by state. `make demo-check`
# runs it with the demo data's variables set; CI runs it, and so does scripts/check-app.sh with a built
# app.
#   scripts/demo-check.sh <BriefBar binary>
set -euo pipefail
BIN="${1:?Usage: $0 <BriefBar binary>}"

fail() {
    echo "demo-check failed: $1" >&2
    exit 1
}

JSON="$("$BIN" --demo --json)"

# Each source's counts, by group.
EXPECTED='{"azureDevOps":{"answered":1,"done":1,"failing":2,"idle":2,"needsYou":4,"ready":2,"toReview":1,"waiting":2},"copilot":{"done":1,"idle":3,"needsYou":3,"running":2,"stopped":1},"teams":{"chats":2,"groups":2}}'
COUNTS="$(jq -cS 'with_entries(.value |= .counts)' <<<"$JSON")"
[[ "$COUNTS" == "$EXPECTED" ]] || fail "expected $EXPECTED, got $COUNTS"

# Each section's counts by state, the same for every source: unread chats, pull requests and Copilot sessions
# that need you; failing pull requests and stopped sessions; running sessions; pull requests ready to complete
# and finished sessions. To Review doesn't need you here: the demo doesn't show it in the menu bar.
EXPECTED_STATES='{"azureDevOps.pullRequests":{"done":2,"failing":2,"needsYou":4,"running":0},"copilot.sessions":{"done":1,"failing":1,"needsYou":3,"running":2},"teams.chats":{"done":0,"failing":0,"needsYou":2,"running":0},"teams.groupChats":{"done":0,"failing":0,"needsYou":2,"running":0}}'
STATES="$(jq -cS '[.[].states] | add' <<<"$JSON")"
[[ "$STATES" == "$EXPECTED_STATES" ]] || fail "expected the counts by state $EXPECTED_STATES, got $STATES"

# And added up, as one menu-bar item that shows every section by meaning would count them.
EXPECTED_TOTALS='{"done":3,"failing":3,"needsYou":11,"running":2}'
TOTALS="$(jq -cS '[.[].states[] | to_entries[]] | group_by(.key) | map({(.[0].key): (map(.value) | add)}) | add' <<<"$JSON")"
[[ "$TOTALS" == "$EXPECTED_TOTALS" ]] || fail "expected the sum by state $EXPECTED_TOTALS, got $TOTALS"

# Each source alone, too.
for source in teams:teams ado:azureDevOps copilot:copilot; do
    [[ "$("$BIN" --demo --source "${source%%:*}" --json | jq -cS 'keys')" == "[\"${source##*:}\"]" ]] ||
        fail "--source ${source%%:*} doesn't print only that source"
done

# Azure DevOps' own modes: the demo never uses the Azure CLI or Azure DevOps. (No grep -q in these
# pipes: with pipefail, its early exit could make a match look like none.)
"$BIN" --demo --orgs | grep -x '\*+ contoso' >/dev/null ||
    fail "--demo --orgs doesn't list only the made-up organization"
"$BIN" --demo --source ado --watch | grep 'needsYou  Priya Shah commented: !4091' >/dev/null ||
    fail "--demo --source ado --watch doesn't show the made-up change"
"$BIN" --demo --chats | grep 'Dana Whitfield' >/dev/null ||
    fail "--demo --chats doesn't show the made-up link"
"$BIN" --demo --sprint | grep '^Sprint 42 · Storefront Team' >/dev/null ||
    fail "--demo --sprint doesn't show the made-up sprint"
[[ "$("$BIN" --demo --sprint --mine | grep -c '(you)')" == 5 ]] ||
    fail "--demo --sprint --mine doesn't show your 5 tasks"
"$BIN" --demo --pipelines | grep '^shop-web CI .*Failed in Test' >/dev/null ||
    fail "--demo --pipelines doesn't show the made-up failed run"

echo "demo-check passed: $COUNTS; by state, $TOTALS"
