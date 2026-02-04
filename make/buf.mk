# make/buf.mk: Comprehensive Makefile for Buf CLI operations.
# Provides targets for linting, breaking changes, generation, formatting, and
# dependency/plugin management. Designed to be overridable via config.mk or
# project.mk using `?=` variables.

# Overridable path to the buf executable
BUF ?= buf
# Global flags passed to all buf commands
BUF_FLAGS ?=
# Default input path for buf commands (e.g., project root)
BUF_INPUT ?= .
# Default error format (text, json, msvs, junit, etc.)
BUF_ERROR_FORMAT ?= text

# Command-specific flags (overridable)
BUF_LINT_FLAGS ?=
BUF_FORMAT_FLAGS ?= -w
BUF_BUILD_FLAGS ?=
BUF_GENERATE_FLAGS ?= --template buf.gen.yaml
BUF_BREAKING_FLAGS ?=
# Example: BUF_BREAKING_AGAINST ?= .#branch=main
BUF_BREAKING_AGAINST ?=
BUF_EXPORT_FLAGS ?=
BUF_EXPORT_OUTPUT ?= $(PROJECT_ROOT)/gen/proto/export
BUF_DEP_FLAGS ?=
BUF_PLUGIN_FLAGS ?=
BUF_CONFIG_FLAGS ?=
BUF_LS_FILES_FLAGS ?=
BUF_STATS_FLAGS ?=
# buf curl defaults
BUF_CURL_FLAGS ?= --protocol grpc
BUF_CURL_METHOD ?=
BUF_CURL_SERVER ?=
# beta studio-agent defaults
BUF_AGENT_FLAGS ?= --bind 127.0.0.1 --port 8080

##@ Buf Targets

# PHONY targets and user-facing help comments
.PHONY: buf.format
buf.format: ## Format protobuf files in-place using 'buf format'.
	$(BUF) $(BUF_FLAGS) --error-format=$(BUF_ERROR_FORMAT) format $(BUF_FORMAT_FLAGS) $(BUF_INPUT)

.PHONY: buf.lint
buf.lint: ## Lint protobuf files using 'buf lint'.
	$(BUF) $(BUF_FLAGS) --error-format=$(BUF_ERROR_FORMAT) lint $(BUF_LINT_FLAGS) $(BUF_INPUT)

.PHONY: buf.breaking
buf.breaking: ## Check for breaking changes (requires BUF_BREAKING_AGAINST to be set).
	@$(if $(BUF_BREAKING_AGAINST),, \
		$(error ERROR: BUF_BREAKING_AGAINST is not set. Example: make buf.breaking BUF_BREAKING_AGAINST=.#branch=main))
	$(BUF) $(BUF_FLAGS) --error-format=$(BUF_ERROR_FORMAT) breaking $(BUF_BREAKING_FLAGS) --against $(BUF_BREAKING_AGAINST) $(BUF_INPUT)

.PHONY: buf.build
buf.build: ## Build protobuf files and validate sources.
	$(BUF) $(BUF_FLAGS) --error-format=$(BUF_ERROR_FORMAT) build $(BUF_BUILD_FLAGS) -o /dev/null $(BUF_INPUT)

.PHONY: buf.generate
buf.generate: ## Generate code from protobuf files using 'buf generate'.
	$(BUF) $(BUF_FLAGS) --error-format=$(BUF_ERROR_FORMAT) generate $(BUF_GENERATE_FLAGS) $(BUF_INPUT)

.PHONY: buf.check
buf.check: buf.lint buf.breaking ## Run all checks (lint and breaking).

.PHONY: buf.all
buf.all: buf.build buf.generate buf.lint buf.format ## Run all core buf targets.

# Dependency & plugin management
.PHONY: buf.dep
buf.dep: buf.dep.graph ## Display the dependency graph.

.PHONY: buf.dep.graph
buf.dep.graph: ## Print the dependency graph from buf.lock.
	$(BUF) $(BUF_FLAGS) dep graph $(BUF_DEP_FLAGS) $(BUF_INPUT)

.PHONY: buf.dep.prune
buf.dep.prune: ## Prune unused dependencies from buf.lock.
	$(BUF) $(BUF_FLAGS) dep prune $(BUF_DEP_FLAGS) $(BUF_INPUT)

.PHONY: buf.dep.update
buf.dep.update: ## Update dependencies in buf.lock.
	$(BUF) $(BUF_FLAGS) dep update $(BUF_DEP_FLAGS) $(BUF_INPUT)

.PHONY: buf.plugin
buf.plugin: buf.plugin.prune buf.plugin.update ## Prune and update buf.lock plugins.

.PHONY: buf.plugin.prune
buf.plugin.prune: ## Prune unused plugins from buf.lock.
	$(BUF) $(BUF_FLAGS) plugin prune $(BUF_PLUGIN_FLAGS) $(BUF_INPUT)

.PHONY: buf.plugin.update
buf.plugin.update: ## Update plugins in buf.lock.
	$(BUF) $(BUF_FLAGS) plugin update $(BUF_PLUGIN_FLAGS) $(BUF_INPUT)

.PHONY: buf.update
buf.update: buf.dep.update buf.plugin.update ## Update all dependencies and plugins in buf.lock.

# Configuration & inspection targets
.PHONY: buf.config
buf.config: buf.config.ls-lint-rules buf.config.ls-breaking-rules buf.config.ls-modules ## List configuration details.

.PHONY: buf.config.ls-lint-rules
buf.config.ls-lint-rules: ## List available lint rules.
	$(BUF) $(BUF_FLAGS) config ls-lint-rules $(BUF_CONFIG_FLAGS)

.PHONY: buf.config.ls-breaking-rules
buf.config.ls-breaking-rules: ## List available breaking change rules.
	$(BUF) $(BUF_FLAGS) config ls-breaking-rules $(BUF_CONFIG_FLAGS)

.PHONY: buf.config.ls-modules
buf.config.ls-modules: ## List configured modules.
	$(BUF) $(BUF_FLAGS) config ls-modules $(BUF_CONFIG_FLAGS)

.PHONY: buf.ls-files
buf.ls-files: ## List all protobuf files known to buf.
	$(BUF) $(BUF_FLAGS) ls-files $(BUF_LS_FILES_FLAGS) $(BUF_INPUT)

.PHONY: buf.stats
buf.stats: ## Get statistics for protobuf files.
	$(BUF) $(BUF_FLAGS) --error-format=$(BUF_ERROR_FORMAT) stats $(BUF_STATS_FLAGS) $(BUF_INPUT)

.PHONY: buf.export
buf.export: ## Export .proto files to BUF_EXPORT_OUTPUT.
	@rm -rf $(BUF_EXPORT_OUTPUT)
	@mkdir -p $(BUF_EXPORT_OUTPUT)
	$(BUF) $(BUF_FLAGS) --error-format=$(BUF_ERROR_FORMAT) export $(BUF_EXPORT_FLAGS) -o $(BUF_EXPORT_OUTPUT) $(BUF_INPUT)

# Advanced targets
.PHONY: buf.curl
buf.curl: ## Invoke an RPC (requires BUF_CURL_METHOD and BUF_CURL_SERVER).
	@$(if $(BUF_CURL_METHOD),, \
		$(error ERROR: BUF_CURL_METHOD is not set. Example: make buf.curl BUF_CURL_METHOD=//pkg.Service/Method ...))
	@$(if $(BUF_CURL_SERVER),, \
		$(error ERROR: BUF_CURL_SERVER is not set. Example: make buf.curl BUF_CURL_SERVER=localhost:8080 ...))
	$(BUF) $(BUF_FLAGS) curl $(BUF_CURL_FLAGS) --server $(BUF_CURL_SERVER) $(BUF_CURL_METHOD)

.PHONY: buf.beta.studio-agent
buf.beta.studio-agent: ## Run the Buf Studio agent (beta).
	$(BUF) $(BUF_FLAGS) beta studio-agent $(BUF_AGENT_FLAGS)

# Descriptor set generation for gRPC reflection
.PHONY: buf.descriptor-sets
buf.descriptor-sets: ## Generate FileDescriptorSet for gRPC reflection.
	@mkdir -p $(PROJECT_ROOT)/Server/Sources/MacosUseServer/DescriptorSets
	$(BUF) $(BUF_FLAGS) --error-format=$(BUF_ERROR_FORMAT) build --as-file-descriptor-set -o $(PROJECT_ROOT)/Server/Sources/MacosUseServer/DescriptorSets/macosuse_descriptors.pb $(BUF_INPUT)
