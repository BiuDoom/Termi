# Termi — macOS SSH Client
# Unified build & distribution Makefile

SCHEME      = Termi
PROJECT     = Termi.xcodeproj
BUILD_DIR   = build
ARCHIVE     = $(BUILD_DIR)/Termi.xcarchive
APP         = $(BUILD_DIR)/Termi.app
EXPORT_OPTS = scripts/ExportOptions.plist
VERSION    := $(shell grep MARKETING_VERSION $(PROJECT)/project.pbxproj | head -1 | sed 's/.*= *\(.*\);/\1/' | tr -d ' ')
DMG         = $(BUILD_DIR)/Termi-$(VERSION).dmg

.PHONY: build dmg clean check-xcode

# Ensure xcode-select points to Xcode.app (not CommandLineTools)
check-xcode:
	@if ! xcodebuild -version >/dev/null 2>&1; then \
		echo "Error: xcodebuild not available. Run: sudo xcode-select -s /Applications/Xcode.app"; \
		exit 1; \
	fi

build: check-xcode
	@echo "==> Building Termi $(VERSION) (ad-hoc signed)..."
	bash scripts/build-release.sh
	@echo "==> Build complete: $(APP)"

dmg: build
	@echo "==> Creating DMG..."
	bash scripts/create-dmg.sh
	@echo "==> DMG created: $(DMG)"

clean:
	@echo "==> Cleaning build directory..."
	rm -rf $(BUILD_DIR)
	@echo "==> Clean complete"

# --- Acceptance testing (docs/TESTING.md) ---------------------------------------------------
# SSH servers in Docker and an isolated app profile seeded with hosts for them. Nothing here
# reads or writes the real profile.

TEST_ENV          = $(CURDIR)/.test-env
DEBUG_DERIVED     = $(CURDIR)/$(BUILD_DIR)/DerivedData-Debug
DEBUG_APP         = $(DEBUG_DERIVED)/Build/Products/Debug/Termi.app
# Extra xcodebuild arguments for build-debug, e.g. a shared package checkout.
XCODEBUILD_FLAGS ?=

.PHONY: test-env-up test-env-down test-env-status build-debug run-isolated check-strings

test-env-up:
	bash TestEnvironment/test-env.sh up

test-env-down:
	bash TestEnvironment/test-env.sh down

test-env-status:
	bash TestEnvironment/test-env.sh status

# The Debug configuration: the launch arguments for testing (-debugSeedHosts, -debugPage, …)
# do not exist in the Release archive "make build" produces.
build-debug: check-xcode
	@echo "==> Building Termi (Debug)..."
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath "$(DEBUG_DERIVED)" -quiet $(XCODEBUILD_FLAGS)

# The app on the test environment's own profile, with the hosts of the test servers. -n: a
# separate instance even while the real app is open.
run-isolated: build-debug
	@test -f "$(TEST_ENV)/seed-hosts.json" || { echo "Error: $(TEST_ENV)/seed-hosts.json is missing. Run: make test-env-up"; exit 1; }
	open -n --env TERMI_PROFILE_DIR="$(TEST_ENV)/profile" "$(DEBUG_APP)" \
		--args -debugSeedHosts "$(TEST_ENV)/seed-hosts.json"

# Every string the code shows has a zh-Hans translation, and the catalog holds nothing the code no
# longer uses. "python3 scripts/check-strings.py … --prune" removes the unused entries.
check-strings: build-debug
	python3 scripts/check-strings.py Termi/Localizable.xcstrings "$(DEBUG_DERIVED)" Termi
