# Swift package build targets

SWIFT ?= swift

##@ Swift Package Targets

.PHONY: swift.all
swift.all: swift.build swift.test ## Build and test all Swift packages

.PHONY: swift.build
swift.build: swift.build.root swift.build.Server ## Build all Swift packages

.PHONY: swift.test
swift.test: swift.test.root swift.test.Server ## Test all Swift packages

.PHONY: swift.clean
swift.clean: ## Clean Swift build artifacts
	rm -rf .build
	rm -rf Server/.build

.PHONY: swift.build.root
swift.build.root: ## Build the root Swift package
	$(SWIFT) build -c release

.PHONY: swift.test.root
swift.test.root: ## Test the root Swift package
	$(SWIFT) test

.PHONY: swift.build.Server
swift.build.Server: ## Build the Server Swift package
	cd Server && $(SWIFT) build -c release

.PHONY: swift.test.Server
swift.test.Server: ## Test the Server Swift package
	cd Server && $(SWIFT) test