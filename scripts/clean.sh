#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"

echo "=== Cleaning build artifacts ==="

shopt -s nullglob
derived_data_paths=( "$BUILD_DIR"/DerivedData* )
shopt -u nullglob

if [ "${#derived_data_paths[@]}" -gt 0 ]; then
    echo "Removing ${#derived_data_paths[@]} DerivedData directories from $BUILD_DIR"
    rm -rf "${derived_data_paths[@]}"
else
    echo "No DerivedData directories found in $BUILD_DIR"
fi

rm -rf "$BUILD_DIR/Build"
rm -rf "$BUILD_DIR/Release"
rm -rf "$BUILD_DIR/CompilationCache.noindex"
rm -rf "$BUILD_DIR/ModuleCache.noindex"
rm -rf "$BUILD_DIR/Logs"
rm -rf "$BUILD_DIR/SDKStatCaches.noindex"
rm -rf "$BUILD_DIR/xcresult-export"

echo "Cleaned project build directory"

# Optionally clean system Xcode DerivedData
if [[ "${1:-}" == "--all" ]]; then
    echo "Cleaning system Xcode DerivedData..."
    rm -rf ~/Library/Developer/Xcode/DerivedData/memanager-*/
    echo "Cleaned system DerivedData"
else
    echo ""
    echo "To also clean system Xcode DerivedData, run:"
    echo "  ./scripts/clean.sh --all"
fi

echo ""
echo "=== Clean complete ==="
