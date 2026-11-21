#!/bin/bash
# Build the real application model as a testable library and run it without launching the UI.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/storage-model-checks.XXXXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
mkdir -p .build/modules
flags=(-O -parse-as-library -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$project_dir/.build/modules")
xcrun swiftc "${flags[@]}" -emit-library -emit-module -module-name StorageCore \
    -emit-module-path "$build_dir/StorageCore.swiftmodule" Sources/StorageCore/*.swift -o "$build_dir/libStorageCore.dylib"
link=(-I "$build_dir" -L "$build_dir" -lStorageCore)
xcrun swiftc "${flags[@]}" "${link[@]}" -enable-testing -emit-library -emit-module -module-name StorageApp \
    -emit-module-path "$build_dir/StorageApp.swiftmodule" Sources/StorageApp/*.swift -o "$build_dir/libStorageApp.dylib"
xcrun swiftc "${flags[@]}" "${link[@]}" -lStorageApp Scripts/MonitoringModelChecks.swift -o "$build_dir/checks"
"$build_dir/checks" "$build_dir"
