# make/release.mk: Release tooling targets.
# Provides non-publishing product-version update/tag commands and disposable
# fixture tests. The scripts are intentionally kept together under hack/release.

RELEASE_SHELL ?= /bin/sh
RELEASE_SCRIPT_DIR ?= $(PROJECT_ROOT)/hack/release
RELEASE_UPDATE_SCRIPT ?= $(RELEASE_SCRIPT_DIR)/update-version.sh
RELEASE_TAG_SCRIPT ?= $(RELEASE_SCRIPT_DIR)/tag-version.sh
RELEASE_TEST_SCRIPT ?= $(RELEASE_SCRIPT_DIR)/test-release-scripts.sh

##@ Release Targets

.PHONY: release.test
release.test: ## Run disposable release-script fixture tests.
	@$(RELEASE_SHELL) "$(RELEASE_TEST_SCRIPT)"

.PHONY: release.update
release.update: ## Update product version surfaces; set RELEASE_VERSION=X.Y.Z.
	@if [ -z "$(RELEASE_VERSION)" ]; then \
		printf '%s\n' 'RELEASE_VERSION is required (X.Y.Z)' >&2; \
		exit 2; \
	fi
	@$(RELEASE_UPDATE_SCRIPT) "$(RELEASE_VERSION)"

.PHONY: release.tag
release.tag: ## Create a local annotated tag; set RELEASE_VERSION=X.Y.Z.
	@if [ -z "$(RELEASE_VERSION)" ]; then \
		printf '%s\n' 'RELEASE_VERSION is required (X.Y.Z)' >&2; \
		exit 2; \
	fi
	@$(RELEASE_TAG_SCRIPT) "$(RELEASE_VERSION)"

.PHONY: release.all
release.all: release.test ## Run non-mutating release checks only; never update or tag.
