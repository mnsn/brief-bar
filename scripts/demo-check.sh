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

# Runs a command for at most this many seconds, so a server that waits forever fails the check instead of hanging it.
within() {
    perl -e 'alarm shift; exec @ARGV or die "$!\n"' "$@"
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

# Agents: --mcp speaks the Model Context Protocol, one JSON-RPC message a line, with the made-up data. Teams has no tools.
MCP="$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"needs_me","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"pull_request_prompt","arguments":{"pull_request":4088,"action":"fix_build"}}}' |
    within 60 "$BIN" --demo --mcp)"
[[ "$(jq -sr 'map(select(.id == 1))[0].result.serverInfo.name' <<<"$MCP")" == briefbar ]] ||
    fail "--demo --mcp doesn't answer initialize"
EXPECTED_TOOLS='["needs_me","pull_requests","pull_request","pull_request_prompt","pipelines","sprint","copilot_tasks","watch_pull_request","stop_watching_pull_request","pin_pipeline","unpin_pipeline","copilot_sessions"]'
TOOLS="$(jq -sc 'map(select(.id == 2))[0].result.tools | map(.name)' <<<"$MCP")"
[[ "$TOOLS" == "$EXPECTED_TOOLS" ]] || fail "--demo --mcp lists the tools $TOOLS"
NEEDS_ME="$(jq -sr 'map(select(.id == 3))[0].result.content[0].text' <<<"$MCP")"
grep '^- !4088 “Show delivery estimates on the product page”' <<<"$NEEDS_ME" >/dev/null ||
    fail "--demo --mcp's needs_me doesn't have the failing pull request"
grep '^- “Add dark mode to settings” (shop-web, dark-mode): Waiting for your answer' <<<"$NEEDS_ME" >/dev/null ||
    fail "--demo --mcp's needs_me doesn't have the Copilot session waiting for an answer"
jq -sr 'map(select(.id == 4))[0].result.content[0].text' <<<"$MCP" | grep '2 tests failed in DeliveryEstimateTests' >/dev/null ||
    fail "--demo --mcp's pull_request_prompt doesn't have the failed build's errors"
if within 60 "$BIN" --demo --source teams --mcp </dev/null >/dev/null 2>&1; then
    fail "--demo --source teams --mcp serves Teams"
fi
# Requests from a file too, not only from a pipe as agents send them.
REQUESTS="$(mktemp)"
trap 'rm -f "$REQUESTS"' EXIT
printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"ping"}' >"$REQUESTS"
[[ "$(within 60 "$BIN" --demo --mcp <"$REQUESTS" | jq -r .id)" == 7 ]] ||
    fail "--demo --mcp doesn't answer requests from a file"

echo "demo-check passed: $COUNTS; by state, $TOTALS"
