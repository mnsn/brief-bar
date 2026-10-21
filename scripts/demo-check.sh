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
EXPECTED='{"copilot":{"done":1,"idle":3,"needsYou":3,"running":2,"stopped":1}}'
COUNTS="$("$BIN" --demo --json | jq -cS 'with_entries(.value |= .counts)')"
[[ "$COUNTS" == "$EXPECTED" ]] || fail "expected $EXPECTED, got $COUNTS"

# Each source alone, too.
[[ "$("$BIN" --demo --source copilot --json | jq -cS 'keys')" == '["copilot"]' ]] ||
    fail "--source copilot doesn't print only Copilot"

echo "demo-check passed: $COUNTS"
