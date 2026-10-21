.PHONY: build test check-networking app package install uninstall run demo demo-data demo-check dump watch diagnose render screenshots icon signing-identity pppc-profile clean

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
PULSE = $(shell swift build --show-bin-path)/BriefBar
SCREENSHOTS :=

build:
	swift build

test:
	swift test $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

# Only the Azure DevOps source may use the network; this fails if any other module does.
check-networking: build
	./scripts/check-networking.sh

app:
	./scripts/build-app.sh

# The universal app, checked and zipped, with its SHA-256, in build/release.
package:
	./scripts/package.sh

install:
	./scripts/build-app.sh --install

uninstall:
	-pgrep -f "/BriefBar.app/Contents/MacOS/BriefBar" | xargs kill 2>/dev/null
	rm -rf "$(HOME)/Applications/BriefBar.app"

# Creates the certificate every build is signed with, so Full Disk Access survives rebuilds. Run it once.
signing-identity:
	./scripts/make-signing-identity.sh

# A configuration profile that grants the app built here Full Disk Access, for an MDM to deploy.
pppc-profile: app
	./scripts/make-pppc-profile.sh

# The app from a debug build, with its own settings (it saves no chats). The next three read your own
# data, for the sources that are on in the installed app, or the ones --source names, as in
# make dump ARGS="--source copilot".
run: build
	"$(PULSE)" $(ARGS)

dump: build
	"$(PULSE)" --dump $(ARGS)

watch: build
	"$(PULSE)" --watch $(ARGS)

# Teams' structure only: no names, messages or IDs. Safe to paste into an issue.
diagnose: build
	"$(PULSE)" --diagnose

demo-data:
	swift scripts/make-teams-demo-data.swift "$(DEMO_DIR)/teams"
	swift scripts/make-copilot-demo-data.swift "$(DEMO_DIR)/copilot"

# Runs the app with made-up data for every source instead of yours. Ctrl-C quits.
demo: build demo-data
	$(DEMO_ENV) "$(PULSE)" --demo

# Checks that the made-up data lands in the expected groups. CI runs this.
demo-check: $(if $(filter command line,$(origin PULSE)),,build) demo-data
	@$(DEMO_ENV) ./scripts/demo-check.sh "$(PULSE)"

# Draws the menu bar with each list open, the widgets and Settings from your own data, into the ignored render/.
render: build
	"$(PULSE)" --render render $(ARGS)

# Renders the README's pictures from the demo data.
screenshots: build demo-data
	$(DEMO_ENV) "$(PULSE)" --demo --render build/screenshots
	mkdir -p docs/images
	for name in $(SCREENSHOTS); do cp build/screenshots/$$name.png docs/images/; done

icon:
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build
