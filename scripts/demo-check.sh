#!/bin/bash
# Checks that every source's made-up data lands in the expected groups: the counts that
# `BriefBar --demo --json` prints for each source. `make demo-check` runs it with the demo data's
# variables set; CI runs it, and so does scripts/check-app.sh with a built app.
#   scripts/demo-check.sh <BriefBar binary>
set -euo pipefail
BIN="${1:?Usage: $0 <BriefBar binary>}"

fail() {
    echo "demo-check failed: $1" >&2
    exit 1
}

# Each source's counts, by group.
EXPECTED='{"azureDevOps":{"done":1,"failing":2,"idle":2,"needsYou":3,"ready":2,"toReview":1,"waiting":2},"copilot":{"done":1,"idle":3,"needsYou":3,"running":2,"stopped":1},"teams":{"chats":2,"groups":2}}'
COUNTS="$("$BIN" --demo --json | jq -cS 'with_entries(.value |= .counts)')"
[[ "$COUNTS" == "$EXPECTED" ]] || fail "expected $EXPECTED, got $COUNTS"

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

echo "demo-check passed: $COUNTS"
