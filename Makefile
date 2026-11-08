.PHONY: build test plugin-test check-boundaries signing-key-check homebrew-cask-check release-notes-check updater-check update-rehearsal app package install uninstall run demo demo-data demo-check dump watch diagnose render screenshots readme-tour icon signing-identity pppc-profile clean

# With only the Command Line Tools installed, the compiler sometimes misses Swift Testing's macro
# plugin (it lives in a subfolder), so point it there explicitly.
TESTING_PLUGINS := $(abspath $(dir $(shell xcrun --find swift))../lib/swift/host/plugins/testing)

# Swift Testing's events from `make test`, one JSON object a line, for scripts/check-test-events.sh.
TEST_EVENTS := $(abspath .build/test-events.jsonl)

# Made-up data for every source: Teams notifications in Notification Center's layout
# (scripts/make-teams-demo-data.swift) and a Copilot data directory (scripts/make-copilot-demo-data.swift).
# Azure DevOps and GitHub make up their own (--demo).
DEMO_DIR := $(abspath build/demo)
DEMO_ENV := BRIEFBAR_TEAMS_DB="$(DEMO_DIR)/teams/db2/db" BRIEFBAR_TEAMS_STATE_DIR="$(DEMO_DIR)/teams/state" \
	BRIEFBAR_COPILOT_DIR="$(DEMO_DIR)/copilot"
MAKE_TEAMS_DEMO_DATA := swift scripts/make-teams-demo-data.swift "$(DEMO_DIR)/teams"
MAKE_COPILOT_DEMO_DATA := swift scripts/make-copilot-demo-data.swift "$(DEMO_DIR)/copilot"
# The binary that demo-check runs: the debug build, unless scripts/check-app.sh passes a built app.
BRIEFBAR = $(shell swift build --arch arm64 --show-bin-path)/BriefBar
SCREENSHOTS := menubar-teams.chats-light menubar-teams.chats-dark menubar-combined-light menubar-combined-dark \
	menubar-by-state-light menubar-by-state-dark widget-all-medium-light widget-all-medium-dark
# Window and detail pictures, as JPEG: their backgrounds would make PNGs several times larger.
WINDOW_SHOTS := window-overview-light window-overview-dark \
	window-azureDevOps.sprint-light window-azureDevOps.sprint-dark \
	rows-summary-pull-requests-light rows-summary-pull-requests-dark \
	azureDevOps-copilot-composer-light azureDevOps-copilot-composer-dark

build:
	swift build --arch arm64

# First, in a second, the release notes in changes/ (scripts/prepare-release.sh --check): on a release's tag, as the
# release workflow runs it, that also refuses notes the release didn't gather. Then the tests.
# With a single thread in Swift's cooperative pool, rather than one per core, code that blocks a thread of it while
# waiting for async work hangs here too, as it would on a runner with few cores. Swift Testing's events then show that
# every test process ran to its end: one that ends early, with status 0, would otherwise pass without the tests it
# hadn't run (scripts/check-test-events.sh).
test:
	@./scripts/prepare-release.sh --check
	@rm -f "$(TEST_EVENTS)"
	LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --arch arm64 $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)) \
		--event-stream-output-path "$(TEST_EVENTS)" --event-stream-version 0
	@scripts/check-test-events.sh "$(TEST_EVENTS)"

# BriefBar's extension for the Copilot app's sessions (Resources/CopilotPlugin/briefbar-sessions), with Node's test
# runner and a stand-in for the Copilot SDK, in Tests/CopilotPlugin so that the tests don't ship. CI runs it.
plugin-test:
	node --test --experimental-vm-modules Tests/CopilotPlugin/*.test.mjs

# Only the Azure DevOps and GitHub sources may use the network, and only BriefBarCore starts programs.
check-boundaries: build
	./scripts/check-boundaries.sh

# What keeps signing keys safe, in throwaway keychains: nothing here makes macOS ask anything. CI runs it.
signing-key-check:
	./scripts/test-signing-key.sh

# The release workflow's last step, which points the Homebrew cask at a release, against a tap of its own in a
# temporary folder: no network, no key. CI runs it.
homebrew-cask-check:
	./scripts/test-homebrew-cask.sh

# The release notes that pull requests write in changes/ (see "Release notes" in CONTRIBUTING.md), and the tests of
# scripts/prepare-release.sh, which gathers them for a release, in repositories of their own in a temporary folder. CI
# runs it.
release-notes-check:
	./scripts/prepare-release.sh --check
	./scripts/test-prepare-release.sh

# That BriefBar's updater, which holds Sparkle with library validation off, can't use BriefBar's privacy
# permissions, and that other code in Sparkle's place never runs as BriefBar: in a copy of build/BriefBar.app
# (make app) that macOS opens.
updater-check:
	./scripts/test-updater-isolation.sh

# An update through the updater, as an installed copy gets one: a copy of build/BriefBar.app (make app) installs a
# newer one from a feed on this Mac, signed with throwaway keys, under a bundle identifier of its own.
update-rehearsal:
	./scripts/update-rehearsal.sh

# BriefBar.app in ./build, signed ad hoc (or with your certificate, if you made one: make signing-identity).
app:
	./scripts/build-app.sh

# What a release ships, in build/release: the Apple silicon app, checked and zipped, and its notes. It's signed with
# a certificate, as a release is (see "Signing" in CONTRIBUTING.md).
package:
	./scripts/package.sh

install:
	./scripts/build-app.sh --install

uninstall:
	-pgrep -f "/BriefBar.app/Contents/MacOS/BriefBar" | xargs kill 2>/dev/null
	rm -rf "$(HOME)/Applications/BriefBar.app"

# Optional: a self-signed certificate that every build is then signed with, instead of ad hoc, so Full Disk
# Access survives rebuilds. Each build asks for your login password. scripts/make-signing-identity.sh --delete
# goes back to ad hoc.
signing-identity:
	./scripts/make-signing-identity.sh

# A configuration profile that grants the app built here Full Disk Access, for an MDM to deploy.
pppc-profile: app
	./scripts/make-pppc-profile.sh

# The app from a debug build, with its own settings (it saves no chats). The next three read your own
# data, for the sources that are on in the installed app, or the ones --source names, as in
# make dump ARGS="--source copilot".
run: build
	"$(BRIEFBAR)" $(ARGS)

dump: build
	"$(BRIEFBAR)" --dump $(ARGS)

watch: build
	"$(BRIEFBAR)" --watch $(ARGS)

# Teams' structure only: no names, messages or IDs. Safe to paste into an issue.
diagnose: build
	"$(BRIEFBAR)" --diagnose

demo-data:
	$(MAKE_TEAMS_DEMO_DATA)
	$(MAKE_COPILOT_DEMO_DATA)

# Runs the app with made-up data for every source instead of yours; ARGS=--window opens its window. Ctrl-C quits.
demo: build demo-data
	$(DEMO_ENV) "$(BRIEFBAR)" --demo $(ARGS)

# Checks that the made-up data lands in the expected groups. CI runs this.
demo-check: $(if $(filter command line,$(origin BRIEFBAR)),,build) demo-data
	@$(DEMO_ENV) ./scripts/demo-check.sh "$(BRIEFBAR)"

# Draws the menu bar with each list open, the widgets, the window and Settings from your own data, into the
# ignored render/.
render: build
	"$(BRIEFBAR)" --render render $(ARGS)

# Renders the README's pictures from the demo data, with Teams' summaries if Apple Intelligence is on, and its
# animated tours if ffmpeg is installed. A hundred to a process (--part, which exits with 3 while another part follows):
# SwiftUI keeps a process's view graphs in one table, which can't grow past a limit, so however many pictures there
# are, none runs out of room. Each part makes the demo data again, whose times are relative to now, so that its
# pictures show the times they would in one process.
screenshots: build
	rm -rf build/screenshots
	part=1; while :; do \
		{ $(MAKE_TEAMS_DEMO_DATA) && $(MAKE_COPILOT_DEMO_DATA); } >/dev/null || exit 1; \
		$(DEMO_ENV) BRIEFBAR_RENDER_SUMMARIES=1 "$(BRIEFBAR)" --demo --render build/screenshots --part $$part; \
		status=$$?; [ $$status -eq 3 ] || exit $$status; part=$$((part + 1)); \
	done
	mkdir -p docs/images
	for name in $(SCREENSHOTS); do cp build/screenshots/$$name.png docs/images/; done
	for name in $(WINDOW_SHOTS); do sips -s format jpeg -s formatOptions 88 build/screenshots/$$name.png --out docs/images/$$name.jpg >/dev/null; done
	@if command -v ffmpeg >/dev/null; then $(MAKE) readme-tour; else echo "Skipped the README's tours: brew install ffmpeg, then make readme-tour."; fi

# The README's animated tours, in light and dark, from the pictures make screenshots renders. Needs ffmpeg.
readme-tour:
	swift scripts/make-readme-tour.swift build/screenshots docs/images build/readme-tour

# The app's icon, and the README's copy of it.
icon:
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
	cp build/AppIcon.iconset/icon_128x128@2x.png docs/images/icon.png

clean:
	rm -rf .build build
