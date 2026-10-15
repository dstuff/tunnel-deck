#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/Resources/AppIcon.png"
OUTPUT="${1:-$ROOT_DIR/Resources/AppIcon.icns}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tunneldeck-icon-XXXXXX")"
ICONSET="$WORK_DIR/AppIcon.iconset"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$SOURCE" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" "$SOURCE" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

/usr/bin/iconutil --convert icns "$ICONSET" --output "$OUTPUT"
echo "Icon: $OUTPUT"
