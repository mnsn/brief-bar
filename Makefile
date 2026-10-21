.PHONY: build test check-networking app package install uninstall run demo demo-data demo-check dump watch render screenshots icon signing-identity clean

# With only the Command Line Tools installed, the compiler sometimes misses Swift Testing's macro
# plugin (it lives in a subfolder), so point it there explicitly.
TESTING_PLUGINS := $(abspath $(dir $(shell xcrun --find swift))../lib/swift/host/plugins/testing)

# Made-up data for every source (see scripts/demo-data.sh).
DEMO_DIR := $(abspath build/demo)
DEMO_ENV :=
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

# The app from a debug build, with its own settings (it saves no chats). The next three read your own
# data, for the sources that are on in the installed app, or the ones --source names, as in
# make dump ARGS="--source copilot".
run: build
	"$(PULSE)" $(ARGS)

dump: build
	"$(PULSE)" --dump $(ARGS)

watch: build
	"$(PULSE)" --watch $(ARGS)

demo-data:
	@true

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
