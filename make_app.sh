#!/bin/bash
# Build and bundle MacSweep.app cleanly using SwiftPM + automatic code signing.
# Usage: ./make_app.sh [output_dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/dist}"
APP="$OUT/MacSweep.app"
NAME="MacSweepApp"
DISPLAY_NAME="MacSweep"
BUNDLE_ID="local.macsweep"
VERSION="${MACSWEEP_VERSION:-1.0.0}"
BUILD_NUMBER="${MACSWEEP_BUILD_NUMBER:-1}"

echo "==> Building release binary ($NAME)"
cd "$HERE"
swift build -c release --product "$NAME"

BIN="$(swift build -c release --show-bin-path)/$NAME"
if [ ! -f "$BIN" ]; then
    echo "Error: compiled binary not found at $BIN" >&2
    exit 1
fi

echo "==> Generating AppIcon.icns"
RES_TMP="$HERE/Resources"
mkdir -p "$RES_TMP"
ICON_PNG="$RES_TMP/AppIcon-1024.png"
ICONSET="$RES_TMP/AppIcon.iconset"
ICNS="$RES_TMP/AppIcon.icns"

if [ ! -f "$ICNS" ] || [ "$HERE/scripts/generate_icon.swift" -nt "$ICNS" ]; then
    swift "$HERE/scripts/generate_icon.swift" "$ICON_PNG"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z "$sz" "$sz" "$ICON_PNG" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        double=$((sz * 2))
        sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
    rm -rf "$ICONSET"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
chmod 755 "$APP/Contents/MacOS/$NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSAppDataUsageDescription</key><string>MacSweep scans application service files, caches, and browser extension manifests to calculate disk usage and assist with clean uninstallation.</string>
    <key>NSAppleEventsUsageDescription</key><string>MacSweep uses Finder to move protected or root-owned items to the Trash so they remain recoverable via Put Back.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>app</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Application Bundle</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Resolve signing identity: explicit env -> first Apple Development identity -> ad-hoc fallback
SIGN_IDENTITY="${MACSWEEP_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    AUTO_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2; exit}')"
    if [ -n "$AUTO_ID" ]; then
        SIGN_IDENTITY="$AUTO_ID"
    else
        SIGN_IDENTITY="-"
        echo "Warning: No 'Apple Development' signing identity found; falling back to ad-hoc ('-'). TCC grants may reset after rebuilds." >&2
    fi
fi

echo "==> Signing with identity: $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

echo "==> Done"
du -sh "$APP"
file "$APP/Contents/MacOS/$NAME"
echo "$APP"
