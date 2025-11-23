# MIT License
#
# Copyright (c) 2025 Joseph Cumines
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Example and (current) source of truth:
# https://github.com/joeycumines/MacosUseSDK/blob/main/make/swift.mk

# ---

# simple variables that either represent invariants, or need to be interacted
# with in an imperative manner, e.g. "building" values across includes, without
# separating the output of each include into its own discrete variable

# windows gnu make seems to append includes to the end of MAKEFILE_LIST
# hence the simple variable assignment, prior to any includes
ifeq ($(ROOT_MAKEFILE),)
ROOT_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
endif

# used to support changing the working directory + resolve relative paths
ifeq ($(PROJECT_ROOT),)
PROJECT_ROOT := $(patsubst %/,%,$(dir $(ROOT_MAKEFILE)))
endif

# N.B. this is a multi-platform makefile
# so far only two switching cases have been required (Windows and Unix)
ifeq ($(IS_WINDOWS),)
ifeq ($(OS),Windows_NT)
IS_WINDOWS := true
else
IS_WINDOWS := false
endif
endif

# If set, then ALL targets will be prefixed with this value.
# If you wish to use this as part of a larger project, you might set this like:
#   SWIFT_TARGET_PREFIX := swift.
# Within your root Makefile (which would also need to set ROOT_MAKEFILE).
ifeq ($(SWIFT_TARGET_PREFIX),)
SWIFT_TARGET_PREFIX :=
SWIFT_MK_VAR_PREFIX :=
else
# Simply-expand, attempt to ensure value is set consistently, avoid re-eval.
SWIFT_TARGET_PREFIX := $(SWIFT_TARGET_PREFIX)
# This is a mitigation for collisions. For use in monorepo multi-lang projects.
# Only applies to certain variables, e.g. CLEAN_PATHS.
SWIFT_MK_VAR_PREFIX := SWIFT_
endif
# export the prefixes (normally not necessary, just for sanity)
export SWIFT_TARGET_PREFIX
export SWIFT_MK_VAR_PREFIX

# ---

# intended to be provided on the command line, for certain targets

# determines the output of the debug-vars target
# N.B. only _defined_ variables will be present in the output
$(eval $(SWIFT_MK_VAR_PREFIX)DEBUG_VARS ?= ROOT_MAKEFILE PROJECT_ROOT PROJECT_NAME IS_WINDOWS SWIFT_PACKAGE_PATHS SWIFT_PACKAGE_SLUGS SWIFT_PACKAGE_SLUGS_NO_TESTS SWIFT_PACKAGE_SLUGS_EXCL_NO_TESTS SWIFT_PACKAGE_SLUGS_NO_LINT SWIFT_PACKAGE_SLUGS_EXCL_NO_LINT SWIFT_PACKAGE_SLUGS_NO_FORMAT SWIFT_PACKAGE_SLUGS_EXCL_NO_FORMAT SWIFT_PACKAGE_SLUGS_INCL_NO_FORMAT SWIFT_PACKAGE_SLUGS_NO_UPDATE SWIFT_PACKAGE_SLUGS_EXCL_NO_UPDATE SWIFT_TARGET_PREFIX MAKEFILE_TARGET_PREFIXES $$(MAKEFILE_TARGET_PREFIXES) $$(foreach v,CLEAN_PATHS ALL_TARGETS BUILD_TARGETS LINT_TARGETS LINT_FORMAT_TARGETS LINT_STYLE_TARGETS TEST_TARGETS COVER_TARGETS FORMAT_TARGETS FIX_TARGETS UPDATE_TARGETS RESOLVE_TARGETS,$$(SWIFT_MK_VAR_PREFIX)$$v))

# ---

# Intended to be configurable.
# Also configurable:
#  SWIFT_DAG__<swift package slug converting "." to "__"> := <space-separated list of package slugs it depends on>
# e.g. Given ./SubProject1/SubModuleA with slug SubProject1.SubModuleA depending on ./SubProject2 and ./SubProject3/SubModuleC:
#  SWIFT_DAG__SubProject1__SubModuleA := SubProject2 SubProject3.SubModuleC

PROJECT_NAME ?= $(notdir $(PROJECT_ROOT))
# set (build) these to support dynamically building the help target with replacements
MAKEFILE_TARGET_PREFIXES ?=
SWIFT ?= swift
SWIFT_CONFIGURATION ?= release
SWIFT_FLAGS ?=
SWIFT_BUILD_FLAGS ?=
SWIFT_TEST_FLAGS ?=
# callable variables, with param $1 being a swift package slug (see swift_package_slug_to_path)
SWIFT_BUILD ?= $(SWIFT) build $(SWIFT_FLAGS) $(if $(or $(filter -c,$(SWIFT_BUILD_FLAGS)),$(filter --configuration,$(SWIFT_BUILD_FLAGS))),$(SWIFT_BUILD_FLAGS),$(SWIFT_BUILD_FLAGS) --configuration $(SWIFT_CONFIGURATION))
SWIFT_TEST ?= $(SWIFT) test $(SWIFT_FLAGS) $(SWIFT_TEST_FLAGS)
SWIFT_COVER_TEST ?= $(SWIFT) test --enable-code-coverage $(SWIFT_FLAGS) $(SWIFT_TEST_FLAGS)
SWIFT_UPDATE ?= $(SWIFT) package update
SWIFT_RESOLVE ?= $(SWIFT) package resolve
# simple command variables
SWIFTFORMAT ?= swiftformat
SWIFTFORMAT_FLAGS ?=
SWIFTFORMAT_LINT_FLAGS ?= --lint
SWIFTLINT ?= swiftlint
SWIFTLINT_FLAGS ?=
SWIFTFIX ?= $(SWIFTLINT)
SWIFTFIX_FLAGS ?= --fix
SWIFT_COVERAGE_PACKAGE_FILE ?= coverage.lcov
SWIFT_COVERAGE_ALL_PACKAGES_FILE ?= coverage-all.lcov
LLVM_COV ?= llvm-cov
SWIFTDOC ?= jazzy
_SWIFTDOC_FLAGS := serve --port 6060 # ignore this (use SWIFTDOC_FLAGS)
SWIFTDOC_FLAGS ?= $(_SWIFTDOC_FLAGS)
# for the tools target
SWIFT_TOOLS ?= $(SWIFT_TOOLS_DEFAULT)
# Used to prune _paths_ when searching for packages. Single wildcard (%) supported.
# May match intermediate directories. The pattern `%/.build` is always applied.
# Example: %/vendor %/node_modules ./managed-separately
SWIFT_PACKAGE_PATHS_EXCLUDE_PATTERNS ?=
# used to special-case packages for tools which fail if they find no tests
SWIFT_PACKAGE_SLUGS_NO_TESTS ?=
# used to exclude packages from the update* targets
SWIFT_PACKAGE_SLUGS_NO_UPDATE ?=
# used to exclude packages from swiftlint targets
SWIFT_PACKAGE_SLUGS_NO_LINT ?=
# used to exclude packages from swiftformat targets
SWIFT_PACKAGE_SLUGS_NO_FORMAT ?=
# exclude files from swiftlint, use % for wildcard, space-separated, paths start with "./"
SWIFT_PACKAGE_FILES_NO_LINT ?=
# exclude files from swiftformat, use % for wildcard, space-separated, paths start with "./"
SWIFT_PACKAGE_FILES_NO_FORMAT ?=

# configurable, but unlikely to need to be configured

# separates keys and values, see also the map_* functions
MAP_SEPARATOR ?= :
# path separator (/ replacement) for slugs
SLUG_SEPARATOR ?= .
SWIFT_TOOLS_DEFAULT ?= \
	$(SWIFT_PKG_SWIFTFORMAT) \
	$(SWIFT_PKG_SWIFTLINT) \
	$(SWIFT_PKG_SWIFTDOC)
SWIFT_PKG_SWIFTFORMAT ?= github.com/nicklockwood/SwiftFormat
SWIFT_PKG_SWIFTLINT ?= github.com/realm/SwiftLint
SWIFT_PKG_SWIFTDOC ?= github.com/realm/jazzy
# paths to be deleted on clean - use $($(SWIFT_MK_VAR_PREFIX)CLEAN_PATHS) to get
$(eval $(SWIFT_MK_VAR_PREFIX)CLEAN_PATHS ?= $$(SWIFT_COVERAGE_ALL_PACKAGES_FILE) $$(addsuffix /$$(SWIFT_COVERAGE_PACKAGE_FILE),$$(SWIFT_PACKAGE_PATHS)) $$(addsuffix /.build,$$(SWIFT_PACKAGE_PATHS)))

# ---

# Recursive wildcard match function, with support for optional pruning.
#
# Signature: $(call rwildcard,<dir>,<pattern>,[filter-out])
#
# $1: directory to search (requires a trailing slash, e.g., "src/")
# $2: pattern to match (e.g., "*.go")
# $3: (optional) A whitespace-separated list of patterns to $(filter-out ...).
#     Applied to both files and directories, "guarding" further recursion.
rwildcard ?= \
$(call _rwildcard_filter_out,$(wildcard $1$2),$3) \
$(foreach d,\
$(call _rwildcard_filter_out,$(patsubst %/./,%,$(wildcard $1*/./)),$3),\
$(call rwildcard,$d/,$2,$3)\
)
_rwildcard_filter_out ?= $(if $2,$(filter-out $2,$1),$1)

# looks up a value in a map, $1 is the map, $2 is the key associated with the value
map_value_by_key ?= $(patsubst $2$(MAP_SEPARATOR)%,%,$(filter $2$(MAP_SEPARATOR)%,$1))
# looks up a key in a map, $1 is the map, $2 is the value associated with the key
map_key_by_value ?= $(patsubst %$(MAP_SEPARATOR)$2,%,$(filter %$(MAP_SEPARATOR)$2,$1))
# builds a new map, from a set of keys, using a transform function to build values from the keys
# $1 are the keys, $2 is the transform function
map_transform_keys ?= $(foreach v,$1,$v$(MAP_SEPARATOR)$(call $2,$v))
# extracts only the keys from a map variable, $1 is the map variable
map_keys ?= $(foreach v,$1,$(word 1,$(subst $(MAP_SEPARATOR), ,$v)))

# convert a path to a slug, e.g. ./logiface/logrus -> logiface.logrus, with special case for root
slug_transform ?= $(if $(filter .,$1),root,$(subst /,$(SLUG_SEPARATOR),$(patsubst ./%,%,$1)))
# attempts to perform the opposite of slug_parse, note that it may not be possible to recover the original path
slug_parse ?= $(if $(filter root,$1),$(SLUG_SEPARATOR),$(SLUG_SEPARATOR)/$(subst $(SLUG_SEPARATOR),/,$(filter-out root,$1)))

# escaping for use in recipies, e.g.: echo $(call escape_command_arg,$(MESSAGE))
# WARNING: you may get unexpected results under windows, e.g. if MESSAGE is empty, in the above example
ifeq ($(IS_WINDOWS),true)
escape_command_arg ?= $(strip $(subst %,%%,$(subst |,^|,$(subst >,^>,$(subst <,^<,$(subst &,^&,$(subst ^,^^,$1)))))))
else
escape_command_arg ?= '$(subst ','\'',$1)'
endif

# append $2 $3 to $1 if $2 is not empty and not found in $1 otherwise resolving to just $1
# $1: The base list
# $2: The item to check for uniqueness
# $3: The value to append alongside $2 (optional)
append_if_missing ?= $(if $(strip $2),$(if $(filter $2,$1),$1,$1 $2 $3),$1)

swift_package_path_to_slug = $(call map_value_by_key,$(_SWIFT_PACKAGE_MAP),$1)
swift_package_slug_to_path = $(call map_key_by_value,$(_SWIFT_PACKAGE_MAP),$1)

# paths formatted like ". ./Sources/MyLib ./Tests/MyLibTests"
SWIFT_PACKAGE_PATHS := $(patsubst %/Package.swift,%,$(call rwildcard,./,Package.swift,%/.build $(SWIFT_PACKAGE_PATHS_EXCLUDE_PATTERNS)))
# used by swift_package_path_to_slug and swift_package_slug_to_path to lookup an associated path/slug
_SWIFT_PACKAGE_MAP := $(call map_transform_keys,$(SWIFT_PACKAGE_PATHS),slug_transform)
# example: root Sources.MyLib Tests.MyLibTests
SWIFT_PACKAGE_SLUGS := $(foreach d,$(SWIFT_PACKAGE_PATHS),$(call swift_package_path_to_slug,$d))
# sanity check the path and slug lookups
ifneq ($(SWIFT_PACKAGE_PATHS),$(foreach d,$(SWIFT_PACKAGE_SLUGS),$(call swift_package_slug_to_path,$d)))
$(error SWIFT_PACKAGE_PATHS contains unsupported paths)
endif
ifneq ($(SWIFT_PACKAGE_SLUGS),$(foreach d,$(SWIFT_PACKAGE_PATHS),$(call swift_package_path_to_slug,$d)))
$(error SWIFT_PACKAGE_SLUGS contains unsupported paths)
endif
SWIFT_PACKAGE_SLUGS_EXCL_NO_TESTS := $(filter-out $(SWIFT_PACKAGE_SLUGS_NO_TESTS),$(SWIFT_PACKAGE_SLUGS))
SWIFT_PACKAGE_SLUGS_EXCL_NO_UPDATE := $(filter-out $(SWIFT_PACKAGE_SLUGS_NO_UPDATE),$(SWIFT_PACKAGE_SLUGS))
SWIFT_PACKAGE_SLUGS_EXCL_NO_LINT := $(filter-out $(SWIFT_PACKAGE_SLUGS_NO_LINT),$(SWIFT_PACKAGE_SLUGS))
SWIFT_PACKAGE_SLUGS_INCL_NO_LINT := $(filter-out $(SWIFT_PACKAGE_SLUGS_EXCL_NO_LINT),$(SWIFT_PACKAGE_SLUGS))
SWIFT_PACKAGE_SLUGS_EXCL_NO_FORMAT := $(filter-out $(SWIFT_PACKAGE_SLUGS_NO_FORMAT),$(SWIFT_PACKAGE_SLUGS))
SWIFT_PACKAGE_SLUGS_INCL_NO_FORMAT := $(filter-out $(SWIFT_PACKAGE_SLUGS_EXCL_NO_FORMAT),$(SWIFT_PACKAGE_SLUGS))

# Helper to determine subpackages for a given package path $1
# If $1 is ., subpackages are all other packages. If $1 is not ., subpackages are packages starting with $1/
_swift_subpackages = $(if $(filter .,$1),$(filter-out .,$(SWIFT_PACKAGE_PATHS)),$(filter $1/%,$(SWIFT_PACKAGE_PATHS)))

# Helper to find swift files belonging strictly to package path $1
# 1. Find all files in $1 (recursively)
# 2. Exclude files found in any subpackages of $1
# 3. Return the difference
swift_package_files = $(strip \
  $(filter-out \
	$(foreach p,$(call _swift_subpackages,$1),$(call rwildcard,$p/,*.swift,%/.build $(SWIFT_PACKAGE_PATHS_EXCLUDE_PATTERNS))),\
	$(call rwildcard,$1/,*.swift,%/.build $(SWIFT_PACKAGE_PATHS_EXCLUDE_PATTERNS))\
  ))

# ---

##@ [Swift] Package Targets

# all, all.<swift package slug>

.PHONY: $(SWIFT_TARGET_PREFIX)all
$(SWIFT_TARGET_PREFIX)all: $(addprefix $(SWIFT_TARGET_PREFIX)_all__lint.,$(SWIFT_PACKAGE_SLUGS)) $(addprefix $(SWIFT_TARGET_PREFIX)_all__test.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_TESTS)) ## Builds, then lints and tests (packages in parallel, two stages).

.PHONY: \
$(addprefix $(SWIFT_TARGET_PREFIX)_build__stage.,$(SWIFT_PACKAGE_SLUGS)) \
$(addprefix $(SWIFT_TARGET_PREFIX)_all__lint.,$(SWIFT_PACKAGE_SLUGS)) \
$(addprefix $(SWIFT_TARGET_PREFIX)_all__test.,$(SWIFT_PACKAGE_SLUGS))

# build stages per any defined DAG - also depended on by each corresponding all__lint and all__test target
define _build_stage__TEMPLATE =
$$(SWIFT_TARGET_PREFIX)_build__stage.$1: $(addprefix $(SWIFT_TARGET_PREFIX)_build__stage.,$(SWIFT_DAG__$(subst .,__,$1)))
	@$$(MAKE) --no-print-directory $$(SWIFT_TARGET_PREFIX)build.$1

endef
$(foreach v,$(SWIFT_PACKAGE_SLUGS),$(eval $(call _build_stage__TEMPLATE,$v)))

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)_all__lint.,$(SWIFT_PACKAGE_SLUGS))
$(addprefix $(SWIFT_TARGET_PREFIX)_all__lint.,$(SWIFT_PACKAGE_SLUGS)): $(SWIFT_TARGET_PREFIX)_all__lint.%: $(SWIFT_TARGET_PREFIX)_build__stage.%
	@$(MAKE) --no-print-directory $(SWIFT_TARGET_PREFIX)lint.$*

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)_all__test.,$(SWIFT_PACKAGE_SLUGS))
$(addprefix $(SWIFT_TARGET_PREFIX)_all__test.,$(SWIFT_PACKAGE_SLUGS)): $(SWIFT_TARGET_PREFIX)_all__test.%: $(SWIFT_TARGET_PREFIX)_build__stage.%
	@$(MAKE) --no-print-directory $(SWIFT_TARGET_PREFIX)test.$*

# build, build.<swift package slug>

$(eval $(SWIFT_MK_VAR_PREFIX)BUILD_TARGETS := $$(addprefix $$(SWIFT_TARGET_PREFIX)build.,$$(SWIFT_PACKAGE_SLUGS)))

.PHONY: $(SWIFT_TARGET_PREFIX)build
$(SWIFT_TARGET_PREFIX)build: $(addprefix $(SWIFT_TARGET_PREFIX)_build__stage.,$(SWIFT_PACKAGE_SLUGS)) ## Runs the swift build tool.

.PHONY: $($(SWIFT_MK_VAR_PREFIX)BUILD_TARGETS)
$($(SWIFT_MK_VAR_PREFIX)BUILD_TARGETS): $(SWIFT_TARGET_PREFIX)build.%:
	$(MAKE) -C $(call swift_package_slug_to_path,$*) -f $(ROOT_MAKEFILE) $(SWIFT_TARGET_PREFIX)_build SWIFT=$(call escape_command_arg,$(SWIFT)) SWIFT_FLAGS=$(call escape_command_arg,$(SWIFT_FLAGS)) SWIFT_BUILD_FLAGS=$(call escape_command_arg,$(SWIFT_BUILD_FLAGS)) SWIFT_CONFIGURATION=$(call escape_command_arg,$(SWIFT_CONFIGURATION))

.PHONY: $(SWIFT_TARGET_PREFIX)_build
$(SWIFT_TARGET_PREFIX)_build:
	$(SWIFT_BUILD)

# lint, lint.<swift package slug>

$(eval $(SWIFT_MK_VAR_PREFIX)LINT_TARGETS := $$(addprefix $$(SWIFT_TARGET_PREFIX)lint.,$$(SWIFT_PACKAGE_SLUGS)))

.PHONY: $(SWIFT_TARGET_PREFIX)lint
$(SWIFT_TARGET_PREFIX)lint: $($(SWIFT_MK_VAR_PREFIX)LINT_TARGETS) ## Runs the lint-format and lint-style targets.

.PHONY: $($(SWIFT_MK_VAR_PREFIX)LINT_TARGETS)
$($(SWIFT_MK_VAR_PREFIX)LINT_TARGETS): $(SWIFT_TARGET_PREFIX)lint.%: $(SWIFT_TARGET_PREFIX)lint-format.% $(SWIFT_TARGET_PREFIX)lint-style.%

# lint-style, lint-style.<swift package slug>

$(eval $(SWIFT_MK_VAR_PREFIX)LINT_STYLE_TARGETS := $$(addprefix $$(SWIFT_TARGET_PREFIX)lint-style.,$$(SWIFT_PACKAGE_SLUGS)))

.PHONY: $(SWIFT_TARGET_PREFIX)lint-style
$(SWIFT_TARGET_PREFIX)lint-style: $($(SWIFT_MK_VAR_PREFIX)LINT_STYLE_TARGETS) ## Runs swiftlint.

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)lint-style.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_LINT))
$(addprefix $(SWIFT_TARGET_PREFIX)lint-style.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_LINT)): $(SWIFT_TARGET_PREFIX)lint-style.%:
	$(SWIFTLINT) $(SWIFTLINT_FLAGS) $(filter-out $(SWIFT_PACKAGE_FILES_NO_LINT),$(call swift_package_files,$(call swift_package_slug_to_path,$*)))

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)lint-style.,$(SWIFT_PACKAGE_SLUGS_INCL_NO_LINT))
$(addprefix $(SWIFT_TARGET_PREFIX)lint-style.,$(SWIFT_PACKAGE_SLUGS_INCL_NO_LINT)): $(SWIFT_TARGET_PREFIX)lint-style.%:

# lint-format, lint-format.<swift package slug>

$(eval $(SWIFT_MK_VAR_PREFIX)LINT_FORMAT_TARGETS := $$(addprefix $$(SWIFT_TARGET_PREFIX)lint-format.,$$(SWIFT_PACKAGE_SLUGS)))

.PHONY: $(SWIFT_TARGET_PREFIX)lint-format
$(SWIFT_TARGET_PREFIX)lint-format: $($(SWIFT_MK_VAR_PREFIX)LINT_FORMAT_TARGETS) ## Runs swiftformat --lint.

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)lint-format.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_FORMAT))
$(addprefix $(SWIFT_TARGET_PREFIX)lint-format.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_FORMAT)): $(SWIFT_TARGET_PREFIX)lint-format.%:
	$(SWIFTFORMAT) $(SWIFTFORMAT_LINT_FLAGS) $(filter-out $(SWIFT_PACKAGE_FILES_NO_FORMAT),$(call swift_package_files,$(call swift_package_slug_to_path,$*)))

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)lint-format.,$(SWIFT_PACKAGE_SLUGS_INCL_NO_FORMAT))
$(addprefix $(SWIFT_TARGET_PREFIX)lint-format.,$(SWIFT_PACKAGE_SLUGS_INCL_NO_FORMAT)): $(SWIFT_TARGET_PREFIX)lint-format.%:

# test, test.<swift package slug>

$(eval $(SWIFT_MK_VAR_PREFIX)TEST_TARGETS := $$(addprefix $$(SWIFT_TARGET_PREFIX)test.,$$(SWIFT_PACKAGE_SLUGS)))

.PHONY: $(SWIFT_TARGET_PREFIX)test
$(SWIFT_TARGET_PREFIX)test: $($(SWIFT_MK_VAR_PREFIX)TEST_TARGETS) ## Runs the swift test tool.

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)test.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_TESTS))
$(addprefix $(SWIFT_TARGET_PREFIX)test.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_TESTS)): $(SWIFT_TARGET_PREFIX)test.%:
	$(MAKE) -C $(call swift_package_slug_to_path,$*) -f $(ROOT_MAKEFILE) $(SWIFT_TARGET_PREFIX)_test SWIFT=$(call escape_command_arg,$(SWIFT)) SWIFT_FLAGS=$(call escape_command_arg,$(SWIFT_FLAGS)) SWIFT_TEST_FLAGS=$(call escape_command_arg,$(SWIFT_TEST_FLAGS))

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)test.,$(SWIFT_PACKAGE_SLUGS_NO_TESTS))
$(addprefix $(SWIFT_TARGET_PREFIX)test.,$(SWIFT_PACKAGE_SLUGS_NO_TESTS)): $(SWIFT_TARGET_PREFIX)test.%:

.PHONY: $(SWIFT_TARGET_PREFIX)_test
$(SWIFT_TARGET_PREFIX)_test:
	$(SWIFT_TEST)

# cover, cover.<swift package slug>

$(eval $(SWIFT_MK_VAR_PREFIX)COVER_TARGETS := $$(addprefix $$(SWIFT_TARGET_PREFIX)cover.,$$(SWIFT_PACKAGE_SLUGS)))

.PHONY: $(SWIFT_TARGET_PREFIX)cover
$(SWIFT_TARGET_PREFIX)cover: $($(SWIFT_MK_VAR_PREFIX)COVER_TARGETS) ## Runs swift test --enable-code-coverage and generates an LCOV report.
ifeq ($(IS_WINDOWS),true)
	del /Q /S $(subst /,\,$(SWIFT_COVERAGE_ALL_PACKAGES_FILE))
else
	rm -f $(SWIFT_COVERAGE_ALL_PACKAGES_FILE)
endif
	$(foreach d,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_TESTS),$(cover__TEMPLATE))
	@echo "Merged LCOV report at $(SWIFT_COVERAGE_ALL_PACKAGES_FILE)"
ifeq ($(IS_WINDOWS),true)
define cover__TEMPLATE =
type $(subst /,\,$(call swift_package_slug_to_path,$d)/$(SWIFT_COVERAGE_PACKAGE_FILE)) >>$(SWIFT_COVERAGE_ALL_PACKAGES_FILE)

endef
else
define cover__TEMPLATE =
cat $(call swift_package_slug_to_path,$d)/$(SWIFT_COVERAGE_PACKAGE_FILE) >>$(SWIFT_COVERAGE_ALL_PACKAGES_FILE)

endef
endif

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)cover.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_TESTS))
$(addprefix $(SWIFT_TARGET_PREFIX)cover.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_TESTS)): $(SWIFT_TARGET_PREFIX)cover.%:
	$(MAKE) -C $(call swift_package_slug_to_path,$*) -f $(ROOT_MAKEFILE) $(SWIFT_TARGET_PREFIX)_cover SWIFT=$(call escape_command_arg,$(SWIFT)) SWIFT_FLAGS=$(call escape_command_arg,$(SWIFT_FLAGS)) SWIFT_TEST_FLAGS=$(call escape_command_arg,$(SWIFT_TEST_FLAGS)) LLVM_COV=$(call escape_command_arg,$(LLVM_COV)) SWIFT_COVERAGE_PACKAGE_FILE=$(call escape_command_arg,$(SWIFT_COVERAGE_PACKAGE_FILE))

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)cover.,$(SWIFT_PACKAGE_SLUGS_NO_TESTS))
$(addprefix $(SWIFT_TARGET_PREFIX)cover.,$(SWIFT_PACKAGE_SLUGS_NO_TESTS)): $(SWIFT_TARGET_PREFIX)cover.%:

.PHONY: $(SWIFT_TARGET_PREFIX)_cover
$(SWIFT_TARGET_PREFIX)_cover:
	$(SWIFT_COVER_TEST)
	$_SWIFT_BUILD_PATH=.build/debug
	$_SWIFT_PROFDATA=$$_SWIFT_BUILD_PATH/codecov/default.profdata
	$_SWIFT_PKG_NAME=$(shell $(SWIFT) package describe --type name)
	$_SWIFT_TEST_BINARY=$$_SWIFT_BUILD_PATH/$$_SWIFT_PKG_NAMEPackageTests.xctest
	@if [ ! -f "$$_SWIFT_PROFDATA" ]; then echo "No profdata found at $$_SWIFT_PROFDATA"; exit 1; fi
	@if [ ! -d "$$_SWIFT_TEST_BINARY" ]; then echo "No .xctest bundle found at $$_SWIFT_TEST_BINARY"; exit 1; fi
	$(LLVM_COV) export -format=lcov $$_SWIFT_TEST_BINARY -instr-profile $$_SWIFT_PROFDATA > $(SWIFT_COVERAGE_PACKAGE_FILE)

# format, format.<swift package slug>

$(eval $(SWIFT_MK_VAR_PREFIX)FORMAT_TARGETS := $$(addprefix $$(SWIFT_TARGET_PREFIX)format.,$$(SWIFT_PACKAGE_SLUGS)))

.PHONY: $(SWIFT_TARGET_PREFIX)format
$(SWIFT_TARGET_PREFIX)format: $($(SWIFT_MK_VAR_PREFIX)FORMAT_TARGETS) ## Runs swiftformat to fix formatting.

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)format.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_FORMAT))
$(addprefix $(SWIFT_TARGET_PREFIX)format.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_FORMAT)): $(SWIFT_TARGET_PREFIX)format.%:
	$(SWIFTFORMAT) $(SWIFTFORMAT_FLAGS) $(filter-out $(SWIFT_PACKAGE_FILES_NO_FORMAT),$(call swift_package_files,$(call swift_package_slug_to_path,$*)))

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)format.,$(SWIFT_PACKAGE_SLUGS_INCL_NO_FORMAT))
$(addprefix $(SWIFT_TARGET_PREFIX)format.,$(SWIFT_PACKAGE_SLUGS_INCL_NO_FORMAT)): $(SWIFT_TARGET_PREFIX)format.%:

# fix, fix.<swift package slug>

$(eval $(SWIFT_MK_VAR_PREFIX)FIX_TARGETS := $$(addprefix $$(SWIFT_TARGET_PREFIX)fix.,$$(SWIFT_PACKAGE_SLUGS)))

.PHONY: $(SWIFT_TARGET_PREFIX)fix
$(SWIFT_TARGET_PREFIX)fix: $($(SWIFT_MK_VAR_PREFIX)FIX_TARGETS) ## Runs swiftlint --fix to fix style violations.

.PHONY: $($(SWIFT_MK_VAR_PREFIX)FIX_TARGETS)
$($(SWIFT_MK_VAR_PREFIX)FIX_TARGETS): $(SWIFT_TARGET_PREFIX)fix.%:
	$(SWIFTFIX) $(SWIFTFIX_FLAGS) $(filter-out $(SWIFT_PACKAGE_FILES_NO_LINT),$(call swift_package_files,$(call swift_package_slug_to_path,$*)))

# update, update.<swift package slug>

$(eval $(SWIFT_MK_VAR_PREFIX)UPDATE_TARGETS := $$(addprefix $$(SWIFT_TARGET_PREFIX)update.,$$(SWIFT_PACKAGE_SLUGS)))

.PHONY: $(SWIFT_TARGET_PREFIX)update
$(SWIFT_TARGET_PREFIX)update: $($(SWIFT_MK_VAR_PREFIX)UPDATE_TARGETS) ## Runs swift package update.

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)update.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_UPDATE))
$(addprefix $(SWIFT_TARGET_PREFIX)update.,$(SWIFT_PACKAGE_SLUGS_EXCL_NO_UPDATE)): $(SWIFT_TARGET_PREFIX)update.%:
	@$(MAKE) -C $(call swift_package_slug_to_path,$*) -f $(ROOT_MAKEFILE) $(SWIFT_TARGET_PREFIX)_update

.PHONY: $(addprefix $(SWIFT_TARGET_PREFIX)update.,$(SWIFT_PACKAGE_SLUGS_NO_UPDATE))
$(addprefix $(SWIFT_TARGET_PREFIX)update.,$(SWIFT_PACKAGE_SLUGS_NO_UPDATE)): $(SWIFT_TARGET_PREFIX)update.%: $(SWIFT_TARGET_PREFIX)resolve.%

.PHONY: $(SWIFT_TARGET_PREFIX)_update
$(SWIFT_TARGET_PREFIX)_update:
	$(SWIFT_UPDATE)

# resolve, resolve.<swift package slug>

$(eval $(SWIFT_MK_VAR_PREFIX)RESOLVE_TARGETS := $$(addprefix $$(SWIFT_TARGET_PREFIX)resolve.,$$(SWIFT_PACKAGE_SLUGS)))

.PHONY: $(SWIFT_TARGET_PREFIX)resolve
$(SWIFT_TARGET_PREFIX)resolve: $($(SWIFT_MK_VAR_PREFIX)RESOLVE_TARGETS) ## Runs swift package resolve.

.PHONY: $($(SWIFT_MK_VAR_PREFIX)RESOLVE_TARGETS)
$($(SWIFT_MK_VAR_PREFIX)RESOLVE_TARGETS): $(SWIFT_TARGET_PREFIX)resolve.%:
	@$(MAKE) -C $(call swift_package_slug_to_path,$*) -f $(ROOT_MAKEFILE) $(SWIFT_TARGET_PREFIX)_resolve

.PHONY: $(SWIFT_TARGET_PREFIX)_resolve
$(SWIFT_TARGET_PREFIX)_resolve:
	$(SWIFT_RESOLVE)

# ---

##@ [Swift] Other Targets

.PHONY: $(SWIFT_TARGET_PREFIX)clean
$(SWIFT_TARGET_PREFIX)clean: ## Cleans up outputs of other targets, e.g. removing coverage files and .build dirs.
	$(foreach v,$($(SWIFT_MK_VAR_PREFIX)CLEAN_PATHS),$(_clean_TEMPLATE))
ifeq ($(IS_WINDOWS),true)
define _clean_TEMPLATE =
del /Q /S $(subst /,\,$v)

endef
else
define _clean_TEMPLATE =
rm -rf $v

endef
endif

.PHONY: $(SWIFT_TARGET_PREFIX)tools
$(SWIFT_TARGET_PREFIX)tools: ## Recommends tools to install (e.g., via Homebrew or Mint).
	@echo "This makefile relies on the following Swift tools:"
	$(foreach tool,$(SWIFT_TOOLS),$(_tools_TEMPLATE))
	@echo "Please install them e.g. 'brew install swiftformat swiftlint'."
define _tools_TEMPLATE =
@echo ' 	* $(tool)'

endef

.PHONY: $(SWIFT_TARGET_PREFIX)doc
$(SWIFT_TARGET_PREFIX)doc: ## Runs the swift-doc tool, serving on localhost.
ifeq ($(SWIFTDOC_FLAGS),$(_SWIFTDOC_FLAGS))
	@echo '##################################################'
	@echo '## Serving swift-doc on http://localhost:6060/  ##'
	@echo '## Press Ctrl+C to stop swift-doc server.       ##'
	@echo '##################################################'
	@echo
endif
	$(SWIFTDOC) $(SWIFTDOC_FLAGS)

.PHONY: $(SWIFT_TARGET_PREFIX)debug-vars
$(SWIFT_TARGET_PREFIX)debug-vars: ## Prints the values of the specified variables.
	$(foreach debug_var,$($(SWIFT_MK_VAR_PREFIX)DEBUG_VARS),$(_debug_vars_TEMPLATE))
define _debug_vars_TEMPLATE =
@echo $(debug_var)=$(call escape_command_arg,$($(debug_var)))

endef

# ---

# misc targets users can ignore

# we use .PHONY, but there's an edge case requiring this pattern
.PHONY: $(SWIFT_TARGET_PREFIX)FORCE
$(SWIFT_TARGET_PREFIX)FORCE:
