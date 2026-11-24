#!/bin/bash
# Build and bundle MacSweep.app cleanly using SwiftPM, with auto-versioning,
# code signing (Apple Development / Developer ID / ad-hoc), optional notarization,
# standalone zip packaging, and optional --install to /Applications (removing the
# duplicate dist/MacSweep.app bundle so Spotlight only shows one MacSweep.app).
# Usage: ./make_app.sh [--install] [output_dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_TO_APPLICATIONS=0
OUT=""
for arg in "$@"; do
    if [ "$arg" = "--install" ]; then
        INSTALL_TO_APPLICATIONS=1
    elif [ -z "$OUT" ]; then
        OUT="$arg"
    fi
done
OUT="${OUT:-$HERE/dist}"
APP="$OUT/MacSweep.app"
NAME="MacSweepApp"
DISPLAY_NAME="MacSweep"
BUNDLE_ID="local.macsweep"
VERSION_BASE_COMMIT="db3f7dcb717ffd52736914cd3e0ad89de91d506f"

if [ -n "${MACSWEEP_VERSION:-}" ]; then
    VERSION="$MACSWEEP_VERSION"
    BUILD_NUMBER="${MACSWEEP_BUILD_NUMBER:-1}"
elif git -C "$HERE" rev-parse --verify "${VERSION_BASE_COMMIT}^{commit}" >/dev/null 2>&1; then
    COMMITS_SINCE_BASE="$(git -C "$HERE" rev-list --count "${VERSION_BASE_COMMIT}..HEAD")"
    PATCH_COUNT=$((COMMITS_SINCE_BASE > 0 ? COMMITS_SINCE_BASE - 1 : 0))
    VERSION="1.0.${PATCH_COUNT}"
    BUILD_NUMBER="$((PATCH_COUNT + 1))"
else
    VERSION="1.0.0"
    BUILD_NUMBER="1"
fi

if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,3}(-[A-Za-z0-9.-]+)?$'; then
    echo "Error: Invalid VERSION format: $VERSION" >&2
    exit 1
fi
if ! printf '%s' "$BUILD_NUMBER" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
    echo "Error: Invalid BUILD_NUMBER format: $BUILD_NUMBER" >&2
    exit 1
fi

NOTARY_PROFILE="${MACSWEEP_NOTARY_PROFILE:-}"

# Resolve signing identity: explicit env -> first Apple Development identity -> ad-hoc fallback
if [ "${MACSWEEP_SIGN_IDENTITY+set}" = "set" ] && [ -n "${MACSWEEP_SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY="$MACSWEEP_SIGN_IDENTITY"
else
    AUTO_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2; exit}' || true)"
    if [ -n "$AUTO_ID" ]; then
        SIGN_IDENTITY="$AUTO_ID"
    else
        SIGN_IDENTITY="-"
        echo "Warning: No 'Apple Development' signing identity found; falling back to ad-hoc ('-'). TCC grants may reset after rebuilds." >&2
    fi
fi

if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Error: Notarization requires MACSWEEP_SIGN_IDENTITY set to a Developer ID Application identity." >&2
    exit 1
fi

echo "==> Building release binary ($NAME, v${VERSION} build ${BUILD_NUMBER})"
cd "$HERE"
build_args=(-c release)
if [ -n "${MACSWEEP_SCRATCH_PATH:-}" ]; then
    build_args+=(--scratch-path "$MACSWEEP_SCRATCH_PATH")
fi
swift build "${build_args[@]}" --product "$NAME"

BIN="$(swift build "${build_args[@]}" --show-bin-path)/$NAME"
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

if [ ! -f "$ICON_PNG" ] || [ "$HERE/scripts/generate_icon.swift" -nt "$ICON_PNG" ]; then
    swift "$HERE/scripts/generate_icon.swift" "$ICON_PNG"
fi

if [ ! -f "$ICNS" ] || [ "$ICON_PNG" -nt "$ICNS" ]; then
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
if [ -f "$HERE/LICENSE" ]; then
    cp "$HERE/LICENSE" "$APP/Contents/Resources/LICENSE"
fi

MIN_MACOS="$(otool -l "$APP/Contents/MacOS/$NAME" |
    awk '
        /cmd LC_BUILD_VERSION/ { build=1; next }
        build && $1=="minos" { print $2; build=0 }
        /cmd LC_VERSION_MIN_MACOSX/ { legacy=1; next }
        legacy && $1=="version" { print $2; legacy=0 }
    ' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
MIN_MACOS="${MIN_MACOS:-14.0}"

ARCH="$(lipo -archs "$APP/Contents/MacOS/$NAME")"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "Error: Unsupported output architecture: $ARCH" >&2; exit 1 ;;
esac

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
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 MacSweep Contributors</string>
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

echo "==> Signing (${ARCH}, macOS ${MIN_MACOS}+) with identity: $SIGN_IDENTITY"
# Always enable Hardened Runtime (blocks DYLD_INSERT_LIBRARIES / debugger attach).
# MacSweep has zero bundled third-party dylibs, so Library Validation works even with ad-hoc signing.
sign_args=(--force --sign "$SIGN_IDENTITY" --options runtime)
if [ "$SIGN_IDENTITY" != "-" ]; then
    sign_args+=(--timestamp)
fi
codesign "${sign_args[@]}" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

ZIP_OUT="$OUT/${DISPLAY_NAME}-${ARCH}.zip"
ZIP_TMP_DIR="$(mktemp -d "$OUT/.${DISPLAY_NAME}-zip.XXXXXXXXXX")"
ZIP_TMP="$ZIP_TMP_DIR/${DISPLAY_NAME}-${ARCH}.zip"
trap 'rm -rf "$ZIP_TMP_DIR"' EXIT
ditto -c -k --norsrc --keepParent "$APP" "$ZIP_TMP"
if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$ZIP_TMP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$ZIP_TMP"
    ditto -c -k --norsrc --keepParent "$APP" "$ZIP_TMP"
fi
mv -f "$ZIP_TMP" "$ZIP_OUT"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ "$INSTALL_TO_APPLICATIONS" -eq 1 ]; then
    INSTALL_APP="/Applications/${DISPLAY_NAME}.app"
    echo "==> Installing to $INSTALL_APP"
    rm -rf "$INSTALL_APP"
    ditto "$APP" "$INSTALL_APP"
    codesign --verify --deep --strict --verbose=1 "$INSTALL_APP"
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
        "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
    fi
    rm -rf "$APP"
    echo "==> Done (installed to $INSTALL_APP; removed duplicate $APP)"
    du -sh "$INSTALL_APP" "$ZIP_OUT"
    file "$INSTALL_APP/Contents/MacOS/$NAME"
    echo "$INSTALL_APP"
else
    echo "==> Done"
    du -sh "$APP" "$ZIP_OUT"
    file "$APP/Contents/MacOS/$NAME"
    echo "$APP"
fi
