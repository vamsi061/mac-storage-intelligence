#!/bin/bash
# Run the same fixture assertions as XCTest using the standalone macOS Command Line Tools.
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--mount-boundary" ) ]]; then
    echo "Usage: $0 [--mount-boundary]" >&2
    exit 2
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/storage-scanner-checks.XXXXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
mkdir -p "$project_dir/.build/modules"

xcrun swiftc -O -parse-as-library -D STORAGE_FIXTURE_RUNNER \
    -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$project_dir/.build/modules" \
    "$project_dir"/Sources/StorageCore/*.swift \
    "$project_dir"/Tests/StorageCoreTests/*.swift \
    -o "$build_dir/checks"
if [[ $# -eq 1 ]]; then
    "$project_dir/Scripts/test-mount-boundary.sh" "$build_dir/checks"
else
    "$build_dir/checks"
fi
