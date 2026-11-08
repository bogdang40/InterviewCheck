#!/bin/bash
# Install or verify the exact Eagle SDK used by the v3 C bindings.
# Existing files are never trusted by presence or by a generated checksum file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
THIRD_PARTY_DIR="$ROOT_DIR/third_party/picovoice/eagle"
RESOURCES_DIR="$ROOT_DIR/memanager/Resources"

EAGLE_VERSION="3.0.1"
EAGLE_TAG="3.0.1"
EAGLE_COMMIT="95cc16a80c16d6a24094e2da69f50749181f6538"
EAGLE_REPO="https://github.com/Picovoice/eagle"
CHECKSUM_FILE="$SCRIPT_DIR/eagle-sdk-3.0.1.sha256"
REQUIRED_FILES=(
    include/picovoice.h
    include/pv_eagle.h
    lib/arm64/libpv_eagle.dylib
    lib/x86_64/libpv_eagle.dylib
    eagle_params.pv
)
DOWNLOAD_DIR=""

log_info() { printf '[INFO] %s\n' "$1"; }
log_error() { printf '[ERROR] %s\n' "$1" >&2; }

cleanup() {
    if [[ -n "$DOWNLOAD_DIR" ]]; then
        rm -rf "$DOWNLOAD_DIR"
    fi
}
trap cleanup EXIT

verify_files() {
    local directory="$1"
    [[ -f "$CHECKSUM_FILE" ]] || { log_error "Missing pinned checksum manifest."; return 1; }
    (cd "$directory" && shasum -a 256 -c "$CHECKSUM_FILE") || {
        log_error "SDK files do not match Eagle $EAGLE_VERSION ($EAGLE_COMMIT)."
        return 1
    }
}

verify_existing() {
    verify_files "$THIRD_PARTY_DIR" || return 1
    if [[ ! -f "$THIRD_PARTY_DIR/VERSION" ]] ||
        [[ "$(cat "$THIRD_PARTY_DIR/VERSION")" != "$EAGLE_VERSION" ]]; then
        log_error "SDK version metadata is missing or incorrect. Expected $EAGLE_VERSION."
        return 1
    fi
    if ! cmp -s "$THIRD_PARTY_DIR/eagle_params.pv" "$RESOURCES_DIR/eagle_params.pv"; then
        log_error "Resources/eagle_params.pv does not match the pinned SDK model."
        return 1
    fi
}

has_existing_sdk() {
    local relative_path
    for relative_path in "${REQUIRED_FILES[@]}" VERSION CHECKSUMS.sha256; do
        [[ ! -e "$THIRD_PARTY_DIR/$relative_path" ]] || return 0
    done
    return 1
}

download_sdk() {
    DOWNLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/memanager-eagle.XXXXXX")"
    local source_dir="$DOWNLOAD_DIR/eagle"
    local staged_dir="$DOWNLOAD_DIR/staged"
    log_info "Fetching Eagle tag $EAGLE_TAG at $EAGLE_COMMIT."
    git clone --depth 1 --branch "$EAGLE_TAG" "$EAGLE_REPO" "$source_dir" || {
        log_error "Pinned Eagle SDK could not be fetched. Existing SDK files were preserved."
        return 1
    }
    if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$EAGLE_COMMIT" ]]; then
        log_error "Eagle tag does not resolve to the pinned commit. Existing SDK files were preserved."
        return 1
    fi

    mkdir -p "$staged_dir/include" "$staged_dir/lib/arm64" "$staged_dir/lib/x86_64"
    cp "$source_dir/include/picovoice.h" "$staged_dir/include/"
    cp "$source_dir/include/pv_eagle.h" "$staged_dir/include/"
    cp "$source_dir/lib/mac/arm64/libpv_eagle.dylib" "$staged_dir/lib/arm64/"
    cp "$source_dir/lib/mac/x86_64/libpv_eagle.dylib" "$staged_dir/lib/x86_64/"
    cp "$source_dir/lib/common/eagle_params.pv" "$staged_dir/"
    verify_files "$staged_dir" || return 1

    # Verify the complete download before replacing any installed file.
    local relative_path
    for relative_path in "${REQUIRED_FILES[@]}"; do
        mkdir -p "$(dirname "$THIRD_PARTY_DIR/$relative_path")"
        cp "$staged_dir/$relative_path" "$THIRD_PARTY_DIR/$relative_path"
    done
    mkdir -p "$RESOURCES_DIR"
    cp "$staged_dir/eagle_params.pv" "$RESOURCES_DIR/eagle_params.pv"
    cp "$CHECKSUM_FILE" "$THIRD_PARTY_DIR/CHECKSUMS.sha256"
    printf '%s\n' "$EAGLE_VERSION" > "$THIRD_PARTY_DIR/VERSION"
}

usage() {
    printf 'Usage: %s [--verify-only | --force | --help]\n' "$0"
    printf '  --verify-only  Check the pinned files and metadata without network or writes.\n'
    printf '  --force        Fetch and install the pinned SDK, replacing existing files.\n'
    printf 'Default: verify an existing SDK, or fetch the pinned SDK when absent.\n'
}

main() {
    local force_download=false
    local verify_only=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verify-only) verify_only=true ;;
            --force) force_download=true ;;
            --help) usage; return 0 ;;
            --generate-checksums)
                log_error "Checksums are pinned in source and cannot be regenerated from installed files."
                return 1
                ;;
            *) log_error "Unknown option: $1"; usage; return 1 ;;
        esac
        shift
    done
    if [[ "$verify_only" == true && "$force_download" == true ]]; then
        log_error "--verify-only cannot be combined with --force."
        return 1
    fi
    if [[ "$verify_only" == true ]]; then
        verify_existing || return 1
    elif [[ "$force_download" == true ]] || ! has_existing_sdk; then
        download_sdk
        verify_existing || return 1
    elif ! verify_existing; then
        log_error "Existing SDK was preserved. Review the mismatch before running --force to replace it."
        return 1
    fi
    log_info "Eagle $EAGLE_VERSION verified against the pinned checksum manifest."
}

main "$@"
