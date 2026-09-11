# make/macos-use.mk — local MacosUseServer deployment for macOS.
#
# This GNU Make module builds the Swift gRPC server and Go MCP proxy, packages
# the server as a real .app (including SwiftPM resource bundles), signs it,
# registers it with LaunchServices, and runs it as a per-user LaunchAgent.
#
# The default signing identity is ad hoc (`-`) for zero-configuration local
# development.  TCC permissions are more stable when the app is signed with a
# persistent Apple Development identity:
#
#   gmake macos-use.install \
#     MACOS_USE_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)'
#
# Low-level phase targets are intentionally independent.  For example,
# `macos-use.register` registers the existing app and does not rebuild or
# re-sign it.  `macos-use.install` is the ordered orchestration target.

# Capture this file while it is the last parsed makefile.  Unlike `pwd` or
# `git rev-parse`, this remains correct when make is invoked from a subdirectory
# or the source tree is not a Git worktree.
MACOS_USE_MAKEFILE := $(lastword $(MAKEFILE_LIST))
PROJECT_ROOT ?= $(abspath $(dir $(MACOS_USE_MAKEFILE))/..)

# --- Product and installation paths -----------------------------------------

MACOS_USE_APP_NAME       ?= MacosUseServer
MACOS_USE_BUNDLE_ID      ?= com.macosusesdk.server
MACOS_USE_VERSION        ?= 1.0.0
MACOS_USE_BUILD_VERSION  ?= 1
MACOS_USE_MIN_MACOS      ?= 15.0

MACOS_USE_APP_DIR        ?= $(HOME)/Applications/$(MACOS_USE_APP_NAME).app
MACOS_USE_APP_EXECUTABLE := $(MACOS_USE_APP_DIR)/Contents/MacOS/$(MACOS_USE_APP_NAME)
MACOS_USE_STAGING_DIR    := $(MACOS_USE_APP_DIR).staging

MACOS_USE_SERVER_BUILD_DIR        ?= $(PROJECT_ROOT)/Server/.build/release
MACOS_USE_SERVER_BIN              ?= $(MACOS_USE_SERVER_BUILD_DIR)/$(MACOS_USE_APP_NAME)
MACOS_USE_RESOURCE_BUNDLE_NAME    ?= MacosUseServer_MacosUseServer.bundle
MACOS_USE_REQUIRED_RESOURCE_BUNDLE := $(MACOS_USE_SERVER_BUILD_DIR)/$(MACOS_USE_RESOURCE_BUNDLE_NAME)

MACOS_USE_PLIST          ?= $(HOME)/Library/LaunchAgents/$(MACOS_USE_BUNDLE_ID).plist
MACOS_USE_SOCKET         ?= $(HOME)/Library/Caches/macosuse.sock
MACOS_USE_STDOUT_LOG     ?= $(HOME)/Library/Logs/macosuse.log
MACOS_USE_STDERR_LOG     ?= $(HOME)/Library/Logs/macosuse.error.log

MACOS_USE_BUILD_LOG_DIR  ?= $(PROJECT_ROOT)/.build-logs
MACOS_USE_SERVER_BUILD_LOG ?= $(MACOS_USE_BUILD_LOG_DIR)/macos-use-server.log
MACOS_USE_MCP_BUILD_LOG    ?= $(MACOS_USE_BUILD_LOG_DIR)/macos-use-mcp.log

MACOS_USE_SIGN_IDENTITY  ?= -
MACOS_USE_WAIT_ATTEMPTS  ?= 10
MACOS_USE_WAIT_INTERVAL  ?= 1

MACOS_USE_UID            := $(shell id -u)
MACOS_USE_LAUNCH_DOMAIN  := gui/$(MACOS_USE_UID)
MACOS_USE_SERVICE_TARGET := $(MACOS_USE_LAUNCH_DOMAIN)/$(MACOS_USE_BUNDLE_ID)

# Go installs commands into GOBIN, or the first GOPATH/bin when GOBIN is empty.
# Resolve that once so build, documentation output, verification, and uninstall
# all refer to the same binary.  The fallback is Go's default GOPATH location.
MACOS_USE_GO_BIN_DIR ?= $(strip $(shell \
	gobin="$$(go env GOBIN 2>/dev/null)"; \
	if [ -z "$$gobin" ]; then \
		gopath="$$(go env GOPATH 2>/dev/null)"; \
		gobin="$${gopath%%:*}/bin"; \
	fi; \
	if [ -n "$$gobin" ]; then printf '%s' "$$gobin"; else printf '%s' "$(HOME)/go/bin"; fi))
MACOS_USE_MCP_BIN ?= $(MACOS_USE_GO_BIN_DIR)/macos-use-mcp
MACOS_USE_MCP_BIN_DIR := $(patsubst %/,%,$(dir $(MACOS_USE_MCP_BIN)))

# LaunchServices registration tool supplied by macOS.
MACOS_USE_LSREGISTER ?= /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# --- Embedded plist contents ------------------------------------------------

# LSUIElement keeps this background server out of the Dock and app switcher.
define MACOS_USE_INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$(MACOS_USE_APP_NAME)</string>
    <key>CFBundleExecutable</key>
    <string>$(MACOS_USE_APP_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(MACOS_USE_BUNDLE_ID)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(MACOS_USE_APP_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MACOS_USE_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(MACOS_USE_BUILD_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOS_USE_MIN_MACOS)</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
endef

# This is a LaunchAgent, not a LaunchDaemon: ScreenCaptureKit, AppKit, and
# Accessibility must run in the logged-in user's GUI domain.  KeepAlive=true
# also implies RunAtLoad. The 0177 umask is defense in depth; launchd creates
# the Unix socket with owner-only mode before activating it. The Swift server
# receives that exact descriptor through launch_activate_socket and never binds
# the pathname itself. ThrottleInterval bounds KeepAlive restarts so a repeated
# fatal error cannot spin a tight crash loop; unmanaged paths are never mutated.
define MACOS_USE_LAUNCHD_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(MACOS_USE_BUNDLE_ID)</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(MACOS_USE_APP_EXECUTABLE)</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>GRPC_UNIX_SOCKET</key>
        <string>$(MACOS_USE_SOCKET)</string>
    </dict>
    <key>Sockets</key>
    <dict>
        <key>Listener</key>
        <dict>
            <key>SockFamily</key>
            <string>Unix</string>
            <key>SockType</key>
            <string>Stream</string>
            <key>SockPathName</key>
            <string>$(MACOS_USE_SOCKET)</string>
            <key>SockPathMode</key>
            <integer>384</integer>
        </dict>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>Umask</key>
    <integer>127</integer>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$(MACOS_USE_BUNDLE_ID)</string>
    </array>
    <key>StandardOutPath</key>
    <string>$(MACOS_USE_STDOUT_LOG)</string>
    <key>StandardErrorPath</key>
    <string>$(MACOS_USE_STDERR_LOG)</string>
</dict>
</plist>
endef

# Export multiline values for a single shell invocation.  Quoting the expanded
# environment variable preserves all newlines and XML punctuation.
# Reject values that would be unsafe when interpolated into generated XML or
# make recipes. This is a make-time check: hostile backticks, `$()` text, shell
# separators, and XML delimiters are rejected before any recipe is expanded.
MACOS_USE_BACKTICK := `
define MACOS_USE_VALIDATE_VALUE
$(if $(findstring <,$(1)),$(error $(2) contains '<'; refusing unsafe deployment value))
$(if $(findstring >,$(1)),$(error $(2) contains '>'; refusing unsafe deployment value))
$(if $(findstring &,$(1)),$(error $(2) contains '&'; refusing unsafe deployment value))
$(if $(findstring ",$(1)),$(error $(2) contains a quote; refusing unsafe deployment value))
$(if $(findstring $(MACOS_USE_BACKTICK),$(1)),$(error $(2) contains a backtick; refusing unsafe deployment value))
$(if $(findstring ;,$(1)),$(error $(2) contains ';'; refusing unsafe deployment value))
$(if $(findstring |,$(1)),$(error $(2) contains '|'; refusing unsafe deployment value))
$(if $(findstring $$,$(1)),$(error $(2) contains '$$'; refusing unsafe deployment value))
endef
define MACOS_USE_VALIDATE_CONFIG
$(if $(filter command line environment environment-overrides,$(origin $(1))),$(call MACOS_USE_VALIDATE_VALUE,$(value $(1)),$(1)),$(call MACOS_USE_VALIDATE_VALUE,$($(1)),$(1)))
endef
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_APP_NAME))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_BUNDLE_ID))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_VERSION))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_BUILD_VERSION))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_MIN_MACOS))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_APP_DIR))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_APP_EXECUTABLE))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_PLIST))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_SOCKET))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_STDOUT_LOG))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_STDERR_LOG))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_SERVER_BUILD_DIR))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_SERVER_BIN))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_RESOURCE_BUNDLE_NAME))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_BUILD_LOG_DIR))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_SERVER_BUILD_LOG))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_MCP_BUILD_LOG))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_MCP_BIN))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_GO_BIN_DIR))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_LSREGISTER))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_SIGN_IDENTITY))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_WAIT_ATTEMPTS))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,MACOS_USE_WAIT_INTERVAL))
$(eval $(call MACOS_USE_VALIDATE_CONFIG,PROJECT_ROOT))

# Derived values are expanded from validated inputs; validate their expanded
# result as well for defense in depth.
$(eval $(call MACOS_USE_VALIDATE_VALUE,$(MACOS_USE_APP_EXECUTABLE),MACOS_USE_APP_EXECUTABLE))
$(eval $(call MACOS_USE_VALIDATE_VALUE,$(MACOS_USE_PLIST),MACOS_USE_PLIST))
$(eval $(call MACOS_USE_VALIDATE_VALUE,$(MACOS_USE_STAGING_DIR),MACOS_USE_STAGING_DIR))
$(eval $(call MACOS_USE_VALIDATE_VALUE,$(MACOS_USE_REQUIRED_RESOURCE_BUNDLE),MACOS_USE_REQUIRED_RESOURCE_BUNDLE))
$(eval $(call MACOS_USE_VALIDATE_VALUE,$(MACOS_USE_MCP_BIN_DIR),MACOS_USE_MCP_BIN_DIR))
$(eval $(call MACOS_USE_VALIDATE_VALUE,$(MACOS_USE_SERVICE_TARGET),MACOS_USE_SERVICE_TARGET))

export MACOS_USE_INFO_PLIST_E := $(MACOS_USE_INFO_PLIST)
export MACOS_USE_LAUNCHD_PLIST_E := $(MACOS_USE_LAUNCHD_PLIST)
# Export user-configurable XML inputs as data; recipes read these through shell
# variables after the make-time safety gate above.
export MACOS_USE_APP_NAME MACOS_USE_BUNDLE_ID MACOS_USE_VERSION MACOS_USE_BUILD_VERSION
export MACOS_USE_MIN_MACOS MACOS_USE_APP_EXECUTABLE MACOS_USE_SOCKET
export MACOS_USE_STDOUT_LOG MACOS_USE_STDERR_LOG

# Only the two piped build recipes need Bash's pipefail.  `private` prevents
# SHELL from leaking into their prerequisite targets.
macos-use.build-server macos-use.build-mcp: private SHELL := /bin/bash

# =============================================================================
# Build
# =============================================================================

##@ [MacosUse] Build

.PHONY: macos-use.doctor
macos-use.doctor: ## Check the local deployment toolchain and source layout.
	@failed=0; \
	pass() { printf '  PASS  %s\n' "$$1"; }; \
	fail() { printf '  FAIL  %s\n' "$$1" >&2; failed=1; }; \
	printf '%s\n' '=== MacosUse deployment doctor ==='; \
	if [ "$$(uname -s)" = Darwin ]; then pass 'host operating system is macOS'; else fail 'host operating system is not macOS'; fi; \
	make_major='$(word 1,$(subst ., ,$(MAKE_VERSION)))'; \
	if [ "$$make_major" -ge 4 ] 2>/dev/null; then pass "GNU Make $(MAKE_VERSION)"; else fail "GNU Make 4+ required (found $(MAKE_VERSION))"; fi; \
	for command_name in swift go buf codesign plutil launchctl xattr ditto tccutil; do \
		if command -v "$$command_name" >/dev/null 2>&1; then pass "command available: $$command_name"; else fail "missing command: $$command_name"; fi; \
	done; \
	if [ -x "$(MACOS_USE_LSREGISTER)" ]; then pass 'LaunchServices registration tool is available'; else fail "missing lsregister: $(MACOS_USE_LSREGISTER)"; fi; \
	if [ -f "$(PROJECT_ROOT)/Server/Package.swift" ]; then pass 'Server/Package.swift exists'; else fail 'Server/Package.swift is missing'; fi; \
	if [ -f "$(PROJECT_ROOT)/go.mod" ]; then pass 'go.mod exists'; else fail 'go.mod is missing'; fi; \
	if command -v sw_vers >/dev/null 2>&1; then \
		macos_version=$$(sw_vers -productVersion); macos_major=$${macos_version%%.*}; \
		if [ "$$macos_major" -ge 15 ] 2>/dev/null; then pass "macOS $$macos_version"; else fail "macOS 15+ required (found $$macos_version)"; fi; \
	fi; \
	if command -v swift >/dev/null 2>&1; then swift --version | sed -n '1p'; fi; \
	if command -v go >/dev/null 2>&1; then \
		go version; \
		if [ -f "$(PROJECT_ROOT)/go.mod" ]; then printf '  module Go directive: '; awk '$$1 == "go" { print $$2; exit }' "$(PROJECT_ROOT)/go.mod"; fi; \
	fi; \
	if [ "$$failed" -ne 0 ]; then printf '%s\n' 'Doctor checks failed.' >&2; exit 1; fi; \
	printf '%s\n' 'Doctor checks passed.'

.PHONY: macos-use.build-server
macos-use.build-server: ## Build the release Swift server and its resource bundle.
	@set -uo pipefail; \
	mkdir -p "$(MACOS_USE_BUILD_LOG_DIR)"; \
	printf '%s\n' '=== Building MacosUseServer (release) ==='; \
	$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory buf.descriptor-sets; \
	cd "$(PROJECT_ROOT)/Server"; \
	swift build --configuration release 2>&1 | tee "$(MACOS_USE_SERVER_BUILD_LOG)" | tail -n 40; \
	test -x "$(MACOS_USE_SERVER_BIN)"; \
	if [ ! -d "$(MACOS_USE_REQUIRED_RESOURCE_BUNDLE)" ]; then \
		printf 'ERROR: SwiftPM resource bundle missing: %s\n' "$(MACOS_USE_REQUIRED_RESOURCE_BUNDLE)" >&2; \
		exit 1; \
	fi; \
	if ! find "$(MACOS_USE_REQUIRED_RESOURCE_BUNDLE)" -type f -name '*.pb' -print -quit | grep -q .; then \
		printf 'ERROR: no protobuf descriptor set (*.pb) was packaged in %s\n' "$(MACOS_USE_REQUIRED_RESOURCE_BUNDLE)" >&2; \
		exit 1; \
	fi; \
	printf 'Server binary: %s\n' "$(MACOS_USE_SERVER_BIN)"; \
	printf 'Resource bundle: %s\n' "$(MACOS_USE_REQUIRED_RESOURCE_BUNDLE)"

.PHONY: macos-use.build-mcp
macos-use.build-mcp: ## Build and install the Go MCP proxy at the resolved Go bin path.
	@set -uo pipefail; \
	mkdir -p "$(MACOS_USE_BUILD_LOG_DIR)" "$(MACOS_USE_MCP_BIN_DIR)"; \\
	printf '%s\n' '=== Building macos-use-mcp ==='; \
	cd "$(PROJECT_ROOT)"; \
	GOBIN="$(MACOS_USE_MCP_BIN_DIR)" go install ./cmd/macos-use-mcp 2>&1 | tee "$(MACOS_USE_MCP_BUILD_LOG)" | tail -n 30; \
	test -x "$(MACOS_USE_MCP_BIN)"; \
	printf 'MCP binary: %s\n' "$(MACOS_USE_MCP_BIN)"

.PHONY: macos-use.build
macos-use.build: ## Build the Swift server, then the Go MCP proxy.
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.build-server
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.build-mcp
	@printf '%s\n' 'Build complete.'

# =============================================================================
# Bundle, sign, and registration
# =============================================================================

##@ [MacosUse] Bundle + Sign

.PHONY: macos-use.bundle
macos-use.bundle: ## Create a clean .app and include all SwiftPM resource bundles.
	@set -u; \
	validate_xml_value() { value="$$1"; name="$$2"; case "$$value" in *'<'*|*'>'*|*'&'*|*'"'*) printf 'ERROR: %s contains XML-significant characters.\\n' "$$name" >&2; exit 1;; esac; }; \
	validate_xml_value "$$MACOS_USE_APP_NAME" MACOS_USE_APP_NAME; \
	validate_xml_value "$$MACOS_USE_BUNDLE_ID" MACOS_USE_BUNDLE_ID; \
	validate_xml_value "$$MACOS_USE_VERSION" MACOS_USE_VERSION; \
	validate_xml_value "$$MACOS_USE_BUILD_VERSION" MACOS_USE_BUILD_VERSION; \
	validate_xml_value "$$MACOS_USE_MIN_MACOS" MACOS_USE_MIN_MACOS; \
	validate_xml_value "$$MACOS_USE_APP_EXECUTABLE" MACOS_USE_APP_EXECUTABLE; \
	if launchctl print "$(MACOS_USE_SERVICE_TARGET)" >/dev/null 2>&1; then \
		printf '%s\n' "ERROR: service is loaded; run 'gmake macos-use.stop' before replacing the app." >&2; \
		exit 1; \
	fi; \
	if [ ! -x "$(MACOS_USE_SERVER_BIN)" ]; then \
		printf 'ERROR: server binary not found: %s\n' "$(MACOS_USE_SERVER_BIN)" >&2; \
		printf '%s\n' "Run 'gmake macos-use.build-server' first." >&2; \
		exit 1; \
	fi; \
	if [ ! -d "$(MACOS_USE_REQUIRED_RESOURCE_BUNDLE)" ]; then \
		printf 'ERROR: required SwiftPM resource bundle not found: %s\n' "$(MACOS_USE_REQUIRED_RESOURCE_BUNDLE)" >&2; \
		exit 1; \
	fi; \
	printf '%s\n' '=== Creating staged application bundle ==='; \
	rm -rf "$(MACOS_USE_STAGING_DIR)"; \
	mkdir -p "$(MACOS_USE_STAGING_DIR)/Contents/MacOS" "$(MACOS_USE_STAGING_DIR)/Contents/Resources"; \
	install -m 0755 "$(MACOS_USE_SERVER_BIN)" "$(MACOS_USE_STAGING_DIR)/Contents/MacOS/$(MACOS_USE_APP_NAME)"; \
	printf '%s\n' "$$MACOS_USE_INFO_PLIST_E" > "$(MACOS_USE_STAGING_DIR)/Contents/Info.plist"; \
	resource_count=0; \
	for resource_bundle in "$(MACOS_USE_SERVER_BUILD_DIR)"/*.bundle; do \
		[ -d "$$resource_bundle" ] || continue; \
		resource_name=$$(basename "$$resource_bundle"); \
		ditto "$$resource_bundle" "$(MACOS_USE_STAGING_DIR)/Contents/Resources/$$resource_name"; \
		resource_count=$$((resource_count + 1)); \
	done; \
	if [ "$$resource_count" -eq 0 ]; then \
		printf '%s\n' 'ERROR: no SwiftPM .bundle resources were copied.' >&2; \
		exit 1; \
	fi; \
	plutil -lint "$(MACOS_USE_STAGING_DIR)/Contents/Info.plist"; \
	test -d "$(MACOS_USE_STAGING_DIR)/Contents/Resources/$(MACOS_USE_RESOURCE_BUNDLE_NAME)"; \
	rm -rf "$(MACOS_USE_APP_DIR)"; \
	mkdir -p "$(dir $(MACOS_USE_APP_DIR))"; \
	mv "$(MACOS_USE_STAGING_DIR)" "$(MACOS_USE_APP_DIR)"; \
	printf 'Bundle created: %s (%s SwiftPM resource bundle(s))\n' "$(MACOS_USE_APP_DIR)" "$$resource_count"

.PHONY: macos-use.sign
macos-use.sign: ## Sign the existing .app, then perform strict recursive verification.
	@set -u; \
	if [ ! -x "$(MACOS_USE_APP_EXECUTABLE)" ]; then \
		printf '%s\n' "ERROR: app bundle is missing; run 'gmake macos-use.bundle' first." >&2; \
		exit 1; \
	fi; \
	if launchctl print "$(MACOS_USE_SERVICE_TARGET)" >/dev/null 2>&1; then \
		printf '%s\n' "ERROR: service is loaded; run 'gmake macos-use.stop' before signing." >&2; \
		exit 1; \
	fi; \
	printf '%s\n' '=== Clearing extended attributes from the generated app ==='; \
	chmod -R u+w "$(MACOS_USE_APP_DIR)"; \
	xattr -cr "$(MACOS_USE_APP_DIR)"; \
	printf '=== Signing with identity: %s ===\n' "$(MACOS_USE_SIGN_IDENTITY)"; \
	codesign --force --sign "$(MACOS_USE_SIGN_IDENTITY)" "$(MACOS_USE_APP_DIR)"; \
	printf '%s\n' '=== Verifying signature (deep + strict) ==='; \
	codesign --verify --deep --strict --verbose=4 "$(MACOS_USE_APP_DIR)"; \
	codesign -d --verbose=4 "$(MACOS_USE_APP_DIR)" 2>&1 | grep -E '^(Executable|Identifier|Format|CodeDirectory|Signature|TeamIdentifier)=' || true

.PHONY: macos-use.register
macos-use.register: ## Register the existing signed .app with LaunchServices.
	@set -u; \
	if [ ! -d "$(MACOS_USE_APP_DIR)" ]; then \
		printf '%s\n' "ERROR: app bundle is missing; run bundle and sign first." >&2; \
		exit 1; \
	fi; \
	codesign --verify --deep --strict "$(MACOS_USE_APP_DIR)"; \
	"$(MACOS_USE_LSREGISTER)" -f "$(MACOS_USE_APP_DIR)"; \
	printf 'Registered %s (%s) with LaunchServices.\n' "$(MACOS_USE_APP_DIR)" "$(MACOS_USE_BUNDLE_ID)"

# =============================================================================
# LaunchAgent
# =============================================================================

##@ [MacosUse] LaunchAgent

.PHONY: macos-use.launchd
macos-use.launchd: ## Write, bootstrap, and wait for the per-user LaunchAgent.
	@set -u; \
	validate_xml_value() { value="$$1"; name="$$2"; case "$$value" in *'<'*|*'>'*|*'&'*|*'"'*) printf 'ERROR: %s contains XML-significant characters.\\n' "$$name" >&2; exit 1;; esac; }; \
	validate_xml_value "$$MACOS_USE_BUNDLE_ID" MACOS_USE_BUNDLE_ID; \
	validate_xml_value "$$MACOS_USE_APP_EXECUTABLE" MACOS_USE_APP_EXECUTABLE; \
	validate_xml_value "$$MACOS_USE_SOCKET" MACOS_USE_SOCKET; \
	validate_xml_value "$$MACOS_USE_STDOUT_LOG" MACOS_USE_STDOUT_LOG; \
	validate_xml_value "$$MACOS_USE_STDERR_LOG" MACOS_USE_STDERR_LOG; \
	if [ ! -x "$(MACOS_USE_APP_EXECUTABLE)" ]; then \
		printf '%s\n' 'ERROR: installed app executable is missing.' >&2; \
		exit 1; \
	fi; \
	codesign --verify --deep --strict "$(MACOS_USE_APP_DIR)"; \
	mkdir -p "$(dir $(MACOS_USE_PLIST))" "$(dir $(MACOS_USE_SOCKET))" "$(dir $(MACOS_USE_STDOUT_LOG))" "$(dir $(MACOS_USE_STDERR_LOG))"; \
	plist_tmp=$$(mktemp "$(MACOS_USE_PLIST).tmp.XXXXXX"); \
	cleanup_plist_tmp() { rm -f "$$plist_tmp"; }; \
	trap cleanup_plist_tmp EXIT INT TERM; \
	printf '%s\n' "$$MACOS_USE_LAUNCHD_PLIST_E" > "$$plist_tmp"; \
	plutil -lint "$$plist_tmp"; \
	chmod 600 "$$plist_tmp"; \
	service_absent() { output=$$(launchctl print "$(MACOS_USE_SERVICE_TARGET)" 2>&1); status=$$?; [ "$$status" -ne 0 ] && printf '%s\n' "$$output" | grep -Fq 'Could not find service'; }; \
	if ! launchctl bootout "$(MACOS_USE_SERVICE_TARGET)" >/dev/null 2>&1; then \
		if ! service_absent; then printf '%s\n' 'ERROR: could not confirm LaunchAgent bootout; refusing replacement.' >&2; exit 1; fi; \
	fi; \
	attempt=0; \
	while ! service_absent && [ "$$attempt" -lt 10 ]; do sleep 1; attempt=$$((attempt + 1)); done; \
	if ! service_absent; then \
		printf '%s\n' 'ERROR: LaunchAgent remained loaded or could not be queried; refusing replacement.' >&2; \
		exit 1; \
	fi; \
	mv "$$plist_tmp" "$(MACOS_USE_PLIST)"; \
	launchctl enable "$(MACOS_USE_SERVICE_TARGET)"; \
	launchctl bootstrap "$(MACOS_USE_LAUNCH_DOMAIN)" "$(MACOS_USE_PLIST)"
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.wait

.PHONY: macos-use.wait
macos-use.wait:
	@socket_endpoint_ready() { \
		[ -S "$(MACOS_USE_SOCKET)" ] && [ ! -L "$(MACOS_USE_SOCKET)" ] || return 1; \
		socket_owner=$$(stat -f '%u' "$(MACOS_USE_SOCKET)" 2>/dev/null || true); \
		socket_mode=$$(stat -f '%Sp' "$(MACOS_USE_SOCKET)" 2>/dev/null || true); \
		[ "$$socket_owner" = "$(MACOS_USE_UID)" ] && [ "$$socket_mode" = 'srw-------' ]; \
	}; \
	attempt=0; \
	while [ "$$attempt" -lt "$(MACOS_USE_WAIT_ATTEMPTS)" ]; do \
		if launchctl print "$(MACOS_USE_SERVICE_TARGET)" 2>/dev/null | grep -q 'state = running' \
			&& socket_endpoint_ready; then \
			printf 'Service ready: %s\n' "$(MACOS_USE_SERVICE_TARGET)"; \
			ls -l "$(MACOS_USE_SOCKET)"; \
			exit 0; \
		fi; \
		attempt=$$((attempt + 1)); \
		sleep "$(MACOS_USE_WAIT_INTERVAL)"; \
	done; \
	printf 'ERROR: service/socket not ready after %s attempt(s).\n' "$(MACOS_USE_WAIT_ATTEMPTS)" >&2; \
	launchctl print "$(MACOS_USE_SERVICE_TARGET)" 2>&1 | sed -n '1,80p' >&2 || true; \
	tail -n 40 "$(MACOS_USE_STDERR_LOG)" 2>/dev/null >&2 || true; \
	exit 1

# =============================================================================
# Full install and verification
# =============================================================================

##@ [MacosUse] Install + Verify

.PHONY: macos-use.install
macos-use.install: ## Doctor + build + stop + bundle + sign + register + launch + verify.
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.doctor
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.build
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.stop
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.bundle
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.sign
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.register
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.launchd
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.verify
	@printf '\n%s\n' '============================================================'; \
	printf '%s\n' '  MACOS USE INSTALL COMPLETE'; \
	printf '%s\n' '============================================================'; \
	printf '  App:       %s\n' "$(MACOS_USE_APP_DIR)"; \
	printf '  MCP:       %s\n' "$(MACOS_USE_MCP_BIN)"; \
	printf '  Socket:    %s\n' "$(MACOS_USE_SOCKET)"; \
	printf '  Service:   %s\n' "$(MACOS_USE_SERVICE_TARGET)"; \
	printf '  Signing:   %s\n' "$(MACOS_USE_SIGN_IDENTITY)"; \
	printf '\n%s\n' '  Grant Accessibility and Screen & System Audio Recording'; \
	printf '%s\n' '  in System Settings > Privacy & Security, then run:'; \
	printf '%s\n' '    gmake macos-use.restart'; \
	if [ "$(MACOS_USE_SIGN_IDENTITY)" = '-' ]; then \
		printf '\n%s\n' '  NOTE: ad-hoc signing is convenient but TCC grants may be lost'; \
		printf '%s\n' '        after a rebuild. Use an Apple Development identity for'; \
		printf '%s\n' '        stable grants across builds.'; \
	fi; \
	printf '%s\n' '============================================================'

.PHONY: macos-use.verify
macos-use.verify: ## Fail unless bundle, resources, signature, service, socket, and MCP are valid.
	@failed=0; \
	pass() { printf '  PASS  %s\n' "$$1"; }; \
	fail() { printf '  FAIL  %s\n' "$$1" >&2; failed=1; }; \
	printf '%s\n' '=== Verifying MacosUse deployment ==='; \
	if [ -d "$(MACOS_USE_APP_DIR)" ]; then pass 'application bundle exists'; else fail 'application bundle is missing'; fi; \
	if [ -x "$(MACOS_USE_APP_EXECUTABLE)" ]; then pass 'server executable exists and is executable'; else fail 'server executable is missing or not executable'; fi; \
	if plutil -lint "$(MACOS_USE_APP_DIR)/Contents/Info.plist" >/dev/null 2>&1; then pass 'Info.plist is valid'; else fail 'Info.plist is invalid or missing'; fi; \
	bundle_id=$$(plutil -extract CFBundleIdentifier raw -o - "$(MACOS_USE_APP_DIR)/Contents/Info.plist" 2>/dev/null || true); \
	if [ "$$bundle_id" = "$(MACOS_USE_BUNDLE_ID)" ]; then pass 'bundle identifier matches'; else fail "bundle identifier mismatch: $$bundle_id"; fi; \
	if [ -d "$(MACOS_USE_APP_DIR)/Contents/Resources/$(MACOS_USE_RESOURCE_BUNDLE_NAME)" ]; then pass 'SwiftPM resource bundle is installed in Contents/Resources'; else fail 'SwiftPM resource bundle is missing from Contents/Resources'; fi; \
		if [ -d "$(MACOS_USE_APP_DIR)/Contents/Resources/$(MACOS_USE_RESOURCE_BUNDLE_NAME)" ] && find "$(MACOS_USE_APP_DIR)/Contents/Resources/$(MACOS_USE_RESOURCE_BUNDLE_NAME)" -type f -name "*.pb" -print -quit 2>/dev/null | grep -q .; then pass 'resource bundle accessible in Contents/Resources'; else fail 'resource bundle not accessible'; fi; \
	if find "$(MACOS_USE_APP_DIR)/Contents/Resources/$(MACOS_USE_RESOURCE_BUNDLE_NAME)" -type f -name '*.pb' -print -quit 2>/dev/null | grep -q .; then pass 'protobuf descriptor resources are present'; else fail 'protobuf descriptor resources are missing'; fi; \
	if codesign --verify --deep --strict "$(MACOS_USE_APP_DIR)" >/dev/null 2>&1; then pass 'code signature passes deep strict verification'; else fail 'code signature verification failed'; fi; \
	if plutil -lint "$(MACOS_USE_PLIST)" >/dev/null 2>&1; then pass 'LaunchAgent plist is valid'; else fail 'LaunchAgent plist is invalid or missing'; fi; \
	if launchctl print "$(MACOS_USE_SERVICE_TARGET)" >/dev/null 2>&1; then pass 'LaunchAgent is loaded in the GUI domain'; else fail 'LaunchAgent is not loaded'; fi; \
	if launchctl print "$(MACOS_USE_SERVICE_TARGET)" 2>/dev/null | grep -q 'state = running'; then pass 'LaunchAgent process is running'; else fail 'LaunchAgent is not in the running state'; fi; \
	if [ -S "$(MACOS_USE_SOCKET)" ] && [ ! -L "$(MACOS_USE_SOCKET)" ]; then pass 'Unix socket exists without symlink indirection'; else fail 'Unix socket is missing or is a symlink'; fi; \
	if [ -S "$(MACOS_USE_SOCKET)" ] && [ ! -L "$(MACOS_USE_SOCKET)" ]; then \
		socket_owner=$$(stat -f '%u' "$(MACOS_USE_SOCKET)" 2>/dev/null || true); \
		socket_mode=$$(stat -f '%Sp' "$(MACOS_USE_SOCKET)" 2>/dev/null || true); \
		if [ "$$socket_owner" = "$(MACOS_USE_UID)" ]; then pass 'Unix socket owner matches current user'; else fail "Unix socket owner mismatch: $$socket_owner"; fi; \
		if [ "$$socket_mode" = 'srw-------' ]; then pass 'Unix socket mode is 0600'; else fail "Unix socket mode is not 0600: $$socket_mode"; fi; \
	fi; \
	if [ -x "$(MACOS_USE_MCP_BIN)" ]; then pass 'macos-use-mcp binary exists and is executable'; else fail "macos-use-mcp is missing: $(MACOS_USE_MCP_BIN)"; fi; \
	printf '%s\n' '--- Signature identity ---'; \
	codesign -d --verbose=4 "$(MACOS_USE_APP_DIR)" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)=' || true; \
	printf '%s\n' '--- Embedded entitlements ---'; \
	if ! codesign -d --entitlements :- "$(MACOS_USE_APP_DIR)" 2>/dev/null; then printf '%s\n' '  (none)'; fi; \
	if [ "$$failed" -ne 0 ]; then printf '%s\n' 'Deployment verification FAILED.' >&2; exit 1; fi; \
	printf '%s\n' 'Deployment verification passed.'

# =============================================================================
# Lifecycle and diagnostics
# =============================================================================

##@ [MacosUse] Lifecycle

.PHONY: macos-use.status
macos-use.status: ## Show exact LaunchAgent, process, socket, signature, and MCP status.
	@printf '%s\n' '=== LaunchAgent ==='; \
	launchctl print "$(MACOS_USE_SERVICE_TARGET)" 2>/dev/null | sed -n '1,45p' || printf '%s\n' '  not loaded'; \
	printf '%s\n' '=== Socket ==='; \
	ls -l "$(MACOS_USE_SOCKET)" 2>/dev/null || printf '%s\n' '  not found'; \
	printf '%s\n' '=== App signature ==='; \
	codesign -d --verbose=4 "$(MACOS_USE_APP_DIR)" 2>&1 | grep -E '^(Executable|Identifier|Format|Signature|TeamIdentifier)=' || printf '%s\n' '  not signed'; \
	printf '%s\n' '=== MCP binary ==='; \
	if [ -x "$(MACOS_USE_MCP_BIN)" ]; then ls -l "$(MACOS_USE_MCP_BIN)"; else printf '  not found: %s\n' "$(MACOS_USE_MCP_BIN)"; fi

.PHONY: macos-use.start
macos-use.start: ## Start the service without rebuilding or signing.
	@set -u; \
	if [ ! -f "$(MACOS_USE_PLIST)" ]; then printf '%s\n' "ERROR: missing $(MACOS_USE_PLIST)" >&2; exit 1; fi; \
	if launchctl print "$(MACOS_USE_SERVICE_TARGET)" >/dev/null 2>&1; then \
		launchctl kickstart "$(MACOS_USE_SERVICE_TARGET)"; \
	else \
		launchctl enable "$(MACOS_USE_SERVICE_TARGET)"; \
		launchctl bootstrap "$(MACOS_USE_LAUNCH_DOMAIN)" "$(MACOS_USE_PLIST)"; \
	fi
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.wait

.PHONY: macos-use.restart
macos-use.restart: ## Restart the service without rebuilding or re-signing.
	@set -u; \
	if [ ! -f "$(MACOS_USE_PLIST)" ]; then printf '%s\n' "ERROR: missing $(MACOS_USE_PLIST)" >&2; exit 1; fi; \
	if launchctl print "$(MACOS_USE_SERVICE_TARGET)" >/dev/null 2>&1; then \
		launchctl kickstart -k "$(MACOS_USE_SERVICE_TARGET)"; \
	else \
		launchctl enable "$(MACOS_USE_SERVICE_TARGET)"; \
		launchctl bootstrap "$(MACOS_USE_LAUNCH_DOMAIN)" "$(MACOS_USE_PLIST)"; \
	fi
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos-use.wait

.PHONY: macos-use.stop
macos-use.stop: ## Stop and unload the service; preserve app, plist, MCP, and TCC grants.
	@set -u; \
	printf '%s\n' 'Stopping MacosUseServer LaunchAgent...'; \
	service_absent() { output=$$(launchctl print "$(MACOS_USE_SERVICE_TARGET)" 2>&1); status=$$?; [ "$$status" -ne 0 ] && printf '%s\n' "$$output" | grep -Eq 'Could not find service|No such process|service does not exist'; }; \
	if ! launchctl bootout "$(MACOS_USE_SERVICE_TARGET)" >/dev/null 2>&1; then \
		if ! service_absent; then printf '%s\n' 'ERROR: could not confirm LaunchAgent bootout; refusing success.' >&2; exit 1; fi; \
	fi; \
	attempt=0; \
	while ! service_absent && [ "$$attempt" -lt 10 ]; do sleep 1; attempt=$$((attempt + 1)); done; \
	if ! service_absent; then \
		printf '%s\n' 'ERROR: LaunchAgent remained loaded or could not be queried; service was not confirmed stopped.' >&2; \
		exit 1; \
	fi; \
	printf '%s\n' 'Service stopped.'

.PHONY: macos-use.tcc-reset
macos-use.tcc-reset: ## Reset Accessibility and ScreenCapture TCC records for this bundle ID.
	@printf 'Resetting TCC records for %s...\n' "$(MACOS_USE_BUNDLE_ID)"; \
	for tcc_service in Accessibility ScreenCapture; do \
		if tccutil reset "$$tcc_service" "$(MACOS_USE_BUNDLE_ID)"; then \
			printf '  reset %s\n' "$$tcc_service"; \
		else \
			printf '  warning: could not reset %s (there may be no matching record)\n' "$$tcc_service" >&2; \
		fi; \
	done; \
	printf '%s\n' 'Re-grant permissions in System Settings, then run gmake macos-use.restart.'

.PHONY: macos-use.logs
macos-use.logs: ## Show recent stdout, stderr, and unified-log entries.
	@printf '%s\n' '=== stdout (last 40 lines) ==='; \
	tail -n 40 "$(MACOS_USE_STDOUT_LOG)" 2>/dev/null || printf '%s\n' '(empty)'; \
	printf '%s\n' '=== stderr (last 40 lines) ==='; \
	tail -n 40 "$(MACOS_USE_STDERR_LOG)" 2>/dev/null || printf '%s\n' '(empty)'; \
	printf '%s\n' '=== unified log (last 5 minutes) ==='; \
	log show --last 5m --style compact --predicate 'process == "MacosUseServer"' 2>/dev/null | tail -n 80 || printf '%s\n' '(unavailable)'

.PHONY: macos-use.uninstall
macos-use.uninstall: ## Remove app, LaunchAgent, plist, logs, MCP binary, and TCC records; preserve the configured socket pathname.
	@printf '%s\n' '=== Uninstalling MacosUseServer ==='; \
	service_absent() { output=$$(launchctl print "$(MACOS_USE_SERVICE_TARGET)" 2>&1); status=$$?; [ "$$status" -ne 0 ] && printf '%s\n' "$$output" | grep -Eq 'Could not find service|No such process|service does not exist'; }; \
	if ! launchctl bootout "$(MACOS_USE_SERVICE_TARGET)" >/dev/null 2>&1; then \
		if ! service_absent; then printf '%s\n' 'ERROR: could not confirm LaunchAgent bootout; refusing uninstall.' >&2; exit 1; fi; \
	fi; \
	attempt=0; \
	while ! service_absent && [ "$$attempt" -lt 10 ]; do sleep 1; attempt=$$((attempt + 1)); done; \
	if ! service_absent; then \
		printf '%s\n' 'ERROR: LaunchAgent remained loaded or could not be queried; refusing uninstall.' >&2; \
		exit 1; \
	fi; \

	for tcc_service in Accessibility ScreenCapture; do \
		tccutil reset "$$tcc_service" "$(MACOS_USE_BUNDLE_ID)" >/dev/null 2>&1 || true; \
	done; \
	if [ -d "$(MACOS_USE_APP_DIR)" ]; then "$(MACOS_USE_LSREGISTER)" -u "$(MACOS_USE_APP_DIR)" >/dev/null 2>&1 || true; fi; \
	rm -rf "$(MACOS_USE_APP_DIR)" "$(MACOS_USE_STAGING_DIR)"; \
	rm -f "$(MACOS_USE_PLIST)"; \
	rm -f "$(MACOS_USE_STDOUT_LOG)" "$(MACOS_USE_STDERR_LOG)"; \
	rm -f "$(MACOS_USE_MCP_BIN)"; \
	printf '%s\n' 'Uninstall complete.'

# Convenience target for deterministic TextEdit automation testing.
.PHONY: macos-use-open-textedit-doc
macos-use-open-textedit-doc: ## Open an empty TextEdit document at a stable path.
	@mkdir -p "$(PROJECT_ROOT)"; \
	: > "$(PROJECT_ROOT)/tmp_hello.txt"; \
	open -a TextEdit "$(PROJECT_ROOT)/tmp_hello.txt"
