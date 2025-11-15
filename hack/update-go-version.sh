#!/bin/sh

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 <go-version>"
  exit 1
fi

find . -name ".build" -prune -o -name "go.mod" \
  -exec echo "[Go $1]" Updating {} \; \
  -exec go mod edit -go="$1" -toolchain= {} \;
