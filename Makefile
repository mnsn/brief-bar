.PHONY: build test check-boundaries signing-key-check app package install uninstall run demo demo-data demo-check dump watch diagnose render screenshots icon signing-identity pppc-profile clean

# With only the Command Line Tools installed, the compiler sometimes misses Swift Testing's macro
# plugin (it lives in a subfolder), so point it there explicitly.
TESTING_PLUGINS := $(abspath $(dir $(shell xcrun --find swift))../lib/swift/host/plugins/testing)

# Made-up data for every source: Teams notifications in Notification Center's layout
# (scripts/make-teams-demo-data.swift) and a Copilot data directory (scripts/make-copilot-demo-data.swift).
# Azure DevOps makes up its own (--demo).
DEMO_DIR := $(abspath build/demo)
DEMO_ENV := BRIEFBAR_TEAMS_DB="$(DEMO_DIR)/teams/db2/db" BRIEFBAR_TEAMS_STATE_DIR="$(DEMO_DIR)/teams/state" \
	BRIEFBAR_COPILOT_DIR="$(DEMO_DIR)/copilot"
# The binary that demo-check runs: the debug build, unless scripts/check-app.sh passes a built app.
BRIEFBAR = $(shell swift build --show-bin-path)/BriefBar
SCREENSHOTS := menubar-teams.chats-light menubar-teams.chats-dark menubar-combined-light menubar-combined-dark \
	widget-all-medium-light widget-all-medium-dark
# The window's pictures, as JPEG: its translucent background would make PNGs several times larger.
WINDOW_SHOTS := window-azureDevOps.pullRequests-light window-azureDevOps.pullRequests-dark \
	window-azureDevOps.sprint-light window-azureDevOps.sprint-dark

build:
	swift build

test:
	swift test $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

# Only the Azure DevOps source may use the network, and only BriefBarCore starts programs.
check-boundaries: build
	./scripts/check-boundaries.sh

# What keeps signing keys safe, in throwaway keychains: nothing here makes macOS ask anything. CI runs it.
signing-key-check:
	./scripts/test-signing-key.sh

# BriefBar.app in ./build, signed ad hoc (or with your certificate, if you made one: make signing-identity).
app:
	./scripts/build-app.sh

# What a release ships, in build/release: the universal app, checked and zipped, and its notes. It's signed with
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
	swift scripts/make-teams-demo-data.swift "$(DEMO_DIR)/teams"
	swift scripts/make-copilot-demo-data.swift "$(DEMO_DIR)/copilot"

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

# Renders the README's pictures from the demo data, with Teams' summaries if Apple Intelligence is on.
screenshots: build demo-data
	rm -rf build/screenshots
	$(DEMO_ENV) BRIEFBAR_RENDER_SUMMARIES=1 "$(BRIEFBAR)" --demo --render build/screenshots
	mkdir -p docs/images
	for name in $(SCREENSHOTS); do cp build/screenshots/$$name.png docs/images/; done
	for name in $(WINDOW_SHOTS); do sips -s format jpeg -s formatOptions 88 build/screenshots/$$name.png --out docs/images/$$name.jpg >/dev/null; done

icon:
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build
