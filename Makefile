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

.PHONY: all clean whisper setup build local check healthcheck help dev run cloud-smoke cloud-latency paygate-local paygate-local-stop design-tokens design-check mock offline-check meeting-files-check meeting-echo-check meeting-long-check meeting-call-check edit-rate-check mcp-check mcp-agent-eval mcp-perf first-run-check model-residency-check dictation-latency ui-snapshots ui-review sync-e2e

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

build: setup design-check
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

# Which paygate cloud-smoke, cloud-latency and sync-e2e talk to. local (default): a throwaway paygate on this Mac
# (scripts/paygate-local.sh, started on demand, same model allowlist as production); operator scripts run with
# `bun run` there, so nothing is created on production. prod: https://cloud.yap.sma1lboy.me, operator scripts over
# `railway ssh` from PAYGATE_DIR (a Railway-linked paygate checkout); must be asked for explicitly.
PAYGATE ?= local
PAYGATE_LOCAL_DIR := $(CURDIR)/.local-build/paygate-local/paygate
ifeq ($(PAYGATE),local)
PAYGATE_ENV := PAYGATE=local PAYGATE_DIR="$(PAYGATE_LOCAL_DIR)" YAP_CLOUD_SMOKE_URL=http://localhost:8787 YAP_CLOUD_SMOKE_TOKEN=
PAYGATE_UP := paygate-local
else ifeq ($(PAYGATE),prod)
PAYGATE_ENV := PAYGATE=prod YAP_CLOUD_SMOKE_URL=
PAYGATE_UP :=
else
$(error PAYGATE must be local or prod, not "$(PAYGATE)")
endif

# Start / stop the local paygate (Postgres on 55432, paygate on http://localhost:8787, source from ~/i/paygate).
paygate-local:
	@scripts/paygate-local.sh start

paygate-local-stop:
	@scripts/paygate-local.sh stop

# Yap Cloud regression checks of the real client against paygate (PAYGATE above). On production it needs
# YAP_CLOUD_SMOKE_TOKEN or PAYGATE_DIR (prints how to get one). Compiles the real client files with small stubs,
# no app launch; restores anything it changes. YAP_CLOUD_SMOKE_FUNDED=1 adds one real billed transcription + chat
# (funds $0.01 via scripts/adjust.ts, checks the captured generation ids against the ledger, adjusts back to $0).
CLOUD_SMOKE_BIN := $(CURDIR)/.local-build/cloud-smoke
cloud-smoke: $(PAYGATE_UP)
	@mkdir -p "$(dir $(CLOUD_SMOKE_BIN))"
	@xcrun swiftc -DDEBUG -Onone -o "$(CLOUD_SMOKE_BIN)" \
		scripts/cloud-smoke/Stubs.swift scripts/cloud-smoke/Ops.swift scripts/cloud-smoke/main.swift \
		VoiceInk/Infrastructure/Cloud/YapCloudClient.swift VoiceInk/Infrastructure/Cloud/YapCloudProvider.swift \
		VoiceInk/Infrastructure/Providers/Transcription/Cloud/TranscriptionHints.swift
	@$(PAYGATE_ENV) "$(CLOUD_SMOKE_BIN)"

# Yap Cloud latency with the real client code (PAYGATE above; on production PAYGATE_DIR is required). Uses a
# throwaway account funded $0.05, zeroed and deleted at the end.
CLOUD_LATENCY_BIN := $(CURDIR)/.local-build/cloud-latency
cloud-latency: $(PAYGATE_UP)
	@mkdir -p "$(dir $(CLOUD_LATENCY_BIN))"
	@xcrun swiftc -DDEBUG -O -o "$(CLOUD_LATENCY_BIN)" \
		scripts/cloud-smoke/Stubs.swift scripts/cloud-smoke/Ops.swift scripts/cloud-latency/main.swift \
		VoiceInk/Infrastructure/Cloud/YapCloudClient.swift VoiceInk/Infrastructure/Cloud/YapCloudProvider.swift \
		VoiceInk/Infrastructure/Providers/Transcription/Cloud/TranscriptionHints.swift
	@$(PAYGATE_ENV) "$(CLOUD_LATENCY_BIN)"

SYNC_E2E_BIN := $(CURDIR)/.local-build/sync-e2e
sync-e2e: $(PAYGATE_UP)
	@mkdir -p "$(dir $(SYNC_E2E_BIN))"
	@xcrun swiftc -DDEBUG -DSYNC_E2E -Onone -o "$(SYNC_E2E_BIN)" \
		scripts/cloud-smoke/Stubs.swift scripts/sync-e2e/LoaderStub.swift scripts/sync-e2e/main.swift \
		VoiceInk/Infrastructure/Config/YapConfig.swift \
		VoiceInk/Infrastructure/Config/CloudConfigSync.swift \
		VoiceInk/Infrastructure/Config/RecommendedSetup.swift \
		VoiceInk/Infrastructure/Cloud/YapCloudClient.swift \
		VoiceInk/Infrastructure/Cloud/YapCloudProvider.swift \
		VoiceInk/Infrastructure/Providers/Transcription/Cloud/TranscriptionHints.swift \
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
	@$(PAYGATE_ENV) scripts/sync-e2e/run.sh "$(SYNC_E2E_BIN)"

# docs/DESIGN.md is the only source of design tokens: generate the app's DesignTokens.generated.swift and
# design/web/tokens.css from it, and check that nothing hard-codes colors, font sizes, radii or spacing.
design-tokens:
	@python3 scripts/design-tokens.py

design-check:
	@python3 scripts/design-tokens.py --check
	@python3 scripts/check-i18n.py

# Run the Debug app with fake data (signed in, 20 transcripts, 5 modes…), offline, in its own settings domain
# (me.sma1lboy.yap.mock). Everything it created is deleted on quit. See scripts/mock.sh.
mock: build
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/mock.sh "$$APP_DIR"

# Does a local dictation (Whisper model MODEL, cleanup off) touch the network? Runs one dictation with the network
# denied, then one with it allowed while logging the app's sockets. See scripts/offline-check.sh.
offline-check: build
	@test -n "$(MODEL)" || { echo "usage: make offline-check MODEL=/path/to/ggml-large-v3-turbo-q5_0.bin"; exit 2; }
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/offline-check.sh "$$APP_DIR" "$(MODEL)"

# Yap's memory while a local Whisper model is loaded vs released, and how long the first dictation after the release
# waits, without and with the shortcut-press preload (scripts/model-residency-check.sh). KEEP=<seconds> (default 5).
model-residency-check: build
	@test -n "$(MODEL)" || { echo "usage: make model-residency-check MODEL=/path/to/ggml-*.bin"; exit 2; }
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/model-residency-check.sh "$$APP_DIR" "$(MODEL)"

# yap-mcp, the read-only MCP server in Yap.app/Contents/Helpers (docs/mcp.md), over stdio against fixture data written
# by the mock app: protocol, tools, get_meeting byte for byte the History export (English and Chinese), data files'
# SHA-256 unchanged, no network socket. See scripts/mcp-check.sh.
mcp-check: build
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/mcp-check.sh "$$APP_DIR"

# Real agents (Codex CLI; Claude Code when it isn't over its limit) answer ten questions about a month of fixture data
# through yap-mcp, with the agent-access switches on, half on and off. Needs the network and a signed-in CLI; skips a
# CLI that's missing. LABEL names the results folder, /tmp/yap-mcp-eval/<LABEL>. See scripts/mcp-agent-eval.sh.
mcp-agent-eval: build
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/mcp-agent-eval.sh "$$APP_DIR" "$(or $(LABEL),run)"

# How long yap-mcp's tools take on two years of heavy use (20,000 dictations, 200 hour-long meetings): each tool cold
# (a new helper process) and warm, p50 and p95, with the copy / open / read split. The data stays in
# /tmp/yap-mcp-perf/data between runs (FRESH=1 writes it again). See scripts/mcp-perf.sh.
mcp-perf: build
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/mcp-perf.sh "$$APP_DIR"

# A new user's first local dictation: fresh mock install, download the default model, preflight mid-download, cold and
# warm dictation times (scripts/first-run-check.sh). Needs the network; never touches the dev or release app's data.
first-run-check: build
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/first-run-check.sh "$$APP_DIR" $(MODEL)

# Release-to-paste time per step (stop → transcribed → filters → ⌘V) with local Whisper MODEL warm, no AI cleanup,
# ROUNDS rounds (default 12) of five Chinese and English clips; paste is a dry run, nothing is typed anywhere.
# p50/p95 per step. LANGUAGE=zh (or en, …) fixes the mode's language instead of auto; CLIPS=all dictates eighteen
# Chinese, English and code-switched clips and scores each kind's accuracy. See scripts/dictation-latency.sh and
# docs/dictation-latency.md.
dictation-latency: build
	@test -n "$(MODEL)" || { echo "usage: make dictation-latency MODEL=/path/to/ggml-large-v3-turbo-q5_0.bin [ROUNDS=12] [LANGUAGE=auto] [CLIPS=latency|all]"; exit 2; }
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/dictation-latency.sh "$$APP_DIR" "$(MODEL)" "$(or $(ROUNDS),12)" \
		"$(or $(LANGUAGE),auto)" "$(or $(CLIPS),latency)"

# Meeting recording from two local files, end to end (chunking, transcription with MODEL, notes with NOTES=1,
# History entry), without microphone or system audio permission. See scripts/meeting-files-check.sh.
meeting-files-check: build
	@test -n "$(MODEL)" || { echo "usage: make meeting-files-check MODEL=/path/to/ggml-large-v3-turbo-q5_0.bin [NOTES=1]"; exit 2; }
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/meeting-files-check.sh "$$APP_DIR" "$(MODEL)" $(NOTES)

# A meeting without headphones: the other side's voice reaches the microphone through the speakers (30 ms / 12 dB and
# 80 ms / 20 dB). Checks that echo is taken out of "Me" and nothing the user said is. See scripts/meeting-echo-check.sh.
meeting-echo-check: build
	@test -n "$(MODEL)" || { echo "usage: make meeting-echo-check MODEL=/path/to/ggml-large-v3-turbo-q5_0.bin"; exit 2; }
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/meeting-echo-check.sh "$$APP_DIR" "$(MODEL)"

# An 11-minute meeting with three remote voices: how long transcribing and telling speakers apart take at the end,
# with the speaker models downloaded (cold) and cached (warm). See scripts/meeting-long-check.sh.
meeting-long-check: build
	@test -n "$(MODEL)" || { echo "usage: make meeting-long-check MODEL=/path/to/ggml-*.bin"; exit 2; }
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/meeting-long-check.sh "$$APP_DIR" "$(MODEL)"

# Which processes use the microphone right now and what call detection makes of each (a call app, a browser, Yap
# itself, nothing), after the detector's self-check. Reads Core Audio only and exits before touching any settings.
# Run it during a real Zoom / FaceTime / browser call to check the detection by hand (docs/meeting-recording.md).
meeting-call-check: build
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh "$$APP_DIR/VoiceInk Dev.app/Contents/MacOS/VoiceInk Dev" --meeting-call-check

# Auto Learn's correction rate on fixed paste fixtures (unchanged, one word in English and Chinese, rewritten, deleted,
# field emptied, text typed around the paste…): one JSON line per fixture with what the dictation's SessionMetric would
# get, then the self-checks of the measure, the metric update and Recently Learned. Reads no app; exits before any
# settings are touched (docs/auto-learn.md).
edit-rate-check: build
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh "$$APP_DIR/VoiceInk Dev.app/Contents/MacOS/VoiceInk Dev" --edit-rate-check

# Home's stop-to-paste median and unchanged-after-paste share on fixed weeks of SessionMetrics (with data, only older
# dictations, too few, Auto Learn off, few watched, nothing last week): each written to an in-memory store, read back
# through WeekStatsLoader and checked, one JSON line per week; then the aggregation and late-edit-refresh self-checks.
# Reads no app; exits before any settings are touched (docs/dictation-latency.md, "On Home").
home-feedback-check: build
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh "$$APP_DIR/VoiceInk Dev.app/Contents/MacOS/VoiceInk Dev" --home-feedback-check

# Render every page, Settings group, onboarding screen and sheet in light and dark, plus the main ones in Chinese
# (-zh, and -zht for Traditional), German (-de) and French (-fr), with fake data to /tmp/yap-ui/snapshots. A copy of the Debug build re-identified as me.sma1lboy.yap.snapshots
# (scripts/ui-snapshots.sh), so its fake modes and providers go to a throwaway defaults domain, never the dev app's;
# dev-defaults-guard.sh fails the run if the dev app's settings changed anyway. No window, no focus change; the
# sandbox profile denies network access.
ui-snapshots: build
	@APP_DIR=$$(xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	scripts/dev-defaults-guard.sh scripts/ui-snapshots.sh "$$APP_DIR"

# Self-contained review page(s) of the snapshots: /tmp/yap-ui/review.html (review-N.html past 3.8 MB each).
ui-review: ui-snapshots
	@python3 scripts/ui-review.py

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
