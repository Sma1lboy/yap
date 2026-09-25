# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build
LOCAL_CODESIGN_IDENTITY ?=
# Extra xcodebuild settings for `local`, e.g. MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION=1042
EXTRA_BUILD_SETTINGS ?=
# CI sets LOCAL_CLEAN=0 to reuse a cached .local-build (compiled Swift packages) instead of starting from scratch
LOCAL_CLEAN ?= 1
RUN_APP_NAME ?= VoiceInk

.PHONY: all clean whisper setup build local check healthcheck help dev run cloud-smoke sync-e2e

# Default target
all: check build

# Development workflow
dev: RUN_APP_NAME = VoiceInk Dev
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		else \
			(cd $(WHISPER_CPP_DIR) && git pull); \
		fi; \
		cd $(WHISPER_CPP_DIR) && ./build-xcframework.sh; \
	else \
		echo "whisper.xcframework already built in $(DEPS_DIR), skipping build"; \
	fi

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" \
		-skipPackagePluginValidation \
		-skipMacroValidation \
		build

# Build locally with stable Apple Development signing when available.
local: check setup
	@echo "Building VoiceInk for local use (no Apple Developer certificate required)..."
	@if [ "$(LOCAL_CLEAN)" = "1" ]; then rm -rf "$(LOCAL_DERIVED_DATA)"; fi
	@SIGNING_IDENTITY="$(LOCAL_CODESIGN_IDENTITY)"; \
	if [ -z "$$SIGNING_IDENTITY" ]; then \
		SIGNING_IDENTITIES=$$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $$2 }'); \
		SIGNING_IDENTITY_COUNT=$$(printf '%s\n' "$$SIGNING_IDENTITIES" | awk 'NF { count++ } END { print count + 0 }'); \
		if [ "$$SIGNING_IDENTITY_COUNT" -eq 1 ]; then \
			SIGNING_IDENTITY=$$(printf '%s\n' "$$SIGNING_IDENTITIES" | awk 'NF { print; exit }'); \
		elif [ "$$SIGNING_IDENTITY_COUNT" -gt 1 ]; then \
			echo "Multiple Apple Development identities found; set LOCAL_CODESIGN_IDENTITY to choose one; using ad-hoc signing"; \
		fi; \
	fi; \
	if [ -n "$$SIGNING_IDENTITY" ] && [ "$$SIGNING_IDENTITY" != "-" ]; then \
		SIGNING_REQUIRED=YES; \
		echo "Using stable local signing identity: $$SIGNING_IDENTITY"; \
	else \
		SIGNING_IDENTITY="-"; \
		SIGNING_REQUIRED=NO; \
		echo "Using ad-hoc signing (permissions may need approval after rebuilds)"; \
	fi; \
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="$$SIGNING_IDENTITY" \
		CODE_SIGNING_REQUIRED="$$SIGNING_REQUIRED" \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		$(EXTRA_BUILD_SETTINGS) \
		-skipPackagePluginValidation \
		-skipMacroValidation \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Release/Yap.app" && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Copying Yap.app to ~/Downloads..."; \
		rm -rf "$$HOME/Downloads/Yap.app"; \
		ditto "$$APP_PATH" "$$HOME/Downloads/Yap.app"; \
		xattr -cr "$$HOME/Downloads/Yap.app"; \
		echo ""; \
		echo "Build complete! App saved to: ~/Downloads/Yap.app"; \
		echo "Run with: open ~/Downloads/Yap.app"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
			else \
		echo "Error: Could not find built Yap.app at $$APP_PATH"; \
		exit 1; \
	fi

# Yap Cloud regression checks against a live paygate (needs YAP_CLOUD_SMOKE_TOKEN; prints how to get one).
# Compiles the real client files with small stubs, no app launch; restores anything it changes.
# YAP_CLOUD_SMOKE_FUNDED=1 PAYGATE_DIR=<railway-linked paygate checkout> adds one real billed transcription + chat
# (funds $0.01 via scripts/adjust.ts, checks the captured generation ids against the ledger, adjusts back to $0).
CLOUD_SMOKE_BIN := $(CURDIR)/.local-build/cloud-smoke
cloud-smoke:
	@mkdir -p "$(dir $(CLOUD_SMOKE_BIN))"
	@xcrun swiftc -DDEBUG -Onone -o "$(CLOUD_SMOKE_BIN)" \
		scripts/cloud-smoke/Stubs.swift scripts/cloud-smoke/main.swift \
		VoiceInk/Infrastructure/Cloud/YapCloudClient.swift VoiceInk/Infrastructure/Cloud/YapCloudProvider.swift
	@"$(CLOUD_SMOKE_BIN)"

SYNC_E2E_BIN := $(CURDIR)/.local-build/sync-e2e
sync-e2e:
	@mkdir -p "$(dir $(SYNC_E2E_BIN))"
	@xcrun swiftc -DDEBUG -Onone -o "$(SYNC_E2E_BIN)" \
		scripts/cloud-smoke/Stubs.swift scripts/sync-e2e/LoaderStub.swift scripts/sync-e2e/main.swift \
		VoiceInk/Infrastructure/Config/YapConfig.swift \
		VoiceInk/Infrastructure/Config/CloudConfigSync.swift \
		VoiceInk/Infrastructure/Config/RecommendedSetup.swift \
		VoiceInk/Infrastructure/Cloud/YapCloudClient.swift \
		VoiceInk/Infrastructure/Cloud/YapCloudProvider.swift \
		VoiceInk/Infrastructure/Cloud/YapCloud+ConfigSync.swift \
		VoiceInk/Infrastructure/SystemIntegration/Lifecycle/LifecycleObserver.swift \
		VoiceInk/Features/Settings/Backup/BackupTypes.swift \
		VoiceInk/Features/Shortcuts/Models/ShortcutBackup.swift \
		VoiceInk/Features/Shortcuts/Models/Shortcut.swift \
		VoiceInk/Features/Shortcuts/Models/Shortcut+ConfigString.swift \
		VoiceInk/Features/Modes/State/ModeConfig.swift \
		VoiceInk/Features/Enhancement/Models/CustomPrompt.swift \
		VoiceInk/Features/ModelLibrary/Models/CustomAIProviderConfig.swift \
		VoiceInk/Features/Modes/Models/ModeTriggerModels.swift \
		VoiceInk/Features/Modes/Models/ModeIcon.swift
	@scripts/sync-e2e/run.sh "$(SYNC_E2E_BIN)"

# Run application
run:
	@if [ -d "$$HOME/Downloads/$(RUN_APP_NAME).app" ]; then \
		echo "Opening ~/Downloads/$(RUN_APP_NAME).app..."; \
		open "$$HOME/Downloads/$(RUN_APP_NAME).app"; \
	else \
		echo "Looking for $(RUN_APP_NAME).app in DerivedData..."; \
		APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "$(RUN_APP_NAME).app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "$(RUN_APP_NAME).app not found. Build it with 'make local' or use 'make dev' for the development app."; \
			exit 1; \
		fi; \
	fi

# Build a signed, notarized DMG and matching local Sparkle Appcast.
# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(DEPS_DIR)
	@echo "Clean complete"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoiceInk project"
	@echo "  build              Build the VoiceInk Xcode project"
	@echo "  local              Build locally with stable signing when available"
	@echo "    LOCAL_CODESIGN_IDENTITY=<SHA or name> overrides automatic Apple Development detection"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  cloud-smoke        Check the Yap Cloud client against live paygate (YAP_CLOUD_SMOKE_TOKEN)"
	@echo "  sync-e2e           Two simulated Macs sync through live paygate (throwaway account, needs railway CLI)"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"
