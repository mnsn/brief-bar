#!/bin/bash
# Checks that every test process `make test` started ran to its end, from Swift Testing's events: one JSON object a
# line, in its event stream's version 0, which `swift test` appends to for each test process. A process that ends early
# leaves `swift test` passing, though Swift Testing never said how its tests went and some never ran: Swift's async
# main ends it with status 0 as soon as the main run loop returns, which AppKit makes it do once it waits for events
# (see `KeepsTheMainRunLoopRunning` in Tests/BriefBarUITests/Support.swift). A test that fails needs no check here:
# `swift test` fails with it.
#   scripts/check-test-events.sh <events>   (after `swift test --event-stream-output-path <events> --event-stream-version 0`)
set -euo pipefail
events="${1:?usage: scripts/check-test-events.sh <events>}"

if [[ ! -s "$events" ]]; then
    echo "error: Swift Testing wrote no events to $events, so there's no telling whether the tests ran." >&2
    exit 1
fi
started=$(grep -cE '"kind" *: *"runStarted"' "$events" || true)
ended=$(grep -cE '"kind" *: *"runEnded"' "$events" || true)
if (( started == 0 || ended != started )); then
    echo "error: $started test runs started, but $ended ran to their end: a test process ended early, so not every" \
        "test ran. Its last tests to start are the likely cause." >&2
    exit 1
fi
echo "Every test run ran to its end ($ended of $started)."
