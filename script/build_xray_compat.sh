#!/usr/bin/env bash
# Rebuild TunnelDeck's opt-in REALITY compatibility profile from pinned Xray source.
set -euo pipefail

XRAY_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XRAY_SOURCE_ARCHIVE="$XRAY_ROOT_DIR/.runtime-sources/xray-v26.3.27-source.tar.gz"
XRAY_SOURCE_SHA256=992a4997e6bb846d11469435d687f99ef812fcde1e0a009bb8e95189ea20331d
XRAY_SOURCE_URL=https://github.com/XTLS/Xray-core/archive/refs/tags/v26.3.27.tar.gz

[[ "$(uname -m)" == "arm64" ]] || { echo "This Xray runtime lock is for Apple Silicon." >&2; exit 1; }
mkdir -p "$XRAY_ROOT_DIR/.runtime-sources" "$XRAY_ROOT_DIR/Runtime/xray"
if [[ ! -f "$XRAY_SOURCE_ARCHIVE" ]]; then
    XRAY_DOWNLOAD_PATH="$(mktemp "$XRAY_ROOT_DIR/.runtime-sources/xray-source-download.XXXXXX")"
    curl -L --fail --max-time 180 "$XRAY_SOURCE_URL" -o "$XRAY_DOWNLOAD_PATH"
    printf '%s  %s\n' "$XRAY_SOURCE_SHA256" "$XRAY_DOWNLOAD_PATH" | shasum -a 256 -c -
    mv "$XRAY_DOWNLOAD_PATH" "$XRAY_SOURCE_ARCHIVE"
fi
printf '%s  %s\n' "$XRAY_SOURCE_SHA256" "$XRAY_SOURCE_ARCHIVE" | shasum -a 256 -c -

# Always use a new directory: never reset or overwrite another source checkout.
XRAY_BUILD_DIR="$(mktemp -d "$XRAY_ROOT_DIR/.runtime-sources/xray-compat-build.XXXXXX")"
tar -xzf "$XRAY_SOURCE_ARCHIVE" -C "$XRAY_BUILD_DIR" --strip-components=1
cd "$XRAY_BUILD_DIR"
patch -p1 -i "$XRAY_ROOT_DIR/script/xray_compat.patch"

export GOCACHE="$XRAY_ROOT_DIR/.runtime-sources/go-cache"
export GOMODCACHE="$XRAY_ROOT_DIR/.runtime-sources/go-mod"
export GOTOOLCHAIN=go1.26.0
export CGO_ENABLED=0 GOOS=darwin GOARCH=arm64
go mod download
go test ./transport/internet/reality -run '^TestTunnelDeckSafari15' -count=1
go build -trimpath -buildvcs=false -gcflags=all=-l=4 \
    '-ldflags=-X github.com/xtls/xray-core/core.build=TunnelDeck.2 -s -w -buildid=' \
    -o "$XRAY_BUILD_DIR/xray-tunneldeck" ./main
install -m 755 "$XRAY_BUILD_DIR/xray-tunneldeck" "$XRAY_ROOT_DIR/Runtime/xray/xray"
"$XRAY_ROOT_DIR/Runtime/xray/xray" version
printf 'Xray compatibility source retained at %s\n' "$XRAY_BUILD_DIR"
