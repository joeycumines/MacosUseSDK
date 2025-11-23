#!/usr/bin/env bash

# This script runs the Google API linter with the correct proto paths.
# It exports the main protos and their googleapis dependencies to a temp dir.

set -o pipefail || exit 1

SCRIPT_DIR=$(dirname "$0")
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LINTER_MODULE_DIR="$REPO_ROOT/hack/google-api-linter"
CONFIG_FILE="$REPO_ROOT/google-api-linter.yaml"

if ! TEMP_DIR=$(mktemp -d); then
  echo "::error::Failed to create temporary directory."
  exit 1
fi

trap 'exit_code="$?"; trap - EXIT; rm -rf "$TEMP_DIR"; exit "$exit_code"' EXIT TERM INT

if ! (cd "$REPO_ROOT" && buf export . --output "$TEMP_DIR"); then
  echo "::error::'buf export .' (main protos) failed."
  exit 1
fi

if ! (cd "$REPO_ROOT" && buf export buf.build/googleapis/googleapis --output "$TEMP_DIR"); then
  echo "::error::'buf export googleapis' failed."
  exit 1
fi

find "$TEMP_DIR/macosusesdk" -name "*.proto" \
  -exec go -C "$LINTER_MODULE_DIR" tool github.com/googleapis/api-linter/cmd/api-linter \
  --config="$CONFIG_FILE" \
  --output-format=github \
  --set-exit-status \
  --proto-path="$TEMP_DIR" \
  {} + |
  sed 's/^::error file=/::error file=proto\//'

LINTER_EXIT_CODE="$?"

if ! [ "$LINTER_EXIT_CODE" -eq 0 ]; then
  echo "::error::API linter found issues."
  exit "$LINTER_EXIT_CODE"
fi
