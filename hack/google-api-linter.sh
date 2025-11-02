#!/usr/bin/env bash

# This script runs the Google API linter with the correct proto paths.
# It exports the main protos and their googleapis dependencies to a temp dir.

set -o pipefail || exit 1

# 1. Define paths
SCRIPT_DIR=$(dirname "$0")
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LINTER_MODULE_DIR="$REPO_ROOT/hack/google-api-linter"
CONFIG_FILE="$REPO_ROOT/google-api-linter.yaml"

# 2. Create a temporary directory
TEMP_DIR=$(mktemp -d)
if [ $? -ne 0 ]; then
  echo "::error::Failed to create temporary directory."
  exit 1
fi

# 3. Set a trap to clean up the temp directory on exit
trap 'exit_code=0; trap - EXIT; rm -rf "$TEMP_DIR"; exit "$?"' EXIT TERM INT

# 4. Export main protos (from 'proto' directory) to the temp dir
(cd "$REPO_ROOT" && buf export . --output "$TEMP_DIR")
if [ $? -ne 0 ]; then
  echo "::error::'buf export .' (main protos) failed."
  exit 1
fi

# 5. Export googleapis dependencies to the temp dir
(cd "$REPO_ROOT" && buf export buf.build/googleapis/googleapis --output "$TEMP_DIR")
if [ $? -ne 0 ]; then
  echo "::error::'buf export googleapis' failed."
  exit 1
fi

# 6. Run the linter from the dedicated Go module
(cd "$LINTER_MODULE_DIR" &&
  find "$TEMP_DIR/macosusesdk" -name "*.proto" -exec go tool github.com/googleapis/api-linter/cmd/api-linter \
    --config="$CONFIG_FILE" \
    --output-format=github \
    --set-exit-status \
    --proto-path="$TEMP_DIR" \
    {} + |
  sed 's/^::error file=/::error file=proto\//')

LINTER_EXIT_CODE="$?"

if ! [ "$LINTER_EXIT_CODE" -eq 0 ]; then
  echo "::error::API linter found issues."
  exit "$LINTER_EXIT_CODE"
fi
