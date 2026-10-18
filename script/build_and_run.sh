#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TunnelDeck"
APP_EXECUTABLE="$APP_NAME"
APP_DISPLAY_NAME="$APP_NAME"
BUNDLE_ID="local.TunnelDeck"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
if [[ "$MODE" == "--preview" || "$MODE" == "--routing-preview" ]]; then
    APP_BUNDLE="$ROOT_DIR/dist/TunnelDeck Preview.app"
    BUNDLE_ID="local.TunnelDeck.Preview"
    APP_EXECUTABLE="TunnelDeckPreview"
    APP_DISPLAY_NAME="TunnelDeck Preview"
fi
mkdir -p "$ROOT_DIR/dist"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/dist/.bundle-XXXXXX")"
STAGED_BUNDLE="$STAGING_DIR/$APP_NAME.app"
CONTENTS="$STAGED_BUNDLE/Contents"
cd "$ROOT_DIR"
python3 "$ROOT_DIR/script/runtime_manifest.py" "$ROOT_DIR/Runtime" --verify-pins
python3 "$ROOT_DIR/script/verify_openconnect.py" "$ROOT_DIR/Runtime/bin/openconnect"

if [[ "$MODE" != "--build-only" && "$MODE" != "--preview" && "$MODE" != "--routing-preview" ]]; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
swift build
BUILD_DIR="$(swift build --show-bin-path)"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"
bash "$ROOT_DIR/script/build_icon.sh" "$CONTENTS/Resources/AppIcon.icns"
cp "$BUILD_DIR/TunnelDeck" "$CONTENTS/MacOS/$APP_EXECUTABLE"
cp "$BUILD_DIR/TunnelDeckHelper" "$CONTENTS/Helpers/TunnelDeckHelper"
/usr/bin/ditto "$BUILD_DIR/TunnelDeck_TunnelLocalization.bundle" "$CONTENTS/Resources/TunnelDeck_TunnelLocalization.bundle"
for language in ru en-US; do
    mkdir -p "$CONTENTS/Resources/$language.lproj"
    cp "$ROOT_DIR/Sources/TunnelLocalization/Resources/$language.lproj/InfoPlist.strings" "$CONTENTS/Resources/$language.lproj/InfoPlist.strings"
done
/usr/bin/ditto "$ROOT_DIR/Runtime" "$CONTENTS/Resources/Runtime"
mkdir -p "$CONTENTS/Resources/Runtime/source"
cp "$ROOT_DIR/script/xray_compat.patch" "$CONTENTS/Resources/Runtime/source/xray_compat.patch"
cp "$ROOT_DIR/script/build_xray_compat.sh" "$CONTENTS/Resources/Runtime/source/build_xray_compat.sh"
cp "$ROOT_DIR/script/build_openconnect.sh" "$CONTENTS/Resources/Runtime/source/build_openconnect.sh"
cp "$ROOT_DIR/script/verify_openconnect.py" "$CONTENTS/Resources/Runtime/source/verify_openconnect.py"
cp "$ROOT_DIR/script/prepare_geoip.py" "$CONTENTS/Resources/Runtime/source/prepare_geoip.py"
/usr/bin/ditto "$ROOT_DIR/script/xray-routing" "$CONTENTS/Resources/Runtime/source/xray-routing"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>TunnelDeck</string>
  <key>CFBundleIdentifier</key><string>local.TunnelDeck</string>
  <key>CFBundleName</key><string>TunnelDeck</string>
  <key>CFBundleDisplayName</key><string>TunnelDeck</string>
  <key>CFBundleDevelopmentRegion</key><string>en-US</string>
  <key>CFBundleLocalizations</key><array><string>ru</string><string>en-US</string></array>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>Allow TunnelDeck to request macOS permission to configure a VPN connection.</string>
  <key>NSHumanReadableCopyright</key><string>TunnelDeck. Third-party engine licenses are included in Resources/Runtime.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_EXECUTABLE" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_DISPLAY_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_DISPLAY_NAME" "$CONTENTS/Info.plist"
for binary in "$CONTENTS/Helpers/TunnelDeckHelper" "$CONTENTS/Resources/Runtime/bin/openconnect" "$CONTENTS/Resources/Runtime/bin/amneziawg-go" "$CONTENTS/Resources/Runtime/bin/awg" "$CONTENTS/Resources/Runtime/bin/hev-socks5-tunnel" "$CONTENTS/Resources/Runtime/xray/xray"; do
    if [[ -f "$binary" ]]; then /usr/bin/codesign --force --sign - --timestamp=none "$binary"; fi
done
python3 "$ROOT_DIR/script/runtime_manifest.py" "$CONTENTS/Resources/Runtime"
/usr/bin/codesign --force --sign - --timestamp=none "$STAGED_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$STAGED_BUNDLE"
# Replace complete bundles, preserving mapped executables of a running build.
if [[ -d "$APP_BUNDLE" ]]; then
    mkdir -p "$ROOT_DIR/dist/.previous"
    mv "$APP_BUNDLE" "$ROOT_DIR/dist/.previous/TunnelDeck-$(uuidgen).app"
fi
mv "$STAGED_BUNDLE" "$APP_BUNDLE"
rmdir "$STAGING_DIR"

case "$MODE" in
  --build-only) echo "Built: $APP_BUNDLE" ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "Launched: $APP_BUNDLE"
    ;;
  --preview)
    /usr/bin/open -n "$APP_BUNDLE" --args --design-preview "${@:2}"
    ;;
  --routing-preview)
    /usr/bin/open -n "$APP_BUNDLE" --args --design-preview --routing-preview "${@:2}"
    ;;
  --debug|debug) lldb -- "$CONTENTS/MacOS/TunnelDeck" ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "TunnelDeck"'
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.TunnelDeck"'
    ;;
  *) echo "usage: $0 [run|--build-only|--verify|--preview|--routing-preview|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
