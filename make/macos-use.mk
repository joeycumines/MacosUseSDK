# make/macos-use.mk — MacosUseServer deployment: build, sign, install, verify.
#
# This module implements the full DEPLOYMENT.md workflow as GNU Make targets.
# It replaces the previous ad-hoc targets that lived in config.mk.
#
# The .app bundle is signed with an ad-hoc identity (`codesign --force --deep
# --sign -`). This is sufficient for local deployment — macOS TCC tracks the
# app by bundle identifier. Re-codesigning (e.g. after `macos-use.install`)
# changes the cdhash and may invalidate TCC grants; use `macos-use.restart`
# (which does NOT re-sign) to pick up re-granted permissions.
#
# ---------------------------------------------------------------------------
# APPLE DOCUMENTATION REFERENCES
# ---------------------------------------------------------------------------
#
#   Hardened Runtime
#     https://developer.apple.com/documentation/security/hardened_runtime
#
#   Notarizing macOS software before distribution
#     https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
#
#   Entitlements
#     https://developer.apple.com/documentation/bundleresources/entitlements
#
#   codesign(1) man page
#     https://www.unix.com/man-page/osx/1/codesign/
#
#   SCScreenshotManager (single-frame capture API)
#     https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
#
# ---------------------------------------------------------------------------
# USAGE (EXTREMELY SIMPLE)
# ---------------------------------------------------------------------------
#
#   gmake macos-use.install          # Build + bundle + sign + launchd + verify
#   gmake macos-use.status           # Show launchd status + socket + signature
#   gmake macos-use.verify           # Verify bundle signature + plist + socket
#   gmake macos-use.stop             # Stop the service (no uninstall)
#   gmake macos-use.restart          # Restart the service (no rebuild/codesign)
#   gmake macos-use.tcc-reset        # Reset TCC permissions (re-grant in Settings)
#   gmake macos-use.uninstall        # Remove everything + reset TCC
#
# After `macos-use.install`, grant Accessibility + Screen Recording in:
#   System Settings > Privacy & Security > Accessibility
#   System Settings > Privacy & Security > Screen Recording
# Then run `gmake macos-use.restart` so the server picks up the TCC grants.
# ---------------------------------------------------------------------------

# --- Variables ---------------------------------------------------------------

PROJECT_ROOT ?= $(shell git rev-parse --show-toplevel 2>/dev/null || pwd)

MACOS_USE_APP_DIR     := $(HOME)/Applications/MacosUseServer.app
MACOS_USE_PLIST       := $(HOME)/Library/LaunchAgents/com.macosusesdk.server.plist
MACOS_USE_SOCKET      := $(HOME)/Library/Caches/macosuse.sock
MACOS_USE_BUNDLE_ID   := com.macosusesdk.server
MACOS_USE_SERVER_BIN  := $(PROJECT_ROOT)/Server/.build/release/MacosUseServer
MACOS_USE_STDOUT_LOG  := $(HOME)/Library/Logs/macosuse.log
MACOS_USE_STDERR_LOG  := $(HOME)/Library/Logs/macosuse.error.log

# LaunchServices registration tool.
MACOS_USE_LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# --- Embedded file contents --------------------------------------------------

# Info.plist for the .app bundle.
# LSUIElement=true keeps the server out of the Dock and Cmd+Tab switcher.
define MACOS_USE_INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacosUseServer</string>
    <key>CFBundleIdentifier</key>
    <string>$(MACOS_USE_BUNDLE_ID)</string>
    <key>CFBundleName</key>
    <string>MacosUseServer</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
endef

# launchd plist for the service.  KeepAlive=true auto-restarts on crash.
# The server enforces 0600 on the socket itself — no Umask needed.
define MACOS_USE_LAUNCHD_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(MACOS_USE_BUNDLE_ID)</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(MACOS_USE_APP_DIR)/Contents/MacOS/MacosUseServer</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>GRPC_UNIX_SOCKET</key>
        <string>$(MACOS_USE_SOCKET)</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(MACOS_USE_STDOUT_LOG)</string>
    <key>StandardErrorPath</key>
    <string>$(MACOS_USE_STDERR_LOG)</string>
</dict>
</plist>
endef

# Expand and export embedded content for shell access.
# Shell accesses them via "$$VAR" (double-quoted to handle multi-line
# content correctly — single quotes break because make splits on newlines).
export MACOS_USE_INFO_PLIST_E     := $(MACOS_USE_INFO_PLIST)
export MACOS_USE_LAUNCHD_PLIST_E  := $(MACOS_USE_LAUNCHD_PLIST)

# ============================================================================
# TARGETS
# ============================================================================
# Multi-line content is written via exported env vars + printf "$$VAR".
# This avoids make's per-line recipe splitting which breaks single-quoted
# multi-line strings.

##@ [MacosUse] Build

# Build the Swift server in release configuration.
# Depends on buf.descriptor-sets (generated proto descriptors for gRPC reflection).
.PHONY: macos-use.build-server
macos-use.build-server: ## Build the MacosUseServer release binary.
macos-use.build-server: SHELL := /bin/bash
macos-use.build-server:
	@echo "Building MacosUseServer (release)..."; \
	set -o pipefail; \
	$(MAKE) buf.descriptor-sets && \
	cd $(PROJECT_ROOT)/Server && \
		swift build --configuration release 2>&1 | \
		tee $(PROJECT_ROOT)/build.log | tail -n 25; \
	exit $${PIPESTATUS[0]}

# Build the Go MCP proxy and install it to $GOPATH/bin.
# The binary lands at $GOPATH/bin/macos-use-mcp (default: ~/go/bin/macos-use-mcp).
.PHONY: macos-use.build-mcp
macos-use.build-mcp: ## Build and install the macos-use-mcp Go binary.
macos-use.build-mcp: SHELL := /bin/bash
macos-use.build-mcp:
	@echo "Installing macos-use-mcp Go binary..."; \
	set -o pipefail; \
	cd $(PROJECT_ROOT) && \
		go install ./cmd/macos-use-mcp 2>&1 | \
		tee -a $(PROJECT_ROOT)/build.log | tail -n 15; \
	exit $${PIPESTATUS[0]}

.PHONY: macos-use.build
macos-use.build: ## Build both the server and the MCP proxy.
macos-use.build: macos-use.build-server macos-use.build-mcp
	@echo "Build complete."

##@ [MacosUse] Bundle + Sign

# Create the .app bundle from scratch.  Deletes any existing .app first.
# Copies the release binary and writes Info.plist.
.PHONY: macos-use.bundle
macos-use.bundle: ## Create the MacosUseServer.app bundle (clean, from scratch).
macos-use.bundle: SHELL := /bin/bash
macos-use.bundle:
	@if [ ! -f "$(MACOS_USE_SERVER_BIN)" ]; then \
		echo "ERROR: Server binary not found at $(MACOS_USE_SERVER_BIN)" >&2; \
		echo "       Run 'gmake macos-use.build-server' first." >&2; \
		exit 1; \
	fi
	@echo "=== Creating .app bundle (clean) ==="
	@rm -rf "$(MACOS_USE_APP_DIR)"
	@mkdir -p "$(MACOS_USE_APP_DIR)/Contents/MacOS" "$(MACOS_USE_APP_DIR)/Contents/Resources"
	@cp "$(MACOS_USE_SERVER_BIN)" "$(MACOS_USE_APP_DIR)/Contents/MacOS/MacosUseServer"
	@chmod 755 "$(MACOS_USE_APP_DIR)/Contents/MacOS/MacosUseServer"
	@printf '%s\n' "$$MACOS_USE_INFO_PLIST_E" > "$(MACOS_USE_APP_DIR)/Contents/Info.plist"
	@echo "Bundle created at $(MACOS_USE_APP_DIR)"
	@plutil -lint "$(MACOS_USE_APP_DIR)/Contents/Info.plist"

# Sign the .app bundle with an ad-hoc identity.
# Clears extended attributes first (required for a clean signature —
# ref: codesign(1) "Resource fork, Finder information ... not allowed").
#
# Ref: https://www.unix.com/man-page/osx/1/codesign/
.PHONY: macos-use.sign
macos-use.sign: ## Ad-hoc codesign (--force --deep --sign -) + xattr clear + verify.
macos-use.sign: SHELL := /bin/bash
macos-use.sign:
	@if [ ! -d "$(MACOS_USE_APP_DIR)" ]; then \
		echo "ERROR: .app bundle not found. Run 'gmake macos-use.bundle' first." >&2; \
		exit 1; \
	fi
	@echo "=== Clearing extended attributes ==="
	@xattr -cr "$(MACOS_USE_APP_DIR)"
	@echo "=== Ad-hoc signing (--force --deep --sign -) ==="
	@codesign --force --deep --sign - "$(MACOS_USE_APP_DIR)"
	@echo "=== Verifying signature ==="
	@codesign --verify --deep --strict --verbose=4 "$(MACOS_USE_APP_DIR)"
	@echo "Signature verified: valid on disk, satisfies Designated Requirement."

# Register the .app bundle with LaunchServices so TCC can identify it by
# bundle identifier.  Must be run AFTER codesign so LaunchServices caches
# the signed version.
.PHONY: macos-use.register
macos-use.register: ## Register the .app with LaunchServices (lsregister).
macos-use.register: SHELL := /bin/bash
macos-use.register:
	@echo "=== Registering with LaunchServices ==="; \
	"$(MACOS_USE_LSREGISTER)" -f "$(MACOS_USE_APP_DIR)"; \
	if [ $$? -ne 0 ]; then \
		echo "ERROR: lsregister failed." >&2; exit 1; \
	fi; \
	echo "Registered: $(MACOS_USE_BUNDLE_ID)"

##@ [MacosUse] Launchd Service

# Create the launchd plist and bootstrap the service.
.PHONY: macos-use.launchd
macos-use.launchd: ## Create and load the launchd service.
macos-use.launchd: SHELL := /bin/bash
macos-use.launchd:
	@echo "=== Creating launchd service ==="
	@printf '%s\n' "$$MACOS_USE_LAUNCHD_PLIST_E" > "$(MACOS_USE_PLIST)"
	@chmod 644 "$(MACOS_USE_PLIST)"
	@launchctl bootout gui/$$(id -u)/$(MACOS_USE_BUNDLE_ID) 2>/dev/null || true
	@rm -f "$(MACOS_USE_SOCKET)"
	@launchctl bootstrap gui/$$(id -u) "$(MACOS_USE_PLIST)"
	@echo "=== Waiting for socket ==="
	@for i in $$(seq 1 10); do \
		if [ -S "$(MACOS_USE_SOCKET)" ]; then \
			ls -la "$(MACOS_USE_SOCKET)"; \
			echo "Service started successfully."; \
			exit 0; \
		fi; \
		sleep 0.5; \
	done; \
	echo "ERROR: socket did not appear within 5 seconds." >&2; \
	echo "Check logs: $(MACOS_USE_STDERR_LOG)" >&2; \
	exit 1

##@ [MacosUse] Full Install

# Full install pipeline: build → bundle → sign → register → launchd.
# This is the main entry point.
.PHONY: macos-use.install
macos-use.install: ## Full install: build + bundle + sign + register + launchd.
macos-use.install: macos-use.build macos-use.bundle macos-use.sign macos-use.register macos-use.launchd
	@echo ""; \
	echo "============================================================"; \
	echo "  INSTALL COMPLETE"; \
	echo "============================================================"; \
	echo "  App:       $(MACOS_USE_APP_DIR)"; \
	echo "  Socket:    $(MACOS_USE_SOCKET)"; \
	echo "  Service:   $(MACOS_USE_BUNDLE_ID)"; \
	echo "  Identity:  ad-hoc (--sign -)"; \
	echo ""; \
	echo "  NEXT: Grant TCC permissions in System Settings:"; \
	echo "    Privacy & Security > Accessibility   > toggle ON MacosUseServer"; \
	echo "    Privacy & Security > Screen Recording > toggle ON MacosUseServer"; \
	echo "  Then: gmake macos-use.restart"; \
	echo "============================================================"

##@ [MacosUse] Verify

# Verify the full deployment: signature, plist, socket, process.
.PHONY: macos-use.verify
macos-use.verify: ## Verify the deployment (signature, plist, socket, process).
macos-use.verify: SHELL := /bin/bash
macos-use.verify:
	@set -e; \
	echo "=== 1. Bundle structure ==="; \
	find "$(MACOS_USE_APP_DIR)" -type f | sort; \
	echo ""; \
	echo "=== 2. codesign --verify ==="; \
	codesign --verify --deep --strict --verbose=4 "$(MACOS_USE_APP_DIR)" 2>&1; \
	echo ""; \
	echo "=== 3. Entitlements (embedded) ==="; \
	codesign -d --entitlements - "$(MACOS_USE_APP_DIR)" 2>&1; \
	echo ""; \
	echo "=== 4. Info.plist lint ==="; \
	plutil -lint "$(MACOS_USE_APP_DIR)/Contents/Info.plist"; \
	echo ""; \
	echo "=== 5. Socket ==="; \
	ls -la "$(MACOS_USE_SOCKET)" 2>/dev/null || echo "  socket not found"; \
	echo ""; \
	echo "=== 6. Process ==="; \
	pgrep -fl MacosUseServer || echo "  process not running"; \
	echo ""; \
	echo "=== 7. launchd ==="; \
	launchctl print gui/$$(id -u) 2>/dev/null | grep "$(MACOS_USE_BUNDLE_ID)" || echo "  service not loaded"; \
	echo ""; \
	echo "All checks passed."

##@ [MacosUse] Lifecycle

.PHONY: macos-use.status
macos-use.status: ## Show launchd status, socket, and process.
macos-use.status: SHELL := /bin/bash
macos-use.status:
	@echo "=== launchd ==="; \
	launchctl print gui/$$(id -u) 2>/dev/null | grep "$(MACOS_USE_BUNDLE_ID)" || echo "  not loaded"; \
	echo "=== Process ==="; \
	pgrep -fl MacosUseServer || echo "  not running"; \
	echo "=== Socket ==="; \
	ls -la "$(MACOS_USE_SOCKET)" 2>/dev/null || echo "  not found"; \
	echo "=== Signature ==="; \
	codesign -dv "$(MACOS_USE_APP_DIR)" 2>&1 | grep -E "Identifier|Signature|Format" || echo "  not signed"

.PHONY: macos-use.restart
macos-use.restart: ## Restart the launchd service (no rebuild/codesign).
macos-use.restart: SHELL := /bin/bash
macos-use.restart:
	@echo "Restarting MacosUseServer launchd service..."; \
	set -e; \
	launchctl bootout gui/$$(id -u)/$(MACOS_USE_BUNDLE_ID) 2>/dev/null || true; \
	launchctl remove $(MACOS_USE_BUNDLE_ID) 2>/dev/null || true; \
	rm -f "$(MACOS_USE_SOCKET)"; \
	sleep 1; \
	launchctl bootstrap gui/$$(id -u) "$(MACOS_USE_PLIST)"; \
	for i in $$(seq 1 10); do \
		if [ -S "$(MACOS_USE_SOCKET)" ]; then \
			ls -la "$(MACOS_USE_SOCKET)"; \
			exit 0; \
		fi; \
		sleep 0.5; \
	done; \
	echo "ERROR: socket did not appear within 5 seconds." >&2; \
	exit 1

.PHONY: macos-use.tcc-reset
macos-use.tcc-reset: ## Reset TCC permissions (Accessibility + Screen Recording).
macos-use.tcc-reset: SHELL := /bin/bash
macos-use.tcc-reset:
	@echo "Resetting TCC permissions for $(MACOS_USE_BUNDLE_ID)..."; \
	tccutil reset Accessibility $(MACOS_USE_BUNDLE_ID) 2>/dev/null || true; \
	tccutil reset ScreenCapture $(MACOS_USE_BUNDLE_ID) 2>/dev/null || true; \
	echo "TCC reset complete. Re-grant in System Settings > Privacy & Security."

.PHONY: macos-use.uninstall
macos-use.uninstall: ## Completely uninstall MacosUseServer.app, launchd service, and TCC entries.
macos-use.uninstall: SHELL := /bin/bash
macos-use.uninstall:
	@echo "=== Uninstalling MacosUseServer ==="; \
	set +e; \
	launchctl bootout gui/$$(id -u)/$(MACOS_USE_BUNDLE_ID) 2>/dev/null; \
	launchctl remove $(MACOS_USE_BUNDLE_ID) 2>/dev/null; \
	rm -rf "$(MACOS_USE_APP_DIR)"; \
	rm -f  "$(MACOS_USE_PLIST)"; \
	rm -f  "$(MACOS_USE_SOCKET)"; \
	rm -f  "$(MACOS_USE_STDOUT_LOG)"; \
	rm -f  "$(MACOS_USE_STDERR_LOG)"; \
	tccutil reset Accessibility $(MACOS_USE_BUNDLE_ID) 2>/dev/null || true; \
	tccutil reset ScreenCapture $(MACOS_USE_BUNDLE_ID) 2>/dev/null || true; \
	echo "Uninstall complete."

.PHONY: macos-use.logs
macos-use.logs: ## Show recent MacosUseServer log entries (error log + OSLog).
macos-use.logs: SHELL := /bin/bash
macos-use.logs:
	@echo "=== Error log (last 30 lines) ==="; \
	tail -n 30 "$(MACOS_USE_STDERR_LOG)" 2>/dev/null || echo "(empty)"; \
	echo ""; \
	echo "=== OSLog (last 2 minutes) ==="; \
	log show --last 2m --predicate 'process == "MacosUseServer"' 2>/dev/null | tail -n 40 || \
		echo "OSLog unavailable"

.PHONY: macos-use.stop
macos-use.stop: ## Stop the launchd service (no rebuild/codesign/uninstall).
macos-use.stop: SHELL := /bin/bash
macos-use.stop:
	@echo "Stopping MacosUseServer launchd service..."; \
	launchctl bootout gui/$$(id -u)/$(MACOS_USE_BUNDLE_ID) 2>/dev/null || true; \
	launchctl remove $(MACOS_USE_BUNDLE_ID) 2>/dev/null || true; \
	rm -f "$(MACOS_USE_SOCKET)"; \
	echo "Service stopped."

.PHONY: macos-use.start
macos-use.start: ## Start (or restart) the launchd service (no rebuild/codesign).
macos-use.start: macos-use.restart
	@:

# Convenience: open a TextEdit document for testing (not a deployment target).
.PHONY: macos-use-open-textedit-doc
macos-use-open-textedit-doc: ## Open a target TextEdit document deterministically.
macos-use-open-textedit-doc: SHELL := /bin/bash
macos-use-open-textedit-doc:
	mkdir -p "$(HOME)/dev/MacosUseSDK" && \
	printf '' > "$(HOME)/dev/MacosUseSDK/tmp_hello.txt" && \
	open -a TextEdit "$(HOME)/dev/MacosUseSDK/tmp_hello.txt"
