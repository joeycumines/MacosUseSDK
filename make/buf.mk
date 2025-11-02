BUF ?= buf
BUF_FLAGS ?=

.PHONY: buf.format
buf.format: ## Format protobuf files in-place using `buf format -w`.
	$(BUF) $(BUF_FLAGS) format -w
