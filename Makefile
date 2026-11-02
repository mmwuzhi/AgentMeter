.PHONY: build run app adhoc debug clean dmg appcast

# Compile (release)
build:
	swift build -c release

# Assemble dist/AgentMeter.app
app:
	bash Scripts/bundle.sh

# Assemble dist/AgentMeter.app signed ad-hoc: no certificate or Team ID
# needed, and updates off (a test build never updates itself)
adhoc:
	CODESIGN_IDENTITY=- UPDATE_CHANNEL=rc bash Scripts/bundle.sh

# Build, bundle, and launch
run: app
	open dist/AgentMeter.app

# Quick debug build + run from terminal (no .app)
debug:
	swift build && ./.build/debug/AgentMeter

# Package a DMG from the built .app
dmg: app
	bash Scripts/dmg.sh

# Regenerate appcast.xml entry for the latest DMG
appcast:
	bash Scripts/appcast.sh

clean:
	rm -rf .build dist
