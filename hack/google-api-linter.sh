#!/bin/sh

# This script runs the Google API linter with the correct proto paths.
# It exports the main protos and their googleapis dependencies to a temp dir.
# It does not use 'set -e' and checks for errors explicitly.

set -x # Print commands as they are executed

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
# POSIX-compliant trap for EXIT
trap 'echo "Cleaning up $TEMP_DIR"; rm -rf "$TEMP_DIR"' EXIT

echo "Staging protos in $TEMP_DIR"

# 4. Export main protos (from 'proto' directory) to the temp dir
# This exports the 'proto' module, which is rooted at 'proto'
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

echo "Running api-linter..."

# 6. Run the linter from the dedicated Go module
# We lint all .proto files found under '$TEMP_DIR/macosusesdk'
# We set --proto-path="$TEMP_DIR" so it can find both 'macosusesdk/' and 'google/'
(cd "$LINTER_MODULE_DIR" && go run github.com/googleapis/api-linter/cmd/api-linter \
    --config "$CONFIG_FILE" \
    --output-format "yaml" \
    --set-exit-status \
    --proto-path "$TEMP_DIR" \
    $(find "$TEMP_DIR/macosusesdk" -name "*.proto"))

LINTER_EXIT_CODE=$?
if [ $LINTER_EXIT_CODE -ne 0 ]; then
    echo "::error::API linter found issues."
    exit $LINTER_EXIT_CODE
fi

echo "API linter finished successfully."
exit 0